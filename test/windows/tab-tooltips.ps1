# Checks, for CI, the tab bar's tooltips: it opens a terminal with the tab
# bar shown, moves the real cursor over the "New Tab" button and then over
# the tab, and checks that a tooltip with each one's name appears. It moves
# the mouse, so it only runs in CI.
#
#     ./tab-tooltips.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this moves the mouse, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyTooltip -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][GhosttyTooltip.Win32]::SetProcessDPIAware()

$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', '--window-save-state=never', '--window-show-tab-bar=always'

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$ByProcess = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $process.Id)

function TopLevel {
    $AE::RootElement.FindAll($Scope::Children, $ByProcess)
}

# The window's element of this control type, and name if given.
function Find([System.Windows.Automation.ControlType]$type, [string]$name) {
    foreach ($window in TopLevel) {
        foreach ($element in $window.FindAll($Scope::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $type)))) {
            if (-not $name -or $element.Current.Name -eq $name) { return $element }
        }
    }
}

# The text of the process's visible tooltip. UI Automation lists it either
# at the top level or under the window that owns it.
function Tooltip {
    $byClass = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'tooltips_class32')
    foreach ($window in TopLevel) {
        $tips = @($window) + @($window.FindAll($Scope::Descendants, $byClass))
        foreach ($tip in $tips) {
            if ($tip.Current.ClassName -eq 'tooltips_class32' -and -not $tip.Current.IsOffscreen) {
                return $tip.Current.Name
            }
        }
    }
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what (tooltip: '$(Tooltip)')"
}

# Move the cursor to the element's center, in two steps so the tab bar
# sees a move inside it.
function Hover($element) {
    $r = $element.Current.BoundingRectangle
    $x = [int]($r.X + $r.Width / 2)
    $y = [int]($r.Y + $r.Height / 2)
    [void][GhosttyTooltip.Win32]::SetCursorPos($x - 2, $y)
    Start-Sleep -Milliseconds 100
    [void][GhosttyTooltip.Win32]::SetCursorPos($x, $y)
}

try {
    $window = WaitFor { TopLevel | Where-Object { $_.Current.ClassName -ne 'tooltips_class32' } | Select-Object -First 1 } 'the window'
    [void][GhosttyTooltip.Win32]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle)

    $button = WaitFor { Find ([System.Windows.Automation.ControlType]::Button) 'New Tab' } 'the New Tab button'
    Hover $button
    [void](WaitFor { (Tooltip) -eq 'New Tab' } 'the New Tab tooltip')
    Write-Host "Hovering the New Tab button shows its tooltip."

    $tab = WaitFor { Find ([System.Windows.Automation.ControlType]::TabItem) } 'the tab'
    Hover $tab
    # The shell can change the title meanwhile, so compare with the current one.
    $title = WaitFor { $t = $tab.Current.Name; if ((Tooltip) -eq $t) { $t } } "the tab's tooltip ('$($tab.Current.Name)')"
    Write-Host "Hovering the tab shows its title, '$title'."

    # A title longer than the tooltip's buffer (255 UTF-16 units) used to
    # overflow it. It's cut to what fits, and the emoji whose two units
    # would straddle the end is left out whole.
    Stop-Process -Id $process.Id -Force
    $long = ('x' * 254) + [char]::ConvertFromUtf32(0x1F600) + ('y' * 100)
    $process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', '--window-save-state=never',
        '--window-show-tab-bar=always', "`"--title=$long`""
    $ByProcess = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $process.Id)
    $window = WaitFor { TopLevel | Where-Object { $_.Current.ClassName -ne 'tooltips_class32' } | Select-Object -First 1 } 'the long title window'
    [void][GhosttyTooltip.Win32]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle)
    $tab = WaitFor { $t = Find ([System.Windows.Automation.ControlType]::TabItem); if ($t -and $t.Current.Name -eq $long) { $t } } 'the tab with the long title'
    Hover $tab
    [void](WaitFor { (Tooltip) -eq ('x' * 254) } "the long title's tooltip, cut to 254 units")
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) { throw "Ghostty exited after showing the long title's tooltip" }
    Write-Host "A 356 unit title's tooltip is cut to the 254 units before its emoji, and Ghostty keeps running."
} catch {
    Write-Host "::error title=tab-tooltips::$($_.Exception.Message)"
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
