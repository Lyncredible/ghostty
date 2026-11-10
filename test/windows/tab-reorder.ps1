# Checks reordering tabs by dragging: the second tab, named with cmd's
# `title` (the shell integration's titles are off so the name stays), is
# dragged over the first one with posted mouse messages, and UI Automation
# then lists it first. Then `move_tab:1` from a keybind moves it back to
# second, and `move_tab:1` again (past the end) wraps it around to first,
# like the other platforms, and `copy_title_to_clipboard` copies its title.
# The tabs' positions come from UI Automation, so it
# follows the tab bar's layout (margins and gaps between tabs) and runs on
# a locked desktop.
#
#     ./tab-reorder.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=tab-reorder::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyTabReorder -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ScreenToClient(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
// A mouse message to h at a point on the screen.
public static void Mouse(System.IntPtr h, uint msg, uint keys, int x, int y) {
  var p = new POINT { x = x, y = y }; ScreenToClient(h, ref p);
  PostMessageW(h, msg, (System.IntPtr)keys, (System.IntPtr)((p.x & 0xFFFF) | (p.y << 16)));
}
// Characters, as WM_CHAR.
public static void Type(System.IntPtr h, string s) {
  foreach (char ch in s) { PostMessageW(h, 0x0102, (System.IntPtr)ch, (System.IntPtr)1); System.Threading.Thread.Sleep(5); }
}
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyTabReorder.Win32]
[void]$W::SetThreadDpiAwarenessContext([IntPtr]-4)   # per monitor v2, like Ghostty

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-tab-reorder-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--shell-integration-features=no-title', '--keybind=f5=new_tab',
    '--keybind=f6=move_tab:1', '--keybind=f7=copy_title_to_clipboard'

function Fail([string]$message) {
    Write-Host "::error title=tab-reorder::$message"
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
    $script:note = "tabs: " + (($list | ForEach-Object { $_.Current.Name }) -join ', ')
    , $list
}
function Shown { $h = [IntPtr]::Zero; while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { if ($W::IsWindowVisible($h)) { return $h } } }
function Center($element) {
    $r = $element.Current.BoundingRectangle
    @{ X = [int]($r.X + $r.Width / 2); Y = [int]($r.Y + $r.Height / 2) }
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $bar = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', [NullString]::Value); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the tab bar'
    [void](WaitFor { Shown } 'the first terminal')

    # A second tab, named SECOND by cmd. An elevated console (as on CI
    # runners) prefixes titles with "Administrator: ", so names are matched
    # at their end.
    $first = Shown
    $W::Key($first, 0x74, 0x3F)   # F5: new_tab
    $second = WaitFor { $s = Shown; if ($s -and $s -ne $first) { $s } } 'the second tab'
    Start-Sleep -Seconds 2
    $W::Type($second, "title SECOND`r")
    [void](WaitFor { $t = Tabs; $t.Count -eq 2 -and $t[1].Current.Name -match 'SECOND$' } 'the second tab to be named SECOND')
    Write-Host "Before: $note."

    # Drag the second tab over the first, and let go there (in the bar).
    $t = Tabs
    $from = Center $t[1]; $to = Center $t[0]
    $W::Mouse($bar, 0x0201, 1, $from.X, $from.Y)                 # WM_LBUTTONDOWN
    $W::Mouse($bar, 0x0200, 1, $from.X - 20, $from.Y)            # WM_MOUSEMOVE, past the drag threshold
    $W::Mouse($bar, 0x0200, 1, $to.X, $to.Y)
    $W::Mouse($bar, 0x0202, 0, $to.X, $to.Y)                     # WM_LBUTTONUP
    [void](WaitFor { $t = Tabs; $t.Count -eq 2 -and $t[0].Current.Name -match 'SECOND$' } 'SECOND to be the first tab')
    if ((Shown) -ne $second) { Fail 'the dragged tab is no longer the one shown' }
    Write-Host "After dragging the second tab onto the first: $note, and it's still the one shown."

    $W::Key($second, 0x75, 0x40)   # F6: move_tab:1
    [void](WaitFor { $t = Tabs; $t.Count -eq 2 -and $t[1].Current.Name -match 'SECOND$' } 'move_tab:1 to move SECOND back to second')
    $W::Key($second, 0x75, 0x40)
    [void](WaitFor { $t = Tabs; $t.Count -eq 2 -and $t[0].Current.Name -match 'SECOND$' } 'move_tab:1 past the end to wrap SECOND around to first')
    if ((Shown) -ne $second) { Fail 'the moved tab is no longer the one shown' }
    Write-Host "move_tab:1 moved it back to second, and again wrapped it around to first: $note."

    Set-Clipboard -Value 'not the title'
    $W::Key($second, 0x76, 0x41)   # F7: copy_title_to_clipboard
    [void](WaitFor { (Get-Clipboard -Raw) -match 'SECOND$' } 'the title on the clipboard')
    Write-Host "copy_title_to_clipboard copied '$(Get-Clipboard -Raw)'."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
