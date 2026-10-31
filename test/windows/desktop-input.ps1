# Checks of the Windows app with real (synthesized) keyboard and mouse
# input, for CI: typing, Ctrl+V pasting, and focus-follows-mouse between
# splits. SendInput goes to whatever window is in the foreground, so this
# only runs in CI (where nothing else is on the desktop), never on a
# developer's machine.
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
public static void Key(ushort vk, bool up) {
  var i = new INPUT[1]; i[0].type = 1; i[0].u.ki.wVk = vk; i[0].u.ki.dwFlags = up ? 2u : 0u;
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
    '--clipboard-paste-protection=false', '--keybind=f8=new_split:right'

function Fail([string]$message) {
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
    $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
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

    # Ctrl+V pastes (the default binding on Windows).
    Set-Clipboard -Value 'echo pasted-%USERNAME:~0,0%ok'
    [GhosttyDesktop.Win32]::Key(0x11, $false); [GhosttyDesktop.Win32]::Key(0x56, $false)
    [GhosttyDesktop.Win32]::Key(0x56, $true); [GhosttyDesktop.Win32]::Key(0x11, $true)
    [GhosttyDesktop.Win32]::Key(0x0D, $false); [GhosttyDesktop.Win32]::Key(0x0D, $true)
    [void](WaitFor { (Text $surface).Contains('pasted-ok') } 'pasted text to run')
    Write-Host 'Ctrl+V pastes.'

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
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
