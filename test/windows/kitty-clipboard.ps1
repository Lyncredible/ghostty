# Checks the Kitty clipboard protocol (OSC 5522): a PowerShell inside
# Ghostty writes text and a type of its own to the clipboard, reads both
# back with the listing of the types there, and turns on paste events
# (mode 5522), after which a paste sends the listing instead of the text.
# The clipboard then has the text for other programs too. In CI, a second
# run asks first (`clipboard-write` and `clipboard-read` = ask): allowing
# the write writes (its question lists the type of its own along with the
# text), and denying the read answers EPERM. A third checks the
# question's "Remember choice" box: a write with a password, allowed and
# remembered, isn't asked about again, and nor is an OSC 52 read after one
# that was.
#
# The ConPTY built into Windows (build 26100) swallows OSC 5522, so this
# needs the ConPTY package's conpty.dll next to ghostty.exe
# (dist/windows/conpty.ps1); without it, the test says so and passes.
# Keys are posted to Ghostty's window, so it runs on a locked desktop. It
# replaces what's on the clipboard.
#
#     ./kitty-clipboard.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=kitty-clipboard::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyKittyClipboard -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyKittyClipboard.Win32]
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$work = Join-Path ([IO.Path]::GetTempPath()) "ghostty-kitty-clipboard-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$inner = Join-Path $work 'inner.ps1'
$result = Join-Path $work 'result.json'
$ready = Join-Path $work 'ready'
$log = Join-Path $work 'ghostty.log'

# Runs in Ghostty: VT output and raw VT input. Each step's reply is what
# arrives as input until its last packet (status=DONE).
Set-Content -Encoding utf8 -Path $inner -Value @'
param([string]$Result, [string]$Ready, [string]$Mode)
trap { "error: $($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" | Set-Content $Result; exit 1 }
Add-Type -Namespace KittyClipboard -Name Kernel32 -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
"@
$K = [KittyClipboard.Kernel32]
$stdin = $K::GetStdHandle(-10); $stdout = $K::GetStdHandle(-11)
$output = 0; [void]$K::GetConsoleMode($stdout, [ref]$output)
[void]$K::SetConsoleMode($stdout, $output -bor 4)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
[void]$K::SetConsoleMode($stdin, 0x200)           # ENABLE_VIRTUAL_TERMINAL_INPUT only (raw)
$e = [char]27; $st = "$e\"
function B64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function Send([string]$s) { [Console]::Out.Write($s); [Console]::Out.Flush() }
function Collect([double]$seconds, [string]$until = 'status=DONE') {
    $got = ''
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline -and -not $got.Contains($until)) {
        while ([Console]::KeyAvailable) { $got += [Console]::ReadKey($true).KeyChar }
        Start-Sleep -Milliseconds 20
    }
    $got -replace $e, '\e'
}
$replies = [ordered]@{}

if ($Mode -eq 'remember') {
    # Each is asked about at most once: the first with the box checked.
    # A password counts only with a name.
    $who = "pw=$(B64 'test-token'):name=$(B64 'the test')"
    foreach ($n in 1, 2) {
        Send "$e]5522;type=write:$who$st"
        Send "$e]5522;type=wdata:mime=$(B64 'text/plain');$(B64 "remembered $n")$st"
        Send "$e]5522;type=wdata$st"
        $replies["write$n"] = Collect 15
    }
    foreach ($n in 1, 2) {
        Send "$e]52;c;?$st"
        $replies["osc52_$n"] = Collect 15 $st
    }
    $replies | ConvertTo-Json | Set-Content -Encoding utf8 $Result
    exit 0
}

Send "$e]5522;type=write$st"
Send "$e]5522;type=wdata:mime=$(B64 'text/plain');$(B64 'kitty text')$st"
Send "$e]5522;type=wdata:mime=$(B64 'application/x-ghostty-test');$(B64 'custom bytes')$st"
Send "$e]5522;type=wdata$st"
$replies['write'] = Collect 10

Send "$e]5522;type=read;$(B64 'text/plain application/x-ghostty-test .')$st"
$replies['read'] = Collect 10

if ($Mode -eq 'paste') {
    Send "$e[?5522h"
    Set-Content $Ready 'ready'
    $replies['paste'] = Collect 20
    Send "$e[?5522l"
}

$replies | ConvertTo-Json | Set-Content -Encoding utf8 $Result
'@

$bundled = Test-Path (Join-Path (Split-Path $Exe) 'conpty.dll')
$process = $null

# Start Ghostty running the program, with the options.
function Launch([string[]]$options, [string]$mode) {
    Remove-Item -Force $result, $ready -ErrorAction SilentlyContinue
    $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList (@('--window-save-state=never',
        '--keybind=f9=paste_from_clipboard') + $options + @('-e',
        'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $inner, $result, $ready, $mode))
    $window = WaitFor { $script:process.Refresh(); if ($script:process.MainWindowHandle -ne 0) { $script:process.MainWindowHandle } } 'the window'
    $script:surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
}

# The program's replies, once it's done.
function Replies {
    [void](WaitFor { Test-Path $result } 'the replies')
    Start-Sleep -Milliseconds 300
    $text = Get-Content -Raw $result
    if ($text.StartsWith('error:')) { Fail "the script in Ghostty failed: $text" }
    $replies = $text | ConvertFrom-Json
    foreach ($property in $replies.PSObject.Properties) { Write-Host "  $($property.Name) -> '$($property.Value)'" }
    $replies
}

function Close {
    if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
    Start-Sleep -Milliseconds 500
}

function Fail([string]$message) {
    Write-Host "::error title=kitty-clipboard::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $value = & $condition
        if ($value) { return $value }
        if ($script:process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what"
}

# Ghostty's "Authorize Clipboard Access" question, if it's showing.
function Dialog {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, '#32770', 'Authorize Clipboard Access')) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $script:process.Id) { return $h }
    }
}

# The text in a dialog (its message and preview), by UI Automation.
function DialogText($dialog) {
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($dialog)
    $all = $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    (@($all) | ForEach-Object { $_.Current.Name }) -join "`n"
}

# Answer the question: 1 is the accept button (Allow), 2 the reject one
# (Deny), pressed with TDM_CLICK_BUTTON until the dialog is ready and goes
# (the next question can follow at once, with the same title). With
# -Shows, the question's text must have that in it.
function Answer([int]$button, [string]$what, [switch]$Remember, [string]$Shows) {
    $dialog = WaitFor { Dialog } "the question about the $what"
    if ($Shows) {
        $shown = WaitFor { $t = DialogText $dialog; if ($t.Contains($Shows)) { $t } } "the question about the $what to show '$Shows'"
        Write-Host "The question about the $what showed: $($shown -replace "`r?`n", ' | ')"
    }
    # TDM_CLICK_VERIFICATION: check the "Remember choice" box.
    if ($Remember) { [void]$W::SendMessageW($dialog, 0x0471, [IntPtr]1, [IntPtr]::Zero) }
    [void](WaitFor {
        [void]$W::PostMessageW($dialog, 0x0466, [IntPtr]$button, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 300
        -not $W::IsWindow($dialog)
    } "the question about the $what to go")
}

function B64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function Unb64([string]$s) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) }

# The types a reply's listing (a DATA packet for the type '.') names.
function Listing([string]$reply) {
    if ($reply -match 'status=DATA:mime=Lg==[^;]*;([A-Za-z0-9+/=]+)') { return (Unb64 $Matches[1]).Trim() -split '\s+' }
}

$text = "mime=$(B64 'text/plain');$(B64 'kitty text')"
$custom = "mime=$(B64 'application/x-ghostty-test');$(B64 'custom bytes')"

try {
    Write-Host "ConPTY: $(if ($bundled) { "conpty.dll next to $Exe" } else { 'the one built into Windows' })"
    Set-Clipboard -Value 'before the test'
    Launch @('--clipboard-read=allow', '--clipboard-write=allow') 'paste'

    # Paste once the program waits for the event.
    [void](WaitFor { (Test-Path $ready) -or (Test-Path $result) } 'the program to turn on paste events')
    Start-Sleep -Milliseconds 300
    $W::Key($surface, 0x78, 0x43)   # F9: paste_from_clipboard
    $replies = Replies
    Close

    if (-not $bundled -and -not $replies.write) {
        Write-Host "::notice title=kitty-clipboard::The ConPTY built into Windows didn't pass OSC 5522 through (known; conpty.dll does)."
        exit 0
    }

    if ($replies.write -notmatch 'type=write:status=DONE') { Fail "the write wasn't done: '$($replies.write)'" }
    $clip = Get-Clipboard -Raw
    if ($clip -ne 'kitty text') { Fail "the clipboard has '$clip', not the text the program wrote" }
    Write-Host 'The write put the text on the clipboard.'

    if (-not $replies.read.Contains($text)) { Fail "the read didn't serve the text: '$($replies.read)'" }
    if (-not $replies.read.Contains($custom)) { Fail "the read didn't serve the program's own type: '$($replies.read)'" }
    $types = Listing $replies.read
    if ($types -notcontains 'text/plain' -or $types -notcontains 'application/x-ghostty-test') {
        Fail "the read's listing has '$types', not both types"
    }
    Write-Host "The read served both representations and listed: $types."

    $types = Listing $replies.paste
    if ($types -notcontains 'text/plain') { Fail "the paste event's listing has '$types': '$($replies.paste)'" }
    if ($replies.paste.Contains($text)) { Fail "the paste event sent the text, not only the listing: '$($replies.paste)'" }
    Write-Host "A paste with paste events on sent the listing: $types."

    # Asking first shows dialogs, so only in CI.
    if ($env:CI -eq 'true') {
        Set-Clipboard -Value 'before the question'
        Launch @('--clipboard-read=ask', '--clipboard-write=ask') 'ask'
        # It shows both: the type of its own isn't allowed unseen.
        Answer 1 'write' -Shows "application/x-ghostty-test (12 bytes)"
        Answer 2 'read'
        $replies = Replies
        Close
        if ($replies.write -notmatch 'type=write:status=DONE') { Fail "the allowed write wasn't done: '$($replies.write)'" }
        $clip = Get-Clipboard -Raw
        if ($clip -ne 'kitty text') { Fail "after allowing the write the clipboard has '$clip'" }
        if ($replies.read -notmatch 'type=read:status=EPERM') { Fail "the denied read got '$($replies.read)', not EPERM" }
        Write-Host 'Asked first: allowing the write wrote, and denying the read answered EPERM.'

        # Remembered: the second of each isn't asked about, so a question
        # left unanswered would leave its reply empty.
        Launch @('--clipboard-read=ask', '--clipboard-write=ask') 'remember'
        Answer 1 'write with a password' -Remember
        Answer 1 'OSC 52 read' -Remember
        $replies = Replies
        Close
        foreach ($n in 1, 2) {
            if ($replies."write$n" -notmatch 'type=write:status=DONE') { Fail "write $n with the remembered password got '$($replies."write$n")'" }
        }
        $clip = Get-Clipboard -Raw
        if ($clip -ne 'remembered 2') { Fail "after the remembered writes the clipboard has '$clip'" }
        foreach ($n in 1, 2) {
            if (-not $replies."osc52_$n".Contains("52;c;$(B64 'remembered 2')")) { Fail "OSC 52 read $n got '$($replies."osc52_$n")'" }
        }
        Write-Host 'Remembered: the second write with the password and the second OSC 52 read weren''t asked about.'
    }
} finally {
    Close
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
exit 0
