# Checks for memory leaks: Debug builds allocate through Zig's debug
# allocator, which reports every allocation not freed when the program
# exits normally ("error(SafeAllocator): leaked ..." with where it was
# made). Other UI tests end Ghostty with Stop-Process, which skips that.
# This one does some UI work (the search bar, the command palette, tabs and
# splits opened and closed and still kept for undo when it quits,
# resizing, a scrollback full of output, the inspector, font sizes,
# read-only mode, the quick terminal, a title and a bell), then closes the window so Ghostty quits, and fails if
# its standard error reports a leak. Input is posted to Ghostty's windows,
# so it runs on a locked desktop. Release builds don't use the debug
# allocator, so it needs a Debug build.
#
#     ./memory-leak.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyMemLeak -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Type(System.IntPtr h, string s) {
  foreach (char ch in s) { PostMessageW(h, 0x0102, (System.IntPtr)ch, (System.IntPtr)1); System.Threading.Thread.Sleep(5); }
}
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyMemLeak.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-memory-leak-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--confirm-close-surface=false', '--quit-after-last-window-closed=true',
    '--keybind=f5=start_search', '--keybind=f6=end_search', '--keybind=f7=toggle_command_palette',
    '--keybind=f8=new_tab', '--keybind=f9=close_tab', '--keybind=f10=new_split:right', '--keybind=f11=close_surface',
    '--undo-timeout=5m', '--keybind=f1=inspector:toggle', '--keybind=f2=increase_font_size:3',
    '--keybind=f3=reset_font_size', '--keybind=f4=toggle_readonly', '--keybind=f12=toggle_quick_terminal'
# Opening the handle now keeps the exit code for later.
$null = $process.Handle

function Fail([string]$message) {
    Write-Host "::error title=memory-leak::$message"
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

# The process's top-level windows, through UI Automation.
function TopLevel {
    $AE = [System.Windows.Automation.AutomationElement]
    $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $process.Id)))
}

function Surfaces {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', $null)) -ne [IntPtr]::Zero) { $list += $h }
    $list
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $first = WaitFor { @(Surfaces)[0] } 'the terminal'
    Start-Sleep -Seconds 1

    # Output that scrolls, so the scrollback has pages.
    $W::Type($first, "for /L %i in (1,1,400) do @echo line %i of the scrollback`r")
    Start-Sleep -Seconds 2

    $W::Key($first, 0x74, 0x3F)   # F5: start_search
    Start-Sleep -Milliseconds 300
    $W::Key($first, 0x75, 0x40)   # F6: end_search
    $W::Key($first, 0x76, 0x41)   # F7: toggle_command_palette
    Start-Sleep -Milliseconds 300
    $W::Key($first, 0x76, 0x41)

    # Each key goes to the terminal it's for: close_surface and close_tab
    # act on the terminal that gets them. Closed terminals are kept (hidden)
    # for undo, so we watch which ones show.
    $before = @(Surfaces)
    $W::Key($first, 0x77, 0x42)   # F8: new_tab
    $tab = WaitFor { @(Surfaces | Where-Object { $before -notcontains $_ })[0] } 'a new tab'
    $W::Key($tab, 0x79, 0x44)     # F10: new_split:right
    $split = WaitFor { @(Surfaces | Where-Object { $before -notcontains $_ -and $_ -ne $tab })[0] } 'a split'
    $W::Key($split, 0x7A, 0x57)   # F11: close_surface
    [void](WaitFor { -not $W::IsWindowVisible($split) } 'the split to close')
    $W::Key($tab, 0x78, 0x43)     # F9: close_tab
    [void](WaitFor { -not $W::IsWindowVisible($tab) -and $W::IsWindowVisible($first) } 'the tab to close')
    [void]$W::SetWindowPos($window, [IntPtr]::Zero, 60, 60, 900, 600, 0x0014)
    Start-Sleep -Seconds 1
    Write-Host 'Did the search bar, the command palette, tabs, splits and a resize.'

    # The inspector, a bigger font (a new glyph atlas) and back, read-only
    # mode (a badge), the quick terminal, and from cmd a title and a bell.
    $W::Key($first, 0x70, 0x3B)   # F1: inspector:toggle
    Start-Sleep -Seconds 1
    $W::Key($first, 0x70, 0x3B)
    $W::Key($first, 0x71, 0x3C)   # F2: increase_font_size:3
    Start-Sleep -Milliseconds 500
    $W::Key($first, 0x72, 0x3D)   # F3: reset_font_size
    $W::Key($first, 0x73, 0x3E)   # F4: toggle_readonly
    Start-Sleep -Milliseconds 300
    $W::Key($first, 0x73, 0x3E)
    $W::Key($first, 0x7B, 0x58)   # F12: toggle_quick_terminal
    Start-Sleep -Seconds 1
    $W::Key($first, 0x7B, 0x58)
    Start-Sleep -Milliseconds 500
    $W::Type($first, "title memory leak test`r")
    $W::Type($first, "echo " + [char]7 + "`r")
    Start-Sleep -Seconds 1
    Write-Host 'Did the inspector, font sizes, read-only mode, the quick terminal, a title and a bell.'

    # Close the windows (the main one, and the quick terminal, which a
    # second toggle only hides when it's in front): with the last one
    # closed, Ghostty quits normally, and the debug allocator reports
    # what's left. The closed tab and split are still kept for undo then,
    # which must be freed too.
    $windows = @(TopLevel | ForEach-Object { [IntPtr]$_.Current.NativeWindowHandle })
    Write-Host "Closing $($windows.Count) windows."
    foreach ($h in $windows) { [void]$W::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }   # WM_CLOSE
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $left = TopLevel | ForEach-Object { "$($_.Current.ClassName) '$($_.Current.Name)'" }
        Fail "Ghostty did not quit after its window closed; its windows: $($left -join ', ')"
    }
    Write-Host "Ghostty quit with exit code $($process.ExitCode)."
    if ($process.ExitCode -ne 0) { Fail "Ghostty quit with exit code $($process.ExitCode)" }

    $text = Get-Content -Raw $log
    $leaks = [regex]::Matches($text, 'error\(\w+\): leaked')
    if ($leaks.Count -gt 0) {
        Write-Host "--- The first leaks ---"
        ($text -split "`n" | Select-String -Pattern 'leaked' -Context 0, 12 | Select-Object -First 3) | Out-String | Write-Host
        Fail "$($leaks.Count) allocations leaked"
    }
    if ($text -notmatch 'debug|info') { Fail "standard error has no log at all (is this a Debug build?)" }
    Write-Host 'No allocation leaked.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
