param(
  [string]$Question,
  [string]$QuestionFile,
  [int]$MaxWaitSec = 240,
  [string]$ImageOut = "",
  [string]$VideoOut = "",
  [string]$FilePath = "",
  [switch]$VideoMode
)
if (-not $Question -and $QuestionFile) { $Question = [IO.File]::ReadAllText($QuestionFile, [Text.Encoding]::UTF8) }
if (-not $Question) { Write-Output "ERROR_NO_QUESTION"; exit 7 }
# Sends a question to the Google Gemini desktop app (UI Automation) and prints its answer.
# Every step is verified: the text must land in the editor, the question must appear in the
# chat as a "You said ..." line, and the answer is taken only from AFTER that line, so an
# older chat on screen can never be returned as the answer.
# Image answers are also supported: a large Image control named "... AI generated ..." that
# appears after our question counts as a finished answer. The app's own
# "Download full size image" button IS clicked (it works): after the blob download finishes
# (~2-3 min) the app opens a native Save As dialog (#32770, title "blob:...", INVISIBLE to UIA
# desktop-tree FindAll). The script finds it via raw EnumWindows, types the full target path
# into the name edit (control id 1001, WM_SETTEXT), presses "Save" (GetDlgItem id 1, BM_CLICK)
# -> the image lands straight in the project dir and the dialog is never left open. Path is
# printed as "IMAGE_SAVED <path>". Screen capture of the Image element is only a fallback.
# Video answers (Veo) are supported the same way: the video card has NO ControlType.Video and
# NO 'AI generated' Image; it is recognized by an exact-name Button "Download video" that
# appears after the question. Clicking it opens the same native Save As dialog (mp4 default
# name); the file lands in the project as-is and is printed as "VIDEO_SAVED <path>".
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
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, int e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  // Win32 dialog driving (the Save As dialog is a native #32770 invisible in the UIA desktop tree)
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, string l);
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
[void][Native]::SetProcessDPIAware()  # physical pixels must match UIA BoundingRectangle

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
function Find-VideoButtons($w) {
  # the video card has no ControlType.Video and no 'AI generated' Image element; it is
  # recognized ONLY by exact-name buttons 'Download video'/'Share video'/'Mute video'/
  # 'Play video'. Match must be exact: the chat sidebar has 'More options for <chat>'
  # buttons whose titles may themselves contain the word for "video".
  $list = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
  foreach ($b in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $btnCond)) {
    if ($b.Current.Name -eq 'Download video') { $list.Add($b) }
  }
  return ,$list
}
function Test-VideoModeOn($w) {
  # Reliable marker of "Create video" mode: the empty editor's ValuePattern value is the
  # placeholder text, which is 'Describe your video' in video mode and 'Ask Gemini' in
  # normal mode. (The editor toolbar also gains 'Aspect ratio' + 'Deselect Videos'
  # buttons; the checkbox's own ToggleState is None/empty and useless — and it PERSISTS
  # across chats and app restarts, so a blind Toggle() flips it OFF when it was ON.)
  $ed = Find-Editor $w
  if (-not $ed) { return $false }
  try {
    $v = ($ed.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value
    return ($v -match 'Describe your video')
  } catch { return $false }
}
function Toggle-VideoModeByClick {
  # TogglePattern.Toggle() switches the UI (placeholder/chips) but the app may still
  # route the request to the text model ("Я всего лишь языковая модель" refusal) —
  # enable the mode the way a user does: real mouse click on the 'Create video' item.
  $w = Get-Win
  $up = $null
  foreach ($b in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $btnCond)) { if ($b.Current.Name -eq 'Upload & tools') { $up = $b } }
  if (-not $up) { return $false }
  try { $up.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch { return $false }
  Start-Sleep -Milliseconds 1200
  $w = Get-Win
  $cbx = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox)
  $cv = $null
  foreach ($el in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $cbx)) { if ($el.Current.Name -eq 'Create video') { $cv = $el; break } }
  if (-not $cv) { return $false }
  $r = $cv.Current.BoundingRectangle
  if ($r.Width -le 0) { return $false }
  [Windows.Forms.Cursor]::Position = New-Object Drawing.Point([int]($r.X + $r.Width/2), [int]($r.Y + $r.Height/2))
  Start-Sleep -Milliseconds 300
  [Native]::mouse_event(2,0,0,0,0); [Native]::mouse_event(4,0,0,0,0)
  Start-Sleep -Milliseconds 1500
  return $true
}
function Enable-CreateVideoMode {
  # Image-to-video requires the app's "Create video" tool mode: the plain chat with an
  # attached photo does NOT invoke Veo (it answers with prompts for external models).
  # The mode persists across chats/restarts, so when it looks already-on we can't know
  # whether it was set by a real click or by TogglePattern — force a full off→on cycle
  # with real mouse clicks so the routing state is genuinely established.
  if (Test-VideoModeOn (Get-Win)) {
    if (-not (Toggle-VideoModeByClick)) { return $false }
    if (Test-VideoModeOn (Get-Win)) { return $false }
  }
  if (-not (Toggle-VideoModeByClick)) { return $false }
  return (Test-VideoModeOn (Get-Win))
}
function Invoke-ButtonWithRetry($b) {
  # the button is disabled while the blob is still loading — Invoke throws
  # ElementNotEnabledException; wait for it to become clickable
  $deadline = (Get-Date).AddSeconds(60)
  while ($true) {
    try {
      $inv = $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $inv.Invoke()
      return $true
    } catch {
      if ((Get-Date) -ge $deadline) { return $false }
      Start-Sleep -Seconds 5
    }
  }
}
function Save-AiImage($im, [string]$path) {
  $r = $im.Current.BoundingRectangle
  $sw = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  # window may hang off-screen; capture only the visible part
  $cx = [int][Math]::Max($r.X, 0); $cy = [int][Math]::Max($r.Y, 0)
  $cw = [int]([Math]::Min($r.Right, $sw.Width) - $cx)
  $ch = [int]([Math]::Min($r.Bottom, $sw.Height) - $cy)
  if ($cw -le 0 -or $ch -le 0) { return $false }
  $bmp = New-Object System.Drawing.Bitmap $cw, $ch
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($cx, $cy, 0, 0, (New-Object System.Drawing.Size $cw, $ch))
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
function Find-BlobDialog {
  # After clicking "Download full size image" the app finishes the blob download
  # (can take a couple of minutes!) and then opens a native Save As dialog:
  # class #32770, title "blob:null/<guid>". It is NOT visible in the UIA desktop
  # tree, so it must be found with raw EnumWindows.
  $found = New-Object System.Collections.Generic.List[IntPtr]
  $cb = [Native+EnumProc] {
    param($h, $l)
    if (-not [Native]::IsWindowVisible($h)) { return $true }
    $c = New-Object System.Text.StringBuilder 512
    [void][Native]::GetClassNameW($h, $c, 512)
    if ($c.ToString() -ne '#32770') { return $true }
    $t = New-Object System.Text.StringBuilder 1024
    [void][Native]::GetWindowTextW($h, $t, 1024)
    if ($t.ToString().StartsWith('blob:')) { [void]$found.Add($h) }
    return $true
  }
  [void][Native]::EnumWindows($cb, [IntPtr]::Zero)
  if ($found.Count -eq 0) { return [IntPtr]::Zero }
  return $found[0]
}
function Find-ChildByCtrlId($parent, [int]$id) {
  $script:childHit = [IntPtr]::Zero
  $cb = [Native+EnumProc] {
    param($h, $l)
    if ([Native]::GetDlgCtrlID($h) -eq $id) { $script:childHit = $h; return $false }
    return $true
  }
  [void][Native]::EnumChildWindows($parent, $cb, [IntPtr]::Zero)
  return $script:childHit
}
function Handle-SaveDialog($dlg, [string]$dir, [string]$ext = 'jpg') {
  # Put the full target path (dir + the app's default file name) into the file-name
  # edit (control id 1001) and press "Save" (control id 1), so the image is written
  # straight into the project directory and the dialog does not stay open.
  $edit = Find-ChildByCtrlId $dlg 1001
  $save = [Native]::GetDlgItem($dlg, 1)
  if ($save -eq [IntPtr]::Zero) { return $null }
  $base = $null
  try {
    # UIA can read the default name ("Gemini_Generated_Image_xxx.jpg") from the edit
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($dlg)
    $ac = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, '1001')
    $cc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Edit')
    foreach ($e in $el.FindAll([System.Windows.Automation.TreeScope]::Subtree, (New-Object System.Windows.Automation.AndCondition($ac, $cc)))) {
      $n = $e.Current.Name
      if ($n -match '^[\w.\-]+\.(jpg|jpeg|png|webp|mp4)$') { $base = $n; break }
    }
  } catch {}
  if (-not $base) {
    if ($ext -eq 'mp4') { $base = 'Gemini_Generated_Video_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4' }
    else { $base = 'Gemini_Generated_Image_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jpg' }
  }
  $target = Join-Path $dir $base
  [void][Native]::SetForegroundWindow($dlg)
  Start-Sleep -Milliseconds 300
  [void][Native]::SendMessageW($edit, 0x000C, [IntPtr]::Zero, '')      # WM_SETTEXT
  if ($edit -ne [IntPtr]::Zero) { [void][Native]::SendMessageW($edit, 0x000C, [IntPtr]::Zero, $target) }
  Start-Sleep -Milliseconds 300
  [void][Native]::SendMessageW($save, 0x00F5, [IntPtr]::Zero, $null)   # BM_CLICK
  $prevLen = -1; $stable = 0
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $target)) { continue }
    $len = (Get-Item $target).Length
    if ($len -gt 0 -and $len -eq $prevLen) { $stable++ } else { $stable = 0; $prevLen = $len }
    if ($stable -ge 1) { return $target }
  }
  return $null
}
function Cancel-LeftoverDialogs {
  # never leave a half-open Save As dialog behind
  $guard = 0
  while ($guard -lt 3) {
    $h = Find-BlobDialog
    if ($h -eq [IntPtr]::Zero) { return }
    $cancel = [Native]::GetDlgItem($h, 2)
    if ($cancel -ne [IntPtr]::Zero) { [void][Native]::SendMessageW($cancel, 0x00F5, [IntPtr]::Zero, $null) }
    Start-Sleep -Milliseconds 500
    $guard++
  }
}
function Invoke-DownloadButton($im) {
  # click the "Download full size image" button inside the card of $im
  $w = Get-Win
  $dl = $null
  $ir = $im.Current.BoundingRectangle
  foreach ($b in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $btnCond)) {
    if ($b.Current.Name -notmatch 'Download') { continue }
    $br = $b.Current.BoundingRectangle
    $cx = $br.X + $br.Width / 2; $cy = $br.Y + $br.Height / 2
    # button center must lie inside this image's card (top-right corner of it);
    # while the blob is still loading the card is collapsed (h~16 px) but the toolbar
    # already hangs below it — allow +120 px below and +80 above
    if ($cx -ge $ir.Left - 4 -and $cx -le $ir.Right + 4 -and $cy -ge $ir.Top - 80 -and $cy -le $ir.Bottom + 120) { $dl = $b }
  }
  if (-not $dl) { return $false }
  # the button is disabled while the image blob is still loading (e.g. slow network) — wait for it
  $deadline = (Get-Date).AddSeconds(60)
  while ($true) {
    try {
      $inv = $dl.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $inv.Invoke()
      return $true
    } catch {
      if ((Get-Date) -ge $deadline) { return $false }
      Start-Sleep -Seconds 5
    }
  }
}
function Get-DownloadedTmp([hashtable]$before, [DateTime]$since) {
  # fallback signal: some app builds finish the download as a GUID .tmp in Downloads
  # (the Save As dialog only offers it there); return it once its size stops growing
  $dir = Join-Path $env:USERPROFILE 'Downloads'
  if (-not (Test-Path $dir)) { return $null }
  $cands = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object {
    (-not $before.ContainsKey($_.Name)) -and ($_.Name -notmatch '\.crdownload$') -and ($_.LastWriteTime -ge $since)
  } | Sort-Object LastWriteTime)
  if ($cands.Count -eq 0) { return $null }
  return $cands[-1]
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

# Switch the editor into the app's "Create video" tool mode (required for image-to-video;
# auto-enabled whenever a file is attached and -VideoOut is requested)
if ($VideoMode -or ($FilePath -and $VideoOut)) {
  if (Enable-CreateVideoMode) { Write-Output "VIDEOMODE_ON" } else { Write-Output "WARN_VIDEOMODE_NOT_ENABLED" }
}

# Attach a real file: put it on the clipboard as a file drop (CF_HDROP) and Ctrl+V into the
# editor, so the app itself uploads it as an attachment (not as pasted text).
if ($FilePath) {
  if (-not (Test-Path $FilePath)) { Die "ERROR_FILE_NOT_FOUND" 8 }
  $FilePath = (Resolve-Path $FilePath).Path
  $baseName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
  # an attached file shows as a thumbnail with a 'close attachment' button (no name label)
  function Count-Attachments($w) {
    $c = 0
    foreach ($b in $w.FindAll([System.Windows.Automation.TreeScope]::Subtree, $btnCond)) { if ($b.Current.Name -match 'close attachment') { $c++ } }
    return $c
  }
  # clear attachments left by previous failed runs (New chat may not have reset them)
  $w0 = Get-Win
  $guard = 0
  while ($w0 -and ((Count-Attachments $w0) -gt 0) -and ($guard -lt 12)) {
    foreach ($b in $w0.FindAll([System.Windows.Automation.TreeScope]::Subtree, $btnCond)) {
      if ($b.Current.Name -match 'close attachment') {
        try { $cl = $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $cl.Invoke() } catch {}
        break
      }
    }
    Start-Sleep -Milliseconds 600
    $w0 = Get-Win
    $guard++
  }
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
  # wait until the attachment thumbnail appears in the editor (upload accepted)
  $attached = $false
  $attDeadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $attDeadline) {
    Start-Sleep -Milliseconds 800
    $w = Get-Win
    if (-not $w) { continue }
    if ((Count-Attachments $w) -gt 0) { $attached = $true; break }
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
  # the accessibility tree may not be built yet right after an app reload/network blip —
  # give the editor up to 20 s to appear before declaring the UI changed
  $edDeadline = (Get-Date).AddSeconds(20)
  $editor = $null
  while ((Get-Date) -lt $edDeadline) {
    $win = Get-Win
    $editor = Find-Editor $win
    if ($editor) { break }
    Start-Sleep -Milliseconds 1500
  }
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
# same for video cards: count 'Download video' buttons already on screen
$baselineVids = (Find-VideoButtons (Get-Win)).Count

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
  $hasAnswerAfter = ((Extract-Answer $lines).Length -gt 0) -or ((Find-AiImages $w).Count -gt $baselineImgs) -or ((Find-VideoButtons $w).Count -gt $baselineVids)
  if ((-not $stop) -and $hasAnswerAfter -and ($cur -eq $prev) -and ($cur.Trim().Length -gt 0)) { $stable++ } else { $stable = 0 }
  $prev = $cur
  $last = $lines
  if ($stable -ge 3) { break }
  Start-Sleep -Seconds 2
}

$answer = Extract-Answer $last
$imgPath = ""
$imgDone = $false
$newImgs = Find-AiImages (Get-Win)
# race: the answer text can stabilize a moment before the image card renders —
# give the Image element up to 30 s to show up before concluding there is none
$imgDeadline = (Get-Date).AddSeconds(30)
while ($newImgs.Count -le $baselineImgs -and (Get-Date) -lt $imgDeadline) {
  Start-Sleep -Seconds 2
  $newImgs = Find-AiImages (Get-Win)
}
if ($newImgs.Count -gt $baselineImgs) {
  $im = $newImgs | Select-Object -Last 1
  if ($ImageOut) { $imgPath = $ImageOut }
  else { $imgPath = Join-Path $env:TEMP ("gemini-image-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".png") }
  # 1) preferred: press the app's own "Download full size image" button and drive the
  # native Save As dialog it opens after the blob finishes (up to ~3 min): type the full
  # path into the project directory, press Save -> file lands right in the project.
  # Whatever it saved (usually JPEG) is re-encoded into the requested PNG path.
  $savedFile = $null
  if (Invoke-DownloadButton $im) {
    $dir = Split-Path -Parent $imgPath
    $dtmp = Join-Path $env:USERPROFILE 'Downloads'
    $before = @{}
    foreach ($f in (Get-ChildItem $dtmp -File -ErrorAction SilentlyContinue)) { $before[$f.Name] = $true }
    $since = Get-Date
    $tmpPrev = $null
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 2
      $dlg = Find-BlobDialog
      if ($dlg -ne [IntPtr]::Zero) {
        $savedFile = Handle-SaveDialog $dlg $dir
        break
      }
      # some builds may only leave a finished .tmp in Downloads; accept it only after
      # the dialog had plenty of time to appear (and only if it never did)
      if ((Get-Date) -gt $since.AddSeconds(180)) {
        $f = Get-DownloadedTmp $before $since
        if ($f -and $f.Length -gt 0 -and $tmpPrev -and $tmpPrev.Name -eq $f.Name -and $tmpPrev.Length -eq $f.Length) { $savedFile = $f.FullName; break }
        $tmpPrev = $f
      }
    }
  }
  if ($savedFile) {
    try {
      $bytes = [IO.File]::ReadAllBytes($savedFile)
      $ms = New-Object System.IO.MemoryStream @(,$bytes)
      $big = [System.Drawing.Image]::FromStream($ms)
      $sz = "$($big.Width)x$($big.Height)"
      $big.Save($imgPath, [System.Drawing.Imaging.ImageFormat]::Png)
      $big.Dispose(); $ms.Dispose()
      Remove-Item $savedFile -Force
      Write-Output "IMAGE_SOURCE download"
      Write-Output "IMAGE_SIZE $sz"
      Write-Output "IMAGE_SAVED $imgPath"
      $imgDone = $true
    } catch {
      Write-Output "IMAGE_DOWNLOAD_FAILED $($_.Exception.Message)"
    }
  }
  # never leave a half-open Save As dialog behind
  Cancel-LeftoverDialogs
  # 2) fallback: screen-capture the Image element region
  if (-not $imgDone) {
    $wh = (Get-Win).Current.NativeWindowHandle
    $wb = (Get-Win).Current.BoundingRectangle
    # move the window fully on-screen so the capture is not clipped
    $swb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($wb.X -lt 0 -or $wb.Y -lt 0 -or $wb.Right -gt $swb.Width -or $wb.Bottom -gt $swb.Height) {
      $nw = [Math]::Min([int]$wb.Width, $swb.Width); $nh = [Math]::Min([int]$wb.Height, $swb.Height)
      [void][Native]::ShowWindow($wh, 1)
      [void][Native]::MoveWindow($wh, 0, 0, $nw, $nh, $true)
      Start-Sleep -Milliseconds 800
    }
    [void][Native]::SetForegroundWindow($wh)
    Start-Sleep -Milliseconds 600
    $im = (Find-AiImages (Get-Win)) | Select-Object -Last 1
    try {
      Save-AiImage $im $imgPath
      Write-Output "IMAGE_SOURCE screen-capture"
      Write-Output "IMAGE_SAVED $imgPath"
      $imgDone = $true
    } catch {
      Write-Output "IMAGE_CAPTURE_FAILED $($_.Exception.Message)"
    }
  }
}
# Video answer: press the card's own "Download video" button and drive the same native
# Save As dialog (default name "gemini_generated_video_xxx.mp4", opens within seconds to
# a few minutes after the click); the mp4 is moved to the exact -VideoOut path as-is.
$vidDone = $false
$newVids = Find-VideoButtons (Get-Win)
# race (same as for images): the answer text can stabilize before the video card renders
$vidDeadline = (Get-Date).AddSeconds(30)
while ($newVids.Count -le $baselineVids -and (Get-Date) -lt $vidDeadline) {
  Start-Sleep -Seconds 2
  $newVids = Find-VideoButtons (Get-Win)
}
if ($newVids.Count -gt $baselineVids) {
  $vbtn = $newVids | Select-Object -Last 1
  if ($VideoOut) { $vidPath = $VideoOut }
  else { $vidPath = Join-Path $env:TEMP ("gemini-video-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".mp4") }
  $savedVid = $null
  if (Invoke-ButtonWithRetry $vbtn) {
    $dir = Split-Path -Parent $vidPath
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 2
      $dlg = Find-BlobDialog
      if ($dlg -ne [IntPtr]::Zero) { $savedVid = Handle-SaveDialog $dlg $dir 'mp4'; break }
    }
  }
  # never leave a half-open Save As dialog behind
  Cancel-LeftoverDialogs
  if ($savedVid) {
    if ($savedVid -ne $vidPath) { Move-Item $savedVid $vidPath -Force }
    Write-Output "VIDEO_SOURCE download"
    Write-Output "VIDEO_SIZE $((Get-Item $vidPath).Length)"
    Write-Output "VIDEO_SAVED $vidPath"
    $vidDone = $true
  } else {
    Write-Output "VIDEO_DOWNLOAD_FAILED"
  }
}
if (-not $answer -and -not $imgDone -and -not $vidDone) {
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
