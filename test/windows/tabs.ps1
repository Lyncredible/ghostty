# Checks tab operations: `close_tab:other` keeps only the current tab (its
# output too), `close_tab:this` and then `undo` brings the closed tab back
# and `redo` closes it again, and `move_tab_to_new_window` moves the current tab, with its output, into
# a new window. Last, `close_all_windows`, bound to a key sequence (F12
# then F11), closes both windows, and Ghostty quits; while the sequence
# waits for its second key, a badge on the terminal shows the first. One terminal per tab, so terminals count tabs. Keys and
# characters are posted to Ghostty's windows, so it runs on a locked
# desktop.
#
#     ./tabs.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=tabs::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyTabs -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
// The process's top-level windows of a class.
public static System.IntPtr[] TopLevel(uint pid, string cls) {
  var found = new System.Collections.Generic.List<System.IntPtr>();
  var h = System.IntPtr.Zero;
  while ((h = FindWindowExW(System.IntPtr.Zero, h, cls, null)) != System.IntPtr.Zero) {
    uint owner; GetWindowThreadProcessId(h, out owner);
    if (owner == pid && IsWindowVisible(h)) found.Add(h);
  }
  return found.ToArray();
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
$W = [GhosttyTabs.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-tabs-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--confirm-close-surface=false', '--keybind=f5=new_tab',
    '--keybind=f6=close_tab:other', '--keybind=f7=close_tab:this', '--keybind=f8=undo',
    '--keybind=f9=move_tab_to_new_window', '--keybind=f10=redo',
    '--keybind=f12>f11=close_all_windows', '--quit-after-last-window-closed=true'

function Fail([string]$message) {
    Write-Host "::error title=tabs::$message"
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

# A window's terminals (one per tab), and the shown one.
function Terminals([IntPtr]$window) {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { $list += $h }
    $list
}
function Shown([IntPtr]$window) { @(Terminals $window | Where-Object { $W::IsWindowVisible($_) }) | Select-Object -First 1 }
function Windows { $W::TopLevel([uint32]$process.Id, 'GhosttyWindow') }
function Note { $script:note = "windows: $(@(Windows).Count), tabs in the first: $(@(Terminals $window).Count)" }
function ScreenText([IntPtr]$surface) {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($surface)
    $(try { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' })
}
function Prompt([IntPtr]$surface, [string]$what) {
    [void](WaitFor { (ScreenText $surface) -match '>\s*$' } "the prompt in $what")
}

# Type `echo <marker>` and wait for it on the screen twice (the command
# and its output). If nothing of it shows for a while, type it again: on
# a runner the characters, posted right after the prompt showed, once
# never arrived.
function Mark([IntPtr]$surface, [string]$marker, [string]$what) {
    $W::Type($surface, "echo $marker`r")
    $typed = Get-Date
    [void](WaitFor {
        $text = ScreenText $surface
        $count = ([regex]::Matches($text, [regex]::Escape($marker))).Count
        $end = ($text.TrimEnd() -replace '\s+', ' ')
        $script:note = "$count of 2 '$marker' on screen, which ends: '$($end.Substring([Math]::Max(0, $end.Length - 80)))'"
        if ($count -ge 2) { return $true }
        if ($count -eq 0 -and ((Get-Date) - $typed).TotalSeconds -gt 8) {
            Write-Host "::notice title=tabs::typing $marker again: nothing of it showed after 8 s"
            $W::Type($surface, "echo $marker`r")
            $typed = Get-Date
        }
    } $what)
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    [void](WaitFor { Note; @(Terminals $window).Count -eq 1 } 'the first tab')

    # Three tabs; mark the third (current) one, then close the others.
    $W::Key((Shown $window), 0x74, 0x3F)   # F5: new_tab
    [void](WaitFor { Note; @(Terminals $window).Count -eq 2 } 'the second tab')
    $W::Key((Shown $window), 0x74, 0x3F)
    [void](WaitFor { Note; @(Terminals $window).Count -eq 3 } 'the third tab')
    $third = Shown $window
    Prompt $third 'the third tab'
    Mark $third 'KEEP-THIS-TAB' 'the marker'
    $W::Key($third, 0x75, 0x40)   # F6: close_tab:other
    [void](WaitFor { Note; @(Terminals $window).Count -eq 1 } 'the other tabs to close')
    if ((Shown $window) -ne $third) { Fail 'close_tab:other kept a different tab' }
    Write-Host 'close_tab:other closed two tabs and kept the current one.'

    # Close a tab, then undo brings it back. A closed tab is kept (hidden)
    # for `undo-timeout`, so watch which terminal shows rather than count.
    $W::Key($third, 0x74, 0x3F)   # F5: new_tab
    [void](WaitFor { Note; @(Terminals $window).Count -eq 2 -and (Shown $window) -ne $third } 'a new tab')
    $closed = Shown $window
    $W::Key($closed, 0x76, 0x41)   # F7: close_tab:this
    [void](WaitFor { Note; (Shown $window) -eq $third } 'the tab to close')
    $W::Key($third, 0x77, 0x42)   # F8: undo
    [void](WaitFor { Note; (Shown $window) -eq $closed } 'undo to reopen the closed tab')
    Write-Host 'close_tab:this and then undo reopened the same tab.'

    # And redo closes it again. It's kept for undo until the timeout, then
    # destroyed.
    $W::Key($closed, 0x79, 0x44)   # F10: redo
    [void](WaitFor { Note; (Shown $window) -eq $third } 'redo to close the reopened tab again')
    [void](WaitFor { Note; @(Terminals $window).Count -eq 1 } 'the closed tab to expire')
    Write-Host 'redo closed it again.'

    # Move a tab to a new window.
    $W::Key($third, 0x74, 0x3F)   # F5: a second tab, which will move
    $left = WaitFor { Note; $s = Shown $window; if (@(Terminals $window).Count -eq 2 -and $s -and $s -ne $third) { $s } } 'a new tab to move'
    Prompt $left 'the tab to move'
    Mark $left 'MOVE-THIS-TAB' 'the move marker'
    $W::Key($left, 0x78, 0x43)   # F9: move_tab_to_new_window
    $new = WaitFor { Note; $list = @(Windows | Where-Object { $_ -ne $window }); if ($list.Count -eq 1) { $list[0] } } 'a new window'
    [void](WaitFor { Note; @(Terminals $window).Count -eq 1 -and @(Terminals $new).Count -eq 1 } 'one tab in each window')
    $moved = @(Terminals $new)[0]
    if ($moved -ne $left) { Fail 'the new window has a different terminal than the moved tab' }
    if (-not ((ScreenText $moved) -match 'MOVE-THIS-TAB')) { Fail "the moved tab lost its output" }
    if (@(Terminals $window)[0] -ne $third) { Fail 'the first window lost the tab that stayed' }
    Write-Host 'move_tab_to_new_window moved the tab, with its output, into a new window.'

    # The sequence's first key alone does nothing but show itself.
    $W::Key($moved, 0x7B, 0x58)   # F12
    $badge = WaitFor {
        $h = [IntPtr]::Zero
        while (($h = $W::FindWindowExW($moved, $h, 'GhosttyBadge', [NullString]::Value)) -ne [IntPtr]::Zero) {
            $text = New-Object System.Text.StringBuilder 256
            [void]$W::GetWindowTextW($h, $text, 256)
            if ($W::IsWindowVisible($h) -and $text.ToString() -match 'f12') { return $text.ToString() }
        }
    } 'a badge showing the pending key'
    if (@(Windows).Count -ne 2) { Fail "the sequence's first key closed something" }
    Write-Host "The sequence's first key showed '$badge' on the terminal and nothing else."
    $W::Key($moved, 0x7A, 0x57)   # F11: close_all_windows
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { Note; Fail "close_all_windows didn't close every window ($script:note)" }
    Write-Host 'The key sequence F12 F11 ran close_all_windows: both windows closed, and Ghostty quit.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
