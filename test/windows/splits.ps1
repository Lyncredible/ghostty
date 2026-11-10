# Checks the split actions from keybinds: new_split:right makes two
# terminals side by side, goto_split moves the keyboard focus between
# them, resize_split moves the divider, equalize_splits makes them even
# again, and toggle_split_zoom gives the focused one the whole tab and
# back. Keys are posted to the terminals and the focus is read from
# Ghostty's thread (GetGUIThreadInfo), so it runs on a locked desktop.
#
#     ./splits.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttySplits -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
  public int size; public uint flags; public System.IntPtr active, focus, capture, menuOwner, moveSize, caret; public RECT caretRect; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
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
$W = [GhosttySplits.Win32]
[void]$W::SetProcessDPIAware()

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-splits-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--window-width=100', '--window-height=30',
    '--keybind=f5=new_split:right', '--keybind=f6=goto_split:left', '--keybind=f7=goto_split:right',
    '--keybind=f8=resize_split:right,200', '--keybind=f9=equalize_splits', '--keybind=f10=toggle_split_zoom'

function Fail([string]$message) {
    Write-Host "::error title=splits::$message"
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
        Start-Sleep -Milliseconds 100
    }
    Fail "timed out waiting for $what"
}

function Surfaces {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { $list += $h }
    $list
}
function Box($h) { $r = New-Object GhosttySplits.Win32+RECT; [void]$W::GetWindowRect($h, [ref]$r); $r }
function Width($h) { $r = Box $h; $r.r - $r.l }
function Describe($h) { $r = Box $h; "$($r.l - $origin.l),$($r.t - $origin.t) $($r.r - $r.l)x$($r.b - $r.t)$(if (-not $W::IsWindowVisible($h)) { ' hidden' })" }

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $left = WaitFor { @(Surfaces)[0] } 'the terminal'
    Start-Sleep -Seconds 1
    $origin = Box $left
    $whole = Describe $left

    # A split to the right: two terminals side by side, the new one
    # focused.
    $W::Key($left, 0x74, 0x3F)   # F5: new_split:right
    $right = WaitFor { @(Surfaces | Where-Object { $_ -ne $left })[0] } 'the split'
    [void](WaitFor { $W::Focus($window) -eq $right } 'the new split to have the focus')
    $l = Box $left; $r = Box $right
    if (-not ($l.r -le $r.l -and $l.t -eq $r.t -and $l.b -eq $r.b)) { Fail "the split isn't side by side: $(Describe $left) and $(Describe $right)" }
    $even = [Math]::Abs((Width $left) - (Width $right))
    if ($even -gt 2) { Fail "the new split isn't even: $(Describe $left) and $(Describe $right)" }
    Write-Host "new_split:right: $(Describe $left) and $(Describe $right), the new one focused."

    # goto_split moves the focus, and each key goes to the focused one.
    $W::Key($right, 0x75, 0x40)   # F6: goto_split:left
    [void](WaitFor { $W::Focus($window) -eq $left } 'goto_split:left to focus the left terminal')
    $W::Key($left, 0x76, 0x41)    # F7: goto_split:right
    [void](WaitFor { $W::Focus($window) -eq $right } 'goto_split:right to focus the right terminal')
    Write-Host 'goto_split:left and goto_split:right moved the focus.'

    # resize_split:right,200 from the left one moves the divider 200
    # pixels right (a ratio of the tab, so within a pixel or two).
    $before = Width $left
    $W::Key($left, 0x77, 0x42)    # F8: resize_split:right,200
    [void](WaitFor { [Math]::Abs((Width $left) - $before - 200) -le 3 } 'the divider to move 200 pixels right')
    $grown = Width $left
    Write-Host "resize_split:right,200: the left terminal went from $before to $grown px wide."

    # equalize_splits evens them out again.
    $W::Key($left, 0x78, 0x43)    # F9: equalize_splits
    [void](WaitFor { [Math]::Abs((Width $left) - (Width $right)) -le 2 } 'the splits to be even again')
    Write-Host "equalize_splits: $(Describe $left) and $(Describe $right)."

    # toggle_split_zoom gives the left one the whole tab, then back.
    $split = "$(Describe $left) | $(Describe $right)"
    $W::Key($left, 0x79, 0x44)    # F10: toggle_split_zoom
    [void](WaitFor { (Describe $left) -eq $whole -and -not $W::IsWindowVisible($right) } "the left terminal to fill the tab ($whole)")
    Write-Host "toggle_split_zoom: the left terminal fills the tab ($(Describe $left)), the right one is hidden."
    $W::Key($left, 0x79, 0x44)
    [void](WaitFor { "$(Describe $left) | $(Describe $right)" -eq $split } "the splits back ($split)")
    Write-Host 'toggle_split_zoom again put both back.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
