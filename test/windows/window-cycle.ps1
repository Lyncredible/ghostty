# Checks goto_window and toggle_visibility with a hidden quick terminal:
# goto_window cycles through the normal windows and skips the quick
# terminal, and toggle_visibility hides the windows and brings back only
# the ones that were shown, so the hidden quick terminal stays hidden.
# Both used to treat the quick terminal as one more window. Last, with
# the windows hidden again, +new-tab must bring back the window it adds
# its tab to (and only it). Keys are
# posted to Ghostty's windows. Hiding the quick terminal and hiding the
# windows need a Ghostty window in front, which Windows may refuse
# outside CI; then the test says so and stops, and in CI that fails.
#
#     ./window-cycle.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyCycle -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] static extern int GetWindowLongW(System.IntPtr h, int index);
// The process's Ghostty windows, shown or not: the normal ones, then the
// quick terminal (a tool window) if there is one.
public static System.IntPtr[] Windows(uint pid, bool quick) {
  var found = new System.Collections.Generic.List<System.IntPtr>();
  EnumWindows((h, l) => {
    uint p; GetWindowThreadProcessId(h, out p);
    var name = new System.Text.StringBuilder(64); GetClassNameW(h, name, 64);
    bool tool = (GetWindowLongW(h, -20) & 0x80) != 0;
    if (p == pid && name.ToString() == "GhosttyWindow" && tool == quick) found.Add(h);
    return true;
  }, System.IntPtr.Zero);
  return found.ToArray();
}
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyCycle.Win32]

$cli = Join-Path (Split-Path $Exe) 'ghostty.com'
$class = "com.example.ghostty-window-cycle-$PID"
$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-window-cycle-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList "--class=$class", '--command=cmd.exe',
    '--window-save-state=never', '--confirm-close-surface=false', '--quick-terminal-animation-duration=0',
    '--keybind=f5=new_window', '--keybind=f6=goto_window:next', '--keybind=f7=toggle_visibility',
    '--keybind=f8=toggle_quick_terminal'

function Fail([string]$message) {
    Write-Host "::error title=window-cycle::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 30 | Write-Host }
    throw $message
}

# Windows wouldn't put a Ghostty window in front, which the rest needs.
function Inconclusive([string]$message) {
    if ($env:CI -eq 'true') { Fail $message }
    Write-Host "Stopping: $message (Windows may refuse outside CI)."
    exit 0
}

function WaitFor([scriptblock]$condition, [string]$what, [int]$seconds = $TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 100
    }
    if ($seconds -ne $TimeoutSeconds) { return $null }
    Fail "timed out waiting for $what"
}

function Surface($window) { WaitFor { $s = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', $null); if ($s -ne 0) { $s } } 'a terminal' }
function Visible($window) { $W::IsWindowVisible($window) }

try {
    $a = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    Start-Sleep -Seconds 1
    $W::Key((Surface $a), 0x74, 0x3F)   # F5: new_window
    $b = WaitFor { @($W::Windows($process.Id, $false) | Where-Object { $_ -ne $a -and (Visible $_) })[0] } 'a second window'

    # Show the quick terminal, then hide it: a second toggle hides it when
    # it's in front.
    $W::Key((Surface $b), 0x77, 0x42)   # F8: toggle_quick_terminal
    $quick = WaitFor { $q = @($W::Windows($process.Id, $true))[0]; if ($q -and (Visible $q)) { $q } } 'the quick terminal'
    if (-not (WaitFor { $W::GetForegroundWindow() -eq $quick } 'the quick terminal in front' 5)) {
        [void]$W::SetForegroundWindow($quick)
        if (-not (WaitFor { $W::GetForegroundWindow() -eq $quick } 'the quick terminal in front' 5)) {
            Inconclusive "the quick terminal didn't come to the front"
        }
    }
    $W::Key((Surface $quick), 0x77, 0x42)
    [void](WaitFor { -not (Visible $quick) } 'the quick terminal to hide')
    Write-Host 'Two windows, and a quick terminal shown and hidden again.'

    # goto_window:next from each window goes to the other, never to the
    # quick terminal. The windows were made in the order A, B, quick, so
    # next from B used to be the hidden quick terminal.
    foreach ($pair in @(@($b, $a), @($a, $b))) {
        $from, $to = $pair
        [void]$W::SetForegroundWindow($from)
        $W::Key((Surface $from), 0x75, 0x40)   # F6: goto_window:next
        if (-not (WaitFor { $W::GetForegroundWindow() -eq $to } 'the next window in front' 5)) {
            $fg = $W::GetForegroundWindow()
            if ($fg -eq $quick) { Fail "goto_window:next went to the hidden quick terminal" }
            Inconclusive "goto_window:next didn't bring a window to the front (the front is $fg)"
        }
        if (Visible $quick) { Fail "goto_window:next showed the quick terminal" }
    }
    Write-Host 'goto_window:next went from one window to the other and back, skipping the hidden quick terminal.'

    # toggle_visibility from the window in front hides both windows; again
    # (no Ghostty window in front then) brings back just those two.
    $front = $W::GetForegroundWindow()
    $W::Key((Surface $front), 0x76, 0x41)   # F7: toggle_visibility
    [void](WaitFor { -not (Visible $a) -and -not (Visible $b) } 'the windows to hide')
    if (Visible $quick) { Fail "hiding the windows showed the quick terminal" }
    $W::Key((Surface $front), 0x76, 0x41)
    [void](WaitFor { (Visible $a) -and (Visible $b) } 'the windows to show again')
    Start-Sleep -Milliseconds 500
    if (Visible $quick) { Fail "showing the windows again showed the hidden quick terminal" }
    Write-Host 'toggle_visibility hid both windows and brought back just them; the quick terminal stayed hidden.'

    # Hidden again, +new-tab brings back the window it adds its tab to.
    $front = WaitFor { $fg = $W::GetForegroundWindow(); if ($fg -eq $a -or $fg -eq $b) { $fg } } 'a window in front' 5
    if (-not $front) { Inconclusive "no window was in front after showing them again" }
    $W::Key((Surface $front), 0x76, 0x41)   # F7: toggle_visibility
    [void](WaitFor { -not (Visible $a) -and -not (Visible $b) } 'the windows to hide again')
    $out = & $cli '+new-tab' "--class=$class" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "+new-tab exited with $LASTEXITCODE`: $out" }
    [void](WaitFor { (Visible $a) -or (Visible $b) } 'the window with the new tab to show')
    Start-Sleep -Milliseconds 500
    if ((Visible $a) -and (Visible $b)) { Fail "+new-tab brought back both windows" }
    if (Visible $quick) { Fail "+new-tab showed the hidden quick terminal" }
    Write-Host '+new-tab brought back the hidden window it added its tab to, and only it.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
