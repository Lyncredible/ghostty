# Checks the options for new windows: `window-position-x/y` puts the
# visible frame's corner that many points from the primary monitor's work
# area, a position off every monitor falls back to the work area's corner,
# `maximize` maximizes the window and `fullscreen` covers its monitor. Each
# case starts Ghostty and only reads its window, so it runs on a locked
# desktop.
#
#     ./window-options.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=window-options::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyWindowOptions -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT monitor, work; public uint flags; }
[DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
[DllImport("user32.dll")] public static extern System.IntPtr MonitorFromPoint(POINT pt, uint flags);
[DllImport("user32.dll")] public static extern System.IntPtr MonitorFromWindow(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetMonitorInfoW(System.IntPtr m, ref MONITORINFO info);
[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(System.IntPtr m, int type, out uint x, out uint y);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(System.IntPtr h, int attr, out RECT r, int size);
public static MONITORINFO Info(System.IntPtr m) { var i = new MONITORINFO(); i.cbSize = Marshal.SizeOf(i); GetMonitorInfoW(m, ref i); return i; }
// The visible frame, without the invisible resize borders.
public static RECT Frame(System.IntPtr h) { RECT r; DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))); return r; }
'@
$W = [GhosttyWindowOptions.Win32]
[void]$W::SetThreadDpiAwarenessContext([IntPtr]-4)   # per monitor v2, like Ghostty

$primary = $W::MonitorFromPoint((New-Object GhosttyWindowOptions.Win32+POINT), 1)   # MONITOR_DEFAULTTOPRIMARY
$work = $W::Info($primary).work
$dpi = 96; $dpiY = 96; [void]$W::GetDpiForMonitor($primary, 0, [ref]$dpi, [ref]$dpiY)
Write-Host "The primary monitor's work area is $($work.l),$($work.t)-$($work.r),$($work.b) at $dpi DPI."

function Fail([string]$message) {
    Write-Host "::error title=window-options::$message"
    $script:reported = $true
    throw $message
}

function Rect($r) { "$($r.l),$($r.t)-$($r.r),$($r.b)" }

# Start Ghostty with the options, wait until the check passes, and close it.
function Check([string[]]$options, [scriptblock]$check, [string]$what) {
    $process = Start-Process -FilePath $Exe -PassThru -ArgumentList (@('--command=cmd.exe', '--window-save-state=never') + $options)
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $window = [IntPtr]::Zero
        while ((Get-Date) -lt $deadline) {
            $process.Refresh()
            if ($process.MainWindowHandle -ne 0 -and $W::IsWindowVisible($process.MainWindowHandle)) { $window = $process.MainWindowHandle; break }
            Start-Sleep -Milliseconds 200
        }
        if ($window -eq [IntPtr]::Zero) { Fail "no window with $($options -join ' ')" }
        $script:note = ''
        while ((Get-Date) -lt $deadline) {
            if (& $check $window) { Write-Host "$what ($script:note)."; return }
            Start-Sleep -Milliseconds 250
        }
        Fail "timed out waiting for $what with $($options -join ' ') ($script:note)"
    } finally {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
}

$x = $work.l + [math]::Truncate(100 * $dpi / 96); $y = $work.t + [math]::Truncate(50 * $dpi / 96)
Check @('--window-position-x=100', '--window-position-y=50') {
    param($h) $f = $W::Frame($h); $script:note = "frame $(Rect $f), expected corner $x,$y"
    [math]::Abs($f.l - $x) -le 1 -and [math]::Abs($f.t - $y) -le 1
} 'window-position 100,50 puts the frame there'

Check @('--window-position-x=30000', '--window-position-y=30000') {
    param($h) $f = $W::Frame($h); $script:note = "frame $(Rect $f), work area corner $($work.l),$($work.t)"
    [math]::Abs($f.l - $work.l) -le 1 -and [math]::Abs($f.t - $work.t) -le 1
} 'a position off every monitor falls back to the work area corner'

Check @('--maximize=true') {
    param($h) $script:note = "zoomed: $($W::IsZoomed($h))"; $W::IsZoomed($h)
} 'maximize maximizes the window'

Check @('--fullscreen=true') {
    param($h)
    $m = $W::Info($W::MonitorFromWindow($h, 2)).monitor; $r = New-Object GhosttyWindowOptions.Win32+RECT; [void]$W::GetWindowRect($h, [ref]$r)
    $script:note = "window $(Rect $r), monitor $(Rect $m)"
    $r.l -le $m.l -and $r.t -le $m.t -and $r.r -ge $m.r -and $r.b -ge $m.b
} 'fullscreen covers the monitor'
exit 0
