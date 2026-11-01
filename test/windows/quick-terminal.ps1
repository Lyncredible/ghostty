# Checks, for CI, the quick terminal: it toggles it over IPC
# (+toggle-quick-terminal) and samples its position while it slides in from
# the top and back out, then checks that it's hidden. Then it switches to a
# new virtual desktop (Ctrl+Win+D) and checks that showing the quick
# terminal again moves it there (quick-terminal-space-behavior = move). It
# sends real keys and adds a virtual desktop, so it only runs in CI.
#
#     ./quick-terminal.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this sends real keys and adds a virtual desktop, so it only runs in CI" }

Add-Type -Namespace GhosttyQuick -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
[DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] static extern int GetWindowLongW(System.IntPtr h, int index);
// The process's quick terminal: its top level Ghostty window that's a
// tool window (normal windows aren't).
public static System.IntPtr QuickTerminal(uint pid) {
  System.IntPtr found = System.IntPtr.Zero;
  EnumWindows((h, l) => {
    uint p; GetWindowThreadProcessId(h, out p);
    var name = new System.Text.StringBuilder(64); GetClassNameW(h, name, 64);
    if (p == pid && name.ToString() == "GhosttyWindow" && (GetWindowLongW(h, -20) & 0x80) != 0) { found = h; return false; }
    return true;
  }, System.IntPtr.Zero);
  return found;
}
// Press keys together, then release them in reverse.
public static void Chord(params ushort[] vks) {
  int size = Marshal.SizeOf(typeof(INPUT));
  foreach (var vk in vks) { var d = new INPUT[1]; d[0].type = 1; d[0].u.ki.wVk = vk; SendInput(1, d, size); System.Threading.Thread.Sleep(30); }
  for (int k = vks.Length - 1; k >= 0; k--) { var u = new INPUT[1]; u[0].type = 1; u[0].u.ki.wVk = vks[k]; u[0].u.ki.dwFlags = 2; SendInput(1, u, size); System.Threading.Thread.Sleep(30); }
}
[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IVirtualDesktopManager {
  [PreserveSig] int IsWindowOnCurrentVirtualDesktop(System.IntPtr h, out bool on);
  [PreserveSig] int GetWindowDesktopId(System.IntPtr h, out System.Guid id);
  [PreserveSig] int MoveWindowToDesktop(System.IntPtr h, ref System.Guid id);
}
// The virtual desktop a window is on, from the documented
// IVirtualDesktopManager.
public static System.Guid Desktop(System.IntPtr h) {
  var manager = (IVirtualDesktopManager)System.Activator.CreateInstance(
    System.Type.GetTypeFromCLSID(new System.Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")));
  System.Guid id; Marshal.ThrowExceptionForHR(manager.GetWindowDesktopId(h, out id)); return id;
}
public static bool OnCurrentDesktop(System.IntPtr h) {
  var manager = (IVirtualDesktopManager)System.Activator.CreateInstance(
    System.Type.GetTypeFromCLSID(new System.Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")));
  bool on; Marshal.ThrowExceptionForHR(manager.IsWindowOnCurrentVirtualDesktop(h, out on)); return on;
}
'@
[void][GhosttyQuick.Win32]::SetProcessDPIAware()

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-quick-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList `
    '--command=cmd.exe', '--window-save-state=never', '--quick-terminal-animation-duration=0.4'

function Notice([string]$message) { Write-Host "::notice title=quick-terminal::$message" }

function Fail([string]$message) {
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    Write-Host "::error title=quick-terminal::$message"
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

function Toggle {
    $toggle = Start-Process -FilePath $Exe -ArgumentList '+toggle-quick-terminal' -PassThru -Wait -NoNewWindow
    if ($toggle.ExitCode -ne 0) { Fail "+toggle-quick-terminal exited with $($toggle.ExitCode)" }
}

# The window's top edge every 15 ms for a second, while it's visible.
function SampleTops($hwnd) {
    $tops = @()
    $rect = New-Object GhosttyQuick.Win32+RECT
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt 1000) {
        if (-not [GhosttyQuick.Win32]::IsWindowVisible($hwnd)) { $tops += 'hidden'; break }
        [void][GhosttyQuick.Win32]::GetWindowRect($hwnd, [ref]$rect)
        if ($tops.Count -eq 0 -or $tops[-1] -ne $rect.t) { $tops += $rect.t }
        Start-Sleep -Milliseconds 15
    }
    return , $tops
}

try {
    # Wait for the normal window, so the toggles go to this instance.
    [void](WaitFor { $process.Refresh(); $process.MainWindowHandle -ne 0 } 'the window')
    Start-Sleep -Seconds 1

    Toggle
    $quick = WaitFor { $h = [GhosttyQuick.Win32]::QuickTerminal($process.Id); if ($h -ne 0 -and [GhosttyQuick.Win32]::IsWindowVisible($h)) { $h } } 'the quick terminal'
    $in = SampleTops $quick
    Write-Host "Sliding in, its top was: $($in -join ', ')"
    if ($in[-1] -ne 0) { Fail "the quick terminal ended at $($in[-1]), not the top of the screen" }
    if (-not ($in | Where-Object { $_ -is [int] -and $_ -lt 0 })) { Fail "the quick terminal didn't slide in from above the screen" }

    [void](WaitFor { [GhosttyQuick.Win32]::GetForegroundWindow() -eq $quick } 'the quick terminal to be in front')
    Toggle
    $out = SampleTops $quick
    Write-Host "Sliding out, its top was: $($out -join ', ')"
    if ($out[-1] -ne 'hidden') { Fail "the quick terminal didn't hide after sliding out" }
    if (-not ($out | Where-Object { $_ -is [int] -and $_ -lt 0 })) { Fail "the quick terminal didn't slide out above the screen" }

    # A new virtual desktop, which Ctrl+Win+D creates and switches to.
    $first = [GhosttyQuick.Win32]::Desktop($quick)
    [GhosttyQuick.Win32]::Chord(0x11, 0x5B, 0x44)
    Start-Sleep -Seconds 2

    # On an empty desktop the foreground window is the taskbar, which is on
    # every desktop, so we only report what happens there.
    Toggle
    [void](WaitFor { [GhosttyQuick.Win32]::IsWindowVisible($quick) } 'the quick terminal')
    Start-Sleep -Milliseconds 800
    $moved = [GhosttyQuick.Win32]::Desktop($quick) -ne $first
    Notice "on an empty desktop, showing the quick terminal moved it: $moved"
    if (-not $moved) {
        # It's in front on its own desktop, so this hides it.
        Toggle
        [void](WaitFor { -not [GhosttyQuick.Win32]::IsWindowVisible($quick) } 'the quick terminal to hide')
        # If Windows switched back to the first desktop to show it, go to
        # the new one again (Ctrl+Win+Right).
        if ([GhosttyQuick.Win32]::OnCurrentDesktop($process.MainWindowHandle)) {
            Notice 'Windows switched back to the first desktop'
            [GhosttyQuick.Win32]::Chord(0x11, 0x5B, 0x27)
            Start-Sleep -Seconds 1
        }

        # With a window on the new desktop, as there usually is.
        $cmd = Start-Process cmd.exe -PassThru
        [void](WaitFor { $cmd.Refresh(); $cmd.MainWindowHandle -ne 0 -or (Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue) } 'a cmd window')
        Start-Sleep -Seconds 1
        Toggle
        [void](WaitFor { [GhosttyQuick.Win32]::IsWindowVisible($quick) } 'the quick terminal on the new desktop')
        Start-Sleep -Milliseconds 800
    }
    $after = [GhosttyQuick.Win32]::Desktop($quick)
    Write-Host "The quick terminal was on desktop $first, and is now on $after."
    if ($after -eq $first) { Fail "the quick terminal stayed on its desktop (did Ctrl+Win+D add one?)" }
    if (-not [GhosttyQuick.Win32]::OnCurrentDesktop($quick)) { Fail "the quick terminal isn't on the current desktop" }
    Write-Host 'Showing the quick terminal moved it to the new desktop.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if ($cmd -and -not $cmd.HasExited) { Stop-Process -Id $cmd.Id -Force }
    # Close the desktop we added (Ctrl+Win+F4).
    [GhosttyQuick.Win32]::Chord(0x11, 0x5B, 0x73)
}
