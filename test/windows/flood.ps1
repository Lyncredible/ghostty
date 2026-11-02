# Checks that the window keeps answering messages while output floods in
# from a program that changes the title with each line (cmd puts the
# command in the title). Ghostty once updated the title bar for every
# title, slower than they arrived, and stopped responding. Debug builds
# were too slow to show it, so this is run on a release build: -Exe, or
# the package's ghostty.exe with -Zip. It only sends messages to
# Ghostty's window.
#
#     ./flood.ps1 -Zip zig-out/dist/ghostty-windows-unofficial.zip

param(
    [string]$Exe,
    [string]$Zip,
    [int]$Probes = 40
)

$ErrorActionPreference = 'Stop'

if ($Zip) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-flood-$PID"
    Expand-Archive -Force $Zip $dir
    $Exe = (Get-ChildItem -Recurse $dir -Filter ghostty.exe | Select-Object -First 1).FullName
}
if (-not $Exe) { throw "give -Exe or -Zip" }

Add-Type -Namespace GhosttyFlood -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageTimeoutW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l, uint flags, uint timeout, out System.IntPtr result);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
'@
$W = [GhosttyFlood.Win32]

$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--window-save-state=never',
    '"--command=cmd.exe /k for /l %i in (1,1,999999999) do @echo %i"'

function Window {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, 'GhosttyWindow', [NullString]::Value)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $process.Id) { return $h }
    }
}

# Reading another process's window text doesn't send it a message.
function Title($h) {
    $sb = New-Object System.Text.StringBuilder 512
    [void]$W::GetWindowTextW($h, $sb, 512)
    $sb.ToString()
}

try {
    $deadline = (Get-Date).AddSeconds(60)
    while (-not ($h = Window) -or (Title $h) -notmatch 'echo') {
        if ((Get-Date) -gt $deadline) { throw "timed out waiting for the flood (title: $(if ($h) { Title $h }))" }
        if ($process.HasExited) { throw "Ghostty exited" }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep 2

    $times = foreach ($i in 1..$Probes) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $result = [IntPtr]::Zero
        # WM_NULL, SMTO_ABORTIFHUNG
        $ok = $W::SendMessageTimeoutW($h, 0, [IntPtr]0, [IntPtr]0, 2, 5000, [ref]$result)
        if ($ok -eq [IntPtr]::Zero) { 5000 } else { $sw.Elapsed.TotalMilliseconds }
        Start-Sleep -Milliseconds 100
    }
    $last = Title $h
    $sorted = $times | Sort-Object
    $median = $sorted[[int]($sorted.Count / 2)]
    $slow = @($times | Where-Object { $_ -gt 1000 }).Count
    $summary = "median $([math]::Round($median, 1)) ms, max $([math]::Round($sorted[-1], 1)) ms, $slow of $Probes over 1 s; title: $last"
    if ($process.HasExited) { throw "Ghostty exited during the flood" }
    if ($slow -gt 2 -or $median -gt 200) { throw "the window stopped responding during the flood: $summary" }
    Write-Host "::notice title=flood::$summary"
} catch {
    Write-Host "::error title=flood::$($_.Exception.Message)"
    throw
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
