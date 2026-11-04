# Checks, for CI, that the tab bar (which we draw ourselves) uses the
# system colors of a high contrast theme: it starts Ghostty with the tab
# bar shown and a blue background, checks the bar's color on screen comes
# from the terminal's, turns high contrast on (SPI_SETHIGHCONTRAST) and
# expects the theme's window color, then turns it off again and expects the
# terminal's again. It also splits the window and checks the divider turns
# from a blend of the terminal's colors into its foreground, and that the
# search bar gets the theme's window color. It changes the whole desktop,
# so it only runs in CI.
#
#     ./high-contrast.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this turns high contrast on for the whole desktop, so it only runs in CI" }

trap {
    if (-not $script:reported) { Write-Host "::error title=high-contrast::$($_.Exception.Message)" }
    break
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace GhosttyContrast -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct HIGHCONTRAST { public int cbSize; public uint dwFlags; public System.IntPtr scheme; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetSysColor(int index);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
// The class and process of the window at a point on screen.
public static string WindowAt(int x, int y) {
  var p = new POINT(); p.x = x; p.y = y;
  var h = WindowFromPoint(p);
  var s = new System.Text.StringBuilder(64);
  GetClassNameW(h, s, 64);
  uint pid; GetWindowThreadProcessId(h, out pid);
  return s.ToString() + " of process " + pid;
}
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern System.IntPtr GetSystemMenu(System.IntPtr h, bool revert);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr h, EnumProc f, System.IntPtr l);
// The visible windows of a class under a window.
public static System.Collections.Generic.List<System.IntPtr> VisibleChildren(System.IntPtr parent, string cls) {
  var found = new System.Collections.Generic.List<System.IntPtr>();
  EnumChildWindows(parent, (h, l) => {
    var s = new System.Text.StringBuilder(64);
    GetClassNameW(h, s, 64);
    if (s.ToString() == cls && IsWindowVisible(h)) found.Add(h);
    return true;
  }, System.IntPtr.Zero);
  return found;
}
// The first visible window of a class under a window.
public static System.IntPtr VisibleChild(System.IntPtr parent, string cls) {
  System.IntPtr found = System.IntPtr.Zero;
  EnumChildWindows(parent, (h, l) => {
    var s = new System.Text.StringBuilder(64);
    GetClassNameW(h, s, 64);
    if (s.ToString() == cls && IsWindowVisible(h)) { found = h; return false; }
    return true;
  }, System.IntPtr.Zero);
  return found;
}
[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfoW(uint action, uint size, ref HIGHCONTRAST hc, uint ini);
public static bool HighContrast() {
  var hc = new HIGHCONTRAST(); hc.cbSize = Marshal.SizeOf(hc);
  SystemParametersInfoW(0x42, (uint)hc.cbSize, ref hc, 0); // SPI_GETHIGHCONTRAST
  return (hc.dwFlags & 1) != 0;
}
public static bool SetHighContrast(bool on) {
  var hc = new HIGHCONTRAST(); hc.cbSize = Marshal.SizeOf(hc); hc.dwFlags = on ? 1u : 0u;
  return SystemParametersInfoW(0x43, (uint)hc.cbSize, ref hc, 2); // SPI_SETHIGHCONTRAST, SPIF_SENDCHANGE
}
'@
[void][GhosttyContrast.Win32]::SetProcessDPIAware()

$wasOn = [GhosttyContrast.Win32]::HighContrast()
if ($wasOn) { [void][GhosttyContrast.Win32]::SetHighContrast($false) }
$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', `
    '--window-save-state=never', '--window-show-tab-bar=always', '--background=#336699', `
    '--foreground=#FFCC00', '--unfocused-split-opacity=1'

function Fail([string]$message) {
    Write-Host "::error title=high-contrast::$message"
    $script:reported = $true
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
    Fail "timed out waiting for $what (it was $script:last)"
}

# The color of the tab bar's empty part, on screen, as #RRGGBB.
function BarColor {
    $rect = New-Object GhosttyContrast.Win32+RECT
    [void][GhosttyContrast.Win32]::GetWindowRect($bar, [ref]$rect)
    ScreenColor ($rect.l + [int](($rect.r - $rect.l) * 0.7)) ($rect.t + 2)
}

function ScreenColor([int]$x, [int]$y) {
    $bitmap = New-Object System.Drawing.Bitmap 1, 1
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size 1, 1))
    $pixel = $bitmap.GetPixel(0, 0)
    $graphics.Dispose(); $bitmap.Dispose()
    '#{0:X2}{1:X2}{2:X2}' -f $pixel.R, $pixel.G, $pixel.B
}

function SysColor([int]$index) {
    $v = [GhosttyContrast.Win32]::GetSysColor($index)
    '#{0:X2}{1:X2}{2:X2}' -f ($v -band 0xFF), (($v -shr 8) -band 0xFF), (($v -shr 16) -band 0xFF)
}

# The bar is the terminal's background darkened by a quarter.
# (rounding halves away from zero, as the tab bar does).
function Darken([int]$v) { [int][Math]::Round($v * 0.75, [MidpointRounding]::AwayFromZero) }
$terminal = '#{0:X2}{1:X2}{2:X2}' -f (Darken 0x33), (Darken 0x66), (Darken 0x99)

# The divider is the background mixed a quarter of the way to the
# foreground, or under high contrast the foreground itself.
function Mix([int]$bg, [int]$fg) { [int][Math]::Floor(($bg * 3 + $fg) / 4) }
$blend = '#{0:X2}{1:X2}{2:X2}' -f (Mix 0x33 0xFF), (Mix 0x66 0xCC), (Mix 0x99 0x00)

# The color of the divider between the two splits, halfway down.
function DividerColor {
    $rects = foreach ($h in [GhosttyContrast.Win32]::VisibleChildren($window, 'GhosttySurface')) {
        $rect = New-Object GhosttyContrast.Win32+RECT
        [void][GhosttyContrast.Win32]::GetWindowRect($h, [ref]$rect)
        $rect
    }
    $left = $rects | Sort-Object l | Select-Object -First 1
    ScreenColor $left.r ([int](($left.t + $left.b) / 2))
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $process.Refresh() }
    $window = $process.MainWindowHandle
    if ($window -eq 0) { Fail 'no window' }
    $bar = [GhosttyContrast.Win32]::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null)
    if ($bar -eq [IntPtr]::Zero) { Fail 'no tab bar' }
    [void][GhosttyContrast.Win32]::SetForegroundWindow($window)

    [void](WaitFor { $script:last = BarColor; $last -eq $terminal } "the tab bar to be $terminal")
    Write-Host "Without high contrast, the tab bar is $last, from the terminal's background."

    # Split right from the window menu (its seventh command).
    $menu = [GhosttyContrast.Win32]::GetSystemMenu($window, $false)
    [void][GhosttyContrast.Win32]::SendMessageW($window, 0x0117, $menu, [IntPtr]0)   # WM_INITMENUPOPUP
    [void][GhosttyContrast.Win32]::SendMessageW($window, 0x0112, [IntPtr](7 -shl 4), [IntPtr]0)   # WM_SYSCOMMAND
    [void](WaitFor { [GhosttyContrast.Win32]::VisibleChildren($window, 'GhosttySurface').Count -eq 2 } 'a second split')
    [void](WaitFor { $script:last = DividerColor; $last -eq $blend } "the divider to be $blend")
    Write-Host "Without high contrast, the divider is $last, a blend of the terminal's colors."

    if (-not [GhosttyContrast.Win32]::SetHighContrast($true)) { Fail "couldn't turn high contrast on" }
    $expected = WaitFor { if ([GhosttyContrast.Win32]::HighContrast()) { SysColor 5 } } 'high contrast to be on'   # COLOR_WINDOW
    [void](WaitFor { $script:last = BarColor; $last -eq $expected } "the tab bar to be the theme's window color $expected")
    Write-Host "With high contrast, the tab bar is $last, the theme's window color."
    [void](WaitFor { $script:last = DividerColor; $last -eq '#FFCC00' } 'the divider to be the foreground #FFCC00')
    Write-Host "With high contrast, the divider is $last, the terminal's foreground."

    # The search bar too: Find… from the window menu (its eleventh command).
    [void][GhosttyContrast.Win32]::SendMessageW($window, 0x0117, $menu, [IntPtr]0)   # WM_INITMENUPOPUP
    [void][GhosttyContrast.Win32]::SendMessageW($window, 0x0112, [IntPtr](11 -shl 4), [IntPtr]0)   # WM_SYSCOMMAND
    $search = WaitFor { $h = [GhosttyContrast.Win32]::VisibleChild($window, 'GhosttySearchBar'); if ($h -ne [IntPtr]::Zero) { $h } } 'the search bar'
    # Its position is read again each time, in case it's still moving.
    [void](WaitFor {
            $rect = New-Object GhosttyContrast.Win32+RECT
            [void][GhosttyContrast.Win32]::GetWindowRect($search, [ref]$rect)
            $x = $rect.l + 2; $y = $rect.t + 2
            $script:last = "$(ScreenColor $x $y) at $($rect.l),$($rect.t)-$($rect.r),$($rect.b) where there's " +
                "$([GhosttyContrast.Win32]::WindowAt($x, $y)) (Ghostty is $($process.Id)); the middle is " +
                "$(ScreenColor (($rect.l + $rect.r) / 2) (($rect.t + $rect.b) / 2)) and the right end " +
                "$(ScreenColor ($rect.r - 3) (($rect.t + $rect.b) / 2))"
            $last -like "$expected *"
        } "the search bar to be the theme's window color $expected")
    Write-Host "With high contrast, the search bar is $last too."

    if (-not [GhosttyContrast.Win32]::SetHighContrast($false)) { Fail "couldn't turn high contrast off" }
    [void](WaitFor { $script:last = BarColor; $last -eq $terminal } "the tab bar to be $terminal again")
    Write-Host "With high contrast off again, the tab bar is $last."
    [void](WaitFor { $script:last = DividerColor; $last -eq $blend } "the divider to be $blend again")
    Write-Host "With high contrast off again, the divider is $last."
} catch {
    if (-not $script:reported) { Write-Host "::error title=high-contrast::$($_.Exception.Message)" }
    $script:reported = $true
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    [void][GhosttyContrast.Win32]::SetHighContrast($wasOn)
}
