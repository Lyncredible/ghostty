# Checks of the Windows app with real (synthesized) keyboard and mouse
# input, for CI: typing, Ctrl+V pasting, Ctrl+C copying and interrupting,
# focus-follows-mouse between splits, mouse-hide-while-typing, and
# window-step-resize while dragging the window's corner. SendInput goes to
# whatever window is in the foreground, so this only runs in CI (where
# nothing else is on the desktop), never on a developer's machine.
#
#     $env:CI = 'true'; ./desktop-input.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this sends real input to the desktop, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyDesktop -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
  public int cbSize; public int flags; public System.IntPtr hwndActive; public System.IntPtr hwndFocus;
  public System.IntPtr hwndCapture; public System.IntPtr hwndMenuOwner; public System.IntPtr hwndMoveSize;
  public System.IntPtr hwndCaret; public RECT rcCaret; }
[DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, System.IntPtr extra);
[StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize; public int flags; public System.IntPtr hCursor; public int x, y; }
[DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO info);
public static System.IntPtr Cursor() {
  var i = new CURSORINFO(); i.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(i);
  GetCursorInfo(ref i); return i.hCursor; }
public static void Key(ushort vk, bool up) {
  var i = new INPUT[1]; i[0].type = 1; i[0].u.ki.wVk = vk; i[0].u.ki.dwFlags = up ? 2u : 0u;
  SendInput(1, i, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT))); }
// A key by scancode only, as a keyboard sends it (Alt codes need these).
public static void Scan(ushort scan, bool up) {
  var i = new INPUT[1]; i[0].type = 1; i[0].u.ki.wScan = scan; i[0].u.ki.dwFlags = 8u | (up ? 2u : 0u); // KEYEVENTF_SCANCODE
  SendInput(1, i, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT))); }
public static void Char(char ch) {
  var i = new INPUT[2];
  i[0].type = 1; i[0].u.ki.wScan = ch; i[0].u.ki.dwFlags = 4;      // KEYEVENTF_UNICODE
  i[1].type = 1; i[1].u.ki.wScan = ch; i[1].u.ki.dwFlags = 4 | 2;
  SendInput(2, i, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT))); }
public static System.IntPtr Focus(System.IntPtr w) {
  uint pid; uint tid = GetWindowThreadProcessId(w, out pid);
  var i = new GUITHREADINFO(); i.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(i);
  GetGUIThreadInfo(tid, ref i); return i.hwndFocus; }
'@
[void][GhosttyDesktop.Win32]::SetProcessDPIAware()

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-desktop-$PID.log"
$env:GHOSTTY_LOG = 'debug'
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList `
    '--command=cmd.exe', '--window-save-state=never', '--focus-follows-mouse=true', `
    '--clipboard-paste-protection=false', '--keybind=f8=new_split:right', `
    '--keybind=f9=select_all', '--window-step-resize=true', '--mouse-hide-while-typing=true'

function Fail([string]$message) {
    Write-Host "::error title=desktop-input::$message"
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
    Fail "timed out waiting for $what"
}

# The terminal surfaces, as UI Automation elements.
function Surfaces {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))
    }
}

function Text($surface) {
    $(try { $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' })
}

function TypeLine([string]$text) {
    foreach ($ch in $text.ToCharArray()) { [GhosttyDesktop.Win32]::Char($ch) }
    [GhosttyDesktop.Win32]::Key(0x0D, $false); [GhosttyDesktop.Win32]::Key(0x0D, $true)
}

try {
    $surface = WaitFor { Surfaces | Where-Object { (Text $_).Contains('>') } | Select-Object -First 1 } 'the prompt'
    $window = [IntPtr](WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window')
    [void][GhosttyDesktop.Win32]::SetForegroundWindow($window)
    [void](WaitFor { [GhosttyDesktop.Win32]::GetForegroundWindow() -eq $window } 'the window to be in the foreground')
    Write-Host 'The window is in the foreground.'

    # Typing, as keys from the keyboard.
    TypeLine 'echo typed-%USERNAME:~0,0%ok'
    [void](WaitFor { (Text $surface).Contains('typed-ok') } 'typed text to run')
    Write-Host 'Typing works.'

    # An Alt code: Alt+0233 on the numpad types é, and the digits
    # themselves don't reach the shell.
    foreach ($ch in 'echo alt-'.ToCharArray()) { [GhosttyDesktop.Win32]::Char($ch) }
    # Left Alt, then numpad 0, 2, 3, 3 by scancode (with Num Lock on or off).
    [GhosttyDesktop.Win32]::Scan(0x38, $false)
    foreach ($scan in 0x52, 0x50, 0x51, 0x51) {
        [GhosttyDesktop.Win32]::Scan($scan, $false); [GhosttyDesktop.Win32]::Scan($scan, $true)
    }
    [GhosttyDesktop.Win32]::Scan(0x38, $true)
    TypeLine '-ok'
    $line = WaitFor { (Text $surface) -split "`n" | Where-Object { $_ -match '^alt-.*-ok' } | Select-Object -Last 1 } 'the Alt code line to run'
    if ($line.Trim() -ne "alt-$([char]0xE9)-ok") { Fail "the Alt code gave: $line" }
    Write-Host 'Alt codes type their character.'

    # Ctrl+V pastes (the default binding on Windows).
    Set-Clipboard -Value 'echo pasted-%USERNAME:~0,0%ok'
    [GhosttyDesktop.Win32]::Key(0x11, $false); [GhosttyDesktop.Win32]::Key(0x56, $false)
    [GhosttyDesktop.Win32]::Key(0x56, $true); [GhosttyDesktop.Win32]::Key(0x11, $true)
    [GhosttyDesktop.Win32]::Key(0x0D, $false); [GhosttyDesktop.Win32]::Key(0x0D, $true)
    [void](WaitFor { (Text $surface).Contains('pasted-ok') } 'pasted text to run')
    Write-Host 'Ctrl+V pastes.'

    # Ctrl+C copies when there's a selection...
    Set-Clipboard -Value 'nothing yet'
    [GhosttyDesktop.Win32]::Key(0x78, $false); [GhosttyDesktop.Win32]::Key(0x78, $true)
    Start-Sleep -Milliseconds 300
    [GhosttyDesktop.Win32]::Key(0x11, $false); [GhosttyDesktop.Win32]::Key(0x43, $false)
    [GhosttyDesktop.Win32]::Key(0x43, $true); [GhosttyDesktop.Win32]::Key(0x11, $true)
    [void](WaitFor { "$(Get-Clipboard -Raw)".Contains('pasted-ok') } 'Ctrl+C to copy the selection')
    Write-Host 'Ctrl+C copies a selection.'

    # ...and interrupts otherwise (typing clears the selection).
    TypeLine 'ping -t 127.0.0.1'
    [void](WaitFor { ([regex]::Matches((Text $surface), 'Reply from 127').Count -ge 2) } 'ping to run')
    [GhosttyDesktop.Win32]::Key(0x11, $false); [GhosttyDesktop.Win32]::Key(0x43, $false)
    [GhosttyDesktop.Win32]::Key(0x43, $true); [GhosttyDesktop.Win32]::Key(0x11, $true)
    [void](WaitFor { (Text $surface) -match 'Control-C' } 'Ctrl+C to interrupt ping')
    Write-Host 'Ctrl+C interrupts without a selection.'

    # Focus follows the mouse between splits.
    [GhosttyDesktop.Win32]::Key(0x77, $false); [GhosttyDesktop.Win32]::Key(0x77, $true)
    $splits = WaitFor { $s = @(Surfaces); if ($s.Count -eq 2) { , $s } } 'a second split'
    $focused = [GhosttyDesktop.Win32]::Focus($window)
    $other = $splits | Where-Object { [IntPtr]$_.Current.NativeWindowHandle -ne $focused } | Select-Object -First 1
    $handle = [IntPtr]$other.Current.NativeWindowHandle
    $rect = New-Object GhosttyDesktop.Win32+RECT
    [void][GhosttyDesktop.Win32]::GetWindowRect($handle, [ref]$rect)
    $x = [int](($rect.l + $rect.r) / 2); $y = [int](($rect.t + $rect.b) / 2)
    [void][GhosttyDesktop.Win32]::SetCursorPos($x - 10, $y - 10)
    Start-Sleep -Milliseconds 100
    [void][GhosttyDesktop.Win32]::SetCursorPos($x, $y)
    [void](WaitFor { [GhosttyDesktop.Win32]::Focus($window) -eq $handle } 'focus to follow the mouse')
    Write-Host 'Focus follows the mouse.'

    # mouse-hide-while-typing: a typed letter hides the pointer over the
    # terminal, and moving the mouse shows it again.
    # The typing above may have hidden the pointer already, so move the
    # mouse first. A desktop that still shows no pointer has nothing to hide.
    [void][GhosttyDesktop.Win32]::SetCursorPos($x + 5, $y + 5)
    $deadline = (Get-Date).AddSeconds(3)
    while ([GhosttyDesktop.Win32]::Cursor() -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ([GhosttyDesktop.Win32]::Cursor() -eq [IntPtr]::Zero) {
        Write-Host '::notice title=desktop-input::no pointer is shown on this desktop, so mouse-hide-while-typing was not checked'
    } else {
        [GhosttyDesktop.Win32]::Key(0x41, $false); [GhosttyDesktop.Win32]::Key(0x41, $true)
        [void](WaitFor { [GhosttyDesktop.Win32]::Cursor() -eq [IntPtr]::Zero } 'typing to hide the pointer')
        [void][GhosttyDesktop.Win32]::SetCursorPos($x + 10, $y + 10)
        [void](WaitFor { [GhosttyDesktop.Win32]::Cursor() -ne [IntPtr]::Zero } 'moving the mouse to show the pointer')
        [GhosttyDesktop.Win32]::Key(0x08, $false); [GhosttyDesktop.Win32]::Key(0x08, $true)
        Write-Host 'Typing hides the pointer and moving the mouse shows it.'
    }

    # window-step-resize: dragging the bottom-right corner by an amount
    # that isn't whole cells changes the terminal by whole cells.
    $cell = [regex]::Matches((Get-Content $log -Raw), '\.cell = \.\{ \.width = (\d+), \.height = (\d+)') | Select-Object -Last 1
    if (-not $cell) { Fail "no cell size in the log" }
    $cellW = [int]$cell.Groups[1].Value; $cellH = [int]$cell.Groups[2].Value
    $before = New-Object GhosttyDesktop.Win32+RECT
    [void][GhosttyDesktop.Win32]::GetClientRect($window, [ref]$before)
    [void][GhosttyDesktop.Win32]::GetWindowRect($window, [ref]$rect)
    $x = $rect.r - 2; $y = $rect.b - 2
    [void][GhosttyDesktop.Win32]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 200
    [GhosttyDesktop.Win32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    foreach ($i in 1..10) {
        [void][GhosttyDesktop.Win32]::SetCursorPos($x + [int](137 * $i / 10), $y + [int](91 * $i / 10))
        Start-Sleep -Milliseconds 50
    }
    [GhosttyDesktop.Win32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $after = New-Object GhosttyDesktop.Win32+RECT
    [void][GhosttyDesktop.Win32]::GetClientRect($window, [ref]$after)
    $dw = $after.r - $before.r; $dh = $after.b - $before.b
    Write-Host "Dragging the corner by 137x91 px changed the client area by ${dw}x${dh} px (cells are ${cellW}x${cellH})."
    if ($dw -eq 0 -or $dh -eq 0) { Fail "the corner drag didn't resize the window" }
    if ($dw % $cellW -ne 0 -or $dh % $cellH -ne 0) { Fail "the resize wasn't whole cells" }
    Write-Host 'window-step-resize resizes by whole cells.'
} catch {
    if (-not $script:reported) { Write-Host "::error title=desktop-input::$($_.Exception.Message)" }
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
