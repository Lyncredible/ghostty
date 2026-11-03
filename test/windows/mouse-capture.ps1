# Checks that a drag selection ends when another window takes the mouse
# capture with the button still down (Alt+Tab during a drag, for example).
# The core used to keep dragging, so later moves still changed the
# selection. It only posts messages to Ghostty's window and reads the
# selection through UI Automation.
#
#     ./mouse-capture.ps1 -Zip zig-out/dist/ghostty-windows-unofficial.zip

param(
    [string]$Exe,
    [string]$Zip
)

$ErrorActionPreference = 'Stop'

if ($Zip) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-mouse-capture-$PID"
    Expand-Archive -Force $Zip $dir
    $Exe = (Get-ChildItem -Recurse $dir -Filter ghostty.exe | Select-Object -First 1).FullName
}
if (-not $Exe) { throw "give -Exe or -Zip" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyMouseCapture -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
'@
$W = [GhosttyMouseCapture.Win32]

$p = Start-Process $Exe -PassThru -ArgumentList '--window-save-state=never',
    '"--command=cmd.exe /k for /l %i in (1,1,30) do @echo aaaa bbbb cccc dddd eeee ffff gggg hhhh %i"'
try {
    $window = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(30)
    while ($window -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $h = [IntPtr]::Zero
        while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, 'GhosttyWindow', [NullString]::Value)) -ne [IntPtr]::Zero) {
            $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
            if ($id -eq $p.Id) { $window = $h; break }
        }
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

    $text = [System.Windows.Automation.AutomationElement]::FromHandle($surface).GetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern)
    function Selection { $r = $text.GetSelection(); if ($r.Count) { $r[0].GetText(-1) } else { '' } }
    function Point($x, $y) { [IntPtr](($y -shl 16) -bor $x) }

    [void]$W::PostMessageW($surface, 0x0201, [IntPtr]1, (Point 5 30))     # WM_LBUTTONDOWN
    [void]$W::PostMessageW($surface, 0x0200, [IntPtr]1, (Point 120 30))   # WM_MOUSEMOVE, button down
    Start-Sleep -Milliseconds 500
    $dragged = Selection
    if (-not $dragged) { throw "dragging selected nothing" }

    # WM_CANCELMODE makes the default window procedure release the capture,
    # as when another window takes it. The button's release never comes.
    [void]$W::PostMessageW($surface, 0x001F, [IntPtr]0, [IntPtr]0)
    Start-Sleep -Milliseconds 300
    [void]$W::PostMessageW($surface, 0x0200, [IntPtr]0, (Point 200 60))
    [void]$W::PostMessageW($surface, 0x0200, [IntPtr]0, (Point 300 100))
    Start-Sleep -Milliseconds 500
    $after = Selection

    "dragged: '$dragged'"
    "after the capture was lost and two moves: '$after'"
    if ($after -ne $dragged) { throw "the selection changed after the capture was lost" }
    "ok"
} finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
