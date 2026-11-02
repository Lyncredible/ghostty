# Checks that output alone makes Ghostty draw a frame. A program prints a
# letter every 250 ms, and the DXGI ETW provider counts Ghostty's
# presents. The IO thread once woke the renderer through a copy of its
# wakeup handle, which can't wake a thread with libxev's IOCP backend,
# so output was only drawn with the next cursor blink (600 ms) or key.
# Starting an ETW session needs no input; on a desktop without admin
# rights it works for the current user's processes. It also reports the
# frame rate while output floods in, which the display's refresh should
# limit (a locked session doesn't, so Ghostty limits it itself there).
#
#     ./output-frames.ps1 -Zip zig-out/dist/ghostty-windows-unofficial.zip

param(
    [string]$Exe,
    [string]$Zip,
    [int]$Seconds = 6
)

$ErrorActionPreference = 'Stop'

if ($Zip) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-output-frames-$PID"
    Expand-Archive -Force $Zip $dir
    $Exe = (Get-ChildItem -Recurse $dir -Filter ghostty.exe | Select-Object -First 1).FullName
}
if (-not $Exe) { throw "give -Exe or -Zip" }

$session = "ghostty-output-frames-$PID"
$etl = Join-Path ([IO.Path]::GetTempPath()) "$session.etl"
$script:tracing = $false
$script:process = $null

# Ghostty's presents (event 42 is the start of IDXGISwapChain::Present)
# during $Seconds, a few seconds after starting it with $command.
function Frames($command) {
    $script:process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--window-save-state=never', "`"--command=$command`""
    Start-Sleep 5
    if ($process.HasExited) { throw "Ghostty exited" }
    logman start $session -p Microsoft-Windows-DXGI 0xFFFFFFFF 5 -o $etl -ets | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "logman couldn't start the trace" }
    $script:tracing = $true
    Start-Sleep $Seconds
    logman stop $session -ets | Out-Null
    $script:tracing = $false
    Stop-Process -Id $process.Id -Force
    tracerpt $etl -o "$etl.xml" -of XML -y | Out-Null
    [xml]$xml = Get-Content "$etl.xml"
    @($xml.Events.Event | Where-Object {
        $_.System.EventID -eq '42' -and $_.System.Execution.ProcessID -eq "$($process.Id)"
    }).Count
}

try {
    $frames = Frames 'powershell.exe -NoProfile -Command Start-Sleep 3; while (1) { [Console]::Write([char]120); Start-Sleep -Milliseconds 250 }'
    $expected = $Seconds * 4
    $summary = "$frames frames in $Seconds s while a letter was printed every 250 ms ($expected letters)"
    # Cursor blinks alone give about 10.
    if ($frames -lt $expected * 2 / 3) { throw "output didn't make Ghostty draw: $summary" }
    Write-Host "::notice title=output-frames::$summary"

    $frames = Frames 'cmd.exe /k for /l %i in (1,1,999999999) do @echo %i'
    Write-Host "::notice title=output-frames::$([math]::Round($frames / $Seconds)) frames/s while output floods in"
} catch {
    Write-Host "::error title=output-frames::$($_.Exception.Message)"
    throw
} finally {
    # Actions' PowerShell steps exit with the last native exit code, so
    # only stop a trace that's still running.
    if ($tracing) { logman stop $session -ets | Out-Null }
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
