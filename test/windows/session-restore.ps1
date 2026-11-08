# Checks `window-save-state = always`: a window with a split in its first
# tab and a second tab is saved when Ghostty quits and comes back the same
# when it starts again, with only the active tab's terminal showing (the
# other tabs' terminals once showed through, see Tab.setVisible). It runs with its own `--class`, so it has its own
# state file (and instance) and leaves any other Ghostty alone. Keys bound
# to the actions are posted to the terminal and the windows are found with
# EnumChildWindows, so it works on a locked desktop.
#
# Then each terminal's shell and directory: a saved session with a
# PowerShell tab (a shell chosen from the new tab menu, saved as the
# terminal's command) in C:\Windows and a cmd tab (the configured command)
# in the temporary directory comes back with those shells and directories,
# read from the prompts with UI Automation, and quitting saves them again.
#
#     ./session-restore.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
trap {
    if (-not $script:reported) { Write-Host "::error title=session-restore::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttySession -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr parent, EnumProc proc, System.IntPtr l);
// Every descendant of `parent` with the class name.
public static System.IntPtr[] Find(System.IntPtr parent, string cls) {
  var found = new System.Collections.Generic.List<System.IntPtr>();
  EnumChildWindows(parent, (h, l) => {
    var s = new System.Text.StringBuilder(64); GetClassNameW(h, s, 64);
    if (s.ToString() == cls) found.Add(h);
    return true;
  }, System.IntPtr.Zero);
  return found.ToArray();
}
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttySession.Win32]

$class = "com.example.ghostty-session-test-$PID"
$state = Join-Path $env:LOCALAPPDATA "ghostty\window-state-$class.json"
$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-session-$PID.log"
$arguments = @('--command=cmd.exe', "--class=$class", '--window-save-state=always',
    '--confirm-close-surface=false', '--quit-after-last-window-closed=true',
    '--keybind=f9=new_split:right', '--keybind=f10=new_tab', '--keybind=f11=quit',
    '--keybind=f12=goto_tab:1', '--keybind=f8=goto_tab:2')

function Fail([string]$message) {
    Write-Host "::error title=session-restore::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what ($script:note)"
}

function Start-Ghostty {
    $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList $arguments
    $script:window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
}

# The window's terminals, and the visible ones (the selected tab's).
function Surfaces { @($W::Find($window, 'GhosttySurface')) }
function Visible { @(Surfaces | Where-Object { $W::IsWindowVisible($_) }) }
function Note { $script:note = "terminals: $(@(Surfaces).Count), visible: $(@(Visible).Count)" }

# The text of a terminal, from UI Automation.
function Text($surface) {
    try {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($surface)
        $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    } catch { '' }
}

function Quit {
    $W::Key((Visible)[0], 0x7A, 0x57)   # F11: quit
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { Fail 'Ghostty did not quit' }
}

try {
    Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue

    # A split in the first tab, then a second tab.
    Start-Ghostty
    [void](WaitFor { Note; @(Visible).Count -eq 1 } 'the first terminal')
    $W::Key((Visible)[0], 0x78, 0x43)   # F9: new_split:right
    [void](WaitFor { Note; @(Visible).Count -eq 2 } 'the split')
    $W::Key((Visible)[0], 0x79, 0x44)   # F10: new_tab
    [void](WaitFor { Note; @(Surfaces).Count -eq 3 -and @(Visible).Count -eq 1 } 'the second tab')
    Write-Host 'Made a split and a second tab.'
    Quit

    # The saved state: one window, two tabs, the first split left and right.
    if (-not (Test-Path $state)) { Fail "quitting saved no state at $state" }
    $saved = Get-Content -Raw $state | ConvertFrom-Json
    $tabs = @($saved.windows[0].tabs)
    $note = "windows: $(@($saved.windows).Count), tabs: $($tabs.Count), first tab's nodes: $(@($tabs[0].nodes).Count)"
    if (@($saved.windows).Count -ne 1 -or $tabs.Count -ne 2 -or @($tabs[0].nodes).Count -ne 3 -or
        -not $tabs[0].nodes[0].layout -or @($tabs[1].nodes).Count -ne 1) {
        Fail "the saved state isn't one window with a split tab and a plain tab ($note)"
    }
    Write-Host "Quitting saved the session: $note, active tab $($saved.windows[0].active_tab)."

    # Starting again restores both tabs and the split.
    Start-Ghostty
    [void](WaitFor { Note; @(Surfaces).Count -eq 3 } 'the restored terminals')
    # Only the active (second) tab's terminal shows: the others were once
    # left visible, because hiding them was skipped while the window was
    # still hidden.
    [void](WaitFor { Note; @(Visible).Count -eq 1 } "only the restored active tab's terminal to show")
    Write-Host "Starting again restored three terminals, and only the active tab shows ($note)."

    # The first tab has the split, its terminals side by side.
    $W::Key((Visible)[0], 0x7B, 0x58)   # F12: goto_tab:1
    [void](WaitFor { Note; @(Visible).Count -eq 2 } "the first tab's split")
    $rects = @(Visible | ForEach-Object { $r = New-Object GhosttySession.Win32+RECT; [void]$W::GetWindowRect($_, [ref]$r); $r } | Sort-Object l)
    $note = "($($rects[0].l),$($rects[0].t)-$($rects[0].r),$($rects[0].b)) and ($($rects[1].l),$($rects[1].t)-$($rects[1].r),$($rects[1].b))"
    if ($rects[0].r -gt $rects[1].l -or $rects[0].t -ne $rects[1].t) { Fail "the restored split isn't left and right: $note" }
    Write-Host "The first tab's split is restored left and right: $note."
    Quit

    # Each terminal's shell and directory.
    $windows = $env:SystemRoot
    $temp = (Get-Item ([IO.Path]::GetTempPath())).FullName.TrimEnd('\')
    $session = @{ version = 1; windows = @(@{
        left = 100; top = 100; right = 1100; bottom = 700; active_tab = 0
        tabs = @(
            @{ nodes = @(@{ pwd = $windows; command = @{ direct = @('powershell.exe', '-NoProfile') } }) },
            @{ nodes = @(@{ pwd = $temp }) }
        )
    }) }
    # Without a byte order mark, which Windows PowerShell's UTF-8 would add.
    [IO.File]::WriteAllText($state, ($session | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    Start-Ghostty
    [void](WaitFor { Note; @(Surfaces).Count -eq 2 -and @(Visible).Count -eq 1 } 'the two restored tabs')
    $first = (Visible)[0]
    [void](WaitFor { $script:note = "screen: $((Text $first) -replace '\s+', ' ')"; (Text $first) -match [regex]::Escape("PS $windows>") } "PowerShell in $windows in the first tab")
    Write-Host "The first tab runs PowerShell in $windows, as saved."
    $W::Key($first, 0x77, 0x42)   # F8: goto_tab:2
    [void](WaitFor { Note; $v = @(Visible); $v.Count -eq 1 -and $v[0] -ne $first } 'the second tab')
    $second = (Visible)[0]
    [void](WaitFor { $script:note = "screen: $((Text $second) -replace '\s+', ' ')"; $t = Text $second; $t -match [regex]::Escape("$temp>") -and $t -notmatch 'PS ' } "cmd in $temp in the second tab")
    Write-Host "The second tab runs the configured cmd in $temp."
    Quit

    $saved = Get-Content -Raw $state | ConvertFrom-Json
    $tabs = @($saved.windows[0].tabs)
    $command = $tabs[0].nodes[0].command
    if (-not $command -or @($command.direct)[0] -ne 'powershell.exe') { Fail "the PowerShell tab's command wasn't saved again: $($tabs[0].nodes[0] | ConvertTo-Json -Compress)" }
    if ($tabs[1].nodes[0].command) { Fail "the cmd tab saved a command, but it runs the configured one: $($tabs[1].nodes[0] | ConvertTo-Json -Compress)" }
    Write-Host 'Quitting saved the PowerShell tab with its command and the cmd tab without one.'
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $state, $log -Force -ErrorAction SilentlyContinue
}
exit 0
