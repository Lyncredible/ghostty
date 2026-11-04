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
# Errors before the checks start (such as compiling the helpers) get an
# annotation too.
trap {
    if (-not $script:reported) { Write-Host "::error title=cursor-blink::$($_.Exception.Message)" }
    break
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace GhosttyBlink -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetCaretBlinkTime();
[DllImport("user32.dll", SetLastError = true)] public static extern bool SetCaretBlinkTime(uint ms);
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

# A hash of the window's client area on screen.
function ScreenHash {
    $rect = New-Object GhosttyBlink.Win32+RECT
    [void][GhosttyBlink.Win32]::GetClientRect($window, [ref]$rect)
    $point = New-Object GhosttyBlink.Win32+POINT
    [void][GhosttyBlink.Win32]::ClientToScreen($window, [ref]$point)
    $bitmap = New-Object System.Drawing.Bitmap $rect.r, $rect.b
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($point.x, $point.y, 0, 0, $bitmap.Size)
        $graphics.Dispose()
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Bmp)
        [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash($stream.ToArray()))
    } finally { $bitmap.Dispose() }
}

# The times (in ms) the window changed on screen within $ms.
function Changes([int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = $null; $changes = @()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $hash = ScreenHash
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
    $script:reported = $true
    throw
} finally {
    [void][GhosttyBlink.Win32]::SetCaretBlinkTime($saved)
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
