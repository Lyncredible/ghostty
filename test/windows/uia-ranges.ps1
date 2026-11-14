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
# The shell waits a few seconds (ping), then prints: the marks, wide
# characters (日本語, two columns each) next to as many columns of narrow
# ones, and a line that wraps onto three of the 80 columns' rows.
$cjk = "$([char]0x65E5)$([char]0x672C)$([char]0x8A9E)"
$long = ('L' * 200) + 'END'
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--window-save-state=never',
    "`"--command=cmd.exe /k ping -n 4 127.0.0.1 >nul & (for /l %i in (1,1,30) do @echo RANGEMARK line %i) & echo WIDE abcdef $cjk& echo $long`"",
    '--confirm-close-surface=false', '--window-width=80', '--window-height=30'

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
    while ((Get-Date) -lt $deadline -and $text.DocumentRange.GetText(-1) -notmatch 'LEND') {
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

    # Finding text in the screen: with and without regard to case, and
    # from either end.
    $all = $text.DocumentRange
    $found = $all.FindText('rangemark LINE 30', $false, $true)
    if (-not $found -or $found.GetText(-1) -cne 'RANGEMARK line 30') { Fail "FindText ignoring case didn't find 'RANGEMARK line 30'" }
    if ($all.FindText('rangemark LINE 30', $false, $false)) { Fail 'FindText found text in the wrong case when asked to match it' }
    $first = $all.FindText('RANGEMARK', $false, $false)
    $last = $all.FindText('RANGEMARK', $true, $false)
    if (-not $first -or -not $last) { Fail "FindText didn't find RANGEMARK" }
    if ($first.CompareEndpoints($Start, $last, $Start) -ge 0) { Fail 'FindText backward found nothing later than the first RANGEMARK' }
    if ($all.FindText('NO-SUCH-TEXT-HERE', $false, $true)) { Fail "FindText found text that isn't there" }
    Write-Host "FindText found 'RANGEMARK line 30' ignoring case and not when matching it, and the first and last RANGEMARK apart."

    # Where text is on the screen, which screen readers highlight: lines
    # are the screen's rows and a wide character is two columns. The text
    # used to join a wrapped row to the next, and count a character a
    # column.
    function Rect([string]$find) {
        $range = $all.FindText($find, $false, $false)
        if (-not $range) { Fail "FindText didn't find '$find'" }
        $rects = @($range.GetBoundingRectangles())
        if ($rects.Count -ne 1) { Fail "'$find' has $($rects.Count) rectangles, not one" }
        $rects[0]
    }
    $narrow = Rect 'abcdef'
    $wide = Rect $cjk
    $mark = Rect 'WIDE'
    $end = Rect 'LEND'
    $cell = $narrow.Width / 6
    if ($cell -le 0 -or $narrow.Height -le 0) { Fail "'abcdef' is $($narrow.Width)x$($narrow.Height)" }
    if ([math]::Abs($wide.Width - $narrow.Width) -gt 0.5) {
        Fail "three wide characters are $($wide.Width) wide, not the $($narrow.Width) of six narrow ones"
    }
    # LEND is on the third row of the wrapped line, the row after WIDE's
    # being its first, at column 199 - 160.
    $rows = ($end.Top - $mark.Top) / $narrow.Height
    $columns = ($end.Left - $mark.Left) / $cell
    if ([math]::Abs($rows - 3) -gt 0.01 -or [math]::Abs($columns - 39) -gt 0.01) {
        Fail "'LEND' is $rows rows and $columns columns from 'WIDE', not 3 and 39"
    }
    Write-Host "Wide characters are two columns wide, and a wrapped line's rows are lines."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
