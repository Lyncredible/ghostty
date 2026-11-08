# Checks that double clicking a tab renames it, as in Windows Terminal: a
# double click (posted mouse messages) on the second tab selects it and
# opens the "Change Tab Title" dialog, and the title given there becomes
# that tab's name (read with UI Automation) while the first keeps its own.
# The dialog's field is set with WM_SETTEXT and OK pressed with BM_CLICK. It
# shows a dialog, so it only runs in CI (or with $env:CI = 'true').
#
#     $env:CI = 'true'; ./tab-rename.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this shows dialogs, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyTabRename -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, string l);
[DllImport("user32.dll")] public static extern System.IntPtr GetDlgItem(System.IntPtr h, int id);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ScreenToClient(System.IntPtr h, ref POINT p);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Mouse(System.IntPtr h, uint msg, uint keys, int x, int y) {
  var p = new POINT { x = x, y = y }; ScreenToClient(h, ref p);
  PostMessageW(h, msg, (System.IntPtr)keys, (System.IntPtr)((p.x & 0xFFFF) | (p.y << 16)));
}
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyTabRename.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-tab-rename-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f5=new_tab'

function Fail([string]$message) {
    Write-Host "::error title=tab-rename::$message"
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
function Tabs {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $list = @($AE::FromHandle($bar).FindAll([System.Windows.Automation.TreeScope]::Children, $condition))
    $script:note = "tabs: " + (($list | ForEach-Object { $_.Current.Name }) -join ', ')
    , $list
}
function Shown { $h = [IntPtr]::Zero; while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', $null)) -ne [IntPtr]::Zero) { if ($W::IsWindowVisible($h)) { return $h } } }
function Dialog {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, '#32770', 'Change Tab Title')) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $process.Id) { return $h }
    }
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $bar = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the tab bar'
    $first = WaitFor { Shown } 'the first terminal'
    $W::Key($first, 0x74, 0x3F)   # F5: new_tab
    [void](WaitFor { $s = Shown; $s -and $s -ne $first } 'the second tab')
    $tabs = WaitFor { $t = Tabs; if ($t.Count -eq 2) { , $t } } 'two tabs'
    $firstName = $tabs[0].Current.Name

    # Select the first tab, then double click the second, left of its
    # close button.
    $r = $tabs[0].Current.BoundingRectangle
    $W::Mouse($bar, 0x0201, 1, [int]($r.X + 20), [int]($r.Y + $r.Height / 2))
    $W::Mouse($bar, 0x0202, 0, [int]($r.X + 20), [int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 500
    $r = $tabs[1].Current.BoundingRectangle
    $x = [int]($r.X + 20); $y = [int]($r.Y + $r.Height / 2)
    $W::Mouse($bar, 0x0201, 1, $x, $y)   # WM_LBUTTONDOWN
    $W::Mouse($bar, 0x0202, 0, $x, $y)   # WM_LBUTTONUP
    $W::Mouse($bar, 0x0203, 1, $x, $y)   # WM_LBUTTONDBLCLK
    $W::Mouse($bar, 0x0202, 0, $x, $y)   # WM_LBUTTONUP

    $dialog = WaitFor { Dialog } 'the Change Tab Title dialog'
    $edit = $W::FindWindowExW($dialog, [IntPtr]::Zero, 'Edit', $null)
    if ($edit -eq [IntPtr]::Zero) { Fail 'the dialog has no text field' }
    [void]$W::SendMessageW($edit, 0x000C, [IntPtr]::Zero, 'Renamed Tab')   # WM_SETTEXT
    [void]$W::PostMessageW($W::GetDlgItem($dialog, 1), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK on OK
    [void](WaitFor { -not (Dialog) } 'the dialog to close')

    [void](WaitFor { $t = Tabs; $t.Count -eq 2 -and $t[1].Current.Name -eq 'Renamed Tab' } 'the second tab to be renamed')
    if ((Tabs)[0].Current.Name -ne $firstName) { Fail "the first tab's name changed too ($note)" }
    Write-Host "Double clicking the second tab opened Change Tab Title, which renamed it ($note)."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
