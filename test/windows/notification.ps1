# Checks desktop notifications (OSC 9): one shows from the notification
# area icon, and another still shows after the icon is gone, as when
# Explorer restarts while a notification is up (the icon stays only
# while one shows, so Ghostty thought it was still there and every later
# notification failed). The test deletes the icon itself, as Explorer's
# restart would. Last, clicking the notification (its message, posted to
# Ghostty) brings back the minimized window it came from. It shows
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
'@
$W = [GhosttyNotification.Win32]

if ($W::FindWindowW('Shell_TrayWnd', $null) -eq [IntPtr]::Zero) {
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

# How many notifications Ghostty showed, from its log.
function Shown { @(Select-String -Path $log -Pattern 'showing notification' -ErrorAction SilentlyContinue).Count }

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
    # message (WM_APP + 2) with NIN_BALLOONUSERCLICK. A notification that
    # timed out or was hidden (NIN_BALLOONTIMEOUT, NIN_BALLOONHIDE) can't
    # be clicked, and CI's Explorer times them out at once.
    Start-Sleep -Milliseconds 500
    $lines = @(Get-Content $log)
    $last = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'showing notification') { $last = $i } }
    if (@($lines[$last..($lines.Count - 1)] | Where-Object { $_ -match 'notification icon event=0x40[34]' }).Count -gt 0) {
        Write-Host '::notice title=notification::The notification timed out at once, so its click isn''t checked here.'
        exit 0
    }
    $process.Refresh()
    $window = $process.MainWindowHandle
    [void]$W::ShowWindow($window, 6)   # SW_MINIMIZE
    [void](WaitFor { $W::IsIconic($window) } 'the window to minimize')
    [void]$W::PostMessageW($messages, 0x8002, [IntPtr]::Zero, [IntPtr]0x405)
    [void](WaitFor { -not $W::IsIconic($window) } 'the click to bring back the window')
    Write-Host 'Clicking the notification brought back its minimized window.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
