# Checks the overlays a surface makes only when they first show: a new
# terminal has no badge, search bar, command palette, dim overlay, bell
# border, link preview, progress bar, drop zone or drag handle window. Toggling read-only
# mode (a posted F9 bound to `toggle_readonly`) must show one in the top
# right, in the order it would have been made in: just below the
# scrollbar. The search bar and command palette are made when they first
# open too, so a new surface has neither. Toggling read-only mode again
# must hide the badge. A bell (a posted F8 types `echo` and BEL) must
# show the bell border, just above the scrollbar. Then the search bar and
# the command palette (opened from the window menu) must show on top, and
# close again. Last, a split from the window menu must dim the first
# terminal, with its dim overlay above the bell border and below the
# search bar and palette. Then dragging the first terminal's drag handle
# (posted mouse messages) over the second must show its drop zone on top,
# and letting go over the first terminal must hide it and move nothing.
# The link preview isn't shown: it needs a real Ctrl key held down.
# It only posts messages to Ghostty's own window, so it can run anywhere.
#
#     ./overlays.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=overlays::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyBadges -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(System.IntPtr m);
[DllImport("user32.dll")] public static extern uint GetMenuItemID(System.IntPtr m, int pos);
[DllImport("user32.dll")] public static extern System.IntPtr GetSubMenu(System.IntPtr m, int pos);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(System.IntPtr m, uint item, System.Text.StringBuilder s, int n, uint flags);
// The command ID of the menu item with a label (without its &, its
// shortcut and a trailing ellipsis), in the menu or its submenus, or 0.
public static uint MenuCommand(System.IntPtr menu, string label) {
  int n = GetMenuItemCount(menu);
  for (int i = 0; i < n; i++) {
    var sub = GetSubMenu(menu, i);
    if (sub != System.IntPtr.Zero) { uint found = MenuCommand(sub, label); if (found != 0) return found; continue; }
    var s = new System.Text.StringBuilder(256);
    GetMenuStringW(menu, (uint)i, s, 256, 0x400);   // MF_BYPOSITION
    string text = s.ToString().Split('\t')[0].Replace("&", "").TrimEnd('\u2026');
    if (text == label) return GetMenuItemID(menu, i);
  }
  return 0;
}
[DllImport("user32.dll")] public static extern System.IntPtr GetSystemMenu(System.IntPtr h, bool revert);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindow(System.IntPtr h, uint cmd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern bool ScreenToClient(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
  public int cbSize, flags; public System.IntPtr active, focus, capture, menuOwner, moveSize, caret; public RECT caretRect;
}
[DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
// The window that has the mouse capture on h's thread, or zero.
public static System.IntPtr CaptureOf(System.IntPtr h) {
  uint pid; var info = new GUITHREADINFO(); info.cbSize = Marshal.SizeOf(info);
  return GetGUIThreadInfo(GetWindowThreadProcessId(h, out pid), ref info) ? info.capture : System.IntPtr.Zero;
}
// A mouse message to h at a point on the screen.
public static void Mouse(System.IntPtr h, uint msg, uint keys, int x, int y) {
  var p = new POINT { x = x, y = y }; ScreenToClient(h, ref p);
  PostMessageW(h, msg, (System.IntPtr)keys, (System.IntPtr)((p.x & 0xFFFF) | (p.y << 16)));
}
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyBadges.Win32]
# Window rectangles in physical pixels, as Ghostty sees them.
[void]$W::SetThreadDpiAwarenessContext([IntPtr]-4)   # per monitor v2

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-overlays-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f9=toggle_readonly', '"--keybind=f8=text:echo \x07\r"',
    '--bell-features=no-attention,border'

function Fail([string]$message) {
    $warnings = @()
    if (Test-Path $log) { $warnings = @(Get-Content $log | Where-Object { $_ -match '\b(warning|error)\b' } | Select-Object -Last 6) }
    if ($script:dragNote) { $message += " ($script:dragNote)" }
    if ($warnings.Count -gt 0) { $message += " Ghostty's log: " + ($warnings -join ' | ') }
    Write-Host "::error title=overlays::$message"
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
    Fail "timed out waiting for $what (the surface's children, top first: $((Children) -join ', '))"
}

function ClassOf([IntPtr]$h) {
    $name = New-Object System.Text.StringBuilder 64
    [void]$W::GetClassNameW($h, $name, $name.Capacity)
    $name.ToString()
}

# The surface's child windows, top first, as class names, with a * for
# the visible ones.
function Children {
    $list = @()
    $h = $W::GetWindow($script:surface, 5)   # GW_CHILD
    while ($h -ne [IntPtr]::Zero) {
        $list += (ClassOf $h) + $(if ($W::IsWindowVisible($h)) { '*' } else { '' })
        $h = $W::GetWindow($h, 2)   # GW_HWNDNEXT
    }
    $list
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $script:surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
    [void](WaitFor { (Children) -contains 'GhosttyScrollbar' } "the surface's scrollbar")
    Start-Sleep -Seconds 1
    if ((Children) | Where-Object { $_ -match '^Ghostty(Badge|SearchBar|CommandPalette|DimOverlay|BellBorder|LinkPreview|ProgressBar|DropZone|DragHandle)' }) { Fail "a new surface already has a lazily made overlay window: $((Children) -join ', ')" }
    Write-Host "A new surface has no badge, search bar, command palette, dim overlay, bell border, link preview, progress bar, drop zone or drag handle windows: $((Children) -join ', ')"

    $W::Key($surface, 0x78, 0x43)   # F9: toggle_readonly
    [void](WaitFor { (Children) -contains 'GhosttyBadge*' } 'the read-only badge to show')
    $children = @(Children)
    $badge = [Array]::IndexOf($children, 'GhosttyBadge*')
    $scrollbar = [Array]::IndexOf(@($children | ForEach-Object { $_.TrimEnd('*') }), 'GhosttyScrollbar')
    if ($badge -ne $scrollbar + 1) { Fail "the badge isn't just below the scrollbar: $($children -join ', ')" }

    $h = $W::FindWindowExW($surface, [IntPtr]::Zero, 'GhosttyBadge', [NullString]::Value)
    $b = New-Object GhosttyBadges.Win32+RECT; [void]$W::GetWindowRect($h, [ref]$b)
    $s = New-Object GhosttyBadges.Win32+RECT; [void]$W::GetWindowRect($surface, [ref]$s)
    if ($b.r -le $b.l -or $b.r -lt $s.r - ($s.r - $s.l) / 3 -or $b.t -gt $s.t + ($s.b - $s.t) / 3) {
        Fail "the badge isn't in the top right: $($b.l),$($b.t)-$($b.r),$($b.b) in $($s.l),$($s.t)-$($s.r),$($s.b)"
    }
    Write-Host "Read-only mode shows a badge at $($b.l),$($b.t)-$($b.r),$($b.b), just below the scrollbar: $($children -join ', ')"

    $W::Key($surface, 0x78, 0x43)
    [void](WaitFor { -not ((Children) -contains 'GhosttyBadge*') } 'the read-only badge to hide')
    Write-Host 'Leaving read-only mode hides it.'

    $W::Key($surface, 0x77, 0x42)   # F8: echo BEL
    [void](WaitFor { (Children) -contains 'GhosttyBellBorder*' } 'the bell border to show')
    $children = @(Children)
    $bell = [Array]::IndexOf($children, 'GhosttyBellBorder*')
    $scrollbar = [Array]::IndexOf(@($children | ForEach-Object { $_.TrimEnd('*') }), 'GhosttyScrollbar')
    if ($bell -ne $scrollbar - 1) { Fail "the bell border isn't just above the scrollbar: $($children -join ', ')" }
    Write-Host "A bell shows the bell border, just above the scrollbar: $($children -join ', ')"

    # The window menu's Find and Command Palette, found by label after
    # WM_INITMENUPOPUP, which builds the menu.
    $menu = $W::GetSystemMenu($window, $false)
    foreach ($overlay in @(@{ Class = 'GhosttySearchBar'; Label = 'Find' }, @{ Class = 'GhosttyCommandPalette'; Label = 'Command Palette' })) {
        [void]$W::SendMessageW($window, 0x0117, $menu, [IntPtr]0)   # WM_INITMENUPOPUP
        $command = $W::MenuCommand($menu, $overlay.Label)
        if ($command -eq 0) { Fail "the window menu has no '$($overlay.Label)'" }
        [void]$W::SendMessageW($window, 0x0112, [IntPtr]$command, [IntPtr]0)   # WM_SYSCOMMAND
        [void](WaitFor { (Children) -contains "$($overlay.Class)*" } $overlay.Class)
        $children = @(Children)
        if ($children[0] -ne "$($overlay.Class)*") { Fail "$($overlay.Class) isn't on top: $($children -join ', ')" }

        $o = $W::FindWindowExW($surface, [IntPtr]::Zero, $overlay.Class, [NullString]::Value)
        $list = $W::FindWindowExW($o, [IntPtr]::Zero, 'ListBox', [NullString]::Value)
        $entries = if ($list -ne [IntPtr]::Zero) { [int]$W::SendMessageW($list, 0x018B, [IntPtr]0, [IntPtr]0) } else { 0 }   # LB_GETCOUNT
        if ($overlay.Class -eq 'GhosttyCommandPalette' -and $entries -lt 10) { Fail "the command palette lists $entries commands" }

        # Escape in its field closes it.
        $edit = $W::FindWindowExW($o, [IntPtr]::Zero, 'Edit', [NullString]::Value)
        $W::Key($edit, 0x1B, 0x01)
        [void](WaitFor { -not ((Children) -contains "$($overlay.Class)*") } "$($overlay.Class) to close")
        Write-Host "$($overlay.Class) opens on top$(if ($list -ne [IntPtr]::Zero) { " listing $entries entries" }) and closes: $($children -join ', ')"
    }

    # Split Right focuses the new terminal and dims this one.
    [void]$W::SendMessageW($window, 0x0117, $menu, [IntPtr]0)
    [void]$W::SendMessageW($window, 0x0112, [IntPtr]$W::MenuCommand($menu, 'Split Right'), [IntPtr]0)
    [void](WaitFor { (Children) -contains 'GhosttyDimOverlay*' } 'the first terminal to dim')
    $children = @(Children)
    $names = @($children | ForEach-Object { $_.TrimEnd('*') })
    $dim = [Array]::IndexOf($names, 'GhosttyDimOverlay')
    if ($dim -ne [Array]::IndexOf($names, 'GhosttyBellBorder') - 1 -or
        $dim -lt [Array]::IndexOf($names, 'GhosttySearchBar') -or
        $dim -lt [Array]::IndexOf($names, 'GhosttyCommandPalette')) {
        Fail "the dim overlay isn't just above the bell border and below the search bar and palette: $($children -join ', ')"
    }
    Write-Host "A split dims the first terminal, its overlay just above the bell border: $($children -join ', ')"

    $first = $script:surface
    $second = WaitFor { $h = $W::FindWindowExW($window, $first, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the second terminal'
    $handle = $W::FindWindowExW($first, [IntPtr]::Zero, 'GhosttyDragHandle', [NullString]::Value)
    if ($handle -eq [IntPtr]::Zero -or -not $W::IsWindowVisible($handle)) { Fail "the first terminal shows no drag handle in a split: $((Children) -join ', ')" }
    $a = New-Object GhosttyBadges.Win32+RECT; [void]$W::GetWindowRect($first, [ref]$a)
    $b = New-Object GhosttyBadges.Win32+RECT; [void]$W::GetWindowRect($second, [ref]$b)
    $script:surface = $second
    # WM_LBUTTONDOWN on the handle, then WM_MOUSEMOVE near the second's
    # right side. While the handle has the capture Windows sends it moves
    # of its own at the real cursor (elsewhere, with no button down), which
    # the handle must ignore or the zone hides again (from run 42195536279
    # on windows-latest).
    $W::Mouse($handle, 0x0201, 1, $a.l + 10, $a.t + 2)
    $W::Mouse($handle, 0x0200, 1, $b.r - 10, [int](($b.t + $b.b) / 2))
    [void](WaitFor {
        $capture = $W::CaptureOf($handle)
        $who = if ($capture -eq [IntPtr]::Zero) { 'nothing' } else { ClassOf $capture }
        $script:dragNote = "capture: $who, first: $($a.l),$($a.t)-$($a.r),$($a.b), second: $($b.l),$($b.t)-$($b.r),$($b.b)"
        (Children) -contains 'GhosttyDropZone*'
    } "the second terminal's drop zone to show")
    $children = @(Children)
    if ($children[0] -ne 'GhosttyDropZone*') { Fail "the drop zone isn't on top: $($children -join ', ')" }
    $W::Mouse($handle, 0x0200, 1, [int](($a.l + $a.r) / 2), [int](($a.t + $a.b) / 2))
    $W::Mouse($handle, 0x0202, 0, [int](($a.l + $a.r) / 2), [int](($a.t + $a.b) / 2))   # WM_LBUTTONUP over the first
    [void](WaitFor { -not ((Children) -contains 'GhosttyDropZone*') } 'the drop zone to hide')
    $a2 = New-Object GhosttyBadges.Win32+RECT; [void]$W::GetWindowRect($first, [ref]$a2)
    if ($a2.l -ne $a.l -or $a2.t -ne $a.t -or $a2.r -ne $a.r) { Fail "letting go over the first terminal moved it" }
    Write-Host "Dragging the first terminal's handle over the second shows its drop zone on top, and letting go over the first hides it: $($children -join ', ')"
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
