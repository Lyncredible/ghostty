# Checks that a translucent terminal stays translucent with a split and the
# scrollbar: it opens an opaque red Ghostty window, then a half transparent
# black one on top of it, splits it, prints enough lines to scroll, and
# scrolls with the wheel. Both panes must show the red window through them,
# and the scrollbar's thumb must be drawn over the translucent background.
# It only sends messages to Ghostty's windows, but it reads the screen, so
# the desktop must be unlocked.
#
#     ./translucent.ps1 -Exe zig-out/bin/ghostty.exe [-Blur]

param(
    [Parameter(Mandatory)] [string]$Exe,
    [switch]$Blur,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$title = if ($Blur) { 'translucent (blur)' } else { 'translucent' }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -Namespace GhosttyTranslucent -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern System.IntPtr GetSystemMenu(System.IntPtr h, bool revert);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
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

    # Split > Split Right from the window menu (the seventh command).
    $menu = $W::GetSystemMenu($s.Window, $false)
    [void]$W::SendMessageW($s.Window, 0x0117, $menu, [IntPtr]0)                # WM_INITMENUPOPUP
    [void]$W::SendMessageW($s.Window, 0x0112, [IntPtr](7 -shl 4), [IntPtr]0)   # WM_SYSCOMMAND
    $s = WaitFor { $s = Surfaces $front; if ($s.Handles.Count -eq 2 -and ($s.Texts -match '>').Count -eq 2) { $s } } 'the split'
    [void]$W::SetForegroundWindow($s.Window)
    Start-Sleep -Milliseconds 500

    # Both panes, right of their text and below the middle, show red.
    foreach ($handle in $s.Handles) {
        $r = Rect $handle
        $x = $r.r - [int](($r.r - $r.l) / 4)
        $pixel = (Column $x ([int](($r.t + $r.b) / 2)) ([int](($r.t + $r.b) / 2) + 1))[0]
        if (-not (IsShowingRed $pixel)) { throw "a pane at x=$x doesn't show the red window through it: $(Describe $pixel)" }
        Write-Host "Pane at x=$($r.l)..$($r.r): $(Describe $pixel)."
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
            $track = @($column | Where-Object { IsShowingRed $_ })
            if ($thumb.Count -gt 10 -and $track.Count -gt 10) { return "x=${x}: $($thumb.Count) thumb pixels, $($track.Count) showing red" }
        }
    } 'the scrollbar over the translucent background'
    Write-Host "Scrollbar: $found."
} catch {
    Write-Host "::error title=$title::$($_.Exception.Message)"
    throw
} finally {
    foreach ($p in @($front, $back)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
}
