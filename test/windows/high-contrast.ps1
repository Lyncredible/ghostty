# Checks, for CI, that the tab bar (which we draw ourselves) uses the
# system colors of a high contrast theme: it starts Ghostty with the tab
# bar shown and a blue background, checks the bar's color on screen comes
# from the terminal's, turns high contrast on (SPI_SETHIGHCONTRAST) and
# expects the theme's window color, then turns it off again and expects the
# terminal's again. It changes the whole desktop, so it only runs in CI.
#
#     ./high-contrast.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this turns high contrast on for the whole desktop, so it only runs in CI" }

trap {
    if (-not $script:reported) { Write-Host "::error title=high-contrast::$($_.Exception.Message)" }
    break
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace GhosttyContrast -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct HIGHCONTRAST { public int cbSize; public uint dwFlags; public System.IntPtr scheme; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetSysColor(int index);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfoW(uint action, uint size, ref HIGHCONTRAST hc, uint ini);
public static bool HighContrast() {
  var hc = new HIGHCONTRAST(); hc.cbSize = Marshal.SizeOf(hc);
  SystemParametersInfoW(0x42, (uint)hc.cbSize, ref hc, 0); // SPI_GETHIGHCONTRAST
  return (hc.dwFlags & 1) != 0;
}
public static bool SetHighContrast(bool on) {
  var hc = new HIGHCONTRAST(); hc.cbSize = Marshal.SizeOf(hc); hc.dwFlags = on ? 1u : 0u;
  return SystemParametersInfoW(0x43, (uint)hc.cbSize, ref hc, 2); // SPI_SETHIGHCONTRAST, SPIF_SENDCHANGE
}
'@
[void][GhosttyContrast.Win32]::SetProcessDPIAware()

$wasOn = [GhosttyContrast.Win32]::HighContrast()
if ($wasOn) { [void][GhosttyContrast.Win32]::SetHighContrast($false) }
$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', `
    '--window-save-state=never', '--window-show-tab-bar=always', '--background=#336699'

function Fail([string]$message) {
    Write-Host "::error title=high-contrast::$message"
    $script:reported = $true
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
    Fail "timed out waiting for $what (the tab bar was $script:last)"
}

# The color of the tab bar's empty part, on screen, as #RRGGBB.
function BarColor {
    $rect = New-Object GhosttyContrast.Win32+RECT
    [void][GhosttyContrast.Win32]::GetWindowRect($bar, [ref]$rect)
    $bitmap = New-Object System.Drawing.Bitmap 1, 1
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $x = $rect.l + [int](($rect.r - $rect.l) * 0.7)
    $graphics.CopyFromScreen($x, $rect.t + 2, 0, 0, (New-Object System.Drawing.Size 1, 1))
    $pixel = $bitmap.GetPixel(0, 0)
    $graphics.Dispose(); $bitmap.Dispose()
    '#{0:X2}{1:X2}{2:X2}' -f $pixel.R, $pixel.G, $pixel.B
}

function SysColor([int]$index) {
    $v = [GhosttyContrast.Win32]::GetSysColor($index)
    '#{0:X2}{1:X2}{2:X2}' -f ($v -band 0xFF), (($v -shr 8) -band 0xFF), (($v -shr 16) -band 0xFF)
}

# The bar is the terminal's background darkened by a quarter.
# (rounding halves away from zero, as the tab bar does).
function Darken([int]$v) { [int][Math]::Round($v * 0.75, [MidpointRounding]::AwayFromZero) }
$terminal = '#{0:X2}{1:X2}{2:X2}' -f (Darken 0x33), (Darken 0x66), (Darken 0x99)

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $process.Refresh() }
    $window = $process.MainWindowHandle
    if ($window -eq 0) { Fail 'no window' }
    $bar = [GhosttyContrast.Win32]::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null)
    if ($bar -eq [IntPtr]::Zero) { Fail 'no tab bar' }
    [void][GhosttyContrast.Win32]::SetForegroundWindow($window)

    [void](WaitFor { $script:last = BarColor; $last -eq $terminal } "the tab bar to be $terminal")
    Write-Host "Without high contrast, the tab bar is $last, from the terminal's background."

    if (-not [GhosttyContrast.Win32]::SetHighContrast($true)) { Fail "couldn't turn high contrast on" }
    $expected = WaitFor { if ([GhosttyContrast.Win32]::HighContrast()) { SysColor 5 } } 'high contrast to be on'   # COLOR_WINDOW
    [void](WaitFor { $script:last = BarColor; $last -eq $expected } "the tab bar to be the theme's window color $expected")
    Write-Host "With high contrast, the tab bar is $last, the theme's window color."

    if (-not [GhosttyContrast.Win32]::SetHighContrast($false)) { Fail "couldn't turn high contrast off" }
    [void](WaitFor { $script:last = BarColor; $last -eq $terminal } "the tab bar to be $terminal again")
    Write-Host "With high contrast off again, the tab bar is $last."
} catch {
    if (-not $script:reported) { Write-Host "::error title=high-contrast::$($_.Exception.Message)" }
    $script:reported = $true
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    [void][GhosttyContrast.Win32]::SetHighContrast($wasOn)
}
