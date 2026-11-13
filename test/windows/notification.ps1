# Checks desktop notifications (OSC 9): one shows from the notification
# area icon, and another still shows after the icon is gone, as when
# Explorer restarts while a notification is up (the icon stays only
# while one shows, so Ghostty thought it was still there and every later
# notification failed). The test deletes the icon itself, as Explorer's
# restart would. Then clicking the notification (its message, posted to
# Ghostty) brings back the minimized window it came from. Last, as on GTK
# and macOS, a notification is withdrawn once its terminal is focused (a
# split sends one while the other has the focus) or closes. It shows
# notifications, so it only runs in CI (or with $env:CI = 'true').
#
#     ./notification.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this shows notifications, so it only runs in CI" }
Add-Type -Namespace GhosttyNotification -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct NOTIFYICONDATAW {
  public int cbSize; public System.IntPtr hWnd; public uint uID; public uint uFlags;
  public uint uCallbackMessage; public System.IntPtr hIcon;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
  public uint dwState; public uint dwStateMask;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
  public uint uVersion;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
  public uint dwInfoFlags; public System.Guid guidItem; public System.IntPtr hBalloonIcon;
}
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern bool Shell_NotifyIconW(uint msg, ref NOTIFYICONDATAW data);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
  public int size; public uint flags; public System.IntPtr active, focus, capture, menuOwner, moveSize, caret; public RECT caretRect; }
[DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
// The window with the keyboard focus on the thread of `window`.
public static System.IntPtr Focus(System.IntPtr window) {
  uint pid; uint thread = GetWindowThreadProcessId(window, out pid);
  var info = new GUITHREADINFO(); info.size = Marshal.SizeOf(info);
  return GetGUIThreadInfo(thread, ref info) ? info.focus : System.IntPtr.Zero;
}
'@
$W = [GhosttyNotification.Win32]

if ($W::FindWindowW('Shell_TrayWnd', [NullString]::Value) -eq [IntPtr]::Zero) {
    Write-Host '::notice title=notification::No taskbar here, so no notification area; skipped.'
    exit 0
}

$dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-notification-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
$go = Join-Path $dir 'go'
# The shell sends one notification, and another once the test says so.
Set-Content -Encoding utf8 (Join-Path $dir 'shell.ps1') @'
param([string]$Go)
$e = [char]27; $b = [char]7
[Console]::Out.Write("$e]9;first notification$b")
while (-not (Test-Path $Go)) { Start-Sleep -Milliseconds 100 }
[Console]::Out.Write("$e]9;second notification$b")
Start-Sleep -Seconds 600
'@
# The left of two splits sends a notification each time the test says so,
# and exits when it says so after the second.
Set-Content -Encoding utf8 (Join-Path $dir 'split.ps1') @'
param([string]$Dir)
$e = [char]27; $b = [char]7
foreach ($n in 1, 2, 3) {
    while (-not (Test-Path "$Dir\go$n")) { Start-Sleep -Milliseconds 100 }
    if ($n -lt 3) { [Console]::Out.Write("$e]9;notification $n from the left split$b") }
}
'@

$class = "com.example.ghostty-notification-$PID"
$log = Join-Path $dir 'ghostty.log'
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList "--class=$class",
    '--window-save-state=never', '--confirm-close-surface=false',
    "`"--command=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dir\shell.ps1 -Go $go`""

function Fail([string]$message) {
    Write-Host "::error title=notification::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 30 | Write-Host }
    throw $message
}

# How many notifications Ghostty showed, and withdrew, from its log.
function Shown { @(Select-String -Path $log -Pattern 'showing notification' -ErrorAction SilentlyContinue).Count }
function Withdrawn { @(Select-String -Path $log -Pattern 'withdrawing notification' -ErrorAction SilentlyContinue).Count }

# Whether the last notification shown timed out or was hidden
# (NIN_BALLOONTIMEOUT, NIN_BALLOONHIDE): then it can't be clicked or
# withdrawn, and CI's Explorer times them out at once.
function TimedOut {
    $lines = @(Get-Content $log)
    $last = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'showing notification') { $last = $i } }
    @($lines[$last..($lines.Count - 1)] | Where-Object { $_ -match 'notification icon event=0x40[34]' }).Count -gt 0
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 200
    }
    Fail "timed out waiting for $what"
}

try {
    [void](WaitFor { (Shown) -ge 1 } 'the first notification')
    Write-Host 'The first notification showed.'

    # Ghostty's message window, which owns the icon (ID 1), is titled
    # with its class.
    $messages = $W::FindWindowW('GhosttyMessage', $class)
    if ($messages -eq [IntPtr]::Zero) { Fail "no message window titled $class" }
    $data = New-Object GhosttyNotification.Win32+NOTIFYICONDATAW
    $data.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($data)
    $data.hWnd = $messages
    $data.uID = 1
    $deleted = $W::Shell_NotifyIconW(2, [ref]$data)   # NIM_DELETE
    if (-not $deleted) {
        # The notification may be gone already (CI's Explorer times it out
        # at once), and with it the icon. Then the next one adds it anew.
        Write-Host "::notice title=notification::The icon was already gone, so the second notification doesn't check a lost icon here."
    }

    # Notifications more often than once a second are dropped.
    Start-Sleep -Seconds 2
    Set-Content $go 'go'
    [void](WaitFor { (Shown) -ge 2 } 'the second notification, after the icon was deleted')
    Write-Host "$(if ($deleted) { 'After the icon was deleted, the' } else { 'The' }) second notification showed too."
    Get-Content $log | Select-String '(win32).*notification' | ForEach-Object { Write-Host "  $($_.Line)" }

    # A click on it brings back its window. The click comes as the icon's
    # message (WM_APP + 2) with NIN_BALLOONUSERCLICK.
    Start-Sleep -Milliseconds 500
    if (TimedOut) {
        Write-Host '::notice title=notification::The notification timed out at once, so its click isn''t checked here.'
    } else {
        $process.Refresh()
        $window = $process.MainWindowHandle
        [void]$W::ShowWindow($window, 6)   # SW_MINIMIZE
        [void](WaitFor { $W::IsIconic($window) } 'the window to minimize')
        [void]$W::PostMessageW($messages, 0x8002, [IntPtr]::Zero, [IntPtr]0x405)
        [void](WaitFor { -not $W::IsIconic($window) } 'the click to bring back the window')
        Write-Host 'Clicking the notification brought back its minimized window.'
    }
    Stop-Process -Id $process.Id -Force
    Start-Sleep -Milliseconds 500

    # Withdrawn: the left split sends a notification while the right one
    # has the focus, and it goes once the left one is focused; then
    # another, which goes when the left one closes.
    $log = Join-Path $dir 'split.log'
    $process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList "--class=$class-split",
        '--window-save-state=never', '--confirm-close-surface=false', '--command=cmd.exe',
        "`"--initial-command=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dir\split.ps1 -Dir $dir`"",
        '--keybind=f5=new_split:right', '--keybind=f6=goto_split:left', '--keybind=f7=goto_split:right'
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $left = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the terminal'
    Start-Sleep -Seconds 1
    $W::Key($left, 0x74, 0x3F)   # F5: new_split:right
    $right = WaitFor {
        $h = [IntPtr]::Zero
        while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { if ($h -ne $left) { return $h } }
    } 'the split'
    [void](WaitFor { $W::Focus($window) -eq $right } 'the new split to have the focus')

    # A notification that already timed out has nothing to withdraw (CI's
    # Explorer times them out at once); one still showing must go, not
    # time out later.
    Set-Content (Join-Path $dir 'go1') 'go'
    [void](WaitFor { (Shown) -ge 1 } "the left split's notification")
    Start-Sleep -Milliseconds 500
    if (TimedOut) {
        Write-Host '::notice title=notification::The notification timed out at once, so withdrawing it isn''t checked here.'
        exit 0
    }
    $W::Key($right, 0x75, 0x40)   # F6: goto_split:left
    [void](WaitFor { $W::Focus($window) -eq $left } 'goto_split:left to focus the left terminal')
    [void](WaitFor { (Withdrawn) -ge 1 } 'focusing the left split to withdraw its notification')
    Write-Host 'Focusing the left split withdrew its notification.'

    $W::Key($left, 0x76, 0x41)    # F7: goto_split:right
    [void](WaitFor { $W::Focus($window) -eq $right } 'goto_split:right to focus the right terminal')
    Start-Sleep -Seconds 2        # notifications more often than once a second are dropped
    Set-Content (Join-Path $dir 'go2') 'go'
    [void](WaitFor { (Shown) -ge 2 } "the left split's second notification")
    Start-Sleep -Milliseconds 500
    if (TimedOut) {
        Write-Host '::notice title=notification::The second notification timed out at once, so withdrawing it on close isn''t checked here.'
        exit 0
    }
    Set-Content (Join-Path $dir 'go3') 'go'   # the left split's shell exits
    [void](WaitFor { (Withdrawn) -ge 2 } 'closing the left split to withdraw its notification')
    Write-Host 'The left split closing withdrew its second notification.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
