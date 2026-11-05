# Checks the read-only badge: a surface makes its badges' windows only
# when they first show, so a new terminal has none. Toggling read-only
# mode (a posted F9 bound to `toggle_readonly`) must show one in the top
# right, in the order it would have been made in: just below the
# scrollbar, and above the overlays made after it (such as the drop
# zone). The search bar and command palette are made when they first
# open too, so a new surface has neither. Toggling read-only mode again
# must hide the badge. Then the search bar and the command palette
# (opened from the window menu) must show on top, and close again.
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
[DllImport("user32.dll")] public static extern System.IntPtr GetSystemMenu(System.IntPtr h, bool revert);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindow(System.IntPtr h, uint cmd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
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

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-overlays-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f9=toggle_readonly'

function Fail([string]$message) {
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
    $script:surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', $null); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
    [void](WaitFor { (Children) -contains 'GhosttyDragHandle' } "the surface's overlays")
    Start-Sleep -Seconds 1
    if ((Children) | Where-Object { $_ -match '^Ghostty(Badge|SearchBar|CommandPalette)' }) { Fail "a new surface already has a badge, search bar or command palette window: $((Children) -join ', ')" }
    Write-Host "A new surface has no badge, search bar or command palette windows: $((Children) -join ', ')"

    $W::Key($surface, 0x78, 0x43)   # F9: toggle_readonly
    [void](WaitFor { (Children) -contains 'GhosttyBadge*' } 'the read-only badge to show')
    $children = @(Children)
    $badge = [Array]::IndexOf($children, 'GhosttyBadge*')
    $scrollbar = [Array]::IndexOf(@($children | ForEach-Object { $_.TrimEnd('*') }), 'GhosttyScrollbar')
    $drop = [Array]::IndexOf(@($children | ForEach-Object { $_.TrimEnd('*') }), 'GhosttyDropZone')
    if ($badge -ne $scrollbar + 1 -or $drop -lt $badge) { Fail "the badge isn't just below the scrollbar and above the drop zone: $($children -join ', ')" }

    $h = $W::FindWindowExW($surface, [IntPtr]::Zero, 'GhosttyBadge', $null)
    $b = New-Object GhosttyBadges.Win32+RECT; [void]$W::GetWindowRect($h, [ref]$b)
    $s = New-Object GhosttyBadges.Win32+RECT; [void]$W::GetWindowRect($surface, [ref]$s)
    if ($b.r -le $b.l -or $b.r -lt $s.r - ($s.r - $s.l) / 3 -or $b.t -gt $s.t + ($s.b - $s.t) / 3) {
        Fail "the badge isn't in the top right: $($b.l),$($b.t)-$($b.r),$($b.b) in $($s.l),$($s.t)-$($s.r),$($s.b)"
    }
    Write-Host "Read-only mode shows a badge at $($b.l),$($b.t)-$($b.r),$($b.b), just below the scrollbar: $($children -join ', ')"

    $W::Key($surface, 0x78, 0x43)
    [void](WaitFor { -not ((Children) -contains 'GhosttyBadge*') } 'the read-only badge to hide')
    Write-Host 'Leaving read-only mode hides it.'

    # The window menu's Find... (11) and Command Palette (17), after
    # WM_INITMENUPOPUP, which builds it.
    $menu = $W::GetSystemMenu($window, $false)
    foreach ($overlay in @(@{ Class = 'GhosttySearchBar'; Command = 11 }, @{ Class = 'GhosttyCommandPalette'; Command = 17 })) {
        [void]$W::SendMessageW($window, 0x0117, $menu, [IntPtr]0)   # WM_INITMENUPOPUP
        [void]$W::SendMessageW($window, 0x0112, [IntPtr]($overlay.Command -shl 4), [IntPtr]0)   # WM_SYSCOMMAND
        [void](WaitFor { (Children) -contains "$($overlay.Class)*" } $overlay.Class)
        $children = @(Children)
        if ($children[0] -ne "$($overlay.Class)*") { Fail "$($overlay.Class) isn't on top: $($children -join ', ')" }

        $o = $W::FindWindowExW($surface, [IntPtr]::Zero, $overlay.Class, $null)
        $list = $W::FindWindowExW($o, [IntPtr]::Zero, 'ListBox', $null)
        $entries = if ($list -ne [IntPtr]::Zero) { [int]$W::SendMessageW($list, 0x018B, [IntPtr]0, [IntPtr]0) } else { 0 }   # LB_GETCOUNT
        if ($overlay.Class -eq 'GhosttyCommandPalette' -and $entries -lt 10) { Fail "the command palette lists $entries commands" }

        # Escape in its field closes it.
        $edit = $W::FindWindowExW($o, [IntPtr]::Zero, 'Edit', $null)
        $W::Key($edit, 0x1B, 0x01)
        [void](WaitFor { -not ((Children) -contains "$($overlay.Class)*") } "$($overlay.Class) to close")
        Write-Host "$($overlay.Class) opens on top$(if ($list -ne [IntPtr]::Zero) { " listing $entries entries" }) and closes: $($children -join ', ')"
    }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
