# Checks that screen readers can close tabs: each tab (a TabItem) has a
# "Close Tab" button as its child, at the close button's place, and
# invoking it closes that tab. Uses UI Automation and posted keys, so it
# runs on a locked desktop.
#
#     ./tab-close-uia.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyTabCloseUia -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyTabCloseUia.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-tab-close-uia-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--confirm-close-surface=false', '--keybind=f5=new_tab'

function Fail([string]$message) {
    Write-Host "::error title=tab-close-uia::$message"
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
    Fail "timed out waiting for $what ($script:note)"
}

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
function Tabs {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $list = @($AE::FromHandle($bar).FindAll($Scope::Children, $condition))
    $script:note = "$($list.Count) tabs"
    , $list
}
function Shown { $h = [IntPtr]::Zero; while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', $null)) -ne [IntPtr]::Zero) { if ($W::IsWindowVisible($h)) { return $h } } }

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $bar = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the tab bar'
    $first = WaitFor { Shown } 'the first terminal'
    $W::Key($first, 0x74, 0x3F)   # F5: new_tab
    $tabs = WaitFor { $t = Tabs; if ($t.Count -eq 2) { , $t } } 'a second tab'

    # Each tab's only child is its close button, inside the tab.
    $buttons = foreach ($tab in $tabs) {
        $children = @($tab.FindAll($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition))
        if ($children.Count -ne 1) { Fail "tab '$($tab.Current.Name)' has $($children.Count) children, not one close button" }
        $button = $children[0]
        if ($button.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button -or $button.Current.Name -ne 'Close Tab') {
            Fail "tab '$($tab.Current.Name)' has '$($button.Current.Name)' ($($button.Current.ControlType.ProgrammaticName)), not a Close Tab button"
        }
        $outer = $tab.Current.BoundingRectangle; $inner = $button.Current.BoundingRectangle
        if (-not $outer.Contains($inner) -or $inner.Width -le 0) { Fail "the close button ($inner) isn't inside its tab ($outer)" }
        $button
    }
    Write-Host 'Both tabs have a Close Tab button inside them.'

    # Screen readers say "2 of 3" from PositionInSet and SizeOfSet, which
    # the managed API predates, so they're looked up by ID.
    $positionProperty = [System.Windows.Automation.AutomationProperty]::LookupById(30152)
    $sizeProperty = [System.Windows.Automation.AutomationProperty]::LookupById(30153)
    if ($positionProperty -and $sizeProperty) {
        for ($i = 0; $i -lt $tabs.Count; $i++) {
            $position = $tabs[$i].GetCurrentPropertyValue($positionProperty)
            $size = $tabs[$i].GetCurrentPropertyValue($sizeProperty)
            if ($position -ne $i + 1 -or $size -ne $tabs.Count) { Fail "tab $($i + 1) reports $position of $size, not $($i + 1) of $($tabs.Count)" }
        }
        Write-Host "The tabs report their positions: 1 of 2 and 2 of 2."
    } else {
        Write-Host '::notice title=tab-close-uia::this UI Automation client has no PositionInSet or SizeOfSet, so they weren''t checked'
    }

    # Invoking the second tab's closes it, leaving the first.
    $firstName = $tabs[0].Current.Name
    $buttons[1].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    [void](WaitFor { $t = Tabs; $t.Count -eq 1 } 'Close Tab to close the second tab')
    if ((Tabs)[0].Current.Name -ne $firstName) { Fail "the wrong tab closed: '$((Tabs)[0].Current.Name)' is left" }
    Write-Host 'Invoking the second tab''s Close Tab button closed it.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
