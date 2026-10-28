param(
  [string]$Question,
  [string]$QuestionFile,
  [int]$MaxWaitSec = 240,
  [string]$ImageOut = "",
  [string]$FilePath = ""
)
if (-not $Question -and $QuestionFile) { $Question = [IO.File]::ReadAllText($QuestionFile, [Text.Encoding]::UTF8) }
if (-not $Question) { Write-Output "ERROR_NO_QUESTION"; exit 7 }
# Sends a question to the Google Gemini desktop app (UI Automation) and prints its answer.
# Every step is verified: the text must land in the editor, the question must appear in the
# chat as a "You said ..." line, and the answer is taken only from AFTER that line, so an
# older chat on screen can never be returned as the answer.
# Image answers are also supported: a large Image control named "... AI generated ..." that
# appears after our question counts as a finished answer; it is screen-captured (the app's own
# Download button does not work reliably) and its path is printed as "IMAGE_SAVED <path>".
# Exit codes: 0 ok, 2 no window, 3 no editor, 4 send button not found, 5 no answer/timeout, 6 question not sent, 7 no question given.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Native {
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, int e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@
$ErrorActionPreference = "Stop"

function Die([string]$msg, [int]$code) {
  if (-not $srOn) { [void][Native]::SystemParametersInfo(0x0047, 0, [IntPtr]::Zero, 2) }
  Write-Output $msg
  exit $code
}

# Chromium builds its accessibility tree only when a screen reader is active; turn it on,
# remember the previous state, and restore it at the end.
$srOn = $false
try {
  $pv = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
  [void][Native]::SystemParametersInfo(0x0046, 0, $pv, 0)  # SPI_GETSCREENREADER
  $srOn = [Runtime.InteropServices.Marshal]::ReadInt32($pv) -ne 0
  [Runtime.InteropServices.Marshal]::FreeHGlobal($pv)
} catch {}
if (-not $srOn) { [void][Native]::SystemParametersInfo(0x0047, 1, [IntPtr]::Zero, 2) }

$exe = "$env:LOCALAPPDATA\Google\Gemini\Gemini.exe"

function Get-Win {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Gemini')
  $ws = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
  if ($ws.Count -eq 0) { return $null }
  return $ws[0]
}

$editCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
$btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$textCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
$imgCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Image)
$linkCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Hyperlink)

function Find-Editor($w) {
  foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $editCond)) { if ($e.Current.Name -match 'prompt') { return $e } }
  return $null
}
function Find-Button($w, [string]$nameRegex) {
  foreach ($b in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $btnCond)) { if ($b.Current.Name -match $nameRegex) { return $b } }
  return $null
}
function Find-AiImages($w) {
  # large Image controls that the app marks as AI-generated, in tree order
  $list = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
  foreach ($im in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $imgCond)) {
    if ($im.Current.Name -match 'AI generated' -and $im.Current.BoundingRectangle.Width -gt 100) { $list.Add($im) }
  }
  return ,$list
}
function Save-AiImage($im, [string]$path) {
  $r = $im.Current.BoundingRectangle
  $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, (New-Object System.Drawing.Size ([int]$r.Width), ([int]$r.Height)))
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
function Get-AllText($w) {
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($t in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $textCond)) { $lines.Add($t.Current.Name) }
  return ,($lines.ToArray())
}
function Norm([string]$s) {
  if (-not $s) { return "" }
  return (($s.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]',''))
}
$normQ = Norm $Question
if ($normQ.Length -gt 40) { $qKey = $normQ.Substring(0,40) } else { $qKey = $normQ }

function Find-QuestionEcho([string[]]$lines) {
  # last line like "You said <question...>" matching our question
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $l = $lines[$i]
    if ($l -match '^\s*You said\b' -and (Norm $l).Contains($qKey)) { return $i }
  }
  return -1
}
function Extract-Answer([string[]]$lines) {
  $echo = Find-QuestionEcho $lines
  if ($echo -lt 0) { return "" }
  $saidIdx = -1
  for ($i = $echo + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Gemini said\s*$') { $saidIdx = $i; break } }
  if ($saidIdx -lt 0) { return "" }
  $sb = New-Object System.Text.StringBuilder
  for ($i = $saidIdx + 1; $i -lt $lines.Count; $i++) {
    $l = $lines[$i].Trim()
    if ($l -match '^(Ask Gemini|Gemini is AI and can make mistakes|Play|About Gemini|Get Gemini App|Subscriptions|For Business)\b') { break }
    [void]$sb.AppendLine($l)
  }
  return $sb.ToString().Trim()
}

# Start the app if it is not running
$win = Get-Win
if (-not $win) {
  if (-not (Test-Path $exe)) { Die "ERROR_NO_WINDOW" 2 }
  Start-Process $exe
  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $win = Get-Win
    if ($win) { break }
  }
}
if (-not $win) { Die "ERROR_NO_WINDOW" 2 }

[void][Native]::ShowWindow($win.Current.NativeWindowHandle, 9)
[void][Native]::SetForegroundWindow($win.Current.NativeWindowHandle)
Start-Sleep -Milliseconds 500

# Try to start a fresh chat (best effort; correct answer extraction does not depend on it)
foreach ($l in $win.FindAll([System.Windows.Automation.TreeScope]::Subtree, $linkCond)) {
  if ($l.Current.Name -eq 'New chat') {
    try {
      $inv = $l.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $inv.Invoke()
      Start-Sleep -Seconds 2
    } catch {}
    break
  }
}

# Attach a real file: put it on the clipboard as a file drop (CF_HDROP) and Ctrl+V into the
# editor, so the app itself uploads it as an attachment (not as pasted text).
if ($FilePath) {
  if (-not (Test-Path $FilePath)) { Die "ERROR_FILE_NOT_FOUND" 8 }
  $FilePath = (Resolve-Path $FilePath).Path
  $baseName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
  Set-Clipboard -Path $FilePath
  $w = Get-Win
  if (-not $w) { Die "ERROR_NO_WINDOW" 2 }
  [void][Native]::SetForegroundWindow($w.Current.NativeWindowHandle)
  Start-Sleep -Milliseconds 500
  $ed = Find-Editor $w
  if (-not $ed) { Die "ERROR_NO_EDITOR" 3 }
  $r = $ed.Current.BoundingRectangle
  [Windows.Forms.Cursor]::Position = New-Object Drawing.Point([int]($r.X + $r.Width/2), [int]($r.Y + [Math]::Max(1,$r.Height/2)))
  Start-Sleep -Milliseconds 200
  [Native]::mouse_event(2,0,0,0,0); [Native]::mouse_event(4,0,0,0,0)
  Start-Sleep -Milliseconds 400
  [Native]::keybd_event(0x11,0,0,[UIntPtr]::Zero)
  [Native]::keybd_event(0x56,0,0,[UIntPtr]::Zero)
  [Native]::keybd_event(0x56,0,2,[UIntPtr]::Zero)
  [Native]::keybd_event(0x11,0,2,[UIntPtr]::Zero)
  # wait until a chip/button mentioning the file name appears (upload accepted)
  $attached = $false
  $attDeadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $attDeadline) {
    Start-Sleep -Milliseconds 800
    $w = Get-Win
    if (-not $w) { continue }
    $hit = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $baseName)))
    if ($hit) { $attached = $true; break }
    $txt = Get-AllText $w
    if (($txt | Where-Object { $_ -match [regex]::Escape($baseName) }).Count -gt 0) { $attached = $true; break }
  }
  if (-not $attached) { Die "ERROR_ATTACHMENT_NOT_ACCEPTED" 9 }
  Write-Output "ATTACHED $FilePath"
  Start-Sleep -Milliseconds 800
}

$attempts = 0
while ($true) {
  $attempts++
  $win = Get-Win
  $editor = Find-Editor $win
  if (-not $editor) { Die "ERROR_NO_EDITOR" 3 }

  # type the question and verify it really landed in the editor
  $typed = $false
  for ($try = 0; $try -lt 3; $try++) {
    $vp = $editor.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $vp.SetValue($Question)
    Start-Sleep -Milliseconds 700
    $win2 = Get-Win
    $ed2 = Find-Editor $win2
    $val = ""
    try { $vp2 = $ed2.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); $val = $vp2.Current.Value } catch {}
    if ((Norm $val).Contains($qKey)) { $typed = $true; $editor = $ed2; break }
    $editor = $ed2
    Start-Sleep -Milliseconds 400
  }
  if (-not $typed) { Die "ERROR_TYPE_FAILED" 6 }

  $win = Get-Win
  $send = Find-Button $win '^Send message$'
  if (-not $send) { Die "ERROR_NO_SEND_BUTTON" 4 }
  $inv = $send.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $inv.Invoke()

  # wait for the question to appear in the chat as "You said ..."
  $sent = $false
  $sentDeadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $sentDeadline) {
    $w = Get-Win
    if ($w -and ((Find-QuestionEcho (Get-AllText $w)) -ge 0)) { $sent = $true; break }
    Start-Sleep -Milliseconds 1000
  }
  if ($sent) { break }
  if ($attempts -ge 2) { Die "ERROR_NOT_SENT" 6 }
  Write-Output "RETRY_SEND"
}

# count AI-generated images already on screen, so only a NEW one counts as our answer
$baselineImgs = (Find-AiImages (Get-Win)).Count

# Wait for the answer: a "Gemini said" reply after our echo, or a NEW AI-generated image;
# then no Stop button and text stable 3x
$prev = ""
$stable = 0
$started = Get-Date
Start-Sleep -Seconds 5
$last = @()
while (((Get-Date) - $started).TotalSeconds -lt $MaxWaitSec) {
  $w = Get-Win
  if (-not $w) { Start-Sleep -Seconds 2; continue }
  $lines = Get-AllText $w
  $stop = Find-Button $w 'Stop'
  $cur = ($lines -join "`n")
  $hasAnswerAfter = ((Extract-Answer $lines).Length -gt 0) -or ((Find-AiImages $w).Count -gt $baselineImgs)
  if ((-not $stop) -and $hasAnswerAfter -and ($cur -eq $prev) -and ($cur.Trim().Length -gt 0)) { $stable++ } else { $stable = 0 }
  $prev = $cur
  $last = $lines
  if ($stable -ge 3) { break }
  Start-Sleep -Seconds 2
}

$answer = Extract-Answer $last
$imgPath = ""
$newImgs = Find-AiImages (Get-Win)
if ($newImgs.Count -gt $baselineImgs) {
  # keep the window in front and grab the newest generated image by screen capture;
  # the app's own Download button does not reliably produce a file
  [void][Native]::SetForegroundWindow((Get-Win).Current.NativeWindowHandle)
  Start-Sleep -Milliseconds 600
  $im = (Find-AiImages (Get-Win)) | Select-Object -Last 1
  if ($ImageOut) { $imgPath = $ImageOut }
  else { $imgPath = Join-Path $env:TEMP ("gemini-image-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".png") }
  try {
    Save-AiImage $im $imgPath
    Write-Output "IMAGE_SAVED $imgPath"
  } catch {
    Write-Output "IMAGE_CAPTURE_FAILED $($_.Exception.Message)"
    $imgPath = ""
  }
}
if (-not $answer -and -not $imgPath) {
  if ($stable -lt 3) { Die "TIMEOUT_NO_ANSWER" 5 }
  Die "ERROR_NO_ANSWER" 5
}
if ($answer) {
  Write-Output "ANSWER_START"
  Write-Output $answer
  Write-Output "ANSWER_END"
}

# restore screen reader flag if we were the ones who enabled it
if (-not $srOn) { [void][Native]::SystemParametersInfo(0x0047, 0, [IntPtr]::Zero, 2) }
