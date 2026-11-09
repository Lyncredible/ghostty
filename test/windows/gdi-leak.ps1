# Checks that Ghostty's own drawn UI doesn't leak GDI or USER objects:
# a process may have 10,000 of each, and a brush or font made on every
# paint and never deleted would make drawing fail after a long session.
# After a warm-up round, it repeats a round of UI work (the search bar,
# the command palette, a new tab and closing it, a split and closing it,
# resizing the window, and hovering the tab bar) and checks that the
# counts (GetGuiResources) stay about where they were. Input is posted
# to Ghostty's windows, so it runs on a locked desktop.
#
#     ./gdi-leak.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$Rounds = 25,
    # Objects a round may add on average before it counts as a leak.
    [double]$PerRound = 0.5,
    # Which steps a round does (all by default), to find a leak.
    [string[]]$Steps = @('search', 'palette', 'tab', 'split', 'resize', 'hover'),
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyGdi -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetGuiResources(System.IntPtr process, uint flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
public static void Move(System.IntPtr h, int x, int y) {
  PostMessageW(h, 0x0200, System.IntPtr.Zero, (System.IntPtr)((y << 16) | (x & 0xFFFF)));
}
'@
$W = [GhosttyGdi.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-gdi-leak-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--confirm-close-surface=false', '--window-show-tab-bar=always',
    '--keybind=f5=start_search', '--keybind=f6=end_search', '--keybind=f7=toggle_command_palette',
    '--keybind=f8=new_tab', '--keybind=f9=close_tab', '--keybind=f10=new_split:right', '--keybind=f11=close_surface'

function Fail([string]$message) {
    Write-Host "::error title=gdi-leak::$message"
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
        Start-Sleep -Milliseconds 100
    }
    Fail "timed out waiting for $what"
}

function Counts {
    $process.Refresh()
    @{ Gdi = [int]$W::GetGuiResources($process.Handle, 0); User = [int]$W::GetGuiResources($process.Handle, 1); Handles = $process.HandleCount }
}

# The surfaces (terminals) in the window.
function Surfaces {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', $null)) -ne [IntPtr]::Zero) { $list += $h }
    $list
}

function Press([int]$vk, [int]$scan) {
    $surface = @(Surfaces)[0]
    $W::Key($surface, $vk, $scan)
}

# One round of UI work, waiting for each step to take effect.
function Round([int]$i) {
    if ($Steps -contains 'search') {
        Press 0x74 0x3F   # F5: start_search
        Start-Sleep -Milliseconds 150
        Press 0x75 0x40   # F6: end_search
    }
    if ($Steps -contains 'palette') {
        Press 0x76 0x41   # F7: toggle_command_palette
        Start-Sleep -Milliseconds 150
        Press 0x76 0x41
    }
    $tabs = @(Surfaces).Count
    if ($Steps -contains 'tab') {
        Press 0x77 0x42   # F8: new_tab
        [void](WaitFor { @(Surfaces).Count -gt $tabs } 'a new tab')
        Press 0x78 0x43   # F9: close_tab
        [void](WaitFor { @(Surfaces).Count -eq $tabs } 'the tab to close')
    }
    if ($Steps -contains 'split') {
        Press 0x79 0x44   # F10: new_split:right
        [void](WaitFor { @(Surfaces).Count -gt $tabs } 'a split')
        Press 0x7A 0x57   # F11: close_surface
        [void](WaitFor { @(Surfaces).Count -eq $tabs } 'the split to close')
    }
    if ($Steps -contains 'resize') {
        $size = 700 + ($i % 5) * 40
        [void]$W::SetWindowPos($window, [IntPtr]::Zero, 50, 50, $size + 200, $size, 0x0014)   # SWP_NOZORDER | SWP_NOACTIVATE
    }
    if ($Steps -contains 'hover') {
        $bar = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null)
        if ($bar -ne [IntPtr]::Zero) { for ($x = 10; $x -lt 400; $x += 30) { $W::Move($bar, $x, 20) } }
    }
    Start-Sleep -Milliseconds 200
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    [void](WaitFor { @(Surfaces).Count -gt 0 } 'the terminal')
    Start-Sleep -Seconds 1

    # Warm up: everything made once and kept (fonts, the overlays' windows).
    Round 0; Round 1
    Start-Sleep -Milliseconds 500
    $before = Counts
    Write-Host "After warming up: $($before.Gdi) GDI and $($before.User) USER objects, $($before.Handles) kernel handles."

    for ($i = 2; $i -lt $Rounds + 2; $i++) { Round $i }
    Start-Sleep -Milliseconds 500
    $after = Counts
    $gdi = $after.Gdi - $before.Gdi
    $user = $after.User - $before.User
    $handles = $after.Handles - $before.Handles
    Write-Host "After $Rounds more rounds: $($after.Gdi) GDI ($gdi) and $($after.User) USER ($user) objects, $($after.Handles) kernel handles ($handles)."
    $limit = [int][Math]::Ceiling($Rounds * $PerRound)
    if ($gdi -gt $limit) { Fail "GDI objects grew by $gdi over $Rounds rounds (limit $limit): a leak" }
    if ($user -gt $limit) { Fail "USER objects grew by $user over $Rounds rounds (limit $limit): a leak" }
    # Kernel handles come and go with threads and the terminals' processes
    # and pipes, so they get a looser limit: a few a round.
    $handle_limit = $Rounds * 4
    if ($handles -gt $handle_limit) { Fail "kernel handles grew by $handles over $Rounds rounds (limit $handle_limit): a leak" }
    Write-Host "Neither GDI nor USER objects grew by more than $limit, nor kernel handles by more than $handle_limit."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
