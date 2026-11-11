# Checks where a new window opens: a step down and right of the window it
# was opened from, on that window's monitor (Windows used to choose, which
# with two monitors could be the other one, at the wrong scale), and from
# a window near the far corner of the screen, back near the work area's
# top left instead of mostly off screen. The first window is moved with
# SetWindowPos and new_window is a key posted to its terminal, so it runs
# on a locked desktop.
#
#     ./new-window-place.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=new-window-place::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyPlace -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int size; public RECT monitor, work; public uint flags; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int w, int hgt, uint flags);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr MonitorFromWindow(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetMonitorInfoW(System.IntPtr monitor, ref MONITORINFO info);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyPlace.Win32]
# Real pixels, as Ghostty sees them.
[void]$W::SetProcessDPIAware()

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-new-window-place-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--confirm-close-surface=false', '--keybind=f5=new_window',
    "--class=com.example.ghostty-new-window-place-$PID"

function Fail([string]$message) {
    Write-Host "::error title=new-window-place::$message"
    $script:reported = $true
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
        Start-Sleep -Milliseconds 200
    }
    Fail "timed out waiting for $what"
}

# The process's visible windows.
function Windows {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, 'GhosttyWindow', [NullString]::Value)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $process.Id -and $W::IsWindowVisible($h)) { $list += $h }
    }
    $list
}
function Rect([IntPtr]$h) { $r = New-Object GhosttyPlace.Win32+RECT; [void]$W::GetWindowRect($h, [ref]$r); $r }
function Show($r) { "($($r.l),$($r.t))-($($r.r),$($r.b))" }

# Open a window from the first one, which is the only one, and so the one
# a new window goes by; return the new one.
function NewFrom([IntPtr]$first) {
    $surface = WaitFor { $s = $W::FindWindowExW($first, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($s -ne [IntPtr]::Zero) { $s } } 'the terminal'
    $W::Key($surface, 0x74, 0x3F)   # F5: new_window
    $new = WaitFor { @(Windows | Where-Object { $_ -ne $first })[0] } 'the new window'
    Start-Sleep -Milliseconds 500
    $new
}
function Close([IntPtr]$window) {
    [void]$W::PostMessageW($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    [void](WaitFor { @(Windows).Count -eq 1 } 'the new window to close')
}

try {
    $first = WaitFor { $w = @(Windows); if ($w.Count -eq 1) { $w[0] } } 'the window'
    Start-Sleep -Seconds 1
    $monitor = $W::MonitorFromWindow($first, 2)   # MONITOR_DEFAULTTONEAREST
    $info = New-Object GhosttyPlace.Win32+MONITORINFO; $info.size = 40
    [void]$W::GetMonitorInfoW($monitor, [ref]$info)
    $work = $info.work
    $dpi = $W::GetDpiForWindow($first)
    $step = [int][Math]::Round(32 * $dpi / 96)
    Write-Host "The work area is $(Show $work) at $dpi DPI, so a step is $step pixels."

    # By the window it came from.
    $x = $work.l + 3 * $step; $y = $work.t + 2 * $step
    [void]$W::SetWindowPos($first, [IntPtr]::Zero, $x, $y, 0, 0, 0x0015)   # SWP_NOSIZE | NOZORDER | NOACTIVATE
    $from = Rect $first
    $new = NewFrom $first
    $at = Rect $new
    if ($W::MonitorFromWindow($new, 2) -ne $monitor) { Fail "the new window is on another monitor: $(Show $at)" }
    if ($W::GetDpiForWindow($new) -ne $dpi) { Fail "the new window has $($W::GetDpiForWindow($new)) DPI, not $dpi" }
    # It only moves from there to stay inside the work area.
    $fits = ($from.l + $step + ($at.r - $at.l)) -le $work.r -and ($from.t + $step + ($at.b - $at.t)) -le $work.b
    if ($fits -and ($at.l -ne $from.l + $step -or $at.t -ne $from.t + $step)) {
        Fail "from $(Show $from) the new window should be at ($($from.l + $step),$($from.t + $step)): $(Show $at)"
    }
    if ($at.l -lt $work.l -or $at.t -lt $work.t -or $at.l -gt $from.l + $step -or $at.t -gt $from.t + $step) {
        Fail "from $(Show $from) the new window is in an odd place: $(Show $at)"
    }
    Write-Host "From $(Show $from) a new window opened at $(Show $at)$(if (-not $fits) { ', moved back to fit the work area' })."
    Close $new

    # From a window near the far corner: not out there with it.
    [void]$W::SetWindowPos($first, [IntPtr]::Zero, $work.r - 2 * $step, $work.b - 2 * $step, 0, 0, 0x0015)
    $from = Rect $first
    $new = NewFrom $first
    $at = Rect $new
    if ($at.l -lt $work.l -or $at.t -lt $work.t -or $at.l -gt $work.l + $step -or $at.t -gt $work.t + $step) {
        Fail "from $(Show $from), near the far corner, the new window should be near the work area's top left: $(Show $at)"
    }
    Write-Host "From $(Show $from), near the far corner, a new window opened at $(Show $at)."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
