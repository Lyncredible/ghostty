# Checks that screen readers can mix text ranges taken at different times.
# Each range is of the screen as it was when the reader asked for it, and
# readers move one range's end to another's (MoveEndpointByRange), such as
# the document's to the newer selection's. When the screen had grown in
# between, that end was past the older range's text, and reading it
# (GetText) crashed Ghostty. Here the document's range is taken on an
# empty screen, the shell then prints, and the range is moved to the
# selection's end and read. It uses UI Automation only, so it runs on a
# locked desktop.
#
#     ./uia-ranges.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-uia-ranges-$PID.log"
# The shell waits a few seconds (ping), then prints.
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--window-save-state=never',
    '"--command=cmd.exe /k ping -n 4 127.0.0.1 >nul & for /l %i in (1,1,30) do @echo RANGEMARK line %i"',
    '--confirm-close-surface=false'

function Fail([string]$message) {
    Write-Host "::error title=uia-ranges::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 30 | Write-Host }
    throw $message
}

try {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'GhosttySurface')
    $surface = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $surface -and (Get-Date) -lt $deadline) {
        foreach ($s in @($AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))) {
            if ($s.Current.ProcessId -eq $process.Id) { $surface = $s }
        }
        if (-not $surface) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $surface) { Fail 'no terminal' }
    $text = $surface.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)

    $document = $text.DocumentRange
    $before = $document.GetText(-1)
    if ($before -match 'RANGEMARK') { Fail 'the shell printed before the first range was taken' }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and $text.DocumentRange.GetText(-1) -notmatch 'RANGEMARK line 30') {
        Start-Sleep -Milliseconds 250
    }
    $after = $text.DocumentRange.GetText(-1)
    if ($after -notmatch 'RANGEMARK line 30') { Fail "the shell's output didn't come" }
    Write-Host "The screen grew from $($before.Length) to $($after.Length) characters."

    # The selection (the cursor) is after the output, past the old text.
    $selection = $text.GetSelection()[0]
    $End = [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End
    $Start = [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start
    $document.MoveEndpointByRange($End, $selection, $End)
    $document.MoveEndpointByRange($Start, $selection, $End)
    try { $read = $document.GetText(-1) } catch { Fail "reading the moved range failed: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2
    if ($process.HasExited) { Fail 'Ghostty exited after the range was read' }
    if ($read.Length -gt $before.Length) { Fail "the old range read $($read.Length) characters, more than its $($before.Length)" }
    Write-Host "Moving the old range to the newer selection's end and reading it gave $($read.Length) characters, and Ghostty is fine."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
