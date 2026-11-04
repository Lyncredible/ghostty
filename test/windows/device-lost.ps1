# Checks that a terminal keeps drawing after its Direct3D device is lost,
# as when Windows updates or restarts the graphics driver. A debug build
# with GHOSTTY_D3D11_LOSE_DEVICE=N acts as if the device was removed at
# its Nth present; this checks the log says the device was replaced, the
# renderer is healthy again, and the window (read with PrintWindow) shows
# the terminal's background and text (cmd's banner, in the top rows).
# It only opens Ghostty's own window, so it can run anywhere.
#
#     ./device-lost.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=device-lost::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace GhosttyDeviceLost -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr dc, uint f);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][GhosttyDeviceLost.Win32]::SetProcessDPIAware()

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-device-lost-$PID.log"
$env:GHOSTTY_D3D11_LOSE_DEVICE = '3'
try {
    $process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe', `
        '--window-save-state=never', '--background=#336699'
} finally {
    Remove-Item Env:GHOSTTY_D3D11_LOSE_DEVICE
}

function Fail([string]$message) {
    Write-Host "::error title=device-lost::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what"
}

function LogHas([string]$pattern) {
    (Test-Path $log) -and (Select-String -Path $log -Pattern $pattern -Quiet)
}

# The window's contents, with PrintWindow (PW_RENDERFULLCONTENT).
function Capture {
    $rect = New-Object GhosttyDeviceLost.Win32+RECT
    [void][GhosttyDeviceLost.Win32]::GetWindowRect($window, [ref]$rect)
    $bitmap = New-Object System.Drawing.Bitmap ($rect.r - $rect.l), ($rect.b - $rect.t)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    [void][GhosttyDeviceLost.Win32]::PrintWindow($window, $dc, 2)
    $graphics.ReleaseHdc($dc)
    $graphics.Dispose()
    $bitmap
}

function Hex($pixel) { '#{0:X2}{1:X2}{2:X2}' -f $pixel.R, $pixel.G, $pixel.B }

# The middle's color, and how many pixels of the top left (where cmd's
# banner is) aren't the background, sampled every other pixel.
function Look {
    $bitmap = Capture
    try {
        $middle = Hex $bitmap.GetPixel([int]($bitmap.Width * 0.6), [int]($bitmap.Height * 0.6))
        $text = 0
        for ($y = [int]($bitmap.Height * 0.05); $y -lt [int]($bitmap.Height * 0.15); $y += 2) {
            for ($x = 0; $x -lt [int]($bitmap.Width * 0.3); $x += 2) {
                if ((Hex $bitmap.GetPixel($x, $y)) -ne '#336699') { $text++ }
            }
        }
        [pscustomobject]@{ Middle = $middle; Text = $text }
    } finally { $bitmap.Dispose() }
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    [void](WaitFor { LogHas 'simulating a lost device' } 'the simulated device loss (this needs a debug build)')
    [void](WaitFor { LogHas 'recreated the device after it was lost' } 'the device to be replaced')
    [void](WaitFor { LogHas 'renderer health status change status=.healthy' } 'the renderer to be healthy again')
    Write-Host 'The device was replaced, and the renderer is healthy again.'

    [void](WaitFor { $script:last = Look; $last.Middle -eq '#336699' -and $last.Text -gt 20 } 'the background and text to show')
    Write-Host "The terminal shows its background ($($last.Middle)) and text ($($last.Text) pixels) again."
    if (LogHas 'error drawing') { Fail 'a frame failed after the device was replaced' }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
