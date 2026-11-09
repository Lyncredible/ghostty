# Checks the window actions from keybinds, each there and back:
# toggle_maximize maximizes and restores the window, toggle_fullscreen
# covers its monitor and puts it back where it was,
# toggle_window_float_on_top makes it topmost and not, and
# reset_window_size gives a resized window its first size again. The
# first size must already be the one reset_window_size gives (it once
# counted the title bar the tabs then moved into), and coming back from
# fullscreen must give the terminal its old size, with the tabs back in
# the title bar. (The window-options test covers the options that start
# a window that way.) Last, close_window closes it, and Ghostty quits.
# Keys are posted to the terminal, so it runs on a locked desktop.
#
#     ./window-actions.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyWindowActions -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int size; public RECT monitor; public RECT work; public uint flags; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetWindowLongW(System.IntPtr h, int index);
[DllImport("user32.dll")] public static extern System.IntPtr MonitorFromWindow(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetMonitorInfoW(System.IntPtr m, ref MONITORINFO info);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyWindowActions.Win32]
[void]$W::SetProcessDPIAware()

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-window-actions-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--window-width=80', '--window-height=24',
    '--keybind=f5=toggle_maximize', '--keybind=f6=toggle_fullscreen',
    '--keybind=f7=toggle_window_float_on_top', '--keybind=f8=reset_window_size',
    '--keybind=f9=close_window', '--confirm-close-surface=false', '--quit-after-last-window-closed=true'

function Fail([string]$message) {
    Write-Host "::error title=window-actions::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 30 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 100
    }
    Fail "timed out waiting for $what"
}

function Rect {
    $r = New-Object GhosttyWindowActions.Win32+RECT
    [void]$W::GetWindowRect($window, [ref]$r)
    "$($r.l),$($r.t)-$($r.r),$($r.b)"
}
function Size { $r = New-Object GhosttyWindowActions.Win32+RECT; [void]$W::GetWindowRect($window, [ref]$r); "$($r.r - $r.l)x$($r.b - $r.t)" }
# The terminal's size, and whether the tab bar shows.
function Terminal {
    $r = New-Object GhosttyWindowActions.Win32+RECT
    [void]$W::GetWindowRect($surface, [ref]$r)
    $bar = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null)
    "$($r.r - $r.l)x$($r.b - $r.t), tab bar $(if ($bar -ne 0 -and $W::IsWindowVisible($bar)) { 'shown' } else { 'hidden' })"
}
function Topmost { ($W::GetWindowLongW($window, -20) -band 0x8) -ne 0 }   # GWL_EXSTYLE, WS_EX_TOPMOST

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $surface = WaitFor { $s = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', $null); if ($s -ne 0) { $s } } 'the terminal'
    Start-Sleep -Seconds 1
    $start = Rect
    $startSize = Size
    $terminal = Terminal

    # The first size is the one reset_window_size gives.
    $W::Key($surface, 0x77, 0x42)   # F8: reset_window_size
    Start-Sleep -Seconds 1
    if ((Size) -ne $startSize) { Fail "reset_window_size changed the first window's size from $startSize to $(Size)" }
    Write-Host "The first window is the size reset_window_size gives ($startSize; terminal $terminal)."

    # toggle_maximize, there and back.
    $W::Key($surface, 0x74, 0x3F)   # F5
    [void](WaitFor { $W::IsZoomed($window) } 'the window to maximize')
    $W::Key($surface, 0x74, 0x3F)
    [void](WaitFor { -not $W::IsZoomed($window) -and (Rect) -eq $start } 'the window to restore')
    Write-Host "toggle_maximize maximized the window and restored it to $start."

    # toggle_fullscreen covers the monitor, then puts it back.
    $info = New-Object GhosttyWindowActions.Win32+MONITORINFO
    $info.size = [Runtime.InteropServices.Marshal]::SizeOf($info)
    [void]$W::GetMonitorInfoW($W::MonitorFromWindow($window, 2), [ref]$info)
    $monitor = "$($info.monitor.l),$($info.monitor.t)-$($info.monitor.r),$($info.monitor.b)"
    $W::Key($surface, 0x75, 0x40)   # F6
    [void](WaitFor { (Rect) -eq $monitor } "the window to cover the monitor ($monitor)")
    $W::Key($surface, 0x75, 0x40)
    [void](WaitFor { (Rect) -eq $start } "the window back at $start")
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and (Terminal) -ne $terminal) { Start-Sleep -Milliseconds 100 }
    if ((Terminal) -ne $terminal) { Fail "back from fullscreen, the terminal is $(Terminal), not $terminal" }
    Write-Host "toggle_fullscreen covered the monitor ($monitor) and put the window and its terminal back."

    # toggle_window_float_on_top, there and back.
    if (Topmost) { Fail "the window started topmost" }
    $W::Key($surface, 0x76, 0x41)   # F7
    [void](WaitFor { Topmost } 'the window to float on top')
    $W::Key($surface, 0x76, 0x41)
    [void](WaitFor { -not (Topmost) } 'the window to stop floating on top')
    Write-Host 'toggle_window_float_on_top made the window topmost and then not.'

    # reset_window_size after the window is resized, and after it's
    # maximized.
    [void]$W::SetWindowPos($window, [IntPtr]::Zero, 0, 0, 1300, 950, 0x0016)   # SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
    [void](WaitFor { (Size) -eq '1300x950' } 'the window to resize')
    $W::Key($surface, 0x77, 0x42)   # F8
    [void](WaitFor { (Size) -eq $startSize } "the window back at $startSize")
    $W::Key($surface, 0x74, 0x3F)
    [void](WaitFor { $W::IsZoomed($window) } 'the window to maximize')
    $W::Key($surface, 0x77, 0x42)
    [void](WaitFor { -not $W::IsZoomed($window) -and (Size) -eq $startSize } "the maximized window back at $startSize")
    Write-Host "reset_window_size gave the window its first size ($startSize) after a resize and after maximizing."

    # close_window closes it, and with it the last window, Ghostty.
    $W::Key($surface, 0x78, 0x43)   # F9: close_window
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { Fail "close_window didn't close the last window" }
    Write-Host 'close_window closed the window, and Ghostty quit.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
