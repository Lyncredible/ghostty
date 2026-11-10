# Checks, for CI, that a running terminal follows Windows's light and dark
# app mode: it starts Ghostty with a light and a dark theme in light mode,
# switches Windows to dark mode (AppsUseLightTheme, then the settings change
# broadcast the Settings app sends), and back, and checks the terminal's
# background color from the screen each time. It changes the whole desktop,
# so it only runs in CI.
#
#     ./dark-mode.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this switches the desktop between light and dark mode, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -Namespace GhosttyTheme -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessageTimeoutW(
  System.IntPtr h, uint m, System.IntPtr w, string l, uint flags, uint timeout, out System.IntPtr result);
// What the Settings app broadcasts when the app mode changes.
public static void BroadcastColorSet() {
  System.IntPtr result;
  SendMessageTimeoutW((System.IntPtr)0xFFFF, 0x001A, System.IntPtr.Zero, "ImmersiveColorSet", 0x2, 5000, out result);
}
'@
[void][GhosttyTheme.Win32]::SetProcessDPIAware()

$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
if (-not (Test-Path $personalize)) { New-Item -Force $personalize | Out-Null }
$original = (Get-ItemProperty $personalize -ErrorAction SilentlyContinue).AppsUseLightTheme

function SetLightMode([int]$light) {
    Set-ItemProperty $personalize -Name AppsUseLightTheme -Value $light -Type DWord
    [GhosttyTheme.Win32]::BroadcastColorSet()
}

SetLightMode 1
$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', '--window-save-state=never', '"--theme=light:Builtin Light,dark:Builtin Dark"'

function SurfaceHandle {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
            $text = $(try { $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' })
            if ($text.Contains('>')) {
                return @{ Window = [IntPtr]$window.Current.NativeWindowHandle; Handle = [IntPtr]$surface.Current.NativeWindowHandle }
            }
        }
    }
}

# The brightness (0 to 255) of the terminal's background, from a pixel near
# its bottom right corner, away from the prompt.
function Brightness($surface) {
    $rect = New-Object GhosttyTheme.Win32+RECT
    [void][GhosttyTheme.Win32]::GetWindowRect($surface.Handle, [ref]$rect)
    $bitmap = New-Object System.Drawing.Bitmap 1, 1
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.r - 20, $rect.b - 20, 0, 0, (New-Object System.Drawing.Size 1, 1))
    $pixel = $bitmap.GetPixel(0, 0)
    $graphics.Dispose(); $bitmap.Dispose()
    return [int](($pixel.R + $pixel.G + $pixel.B) / 3)
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what (brightness $last)"
}

try {
    $surface = WaitFor { SurfaceHandle } 'the prompt'
    [void][GhosttyTheme.Win32]::SetForegroundWindow($surface.Window)
    [void](WaitFor { $script:last = Brightness $surface; $last -gt 200 } 'the light theme at startup')
    Write-Host "Light mode: the background's brightness is $last."

    SetLightMode 0
    [void](WaitFor { $script:last = Brightness $surface; $last -lt 60 } 'the dark theme after switching to dark mode')
    Write-Host "Dark mode: the background's brightness is $last."

    SetLightMode 1
    [void](WaitFor { $script:last = Brightness $surface; $last -gt 200 } 'the light theme after switching back')
    Write-Host "Light mode again: the background's brightness is $last."
} catch {
    Write-Host "::error title=dark-mode::$($_.Exception.Message)"
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if ($null -ne $original) { SetLightMode $original }
}
