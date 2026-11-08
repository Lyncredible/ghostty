# Checks that a translucent terminal stays translucent with a split and the
# scrollbar: it opens an opaque red Ghostty window, then a half transparent
# black one on top of it, splits it, prints enough lines to scroll, and
# scrolls with the wheel. Both panes must show the red window through them,
# and the scrollbar's thumb must be drawn over the translucent background.
# Then the search bar and the command palette must be drawn opaque over it.
# With -Blur (acrylic) it only reports the colors: Windows draws acrylic as
# a solid color without a GPU, as on GitHub's runners. It only sends
# messages to Ghostty's windows, but it reads the screen, so the desktop
# must be unlocked.
#
#     ./translucent.ps1 -Exe zig-out/bin/ghostty.exe [-Blur]

param(
    [Parameter(Mandatory)] [string]$Exe,
    [switch]$Blur,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$title = if ($Blur) { 'translucent (blur)' } else { 'translucent' }
function Notice([string]$message) { Write-Host "::notice title=$title::$message" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing

# Reading the screen fails on a locked desktop ("The handle is invalid").
# Locally that only means the test can't run; in CI it's a failure.
if ($env:CI -ne 'true') {
    $probe = New-Object System.Drawing.Bitmap 1, 1
    $probeGraphics = [System.Drawing.Graphics]::FromImage($probe)
    try {
        $probeGraphics.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size 1, 1))
    } catch {
        Notice "the screen can't be read (a locked desktop?), so this was skipped: $($_.Exception.InnerException.Message)"
        exit 0
    } finally {
        $probeGraphics.Dispose(); $probe.Dispose()
    }
}

Add-Type -Namespace GhosttyTranslucent -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetMenuItemCount(System.IntPtr m);
[DllImport("user32.dll")] public static extern uint GetMenuItemID(System.IntPtr m, int pos);
[DllImport("user32.dll")] public static extern System.IntPtr GetSubMenu(System.IntPtr m, int pos);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(System.IntPtr m, uint item, System.Text.StringBuilder s, int n, uint flags);
// The command ID of the menu item with a label (without its &, its
// shortcut and a trailing ellipsis), in the menu or its submenus, or 0.
public static uint MenuCommand(System.IntPtr menu, string label) {
  int n = GetMenuItemCount(menu);
  for (int i = 0; i < n; i++) {
    var sub = GetSubMenu(menu, i);
    if (sub != System.IntPtr.Zero) { uint found = MenuCommand(sub, label); if (found != 0) return found; continue; }
    var s = new System.Text.StringBuilder(256);
    GetMenuStringW(menu, (uint)i, s, 256, 0x400);   // MF_BYPOSITION
    string text = s.ToString().Split('\t')[0].Replace("&", "").TrimEnd('\u2026');
    if (text == label) return GetMenuItemID(menu, i);
  }
  return 0;
}
[DllImport("user32.dll")] public static extern System.IntPtr GetSystemMenu(System.IntPtr h, bool revert);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr h, EnumProc f, System.IntPtr l);
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
'@
$W = [GhosttyTranslucent.Win32]
[void]$W::SetProcessDPIAware()
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

$common = '--window-save-state=never', '--window-position-x=100', '--window-position-y=100',
    '--window-width=100', '--window-height=30', '--scrollbar=system'
$back = Start-Process -FilePath $Exe -PassThru -ArgumentList ($common + '--background=#c00000', '--command=cmd.exe')
$front = $null

function Surfaces($process) {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $process.Id)
    foreach ($window in $AE::RootElement.FindAll($Scope::Children, $condition)) {
        if ($window.Current.ClassName -ne 'GhosttyWindow') { continue }
        $surfaces = @($window.FindAll($Scope::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'GhosttySurface'))))
        $texts = @($surfaces | ForEach-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value })
        return @{
            Window = [IntPtr]$window.Current.NativeWindowHandle
            Handles = @($surfaces | ForEach-Object { [IntPtr]$_.Current.NativeWindowHandle })
            Texts = $texts
        }
    }
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($p in @($back, $front)) { if ($p -and $p.HasExited) { throw "Ghostty exited while waiting for $what" } }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what"
}

function Rect($handle) {
    $rect = New-Object GhosttyTranslucent.Win32+RECT
    [void]$W::GetWindowRect($handle, [ref]$rect)
    $rect
}

# A column of screen pixels, as colors.
function Column([int]$x, [int]$top, [int]$bottom) {
    $bitmap = New-Object System.Drawing.Bitmap 1, ($bottom - $top)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($x, $top, 0, 0, (New-Object System.Drawing.Size 1, ($bottom - $top)))
    $pixels = @(0..($bottom - $top - 1) | ForEach-Object { $bitmap.GetPixel(0, $_) })
    $graphics.Dispose(); $bitmap.Dispose()
    $pixels
}

# The red window through black at 50%: red, but darker than the red itself.
function IsShowingRed($pixel) { $pixel.R -gt 40 -and $pixel.R -lt 180 -and $pixel.G -lt 40 -and $pixel.B -lt 40 }
function Describe($pixel) { "rgb($($pixel.R), $($pixel.G), $($pixel.B))" }

try {
    [void](WaitFor { $s = Surfaces $back; $s -and ($s.Texts -match '>') } 'the red window')

    $frontArgs = $common + '--background=#000000', '--background-opacity=0.5', '--foreground=#ffffff',
        '"--command=cmd.exe /k for /l %i in (1,1,300) do @echo %i"'
    if ($Blur) { $frontArgs += '--background-blur=true' }
    $front = Start-Process -FilePath $Exe -PassThru -ArgumentList $frontArgs
    $s = WaitFor { $s = Surfaces $front; if ($s -and ($s.Texts -match '300')) { $s } } 'the translucent window''s output'

    # Split Right from the window menu, found by label.
    $menu = $W::GetSystemMenu($s.Window, $false)
    [void]$W::SendMessageW($s.Window, 0x0117, $menu, [IntPtr]0)                # WM_INITMENUPOPUP
    [void]$W::SendMessageW($s.Window, 0x0112, [IntPtr]$W::MenuCommand($menu, 'Split Right'), [IntPtr]0)   # WM_SYSCOMMAND
    $s = WaitFor { $s = Surfaces $front; if ($s.Handles.Count -eq 2 -and ($s.Texts -match '>').Count -eq 2) { $s } } 'the split'
    [void]$W::SetForegroundWindow($s.Window)
    Start-Sleep -Milliseconds 500

    # Both panes, right of their text and below the middle, show red.
    foreach ($handle in $s.Handles) {
        $r = Rect $handle
        $x = $r.r - [int](($r.r - $r.l) / 4)
        $pixel = (Column $x ([int](($r.t + $r.b) / 2)) ([int](($r.t + $r.b) / 2) + 1))[0]
        if (-not $Blur -and -not (IsShowingRed $pixel)) { throw "a pane at x=$x doesn't show the red window through it: $(Describe $pixel)" }
        Notice "pane at x=$($r.l)..$($r.r): $(Describe $pixel)"
    }

    # Scroll the left pane up, which shows its scrollbar along its right edge.
    $left = $s.Handles | Sort-Object { (Rect $_).l } | Select-Object -First 1
    $r = Rect $left
    $point = [IntPtr]((([int](($r.t + $r.b) / 2)) -shl 16) -bor ([int](($r.l + $r.r) / 2)))
    foreach ($i in 1..5) {
        [void]$W::PostMessageW($left, 0x020A, [IntPtr](120 -shl 16), $point)   # WM_MOUSEWHEEL, up
        Start-Sleep -Milliseconds 50
    }
    $found = WaitFor {
        foreach ($x in ($r.r - 12)..($r.r - 2)) {
            $column = Column $x ($r.t + 2) ($r.b - 2)
            $thumb = @($column | Where-Object { $_.R -gt 150 -and $_.G -gt 150 -and $_.B -gt 150 })
            $track = @($column | Where-Object { $Blur -or (IsShowingRed $_) })
            if ($thumb.Count -gt 10 -and $track.Count -gt 10) { return "x=${x}: $($thumb.Count) thumb pixels, $($track.Count) showing red" }
        }
    } 'the scrollbar over the translucent background'
    Notice "scrollbar at $found"

    # Overlays, from the window menu (found by label): Find and Command
    # Palette. Each must hide the red behind it.
    foreach ($overlay in @(@{ Class = 'GhosttySearchBar'; Label = 'Find' }, @{ Class = 'GhosttyCommandPalette'; Label = 'Command Palette' })) {
        [void]$W::SendMessageW($s.Window, 0x0117, $menu, [IntPtr]0)
        [void]$W::SendMessageW($s.Window, 0x0112, [IntPtr]$W::MenuCommand($menu, $overlay.Label), [IntPtr]0)
        $handle = WaitFor { $h = $W::VisibleChild($s.Window, $overlay.Class); if ($h -ne [IntPtr]::Zero) { $h } } $overlay.Class
        Start-Sleep -Milliseconds 500
        $o = Rect $handle
        $row = [int](($o.t + $o.b) / 2)
        $pixels = foreach ($x in ($o.l + 2)..($o.r - 3)) { (Column $x $row ($row + 1))[0] }
        $red = @($pixels | Where-Object { $_.R -gt 40 -and $_.R -gt $_.G + 30 -and $_.R -gt $_.B + 30 })
        Notice "$($overlay.Class) at x=$($o.l)..$($o.r): $($red.Count) of $($pixels.Count) pixels show red"
        if ($red.Count -gt $pixels.Count / 10) { throw "$($overlay.Class) is translucent: $($red.Count) of $($pixels.Count) pixels show the red window" }
    }
    if ($Blur) { Notice "display adapters: $((Get-CimInstance Win32_VideoController).Name -join ', ')" }
} catch {
    Write-Host "::error title=$title::$($_.Exception.Message)"
    throw
} finally {
    foreach ($p in @($front, $back)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
}
