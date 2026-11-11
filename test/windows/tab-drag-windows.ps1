# Checks dragging a tab from one window to another, with posted mouse
# messages: dropped on the other window's tab bar it goes where the
# pointer is (before a tab, or after one), and dropped on its terminal it
# goes after the last tab. While it's dragged outside its own bar, the
# tab's picture follows the pointer. The two windows are placed one above
# the other first, so that neither covers the other. The tabs are named
# with cmd's `title` (the shell integration's titles are off so the names
# stay), and their order and positions come from UI Automation.
#
# Then, started again without window decorations (so that a window with
# one tab shows no tab bar): a tab dragged over such a window marks it
# with a line along the top of its terminal, which goes when the pointer
# leaves the window, and dropped there the tab joins it.
#
#     ./tab-drag-windows.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=tab-drag-windows::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyTabDragWindows -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ScreenToClient(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
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
$W = [GhosttyTabDragWindows.Win32]
[void]$W::SetThreadDpiAwarenessContext([IntPtr]-4)   # per monitor v2, like Ghostty

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-tab-drag-windows-$PID.log"
function Launch([string[]]$more) {
    Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList (@('--command=cmd.exe',
        '--window-save-state=never', '--shell-integration-features=no-title', '--keybind=f5=new_tab',
        '--keybind=f8=new_window', "--class=ghostty-tab-drag-windows-$PID") + $more)
}
$process = Launch @()

function Fail([string]$message) {
    Write-Host "::error title=tab-drag-windows::$message"
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

# The process's visible top-level windows of a class.
function TopLevels([string]$class) {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, $class, [NullString]::Value)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $process.Id -and $W::IsWindowVisible($h)) { $h }
    }
}
function Bar([IntPtr]$window) { $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', [NullString]::Value) }
function Shown([IntPtr]$window) {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { if ($W::IsWindowVisible($h)) { return $h } }
}

$AE = [System.Windows.Automation.AutomationElement]
# A window's tabs, in order, as UI Automation lists them.
function Tabs([IntPtr]$window) {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    , @($AE::FromHandle((Bar $window)).FindAll([System.Windows.Automation.TreeScope]::Children, $condition))
}
# Their names' ends (an elevated console, as on CI runners, prefixes
# titles with "Administrator: "), like "AONE ATWO".
function Names([IntPtr]$window) {
    ((Tabs $window) | ForEach-Object { ($_.Current.Name -split '[ :]')[-1] }) -join ' '
}
function Both { $script:note = "first window: $(Names $first); second window: $(Names $second)"; $script:note }

# Name the tab that a window shows.
function Name([IntPtr]$window, [string]$name) {
    $W::Type((Shown $window), "title $name`r")
    [void](WaitFor { $script:note = Names $window; ((Names $window) -split ' ') -contains $name } "a tab named $name")
}

# Drag the tab of a window named $name to a point on the screen, checking
# on the way that its picture follows the pointer.
function Drag([IntPtr]$window, [string]$name, [int]$x, [int]$y) {
    $tab = (Tabs $window) | Where-Object { $_.Current.Name -match "$name$" } | Select-Object -First 1
    if (-not $tab) { Fail "no tab named $name to drag ($(Both))" }
    $r = $tab.Current.BoundingRectangle
    $fromX = [int]($r.X + $r.Width / 2); $fromY = [int]($r.Y + $r.Height / 2)
    $bar = Bar $window
    $W::Mouse($bar, 0x0201, 1, $fromX, $fromY)          # WM_LBUTTONDOWN
    Start-Sleep -Milliseconds 300
    $W::Mouse($bar, 0x0200, 1, $fromX, $fromY + 20)     # WM_MOUSEMOVE, past the drag threshold
    $W::Mouse($bar, 0x0200, 1, $x, $y)
    $script:note = 'no GhosttyTabGhost window'
    [void](WaitFor { @(TopLevels 'GhosttyTabGhost').Count -eq 1 } "the picture of $name under the pointer")
    $W::Mouse($bar, 0x0202, 0, $x, $y)                  # WM_LBUTTONUP
    [void](WaitFor { $script:note = 'still showing'; @(TopLevels 'GhosttyTabGhost').Count -eq 0 } "the picture of $name to go after the drop")
}

try {
    $first = WaitFor { $h = @(TopLevels 'GhosttyWindow'); if ($h.Count -eq 1) { $h[0] } } 'the window'
    [void](WaitFor { Shown $first } 'the first terminal')
    Start-Sleep -Seconds 2
    Name $first 'AONE'

    $one = Shown $first
    $W::Key($one, 0x74, 0x3F)   # F5: new_tab
    [void](WaitFor { $s = Shown $first; if ($s -and $s -ne $one) { $s } } 'the second tab')
    Start-Sleep -Seconds 2
    Name $first 'ATWO'

    $W::Key((Shown $first), 0x77, 0x42)   # F8: new_window
    $second = WaitFor { $h = @(TopLevels 'GhosttyWindow' | Where-Object { $_ -ne $first }); if ($h.Count -eq 1) { $h[0] } } 'the second window'
    [void](WaitFor { Shown $second } "the second window's terminal")
    Start-Sleep -Seconds 2
    Name $second 'BONE'

    # One above the other, so that neither covers the other's tab bar or
    # terminal. SWP_NOZORDER | SWP_NOACTIVATE.
    [void]$W::SetWindowPos($first, [IntPtr]::Zero, 20, 20, 1000, 420, 0x0014)
    [void]$W::SetWindowPos($second, [IntPtr]::Zero, 20, 460, 1000, 420, 0x0014)
    Start-Sleep -Seconds 1
    if ((Both) -ne 'first window: AONE ATWO; second window: BONE') { Fail "before the drags: $note" }
    Write-Host "Before: $note."

    # Onto the second window's tab bar, in the first half of its tab:
    # before it.
    $r = (Tabs $second)[0].Current.BoundingRectangle
    Drag $first 'ATWO' ([int]($r.X + $r.Width / 4)) ([int]($r.Y + $r.Height / 2))
    [void](WaitFor { (Both) -eq 'first window: AONE; second window: ATWO BONE' } 'ATWO before BONE in the second window')
    if (-not (Shown $second)) { Fail 'the second window shows no terminal after taking the tab' }
    Write-Host "Dropped on the first half of the other window's tab: $note."

    # Back onto the first window's tab bar, in the second half of its
    # tab: after it.
    $r = (Tabs $first)[0].Current.BoundingRectangle
    Drag $second 'ATWO' ([int]($r.X + $r.Width * 3 / 4)) ([int]($r.Y + $r.Height / 2))
    [void](WaitFor { (Both) -eq 'first window: AONE ATWO; second window: BONE' } 'ATWO after AONE in the first window')
    Write-Host "Dropped on the second half of the other window's tab: $note."

    # A tab from the second window before both: BONE is its only tab, so
    # the second window closes.
    $r = (Tabs $first)[0].Current.BoundingRectangle
    Drag $second 'BONE' ([int]($r.X + $r.Width / 4)) ([int]($r.Y + $r.Height / 2))
    [void](WaitFor { $script:note = "$(@(TopLevels 'GhosttyWindow').Count) windows, first: $(Names $first)"; @(TopLevels 'GhosttyWindow').Count -eq 1 -and (Names $first) -eq 'BONE AONE ATWO' } 'BONE before the others, and its window closed')
    Write-Host "A window's only tab dropped before the other window's tabs: first window: $(Names $first), and its window closed."

    # Out of the window, on nothing of ours: a new window. Then onto the
    # first window's terminal (not its tab bar): after the last tab.
    Drag $first 'AONE' 400 700
    $second = WaitFor { $script:note = "$(@(TopLevels 'GhosttyWindow').Count) windows"; $h = @(TopLevels 'GhosttyWindow' | Where-Object { $_ -ne $first }); if ($h.Count -eq 1) { $h[0] } } 'a new window for the tab dropped outside'
    [void](WaitFor { (Both) -eq 'first window: BONE ATWO; second window: AONE' } 'AONE alone in the new window')
    [void]$W::SetWindowPos($second, [IntPtr]::Zero, 20, 460, 1000, 420, 0x0014)
    Start-Sleep -Seconds 1
    Write-Host "Dropped outside: $note."
    Drag $second 'AONE' 500 300
    [void](WaitFor { $script:note = "$(@(TopLevels 'GhosttyWindow').Count) windows, first: $(Names $first)"; @(TopLevels 'GhosttyWindow').Count -eq 1 -and (Names $first) -eq 'BONE ATWO AONE' } 'AONE after the last tab of the first window')
    Write-Host "Dropped on the other window's terminal: first window: $(Names $first)."

    # Again without decorations: a window with one tab shows no tab bar.
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
    $process = Launch @('--window-decoration=none')
    $first = WaitFor { $h = @(TopLevels 'GhosttyWindow'); if ($h.Count -eq 1) { $h[0] } } 'the window without decorations'
    [void](WaitFor { Shown $first } 'its terminal')
    Start-Sleep -Seconds 2
    $one = Shown $first
    $W::Key($one, 0x74, 0x3F)   # F5: new_tab
    [void](WaitFor { $s = Shown $first; if ($s -and $s -ne $one) { $s } } 'its second tab')
    Start-Sleep -Seconds 2
    Name $first 'ATWO'
    $W::Key((Shown $first), 0x77, 0x42)   # F8: new_window
    $second = WaitFor { $h = @(TopLevels 'GhosttyWindow' | Where-Object { $_ -ne $first }); if ($h.Count -eq 1) { $h[0] } } 'the second window without decorations'
    [void](WaitFor { Shown $second } "the second window's terminal")
    Start-Sleep -Seconds 2
    [void]$W::SetWindowPos($first, [IntPtr]::Zero, 20, 20, 1000, 420, 0x0014)
    [void]$W::SetWindowPos($second, [IntPtr]::Zero, 20, 460, 1000, 420, 0x0014)
    Start-Sleep -Seconds 1
    if ($W::IsWindowVisible((Bar $second))) { Fail 'the second window shows a tab bar with one tab and no decorations' }

    $tab = (Tabs $first) | Where-Object { $_.Current.Name -match 'ATWO$' } | Select-Object -First 1
    if (-not $tab) { Fail 'no tab named ATWO to drag' }
    $r = $tab.Current.BoundingRectangle
    $fromX = [int]($r.X + $r.Width / 2); $fromY = [int]($r.Y + $r.Height / 2)
    $bar = Bar $first
    $W::Mouse($bar, 0x0201, 1, $fromX, $fromY)          # WM_LBUTTONDOWN
    Start-Sleep -Milliseconds 300
    $W::Mouse($bar, 0x0200, 1, $fromX, $fromY + 20)     # WM_MOUSEMOVE, past the drag threshold
    # Over the second window: the tab's picture, and the line on the window.
    $W::Mouse($bar, 0x0200, 1, 500, 650)
    $script:note = 'not two GhosttyTabGhost windows'
    [void](WaitFor { @(TopLevels 'GhosttyTabGhost').Count -eq 2 } 'the picture of ATWO and the mark on the window without a tab bar')
    $area = New-Object GhosttyTabDragWindows.Win32+RECT; [void]$W::GetWindowRect((Shown $second), [ref]$area)
    $marks = @(TopLevels 'GhosttyTabGhost' | Where-Object {
        $m = New-Object GhosttyTabDragWindows.Win32+RECT; [void]$W::GetWindowRect($_, [ref]$m)
        $m.left -eq $area.left -and $m.top -eq $area.top -and $m.right -eq $area.right -and ($m.bottom - $m.top) -lt 20
    })
    if ($marks.Count -ne 1) { Fail "no thin mark along the top of the second window's terminal" }
    # Over our own terminal: nothing to mark.
    $W::Mouse($bar, 0x0200, 1, 500, 300)
    [void](WaitFor { $script:note = 'the mark still shows'; @(TopLevels 'GhosttyTabGhost').Count -eq 1 } 'the mark to go when the pointer leaves the window')
    $W::Mouse($bar, 0x0200, 1, 500, 650)
    [void](WaitFor { $script:note = 'no mark'; @(TopLevels 'GhosttyTabGhost').Count -eq 2 } 'the mark again over the window')
    $W::Mouse($bar, 0x0202, 0, 500, 650)                # WM_LBUTTONUP
    [void](WaitFor { $script:note = 'still showing'; @(TopLevels 'GhosttyTabGhost').Count -eq 0 } 'the picture and the mark to go after the drop')
    [void](WaitFor { $script:note = "second window: $(Names $second)"; $W::IsWindowVisible((Bar $second)) -and (Tabs $second).Count -eq 2 -and (Names $second) -match 'ATWO$' } 'ATWO after the tab of the second window')
    Write-Host "Without decorations, a window with no tab bar was marked along its top while the tab was over it, and took the tab: $note."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
