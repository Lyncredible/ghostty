# Checks a minimized window while output floods in: its terminal keeps
# its size (laying out the minimized window's empty client area once
# shrank the terminal to a tiny grid), nothing is drawn, and drawing
# resumes when it's restored. Frames are counted with the DXGI ETW
# provider. It only posts messages to Ghostty's window.
#
#     ./minimize.ps1 -Zip zig-out/dist/ghostty-windows-unofficial.zip

param(
    [string]$Exe,
    [string]$Zip,
    [int]$Seconds = 4
)

$ErrorActionPreference = 'Stop'

if ($Zip) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-minimize-$PID"
    Expand-Archive -Force $Zip $dir
    $Exe = (Get-ChildItem -Recurse $dir -Filter ghostty.exe | Select-Object -First 1).FullName
}
if (-not $Exe) { throw "give -Exe or -Zip" }

Add-Type -Namespace GhosttyMinimize -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
'@
$W = [GhosttyMinimize.Win32]

$session = "ghostty-minimize-$PID"
$etl = Join-Path ([IO.Path]::GetTempPath()) "$session.etl"
$tracing = $false
$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--window-save-state=never',
    '"--command=cmd.exe /k for /l %i in (1,1,999999999) do @echo %i"'

function Window {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, 'GhosttyWindow', [NullString]::Value)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $process.Id) { return $h }
    }
}

function Size($h) {
    $r = New-Object GhosttyMinimize.Win32+RECT
    [void]$W::GetClientRect($h, [ref]$r)
    "$($r.r - $r.l)x$($r.b - $r.t)"
}

# Frames Ghostty presents in $Seconds (event 42 starts IDXGISwapChain::Present).
function Frames {
    logman start $session -p Microsoft-Windows-DXGI 0xFFFFFFFF 5 -o $etl -ets | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "logman couldn't start the trace" }
    $script:tracing = $true
    Start-Sleep $Seconds
    logman stop $session -ets | Out-Null
    $script:tracing = $false
    tracerpt $etl -o "$etl.xml" -of XML -y | Out-Null
    [xml]$xml = Get-Content "$etl.xml"
    @($xml.Events.Event | Where-Object {
        $_.System.EventID -eq '42' -and $_.System.Execution.ProcessID -eq "$($process.Id)"
    }).Count
}

try {
    $deadline = (Get-Date).AddSeconds(60)
    while (-not ($h = Window)) {
        if ((Get-Date) -gt $deadline) { throw "timed out waiting for the window" }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep 3
    $surface = $W::FindWindowExW($h, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value)
    $before = Size $surface

    [void]$W::PostMessageW($h, 0x0112, [IntPtr]0xF020, [IntPtr]0)   # WM_SYSCOMMAND, SC_MINIMIZE
    Start-Sleep 1
    if (-not $W::IsIconic($h)) { throw "the window didn't minimize" }
    $minimized = Size $surface
    $hidden = Frames

    [void]$W::PostMessageW($h, 0x0112, [IntPtr]0xF120, [IntPtr]0)   # SC_RESTORE
    Start-Sleep 1
    $shown = Frames

    $summary = "terminal $before, minimized $minimized; frames: $hidden minimized, $shown restored in $Seconds s each"
    if ($process.HasExited) { throw "Ghostty exited: $summary" }
    if ($minimized -ne $before) { throw "minimizing resized the terminal: $summary" }
    if ($hidden -gt 2) { throw "Ghostty drew while minimized: $summary" }
    if ($shown -lt 10) { throw "Ghostty didn't draw after restoring: $summary" }
    Write-Host "::notice title=minimize::$summary"
} catch {
    Write-Host "::error title=minimize::$($_.Exception.Message)"
    throw
} finally {
    # Actions' PowerShell steps exit with the last native exit code, so
    # only stop a trace that's still running.
    if ($tracing) { logman stop $session -ets | Out-Null }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
