# Checks that right-clicking in a terminal opens its context menu. Releasing
# the mouse capture on the button's release sends WM_CAPTURECHANGED, and
# handling that once canceled the pending menu, so it never showed. It only
# posts messages to Ghostty's window and looks for the process's popup menu.
#
#     ./context-menu.ps1 -Zip zig-out/dist/ghostty-windows-unofficial.zip
#     ./context-menu.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [string]$Exe,
    [string]$Zip
)

$ErrorActionPreference = 'Stop'

if ($Zip) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-context-menu-$PID"
    Expand-Archive -Force $Zip $dir
    $Exe = (Get-ChildItem -Recurse $dir -Filter ghostty.exe | Select-Object -First 1).FullName
}
if (-not $Exe) { throw "give -Exe or -Zip" }

Add-Type -Namespace GhosttyContextMenu -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
'@
$W = [GhosttyContextMenu.Win32]

# The process's visible top-level window of this class.
function TopLevel([string]$class, [int]$processId) {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, $class, [NullString]::Value)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $processId -and $W::IsWindowVisible($h)) { return $h }
    }
    [IntPtr]::Zero
}

$p = Start-Process $Exe -PassThru -ArgumentList '--window-save-state=never', '--command=cmd.exe'
try {
    $window = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(30)
    while ($window -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $window = TopLevel 'GhosttyWindow' $p.Id
    }
    if ($window -eq [IntPtr]::Zero) { throw "no Ghostty window" }
    Start-Sleep 3

    # The surface is a descendant of the window.
    $surface = [IntPtr]::Zero
    $queue = [Collections.Generic.Queue[IntPtr]]::new(); $queue.Enqueue($window)
    while ($queue.Count -and $surface -eq [IntPtr]::Zero) {
        $parent = $queue.Dequeue()
        $surface = $W::FindWindowExW($parent, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value)
        $child = [IntPtr]::Zero
        while (($child = $W::FindWindowExW($parent, $child, [NullString]::Value, [NullString]::Value)) -ne [IntPtr]::Zero) { $queue.Enqueue($child) }
    }
    if ($surface -eq [IntPtr]::Zero) { throw "no Ghostty surface" }
    if ((TopLevel '#32768' $p.Id) -ne [IntPtr]::Zero) { throw "a menu was open before the click" }

    function Point($x, $y) { [IntPtr](($y -shl 16) -bor $x) }
    [void]$W::PostMessageW($surface, 0x0204, [IntPtr]2, (Point 40 40))   # WM_RBUTTONDOWN, MK_RBUTTON
    [void]$W::PostMessageW($surface, 0x0205, [IntPtr]0, (Point 40 40))   # WM_RBUTTONUP

    $menu = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(5)
    while ($menu -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $menu = TopLevel '#32768' $p.Id
    }
    if ($menu -eq [IntPtr]::Zero) { throw "right-clicking the terminal opened no menu" }
    "menu opened: 0x{0:x}" -f $menu.ToInt64()
    "ok"
} finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
