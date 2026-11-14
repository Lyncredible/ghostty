# Checks the terminal inspector's window: inspector:toggle opens it, named
# for its terminal and sized 1000x800 points; it takes resizing,
# minimizing and input and keeps answering; inspector:show brings the open
# one back rather than opening another; toggling again, or closing it,
# closes it and leaves the terminal running; and closing the terminal
# closes its inspector. Then it quits with the quit action and checks
# that Ghostty exits cleanly. Input is posted to Ghostty's windows, so it
# runs on a locked desktop.
#
#     ./inspector.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyInspector -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageTimeoutW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l, uint flags, uint ms, out System.IntPtr result);
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr context);
[DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int index, uint dpi);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
public static void Mouse(System.IntPtr h, uint msg, uint keys, int x, int y) {
  PostMessageW(h, msg, (System.IntPtr)keys, (System.IntPtr)((x & 0xFFFF) | (y << 16)));
}
'@
$W = [GhosttyInspector.Win32]
# Per monitor, like Ghostty, so window sizes aren't scaled to 96 DPI for us.
[void]$W::SetProcessDpiAwarenessContext([IntPtr](-4))

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-inspector-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--title=inspected', '--window-save-state=never', '--confirm-close-surface=false',
    '--quit-after-last-window-closed=true', '--undo-timeout=0',
    '--keybind=f1=inspector:toggle', '--keybind=f2=inspector:show', '--keybind=f3=new_tab',
    '--keybind=f4=close_surface', '--keybind=f5=quit'
# Opening the handle now keeps the exit code for later.
$null = $process.Handle

function Fail([string]$message) {
    $lines = @()
    if (Test-Path $log) { $lines = @(Get-Content $log | Where-Object { $_ -match '\b(warning|error|panic)\b' } | Select-Object -Last 6) }
    if ($lines.Count -gt 0) { $message += " Ghostty's log: " + ($lines -join ' | ') }
    Write-Host "::error title=inspector::$message"
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

# The process's inspector windows.
function Inspectors {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, 'GhosttyInspector', [NullString]::Value)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $process.Id) { $list += $h }
    }
    $list
}

function Surfaces {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { $list += $h }
    $list
}

function Answers([IntPtr]$h) {
    $r = [IntPtr]::Zero
    $W::SendMessageTimeoutW($h, 0, [IntPtr]0, [IntPtr]0, 0x0002, 5000, [ref]$r) -ne [IntPtr]::Zero   # WM_NULL, SMTO_ABORTIFHUNG
}

function Open([IntPtr]$surface, [int]$vk, [int]$scan, [string]$what) {
    $W::Key($surface, $vk, $scan)
    WaitFor { $list = @(Inspectors | Where-Object { $W::IsWindowVisible($_) }); if ($list.Count -gt 0) { $list[0] } } $what
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $first = WaitFor { @(Surfaces)[0] } 'the terminal'
    Start-Sleep -Seconds 1

    $inspector = Open $first 0x70 0x3B 'inspector:toggle to open the inspector'   # F1
    $text = New-Object System.Text.StringBuilder 256
    [void]$W::GetWindowTextW($inspector, $text, $text.Capacity)
    if ($text.ToString() -ne 'Inspector: inspected') { Fail "the inspector is named '$text', not for its terminal" }
    $r = New-Object GhosttyInspector.Win32+RECT; [void]$W::GetWindowRect($inspector, [ref]$r)
    $dpi = $W::GetDpiForWindow($inspector)
    # Windows keeps a window within its largest tracking size (about the
    # screen and borders): CI's 1024x768 screen gives 788 pixels, not 800.
    $maxW = $W::GetSystemMetricsForDpi(59, $dpi); $maxH = $W::GetSystemMetricsForDpi(60, $dpi)   # SM_CXMAXTRACK, SM_CYMAXTRACK
    $want = "$([Math]::Min([int][Math]::Floor(1000 * $dpi / 96), $maxW))x$([Math]::Min([int][Math]::Floor(800 * $dpi / 96), $maxH))"
    $size = "$($r.r - $r.l)x$($r.b - $r.t)"
    if ($size -ne $want) { Fail "the inspector is $size, not 1000x800 points ($want at $dpi DPI)" }
    Write-Host "inspector:toggle opens '$text', $size at $dpi DPI."

    # Resizing (new swap chain buffers), minimizing and restoring, and
    # input for Dear ImGui: moves, clicks, the wheel and keys.
    [void]$W::SetWindowPos($inspector, [IntPtr]::Zero, 0, 0, 700, 500, 0x0016)   # SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
    Start-Sleep -Milliseconds 300
    [void]$W::SetWindowPos($inspector, [IntPtr]::Zero, 0, 0, 1, 1, 0x0016)
    Start-Sleep -Milliseconds 300
    [void]$W::PostMessageW($inspector, 0x0112, [IntPtr]0xF020, [IntPtr]0)   # WM_SYSCOMMAND, SC_MINIMIZE
    [void](WaitFor { $W::IsIconic($inspector) } 'the inspector to minimize')
    Start-Sleep -Milliseconds 300
    [void]$W::PostMessageW($inspector, 0x0112, [IntPtr]0xF120, [IntPtr]0)   # SC_RESTORE
    [void](WaitFor { -not $W::IsIconic($inspector) } 'the inspector to restore')
    [void]$W::SetWindowPos($inspector, [IntPtr]::Zero, 0, 0, 900, 700, 0x0016)
    for ($i = 0; $i -lt 20; $i++) {
        $W::Mouse($inspector, 0x0200, 0, 30 + 20 * $i, 40 + 10 * $i)   # WM_MOUSEMOVE
        $W::Mouse($inspector, 0x0201, 1, 30 + 20 * $i, 40 + 10 * $i)   # WM_LBUTTONDOWN
        $W::Mouse($inspector, 0x0202, 0, 30 + 20 * $i, 40 + 10 * $i)   # WM_LBUTTONUP
    }
    [void]$W::PostMessageW($inspector, 0x020A, [IntPtr](-120 -shl 16), [IntPtr]((200 -shl 16) -bor 200))   # WM_MOUSEWHEEL down
    $W::Key($inspector, 0x09, 0x0F)   # Tab
    $W::Key($inspector, 0x28, 0x50)   # Down
    Start-Sleep -Seconds 1
    if (-not (Answers $inspector)) { Fail "the inspector stopped answering after resizing, minimizing and input" }
    Write-Host 'It takes resizing (down to 1x1), minimizing and input, and keeps answering.'

    # inspector:show with one open brings it back rather than opening another.
    $W::Key($first, 0x71, 0x3C)   # F2
    Start-Sleep -Seconds 1
    $list = @(Inspectors)
    if ($list.Count -ne 1 -or $list[0] -ne $inspector) { Fail "inspector:show with one open made $($list.Count) windows" }

    # Toggling again closes it; closing it closes it; the terminal stays.
    $W::Key($first, 0x70, 0x3B)
    [void](WaitFor { -not $W::IsWindow($inspector) } 'inspector:toggle to close the inspector')
    $inspector = Open $first 0x70 0x3B 'inspector:toggle to open the inspector again'
    [void]$W::PostMessageW($inspector, 0x0010, [IntPtr]0, [IntPtr]0)   # WM_CLOSE
    [void](WaitFor { -not $W::IsWindow($inspector) } 'closing the inspector to close it')
    if (-not $W::IsWindowVisible($first) -or -not (Answers $window)) { Fail "closing the inspector closed its terminal" }
    Write-Host 'inspector:show keeps one window; toggling or closing it closes it and leaves the terminal.'

    # Closing the terminal closes its inspector (a second tab keeps the
    # window open).
    $W::Key($first, 0x72, 0x3D)   # F3: new_tab
    $tab = WaitFor { @(Surfaces | Where-Object { $_ -ne $first -and $W::IsWindowVisible($_) })[0] } 'a new tab'
    $inspector = Open $tab 0x71 0x3C 'inspector:show to open the new tab''s inspector'
    $W::Key($tab, 0x73, 0x3E)   # F4: close_surface
    [void](WaitFor { -not $W::IsWindow($inspector) } 'closing the terminal to close its inspector')
    if (-not (Answers $window)) { Fail "Ghostty stopped answering after closing a terminal with its inspector open" }
    Write-Host 'Closing a terminal closes its inspector.'

    # Quit with one open.
    $inspector = Open $first 0x70 0x3B 'the first terminal''s inspector'
    $W::Key($first, 0x74, 0x3F)   # F5: quit
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { Fail "Ghostty didn't quit with the inspector open" }
    if ($process.ExitCode -ne 0) { Fail "Ghostty exited with code $($process.ExitCode) quitting with the inspector open" }
    $bad = @(Get-Content $log | Where-Object { $_ -match '\berror\b|panic|leaked' })
    if ($bad.Count -gt 0) { Fail "Ghostty logged errors: $($bad[0..([Math]::Min(5, $bad.Count) - 1)] -join ' | ')" }
    Write-Host 'Quitting with the inspector open exits cleanly.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
