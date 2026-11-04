# Checks, for CI, that the cursor blinks at Windows' cursor blink rate and
# stays on when blinking is turned off there: it focuses a Ghostty window,
# times the cursor's changes on screen, then sets the blink time to
# INFINITE (what "off" is) and checks the screen stays the same. It takes
# focus and changes a desktop setting, so it only runs in CI.
#
#     ./cursor-blink.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this takes focus and changes a desktop setting, so it only runs in CI" }

Add-Type -ReferencedAssemblies System.Drawing -Namespace GhosttyBlink -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetCaretBlinkTime();
[DllImport("user32.dll", SetLastError = true)] public static extern bool SetCaretBlinkTime(uint ms);
// A hash of the window's client area on screen.
public static long Hash(System.IntPtr h) {
  RECT r; GetClientRect(h, out r);
  var p = new POINT(); ClientToScreen(h, ref p);
  using (var bmp = new System.Drawing.Bitmap(r.r, r.b)) {
    using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(p.x, p.y, 0, 0, bmp.Size);
    long sum = 0;
    for (int y = 0; y < bmp.Height; y += 2) for (int x = 0; x < bmp.Width; x += 2) sum = sum * 31 + bmp.GetPixel(x, y).ToArgb();
    return sum;
  }
}
'@
[void][GhosttyBlink.Win32]::SetProcessDPIAware()

$saved = [GhosttyBlink.Win32]::GetCaretBlinkTime()
$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', `
    '--window-save-state=never', '--cursor-style=block', '--window-width=30', '--window-height=6'

function Fail([string]$message) {
    Write-Host "::error title=cursor-blink::$message"
    $script:reported = $true
    throw $message
}

# The times (in ms) the window changed on screen within $ms.
function Changes([int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = $null; $changes = @()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $hash = [GhosttyBlink.Win32]::Hash($window)
        if ($null -ne $last -and $hash -ne $last) { $changes += $sw.ElapsedMilliseconds }
        $last = $hash
        Start-Sleep -Milliseconds 10
    }
    , $changes
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $process.Refresh() }
    $window = $process.MainWindowHandle
    if ($window -eq 0) { Fail "no window" }
    [void][GhosttyBlink.Win32]::SetForegroundWindow($window)
    Start-Sleep -Seconds 3
    if ([GhosttyBlink.Win32]::GetForegroundWindow() -ne $window) { Fail "the window isn't in the foreground" }

    $changes = Changes 6000
    if ($changes.Count -lt 4) { Fail "the cursor didn't blink ($($changes.Count) changes in 6 s)" }
    $interval = ($changes[-1] - $changes[0]) / ($changes.Count - 1)
    Write-Host "With a $saved ms blink time, the cursor changed $($changes.Count) times, every $([int]$interval) ms."
    if ([Math]::Abs($interval - $saved) -gt 50) { Fail "the cursor blinked every $([int]$interval) ms, not $saved" }

    if (-not [GhosttyBlink.Win32]::SetCaretBlinkTime([uint32]::MaxValue)) { Fail "couldn't turn blinking off" }
    Write-Host "Blinking is off: GetCaretBlinkTime is $([GhosttyBlink.Win32]::GetCaretBlinkTime())."
    Start-Sleep -Seconds 2
    $changes = Changes 3000
    if ($changes.Count -gt 0) { Fail "the cursor still changed $($changes.Count) times with blinking off" }
    Write-Host 'With blinking off, the cursor stays on.'
} catch {
    if (-not $script:reported) { Write-Host "::error title=cursor-blink::$($_.Exception.Message)" }
    throw
} finally {
    [void][GhosttyBlink.Win32]::SetCaretBlinkTime($saved)
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
