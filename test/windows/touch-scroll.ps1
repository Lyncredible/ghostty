# Checks, for CI, that a one-finger touch pan scrolls a terminal: it fills
# cmd with numbered lines, drags a (software) finger down the terminal
# with InjectTouchInput, and checks that earlier lines came into view.
# Touch input goes to whatever is on screen, so this only runs in CI.
#
#     ./touch-scroll.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this injects touch input on the desktop, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyTouch -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct POINTER_INFO {
  public int pointerType; public uint pointerId; public uint frameId; public uint pointerFlags;
  public System.IntPtr sourceDevice; public System.IntPtr hwndTarget;
  public POINT ptPixelLocation; public POINT ptHimetricLocation;
  public POINT ptPixelLocationRaw; public POINT ptHimetricLocationRaw;
  public uint dwTime; public uint historyCount; public int InputData; public uint dwKeyStates;
  public ulong PerformanceCount; public int ButtonChangeType; }
[StructLayout(LayoutKind.Sequential)] public struct POINTER_TOUCH_INFO {
  public POINTER_INFO pointerInfo; public uint touchFlags; public uint touchMask;
  public RECT rcContact; public RECT rcContactRaw; public uint orientation; public uint pressure; }
[DllImport("user32.dll", SetLastError = true)] public static extern bool InitializeTouchInjection(uint maxCount, uint mode);
[DllImport("user32.dll", SetLastError = true)] public static extern bool InjectTouchInput(uint count, POINTER_TOUCH_INFO[] contacts);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);

const uint DOWN = 0x10000, UPDATE = 0x20000, UP = 0x40000, INRANGE = 0x2, INCONTACT = 0x4;

static void Touch(int x, int y, uint flags) {
  var c = new POINTER_TOUCH_INFO[1];
  c[0].pointerInfo.pointerType = 2; // PT_TOUCH
  c[0].pointerInfo.pointerId = 0;
  c[0].pointerInfo.pointerFlags = flags;
  c[0].pointerInfo.ptPixelLocation.x = x;
  c[0].pointerInfo.ptPixelLocation.y = y;
  c[0].touchMask = 0x7; // contact area, orientation, pressure
  c[0].rcContact.l = x - 2; c[0].rcContact.r = x + 2;
  c[0].rcContact.t = y - 2; c[0].rcContact.b = y + 2;
  c[0].orientation = 90;
  c[0].pressure = 32000;
  if (!InjectTouchInput(1, c)) throw new System.ComponentModel.Win32Exception();
}

// A one-finger drag from (x, y) down by dy pixels.
public static void Pan(int x, int y, int dy) {
  if (!InitializeTouchInjection(1, 3)) throw new System.ComponentModel.Win32Exception();
  Touch(x, y, DOWN | INRANGE | INCONTACT);
  System.Threading.Thread.Sleep(50);
  for (int i = 1; i <= 30; i++) {
    Touch(x, y + dy * i / 30, UPDATE | INRANGE | INCONTACT);
    System.Threading.Thread.Sleep(16);
  }
  Touch(x, y + dy, UP);
}
'@
[void][GhosttyTouch.Win32]::SetProcessDPIAware()

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
                Text = $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
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

# The numbered lines now on screen.
function VisibleLines {
    [regex]::Matches((Surface).Text, '(?m)^line(\d+)\s*$') | ForEach-Object { [int]$_.Groups[1].Value }
}

try {
    $surface = WaitFor { $s = Surface; if ($s -and $s.Text.Contains('>')) { $s } } 'the prompt'
    [void][GhosttyTouch.Win32]::SetForegroundWindow($surface.Window)

    foreach ($ch in 'for /l %i in (1,1,200) do @echo line%i'.ToCharArray()) {
        [void][GhosttyTouch.Win32]::SendMessageW($surface.Handle, 0x0102, [IntPtr][int]$ch, [IntPtr]1)
    }
    [void][GhosttyTouch.Win32]::PostMessageW($surface.Handle, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)
    [void][GhosttyTouch.Win32]::PostMessageW($surface.Handle, 0x0101, [IntPtr]0x0D, [IntPtr]0xC01C0001)
    [void](WaitFor { (VisibleLines) -contains 200 } 'the lines to print')
    $before = @(VisibleLines)
    Write-Host "Before: lines $($before[0]) to $($before[-1]) are visible."

    $rect = New-Object GhosttyTouch.Win32+RECT
    [void][GhosttyTouch.Win32]::GetWindowRect($surface.Handle, [ref]$rect)
    $x = [int](($rect.l + $rect.r) / 2)
    $top = $rect.t + [int](($rect.b - $rect.t) / 5)
    [GhosttyTouch.Win32]::Pan($x, $top, [int](($rect.b - $rect.t) / 2))

    $after = WaitFor { $lines = @(VisibleLines); if ($lines.Count -gt 0 -and $lines[0] -lt $before[0]) { , $lines } } 'the pan to scroll back'
    Write-Host "After a downward pan: lines $($after[0]) to $($after[-1]) are visible."
} catch {
    Write-Host "::error title=touch-scroll::$($_.Exception.Message)"
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
