# Checks that a terminal keeps drawing after its Direct3D device is lost,
# as when Windows updates or restarts the graphics driver. A debug build
# with GHOSTTY_D3D11_LOSE_DEVICE=N acts as if the device was removed at
# its Nth present; this checks the log says the device was replaced, the
# renderer is healthy again, and the window (read with PrintWindow) shows
# the terminal's background and text (cmd's banner, in the top rows).
# It runs three times: plain, with a custom shader that swaps red and
# blue, and with a solid background image, whose colors must show after
# the device is replaced too.
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

$work = Join-Path ([IO.Path]::GetTempPath()) "ghostty-device-lost-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$shader = Join-Path $work 'swap.glsl'
Set-Content -Path $shader -Encoding ascii -Value @'
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = vec4(texture(iChannel0, uv).bgr, 1.0);
}
'@

# A solid background image, stretched over the terminal.
$image = Join-Path $work 'background.png'
$bitmap = New-Object System.Drawing.Bitmap 16, 16
try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(0xCC, 0x33, 0x00))
    $graphics.Dispose()
    $bitmap.Save($image, [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }

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
    Fail "timed out waiting for $what (it was $script:last)"
}

function LogHas([string]$pattern) {
    (Test-Path $log) -and (Select-String -Path $log -Pattern $pattern -Quiet)
}

function Hex($pixel) { '#{0:X2}{1:X2}{2:X2}' -f $pixel.R, $pixel.G, $pixel.B }

# The middle's color, and how many pixels of the top left (where cmd's
# banner is) aren't the background, sampled every other pixel. The window
# is read with PrintWindow (PW_RENDERFULLCONTENT).
function Look([string]$background) {
    $rect = New-Object GhosttyDeviceLost.Win32+RECT
    [void][GhosttyDeviceLost.Win32]::GetWindowRect($window, [ref]$rect)
    $bitmap = New-Object System.Drawing.Bitmap ($rect.r - $rect.l), ($rect.b - $rect.t)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $dc = $graphics.GetHdc()
        [void][GhosttyDeviceLost.Win32]::PrintWindow($window, $dc, 2)
        $graphics.ReleaseHdc($dc)
        $graphics.Dispose()

        $middle = Hex $bitmap.GetPixel([int]($bitmap.Width * 0.6), [int]($bitmap.Height * 0.6))
        $text = 0
        for ($y = [int]($bitmap.Height * 0.05); $y -lt [int]($bitmap.Height * 0.15); $y += 2) {
            for ($x = 0; $x -lt [int]($bitmap.Width * 0.3); $x += 2) {
                if ((Hex $bitmap.GetPixel($x, $y)) -ne $background) { $text++ }
            }
        }
        [pscustomobject]@{ Middle = $middle; Text = $text }
    } finally { $bitmap.Dispose() }
}

# Start Ghostty with the device lost at its third present, and check it
# draws the given background, and text, once it's replaced.
function Check([string]$name, [string[]]$extra, [string]$background) {
    $script:log = Join-Path $work "$name.log"
    $env:GHOSTTY_D3D11_LOSE_DEVICE = '3'
    try {
        $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList (@('--command=cmd.exe', `
                    '--window-save-state=never', '--background=#336699') + $extra)
    } finally {
        Remove-Item Env:GHOSTTY_D3D11_LOSE_DEVICE
    }
    try {
        $script:window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
        [void](WaitFor { LogHas 'simulating a lost device' } 'the simulated device loss (this needs a debug build)')
        [void](WaitFor { LogHas 'recreated the device after it was lost' } 'the device to be replaced')
        [void](WaitFor { LogHas 'renderer health status change status=.healthy' } 'the renderer to be healthy again')
        [void](WaitFor { $script:last = Look $background; $last.Middle -eq $background -and $last.Text -gt 20 } "$background and text to show")
        if (LogHas 'error drawing') { Fail 'a frame failed after the device was replaced' }
        Write-Host "${name}: after the device was replaced, the terminal shows $($last.Middle) and text ($($last.Text) pixels)."
    } finally {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
}

try {
    Check 'plain' @() '#336699'
    Check 'shader' @("--custom-shader=$shader") '#996633'
    Check 'background-image' @("--background-image=$image", '--background-image-fit=stretch') '#CC3300'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
