# Checks the progress bar along the top of a terminal (ConEmu's OSC 9;4),
# as GTK and macOS have. The left of two splits reports progress while the
# right one has the focus (the taskbar button only shows the focused one's):
# 50% makes a bar half its width at its top, an unknown amount a piece a
# fifth of its width that slides across (but not while the terminal is
# hidden, by zooming the other split: then it waits in the middle), an
# error at 30% a bar 30% wide, and removing it hides it. With Windows'
# animation effects off the piece always waits in the middle; CI's
# runners have them off, so there the test checks that, then turns them
# on for the rest (and back off after). Elsewhere it leaves them be. Keys are posted to the terminals and windows
# are read with GetWindowRect, so it runs on a locked desktop.
#
#     ./progress.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyProgress -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
  public int size; public uint flags; public System.IntPtr active, focus, capture, menuOwner, moveSize, caret; public RECT caretRect; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint param, out bool value, uint winIni);
[DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] public static extern bool SetSystemParameter(uint action, uint param, System.IntPtr value, uint winIni);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
// The window with the keyboard focus on the thread of `window`.
public static System.IntPtr Focus(System.IntPtr window) {
  uint pid; uint thread = GetWindowThreadProcessId(window, out pid);
  var info = new GUITHREADINFO(); info.size = Marshal.SizeOf(info);
  return GetGUIThreadInfo(thread, ref info) ? info.focus : System.IntPtr.Zero;
}
'@
$W = [GhosttyProgress.Win32]
[void]$W::SetProcessDPIAware()

$dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-progress-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
$log = Join-Path $dir 'ghostty.log'
# The left terminal's shell: each report once the test says so.
Set-Content -Encoding utf8 (Join-Path $dir 'shell.ps1') @'
param([string]$Dir)
$e = [char]27; $b = [char]7
$reports = @('1;50', '3', '2;30', '0')
for ($n = 0; $n -lt $reports.Count; $n++) {
    while (-not (Test-Path "$Dir\go$n")) { Start-Sleep -Milliseconds 100 }
    [Console]::Out.Write("$e]9;4;$($reports[$n])$b")
}
Start-Sleep -Seconds 600
'@

$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--window-save-state=never',
    '--confirm-close-surface=false', '--window-width=100', '--window-height=30', '--command=cmd.exe',
    "`"--initial-command=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dir\shell.ps1 -Dir $dir`"",
    '--keybind=f5=new_split:right', '--keybind=f6=toggle_split_zoom'

function Fail([string]$message) {
    Write-Host "::error title=progress::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 30 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 50
    }
    Fail "timed out waiting for $what"
}

function Box($h) { $r = New-Object GhosttyProgress.Win32+RECT; [void]$W::GetWindowRect($h, [ref]$r); $r }
# The left terminal's progress bar, relative to the terminal, or null
# while it's hidden.
function Bar {
    $bar = $W::FindWindowExW($left, [IntPtr]::Zero, 'GhosttyProgressBar', [NullString]::Value)
    if ($bar -eq [IntPtr]::Zero -or -not $W::IsWindowVisible($bar)) { return $null }
    $b = Box $bar; $s = Box $left
    [pscustomobject]@{ Left = $b.l - $s.l; Top = $b.t - $s.t; Width = $b.r - $b.l; Height = $b.b - $b.t }
}
# Where its bar is even while hidden.
function Placed {
    $bar = $W::FindWindowExW($left, [IntPtr]::Zero, 'GhosttyProgressBar', [NullString]::Value)
    $b = Box $bar; $s = Box $left
    [pscustomobject]@{ Left = $b.l - $s.l; Top = $b.t - $s.t; Width = $b.r - $b.l; Height = $b.b - $b.t }
}
function Say($bar) { if ($bar) { "$($bar.Left),$($bar.Top) $($bar.Width)x$($bar.Height)" } else { 'hidden' } }
function Go([int]$n) { Set-Content (Join-Path $dir "go$n") 'go' }

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $script:left = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the terminal'
    Start-Sleep -Seconds 1
    $W::Key($left, 0x74, 0x3F)   # F5: new_split:right
    $right = WaitFor {
        $h = [IntPtr]::Zero
        while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { if ($h -ne $left) { return $h } }
    } 'the split'
    [void](WaitFor { $W::Focus($window) -eq $right } 'the new split to have the focus')
    $s = Box $left
    $width = $s.r - $s.l
    Write-Host "The left terminal is $width px wide; the right one has the focus."

    # 50%: half the width, at the top, a few pixels high.
    Go 0
    $bar = WaitFor { $b = Bar; if ($b -and [Math]::Abs($b.Width - $width / 2) -le 2) { $b } } "a bar half of $width px wide"
    if ($bar.Left -ne 0 -or $bar.Top -ne 0 -or $bar.Height -lt 1 -or $bar.Height -gt 12) { Fail "the 50% bar is at $(Say $bar), not along the top" }
    Write-Host "50%: the bar is $(Say $bar)."

    # Unknown: a piece a fifth of the width (less at the edges) that moves,
    # or with animation effects off waits in the middle.
    $animated = $true
    [void]$W::SystemParametersInfoW(0x1042, 0, [ref]$animated, 0)   # SPI_GETCLIENTAREAANIMATION
    $piece = [Math]::Floor($width / 5)
    $middle = [Math]::Floor(($width + $piece) / 2) - $piece
    function Still([string]$what) {
        $still = WaitFor { $b = Placed; if ([Math]::Abs($b.Left - $middle) -le 1 -and $b.Width -eq $piece) { $b } } "$what to wait in the middle ($middle)"
        Start-Sleep -Milliseconds 500
        if ((Placed).Left -ne $still.Left) { Fail "$what moved from $(Say $still) to $(Say (Placed))" }
        $still
    }
    Go 1
    if (-not $animated) {
        $still = Still 'the piece (animation effects are off)'
        Write-Host "Unknown, with animation effects off: the piece waits at $(Say $still)."
        if ($env:CI -eq 'true') {
            # For this session only (not saved), until the test ends.
            [void]$W::SetSystemParameter(0x1043, 0, [IntPtr]1, 0)   # SPI_SETCLIENTAREAANIMATION
            $script:restoreAnimations = $true
            $animated = $true
            Write-Host 'Turned animation effects on for the rest.'
        } else {
            Write-Host "::notice title=progress::Windows' animation effects are off here, so the piece's sliding isn't checked."
        }
    } else {
        $first = WaitFor { $b = Bar; if ($b -and $b.Width -le $piece + 1) { $b } } 'the sliding piece'
        $moved = WaitFor { $b = Bar; if ($b -and $b.Left -ne $first.Left) { $b } } "the piece to move from $(Say $first)"
        Write-Host "Unknown: the piece went from $(Say $first) to $(Say $moved)."
    }
    if ($animated) {
        # Hidden (the right split zoomed), it waits in the middle: nothing
        # moves where no one can see it. Shown again, it moves again.
        $W::Key($right, 0x75, 0x40)   # F6: toggle_split_zoom
        [void](WaitFor { -not $W::IsWindowVisible($left) } 'the left terminal to be hidden by the zoom')
        $still = Still 'the hidden piece'
        Write-Host "Hidden: the piece waits at $(Say $still)."
        $W::Key($right, 0x75, 0x40)   # F6: toggle_split_zoom
        [void](WaitFor { $b = Bar; if ($b -and $b.Left -ne $still.Left) { $b } } 'the piece to move again once shown')
        Write-Host 'Shown again: the piece moves.'
    }

    # An error at 30%.
    Go 2
    $bar = WaitFor { $b = Bar; if ($b -and $b.Left -eq 0 -and [Math]::Abs($b.Width - $width * 0.3) -le 2) { $b } } "a bar 30% of $width px wide"
    Write-Host "Error at 30%: the bar is $(Say $bar)."

    # Removed.
    Go 3
    [void](WaitFor { -not (Bar) } 'the bar to go')
    Write-Host 'Removed: the bar is hidden.'
} finally {
    if ($script:restoreAnimations) { [void]$W::SetSystemParameter(0x1043, 0, [IntPtr]0, 0) }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
