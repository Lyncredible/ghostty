# Checks the tabs in the title bar: with two tabs the client area covers the
# caption (no title bar row above the tabs), the tab bar's empty space is
# the caption (HTCAPTION), its top edge resizes (HTTOP), its maximize button
# is HTMAXBUTTON (for Windows 11's snap layouts) and the tab bar passes all
# of them to the window (HTTRANSPARENT), while tabs stay the tab bar's. The
# minimize and maximize buttons work, and with one tab again the system's
# title bar comes back. It sends hit tests and posts clicks to Ghostty's
# windows, so it runs on a locked desktop.
#
#     ./titlebar-tabs.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=titlebar-tabs::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyTitleBarTabs -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
// The hit test result for a point on the screen, from a window.
public static int Hit(System.IntPtr h, int x, int y) {
  return (int)(long)SendMessageW(h, 0x0084, System.IntPtr.Zero, (System.IntPtr)((y << 16) | (x & 0xFFFF)));   // WM_NCHITTEST
}
// A left click at a point in a window's client area.
public static void Click(System.IntPtr h, int x, int y) {
  var l = (System.IntPtr)((y << 16) | (x & 0xFFFF));
  PostMessageW(h, 0x0201, (System.IntPtr)1, l);   // WM_LBUTTONDOWN
  PostMessageW(h, 0x0202, System.IntPtr.Zero, l); // WM_LBUTTONUP
}
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyTitleBarTabs.Win32]
[void]$W::SetThreadDpiAwarenessContext([IntPtr]-4)   # per monitor v2, like Ghostty

$HTTRANSPARENT = -1; $HTCLIENT = 1; $HTCAPTION = 2; $HTMAXBUTTON = 9; $HTTOP = 12

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-titlebar-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--confirm-close-surface=false', '--window-width=100', '--window-height=25',
    '--keybind=f5=new_tab', '--keybind=f7=close_tab:this'

function Fail([string]$message) {
    Write-Host "::error title=titlebar-tabs::$message"
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
    Fail "timed out waiting for $what ($script:note)"
}

# The gap between the top of the window and the top of its client area.
function CaptionGap {
    $wr = New-Object GhosttyTitleBarTabs.Win32+RECT; [void]$W::GetWindowRect($window, [ref]$wr)
    $pt = New-Object GhosttyTitleBarTabs.Win32+POINT; [void]$W::ClientToScreen($window, [ref]$pt)
    $script:note = "the client area starts $($pt.y - $wr.t) px below the window's top"
    $pt.y - $wr.t
}

function Visible([IntPtr]$h) { $W::IsWindowVisible($h) }
function Shown { $h = [IntPtr]::Zero; while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', $null)) -ne [IntPtr]::Zero) { if (Visible $h) { return $h } } }

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    [void](WaitFor { Shown } 'the terminal')
    $single = CaptionGap
    if ($single -le 10) { Fail "with one tab the window has no title bar ($note)" }
    Write-Host "One tab: the system's title bar ($note)."

    $W::Key((Shown), 0x74, 0x3F)   # F5: new_tab
    $bar = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', $null); if ($h -ne [IntPtr]::Zero -and (Visible $h)) { $h } } 'the tab bar'
    [void](WaitFor { (CaptionGap) -le 0 } 'the tabs to take the title bar')
    Write-Host "Two tabs: the tabs are in the title bar ($note)."

    $br = New-Object GhosttyTitleBarTabs.Win32+RECT; [void]$W::GetWindowRect($bar, [ref]$br)
    $h = $br.b - $br.t
    $cy = $br.t + [int]($h / 2)
    $button = [int]($h * 46 / 32)   # caption buttons are 46 by 32
    $points = @(
        @{ What = 'empty space'; X = $br.r - 3 * $button - 10; Y = $cy; Bar = $HTTRANSPARENT; Window = $HTCAPTION },
        @{ What = 'the maximize button'; X = $br.r - [int](1.5 * $button); Y = $cy; Bar = $HTTRANSPARENT; Window = $HTMAXBUTTON },
        @{ What = 'the top edge'; X = $br.r - 3 * $button - 10; Y = $br.t + 1; Bar = $HTTRANSPARENT; Window = $HTTOP },
        @{ What = 'the minimize button'; X = $br.r - [int](2.5 * $button); Y = $cy; Bar = $HTCLIENT },
        @{ What = 'the close button'; X = $br.r - [int](0.5 * $button); Y = $cy; Bar = $HTCLIENT },
        @{ What = 'the first tab'; X = $br.l + 40; Y = $cy; Bar = $HTCLIENT }
    )
    foreach ($p in $points) {
        $got = $W::Hit($bar, $p.X, $p.Y)
        if ($got -ne $p.Bar) { Fail "the tab bar's hit test for $($p.What) at $($p.X),$($p.Y) is $got, not $($p.Bar)" }
        if ($p.Window) {
            $got = $W::Hit($window, $p.X, $p.Y)
            if ($got -ne $p.Window) { Fail "the window's hit test for $($p.What) at $($p.X),$($p.Y) is $got, not $($p.Window)" }
        }
    }
    Write-Host 'Hit tests: empty space is the caption, the top edge resizes, maximize is HTMAXBUTTON, and the tabs and other buttons are the tab bar''s.'

    # Minimize, then restore; maximize with a click on the maximize button
    # (WM_NCLBUTTONUP with HTMAXBUTTON, as Windows sends it).
    $W::Click($bar, $br.r - $br.l - [int](2.5 * $button), [int]($h / 2))
    [void](WaitFor { $script:note = 'not minimized'; $W::IsIconic($window) } 'the minimize button to minimize')
    [void]$W::ShowWindow($window, 9)   # SW_RESTORE
    [void](WaitFor { $script:note = 'still minimized'; -not $W::IsIconic($window) } 'the window to restore')
    $lp = [IntPtr](($cy -shl 16) -bor (($br.r - [int](1.5 * $button)) -band 0xFFFF))
    [void]$W::PostMessageW($window, 0x00A2, [IntPtr]$HTMAXBUTTON, $lp)   # WM_NCLBUTTONUP
    [void](WaitFor { $script:note = 'not maximized'; $W::IsZoomed($window) } 'the maximize button to maximize')
    Write-Host 'The minimize and maximize buttons work.'
    [void]$W::ShowWindow($window, 9)

    # One tab again: the system's title bar comes back.
    $W::Key((Shown), 0x76, 0x41)   # F7: close_tab:this
    [void](WaitFor { (CaptionGap) -eq $single } "the system's title bar to come back")
    Write-Host "One tab again: the system's title bar is back ($note)."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
