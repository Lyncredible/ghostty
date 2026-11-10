# Checks, for CI, typing through an IME: it adds the Japanese IME, switches
# a terminal running cmd to it, types "nihon" with real keys, converts and
# commits it, and checks that it reached cmd as kanji (U+65E5 U+672C). It installs a language and
# sends real input, so it only runs in CI.
#
#     ./ime.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this installs a language and sends real input, so it only runs in CI" }

function Notice([string]$message) { Write-Host "::notice title=ime::$message" }

# The Japanese IME comes with the language's basic typing capability.
$capability = Get-WindowsCapability -Online | Where-Object Name -like 'Language.Basic~~~ja-JP~*' | Select-Object -First 1
if (-not $capability) { throw "no Japanese language capability on this image" }
if ($capability.State -ne 'Installed') {
    Notice "installing $($capability.Name)"
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
$languages = Get-WinUserLanguageList
if (-not ($languages | Where-Object LanguageTag -eq 'ja')) {
    $languages.Add('ja-JP')
    Set-WinUserLanguageList $languages -Force
}
Notice "languages: $((Get-WinUserLanguageList | ForEach-Object { "$($_.LanguageTag) [$($_.InputMethodTips -join ',')]" }) -join '; ')"

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyIme -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
[DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr LoadKeyboardLayoutW(string id, uint flags);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern System.IntPtr GetKeyboardLayout(uint thread);
[DllImport("imm32.dll")] public static extern System.IntPtr ImmGetDefaultIMEWnd(System.IntPtr h);
// The keyboard layout of the window's thread.
public static long Layout(System.IntPtr h) { uint pid; return GetKeyboardLayout(GetWindowThreadProcessId(h, out pid)).ToInt64(); }
// WM_IME_CONTROL to the window's default IME window, which works from
// another process.
public static long ImeControl(System.IntPtr h, int command, long value) {
  return SendMessageW(ImmGetDefaultIMEWnd(h), 0x0283, (System.IntPtr)command, (System.IntPtr)value).ToInt64();
}
// Press keys together, then release them in reverse.
public static void Chord(params ushort[] vks) {
  int size = System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT));
  foreach (var vk in vks) { var d = new INPUT[1]; d[0].type = 1; d[0].u.ki.wVk = vk; SendInput(1, d, size); System.Threading.Thread.Sleep(30); }
  for (int k = vks.Length - 1; k >= 0; k--) { var u = new INPUT[1]; u[0].type = 1; u[0].u.ki.wVk = vks[k]; u[0].u.ki.dwFlags = 2; SendInput(1, u, size); System.Threading.Thread.Sleep(30); }
  System.Threading.Thread.Sleep(300);
}
public static void Key(ushort vk) {
  var i = new INPUT[2];
  i[0].type = 1; i[0].u.ki.wVk = vk;
  i[1].type = 1; i[1].u.ki.wVk = vk; i[1].u.ki.dwFlags = 2;
  SendInput(2, i, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
  System.Threading.Thread.Sleep(60);
}
'@

$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', '--window-save-state=never'

function Surface {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
            return @{
                Window = [IntPtr]$window.Current.NativeWindowHandle
                Handle = [IntPtr]$surface.Current.NativeWindowHandle
                Text = $(try { $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' })
            }
        }
    }
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what"
}

# The kanji, built from code points so that the script stays ASCII.
$nihon = [string][char]0x65E5 + [char]0x672C

try {
    $surface = WaitFor { $s = Surface; if ($s -and $s.Text.Contains('>')) { $s } } 'the prompt'
    [void][GhosttyIme.Win32]::SetForegroundWindow($surface.Window)
    Start-Sleep -Milliseconds 500

    # "echo " in direct input, before switching to the IME.
    foreach ($vk in 0x45, 0x43, 0x48, 0x4F, 0x20) { [GhosttyIme.Win32]::Key($vk) }

    # Switch to Japanese the way a user does, with Win+Space (or Alt+Shift):
    # Windows sends the focused window WM_INPUTLANGCHANGEREQUEST, which the
    # terminal leaves to DefWindowProc. (Posting that message from another
    # process didn't switch it.) Then turn the IME on with VK_IME_ON, which
    # Microsoft's IMEs take since Windows 10 (the Kanji key needs a
    # Japanese keyboard).
    $japanese = { ([GhosttyIme.Win32]::Layout($surface.Handle) -band 0xFFFF) -eq 0x0411 }
    [GhosttyIme.Win32]::Chord(0x5B, 0x20) # Win+Space
    Start-Sleep -Seconds 1
    Notice ("after Win+Space: layout {0:X}" -f [GhosttyIme.Win32]::Layout($surface.Handle))
    if (-not (& $japanese)) {
        [GhosttyIme.Win32]::Chord(0xA4, 0xA0) # Left Alt+Left Shift
        Start-Sleep -Seconds 1
        Notice ("after Alt+Shift: layout {0:X}" -f [GhosttyIme.Win32]::Layout($surface.Handle))
    }
    [GhosttyIme.Win32]::Key(0x16) # VK_IME_ON
    Start-Sleep -Milliseconds 500
    # Also open it and choose Hiragana directly: IMC_SETOPENSTATUS, and
    # IMC_SETCONVERSIONMODE with IME_CMODE_NATIVE | IME_CMODE_FULLSHAPE.
    [void][GhosttyIme.Win32]::ImeControl($surface.Handle, 0x0006, 1)
    [void][GhosttyIme.Win32]::ImeControl($surface.Handle, 0x0002, 0x9)
    Start-Sleep -Milliseconds 300
    $layout = '{0:X}' -f [GhosttyIme.Win32]::Layout($surface.Handle)
    $open = [GhosttyIme.Win32]::ImeControl($surface.Handle, 0x0005, 0)  # IMC_GETOPENSTATUS
    $mode = [GhosttyIme.Win32]::ImeControl($surface.Handle, 0x0001, 0)  # IMC_GETCONVERSIONMODE
    Notice "layout $layout, IME open $open, conversion mode $mode"

    # n i h o n, convert (Space), commit (Enter).
    foreach ($vk in 0x4E, 0x49, 0x48, 0x4F, 0x4E, 0x4E) { [GhosttyIme.Win32]::Key($vk) }
    Start-Sleep -Milliseconds 300
    [GhosttyIme.Win32]::Key(0x20)
    Start-Sleep -Milliseconds 500
    [GhosttyIme.Win32]::Key(0x0D)
    Start-Sleep -Milliseconds 500

    # Turn the IME off and run the command.
    [GhosttyIme.Win32]::Key(0x1A) # VK_IME_OFF
    Start-Sleep -Milliseconds 300
    [GhosttyIme.Win32]::Key(0x0D)

    try {
        [void](WaitFor { (Surface).Text -match "(?m)^$nihon\s*`$" } 'cmd to echo nihon in kanji')
    } catch {
        $screen = ((Surface).Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '
        throw "$($_.Exception.Message); screen: $screen"
    }
    Write-Host "Typing through the Japanese IME works: cmd echoed $nihon." 
} catch {
    Write-Host "::error title=ime::$($_.Exception.Message)"
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
