# Checks the search bar: `start_search` opens it, Ctrl+Backspace deletes a
# word in its field, typing a needle counts the
# matches on screen (the bar's name, which screen readers see, is the
# count), `navigate_search:next` and `:previous` move the selected match,
# and `end_search` closes it. Those keys go to the search field, which
# passes keys it has no use for to the terminal's keybindings. cmd prints
# a marker three times, so with the command line there are six matches.
# Keys and characters are posted to Ghostty's windows, so it runs on a
# locked desktop.
#
#     ./search.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=search::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttySearch -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.Text.StringBuilder l);
public static string Text(System.IntPtr h) { var s = new System.Text.StringBuilder(256); GetWindowTextW(h, s, 256); return s.ToString(); }
// An edit field's text (GetWindowText doesn't read another process's).
public static string FieldText(System.IntPtr h) { var s = new System.Text.StringBuilder(256); SendMessageW(h, 0x000D, (System.IntPtr)256, s); return s.ToString(); }
// Characters, as WM_CHAR.
public static void Type(System.IntPtr h, string s) {
  foreach (char ch in s) { PostMessageW(h, 0x0102, (System.IntPtr)ch, (System.IntPtr)1); System.Threading.Thread.Sleep(5); }
}
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttySearch.Win32]

$marker = 'GHOSTMARK'
$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-search-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f9=start_search', '--keybind=f10=navigate_search:next',
    '--keybind=f11=navigate_search:previous', '--keybind=f12=end_search'

function Fail([string]$message) {
    Write-Host "::error title=search::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what ($script:note)"
}

function ScreenText {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($surface)
    $(try { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' })
}

# The search bar's name: "N matches", "Match I of N", or "No matches".
function Count {
    $script:note = "the search bar says '$($W::Text($bar))'"
    $text = $W::Text($bar)
    if ($text -match '^Match (\d+) of (\d+)$') { return @{ Selected = [int]$Matches[1]; Total = [int]$Matches[2] } }
    if ($text -match '^(\d+) matches$') { return @{ Selected = 0; Total = [int]$Matches[1] } }
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
    [void](WaitFor { $script:note = 'no prompt yet'; (ScreenText) -match '>\s*$' } 'the prompt')

    $W::Type($surface, "echo $marker & echo $marker & echo $marker`r")
    [void](WaitFor { $n = ([regex]::Matches((ScreenText), $marker)).Count; $script:note = "$n on screen"; $n -eq 6 } 'the markers')

    $W::Key($surface, 0x78, 0x43)   # F9: start_search
    $script:bar = WaitFor { $h = $W::FindWindowExW($surface, [IntPtr]::Zero, 'GhosttySearchBar', [NullString]::Value); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the search bar'
    $edit = $W::FindWindowExW($bar, [IntPtr]::Zero, 'Edit', [NullString]::Value)
    if ($edit -eq [IntPtr]::Zero) { Fail 'the search bar has no text field' }

    # Ctrl+Backspace (its character, U+007F) deletes the word before the
    # caret rather than typing a box.
    $W::Type($edit, 'abc def')
    $W::Type($edit, [string][char]0x7F)
    [void](WaitFor { $script:note = "the field has '$($W::FieldText($edit))'"; $W::FieldText($edit) -eq 'abc ' } 'Ctrl+Backspace to delete a word')
    $W::Type($edit, [string][char]0x7F)
    [void](WaitFor { $script:note = "the field has '$($W::FieldText($edit))'"; $W::FieldText($edit) -eq '' } 'Ctrl+Backspace to delete the other')
    Write-Host 'Ctrl+Backspace deletes the word before the caret.'

    $W::Type($edit, $marker)
    $count = WaitFor { $c = Count; if ($c -and $c.Total -eq 6) { $c } } 'six matches'
    Write-Host "Searching for $marker counts six matches ($note)."

    # Next selects a match (or the one after), previous goes back. The
    # keys go to the field, which has focus.
    $W::Key($edit, 0x79, 0x44)   # F10: navigate_search:next
    $first = WaitFor { $c = Count; if ($c -and $c.Selected -gt 0 -and $c.Selected -ne $count.Selected) { $c } } 'next to select a match'
    $W::Key($edit, 0x79, 0x44)
    $second = WaitFor { $c = Count; if ($c -and $c.Selected -gt 0 -and $c.Selected -ne $first.Selected) { $c } } 'next to move to another match'
    $W::Key($edit, 0x7A, 0x57)   # F11: navigate_search:previous
    [void](WaitFor { $c = Count; $c -and $c.Selected -eq $first.Selected } "previous to go back to match $($first.Selected)")
    Write-Host "Next selected match $($first.Selected), then $($second.Selected); previous went back to $($first.Selected)."

    $W::Key($edit, 0x7B, 0x58)   # F12: end_search
    [void](WaitFor { $script:note = 'still shown'; -not $W::IsWindowVisible($bar) } 'the search bar to close')
    Write-Host 'end_search closes the search bar.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
