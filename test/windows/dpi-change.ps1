# Checks, for CI, that a terminal follows a DPI change while it runs: it
# raises the display's scale the way the Settings app does
# (SPI_SETLOGICALDPIOVERRIDE), which sends windows the same WM_DPICHANGED
# as moving them to a monitor with another scale, and checks that the
# window kept its size in inches and the font its size in points (cells
# grow with the DPI). A small display only offers 100%, so it first
# switches to the largest display mode, and the window starts small enough
# to grow on it (Windows keeps the suggested size on the screen). It
# changes the desktop, so it only runs in CI.
#
#     ./dpi-change.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this changes the display's resolution and scale, so it only runs in CI" }

function Notice([string]$message) { Write-Host "::notice title=dpi-change::$message" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyDpi -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct DEVMODE {
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
  public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
  public int dmPositionX, dmPositionY; public int dmDisplayOrientation, dmDisplayFixedOutput;
  public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
  public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
  public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettingsW(string device, int mode, ref DEVMODE dm);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettingsW(ref DEVMODE dm, int flags);
[DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, int param, System.IntPtr pv, uint flags);
[DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint param, out int pv, uint flags);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern System.IntPtr SetProcessDpiAwarenessContext(System.IntPtr value);
// The largest mode the display offers, by area.
public static DEVMODE Largest() {
  var best = new DEVMODE(); best.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
  var dm = new DEVMODE(); dm.dmSize = best.dmSize;
  for (int i = 0; EnumDisplaySettingsW(null, i, ref dm); i++)
    if ((long)dm.dmPelsWidth * dm.dmPelsHeight > (long)best.dmPelsWidth * best.dmPelsHeight) best = dm;
  return best;
}
public static DEVMODE Current() {
  var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
  EnumDisplaySettingsW(null, -1, ref dm); return dm;
}
// SPI_GETLOGICALDPIOVERRIDE and SPI_SETLOGICALDPIOVERRIDE (undocumented,
// what the Settings app uses): the scale in steps from the recommended one.
public static int GetScaleStep() { int v; SystemParametersInfoW(0x009E, 0, out v, 0); return v; }
public static bool SetScaleStep(int step) { return SystemParametersInfoW(0x009F, step, System.IntPtr.Zero, 1); }
'@
# Per-monitor DPI aware, so that sizes we read aren't scaled for us.
[void][GhosttyDpi.Win32]::SetProcessDpiAwarenessContext([IntPtr]-4)

$originalMode = [GhosttyDpi.Win32]::Current()
$originalStep = [GhosttyDpi.Win32]::GetScaleStep()
$largest = [GhosttyDpi.Win32]::Largest()
Notice "display $($originalMode.dmPelsWidth)x$($originalMode.dmPelsHeight), largest mode $($largest.dmPelsWidth)x$($largest.dmPelsHeight), scale step $originalStep"
if ($largest.dmPelsWidth * $largest.dmPelsHeight -gt $originalMode.dmPelsWidth * $originalMode.dmPelsHeight) {
    $largest.dmFields = 0x180000 # DM_PELSWIDTH | DM_PELSHEIGHT
    $result = [GhosttyDpi.Win32]::ChangeDisplaySettingsW([ref]$largest, 0)
    Notice "switching to $($largest.dmPelsWidth)x$($largest.dmPelsHeight): result $result"
    Start-Sleep -Seconds 2
}

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-dpi-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList `
    '--command=cmd.exe', '--window-save-state=never', '--font-size=12', '--window-width=60', '--window-height=15'

function Fail([string]$message) {
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    Write-Host "::error title=dpi-change::$message"
    throw $message
}

function Surface {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
            if ($surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value.Contains('>')) {
                return @{ Window = [IntPtr]$window.Current.NativeWindowHandle; Handle = [IntPtr]$surface.Current.NativeWindowHandle }
            }
        }
    }
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

# The last cell size in the log.
function CellSize {
    $cell = [regex]::Matches((Get-Content $log -Raw), '\.cell = \.\{ \.width = (\d+), \.height = (\d+)') | Select-Object -Last 1
    if ($cell) { @{ Width = [int]$cell.Groups[1].Value; Height = [int]$cell.Groups[2].Value } }
}

function ClientWidth($hwnd) {
    $rect = New-Object GhosttyDpi.Win32+RECT
    [void][GhosttyDpi.Win32]::GetClientRect($hwnd, [ref]$rect)
    return $rect.r - $rect.l
}

try {
    $surface = WaitFor { Surface } 'the prompt'
    $dpi = [GhosttyDpi.Win32]::GetDpiForWindow($surface.Window)
    $width = ClientWidth $surface.Window
    $cell = WaitFor { CellSize } 'a cell size in the log'
    Write-Host "Before: DPI $dpi, client width $width px, cells $($cell.Width)x$($cell.Height) px."

    # One step at a time, up to three, until the DPI changes.
    $newDpi = $dpi
    for ($step = $originalStep + 1; $step -le $originalStep + 3 -and $newDpi -eq $dpi; $step++) {
        $ok = [GhosttyDpi.Win32]::SetScaleStep($step)
        Start-Sleep -Seconds 2
        $newDpi = [GhosttyDpi.Win32]::GetDpiForWindow($surface.Window)
        Notice "scale step $step (ok=$ok): the window's DPI is $newDpi"
    }
    if ($newDpi -eq $dpi) { Fail "the display's scale couldn't be raised (DPI stayed $dpi)" }

    $ratio = $newDpi / $dpi
    $grown = WaitFor { $c = CellSize; if ($c.Height -gt $cell.Height) { $c } } 'larger cells after the DPI change'
    $newWidth = ClientWidth $surface.Window
    Select-String -Path $log -Pattern 'dpi changed .*' | ForEach-Object { Notice $_.Matches[0].Value }
    Write-Host "After: DPI $newDpi, client width $newWidth px, cells $($grown.Width)x$($grown.Height) px."

    # The font keeps its size in points, so cells grow with the DPI (to
    # within rounding), and so does the window, which keeps its size in
    # inches (Windows suggests the new size in WM_DPICHANGED).
    $cellRatio = $grown.Height / $cell.Height
    if ([math]::Abs($cellRatio - $ratio) -gt 0.2) { Fail "cells grew by $cellRatio for a DPI change of $ratio" }
    $widthRatio = $newWidth / $width
    if ([math]::Abs($widthRatio - $ratio) -gt 0.1) { Fail "the window grew by $widthRatio for a DPI change of $ratio" }
    Write-Host "A DPI change of $ratio grew cells by $([math]::Round($cellRatio, 2)) and the window by $([math]::Round($widthRatio, 2))."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    [void][GhosttyDpi.Win32]::SetScaleStep($originalStep)
    $originalMode.dmFields = 0x180000
    [void][GhosttyDpi.Win32]::ChangeDisplaySettingsW([ref]$originalMode, 0)
}
