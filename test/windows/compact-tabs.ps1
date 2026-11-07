# Checks compact tabs: with many tabs in a narrow window, each tab shows
# only its number and has no close button, so a click where the close
# button would be (near the tab's right edge) selects the tab instead of
# closing it. Clicks are posted mouse messages at positions from UI
# Automation, so it runs on a locked desktop.
#
#     ./compact-tabs.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$Tabs = 12,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=compact-tabs::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyCompactTabs -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ScreenToClient(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
// A mouse message to h at a point on the screen.
public static void Mouse(System.IntPtr h, uint msg, uint keys, int x, int y) {
  var p = new POINT { x = x, y = y }; ScreenToClient(h, ref p);
  PostMessageW(h, msg, (System.IntPtr)keys, (System.IntPtr)((p.x & 0xFFFF) | (p.y << 16)));
}
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyCompactTabs.Win32]
[void]$W::SetThreadDpiAwarenessContext([IntPtr]-4)   # per monitor v2, like Ghostty

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-compact-tabs-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--window-width=60', '--window-height=10', '--keybind=f5=new_tab'

function Fail([string]$message) {
    Write-Host "::error title=compact-tabs::$message"
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
    Fail "timed out waiting for $what ($script:note)"
}

$AE = [System.Windows.Automation.AutomationElement]
# The tab bar's tabs, in order, as UI Automation lists them.
function Tabs {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $list = @($AE::FromHandle($bar).FindAll([System.Windows.Automation.TreeScope]::Children, $condition))
    $script:note = "$($list.Count) tabs"
    , $list
}
function Selected($element) { $element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected }
function Shown { $h = [IntPtr]::Zero; while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', $null)) -ne [IntPtr]::Zero) { if ($W::IsWindowVisible($h)) { return $h } } }

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $bar = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the tab bar'
    [void](WaitFor { Shown } 'the first terminal')

    for ($i = 1; $i -lt $Tabs; $i++) {
        $before = Shown
        $W::Key($before, 0x74, 0x3F)   # F5: new_tab
        [void](WaitFor { $s = Shown; if ($s -and $s -ne $before) { $s } } "tab $($i + 1)")
    }
    $t = WaitFor { $t = Tabs; if ($t.Count -eq $Tabs) { , $t } } "$Tabs tabs"
    $scale = $W::GetDpiForWindow($window) / 96.0
    $width = $t[0].Current.BoundingRectangle.Width / $scale
    if ($width -ge 88) { Fail "the tabs are $([int]$width) points wide, not compact (under 88); make the window narrower or add tabs" }
    Write-Host "$Tabs tabs, $([int]$width) points wide each."

    # Where a normal tab's close button is: 16 points from the right edge,
    # centered. On a compact tab, a click there selects the tab.
    $target = $t[2]
    $r = $target.Current.BoundingRectangle
    $x = [int]($r.Right - 16 * $scale); $y = [int]($r.Y + $r.Height / 2 - 2 * $scale)
    $W::Mouse($bar, 0x0201, 1, $x, $y)   # WM_LBUTTONDOWN
    $W::Mouse($bar, 0x0202, 0, $x, $y)   # WM_LBUTTONUP
    [void](WaitFor { $t = Tabs; $t.Count -eq $Tabs -and (Selected $t[2]) } 'the third tab to be selected')
    Start-Sleep -Seconds 1
    if ((Tabs).Count -ne $Tabs) { Fail "a click near a compact tab's right edge closed it ($note)" }
    Write-Host 'A click where the close button would be selected the compact tab and closed nothing.'

    # A middle click still closes a compact tab.
    $W::Mouse($bar, 0x0207, 0x10, $x, $y)   # WM_MBUTTONDOWN
    $W::Mouse($bar, 0x0208, 0, $x, $y)      # WM_MBUTTONUP
    [void](WaitFor { (Tabs).Count -eq $Tabs - 1 } 'a middle click to close the tab')
    Write-Host 'A middle click closed it.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
