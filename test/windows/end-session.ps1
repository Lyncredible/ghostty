# Checks what's saved when Windows ends the session (a reboot, signing
# out, an update): the windows as they were when Windows asked
# (WM_QUERYENDSESSION), not after shells exit as they're told to. A WSL
# tab was once lost after a reboot: WSL stopped, its shell exited and its
# tab closed, and only then (WM_ENDSESSION) was the session saved.
#
# A saved session with a cmd tab and a tab running ping, which exits by
# itself like that WSL shell, is restored. Windows asking once and then
# cancelling (another app refused) saves, and asking again saves again.
# The ping tab closes, and the session ending keeps both tabs. Then a
# window whose only terminal exits once the session is ending keeps its
# saved state rather than forgetting it, as it otherwise would.
#
# It runs with its own `--class`, so it has its own state file (and
# instance) and leaves any other Ghostty alone.
#
#     ./end-session.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=end-session::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyEndSession -Name Win32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageTimeoutW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l, uint flags, uint timeout, out System.IntPtr result);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr parent, EnumProc proc, System.IntPtr l);
// Every descendant of `parent` with the class name.
public static System.IntPtr[] Find(System.IntPtr parent, string cls) {
  var found = new System.Collections.Generic.List<System.IntPtr>();
  EnumChildWindows(parent, (h, l) => {
    var s = new System.Text.StringBuilder(64); GetClassNameW(h, s, 64);
    if (s.ToString() == cls) found.Add(h);
    return true;
  }, System.IntPtr.Zero);
  return found.ToArray();
}
'@
$W = [GhosttyEndSession.Win32]
$WM_QUERYENDSESSION = 0x0011
$WM_ENDSESSION = 0x0016
$ENDSESSION_CLOSEAPP = 0x1

$class = "com.example.ghostty-end-session-test-$PID"
$state = Join-Path $env:LOCALAPPDATA "ghostty\window-state-$class.json"
$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-end-session-$PID.log"
$arguments = @('--command=cmd.exe', "--class=$class", '--window-save-state=always',
    '--confirm-close-surface=false', '--quit-after-last-window-closed=true')

function Fail([string]$message) {
    Write-Host "::error title=end-session::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what ($script:note)"
}

# Start Ghostty from a saved session, then remove the file, so that only
# a save we cause brings it back.
function Start-Ghostty($session, [int]$terminals) {
    # Without a byte order mark, which Windows PowerShell's UTF-8 would add.
    [IO.File]::WriteAllText($state, ($session | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList $arguments
    $script:window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    [void](WaitFor { Note; @(Surfaces).Count -eq $terminals } "the $terminals restored terminals")
    Remove-Item -LiteralPath $state -Force
}

function Surfaces { @($W::Find($window, 'GhosttySurface')) }
function Note { $script:note = "terminals: $(@(Surfaces).Count)" }

# Send a message to the window as Windows does, and return its result.
function Send([uint32]$message, [long]$wparam, [long]$lparam) {
    $result = [IntPtr]::Zero
    $SMTO_ABORTIFHUNG = 0x2
    if ($W::SendMessageTimeoutW($window, $message, [IntPtr]$wparam, [IntPtr]$lparam, $SMTO_ABORTIFHUNG, 5000, [ref]$result) -eq [IntPtr]::Zero) {
        Fail "the window didn't answer message $message"
    }
    $result.ToInt64()
}

# The saved tabs' commands ('' for the configured one), or null if
# nothing is saved.
function SavedTabs {
    if (-not (Test-Path $state)) { return $null }
    $saved = Get-Content -Raw $state | ConvertFrom-Json
    , @(@($saved.windows[0].tabs) | ForEach-Object { "$(@($_.nodes[0].command.direct)[0])" })
}

# A ping that ends by itself after a few seconds, as a WSL shell does
# when WSL stops.
$ping = @{ direct = @('ping.exe', '-n', '8', '127.0.0.1') }

try {
    Start-Ghostty @{ version = 1; windows = @(@{
        left = 100; top = 100; right = 900; bottom = 600; active_tab = 0
        tabs = @(@{ nodes = @(@{}) }, @{ nodes = @(@{ command = $ping }) })
    }) } 2

    # Windows asks, then cancels: the windows were saved when it asked.
    if ((Send $WM_QUERYENDSESSION 0 0) -ne 1) { Fail "WM_QUERYENDSESSION wasn't answered with TRUE" }
    $tabs = SavedTabs
    if ($null -eq $tabs -or $tabs.Count -ne 2) { Fail "Windows asking to end the session didn't save both tabs (saved: $tabs)" }
    [void](Send $WM_ENDSESSION 0 0)
    Remove-Item -LiteralPath $state -Force
    Write-Host 'Windows asking to end the session saved both tabs.'

    # Windows asks again (as for an update, which closes apps), then the
    # ping tab closes, as a WSL tab's would, and the session ends.
    if ((Send $WM_QUERYENDSESSION 0 $ENDSESSION_CLOSEAPP) -ne 1) { Fail "WM_QUERYENDSESSION wasn't answered with TRUE" }
    if ($null -eq (SavedTabs)) { Fail 'Windows asking again after a cancelled end saved nothing' }
    [void](WaitFor { Note; @(Surfaces).Count -eq 1 } 'the ping tab to close')
    [void](Send $WM_ENDSESSION 1 $ENDSESSION_CLOSEAPP)
    $tabs = SavedTabs
    if ($null -eq $tabs -or $tabs.Count -ne 2 -or $tabs[0] -ne '' -or $tabs[1] -ne 'ping.exe') {
        Fail "the session ending didn't keep the cmd and ping tabs (saved: $($tabs -join ', '))"
    }
    Write-Host 'After the ping tab closed, the session ending kept both tabs.'
    # Windows ends the process after WM_ENDSESSION.
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()

    # A window whose only terminal exits once the session is ending: its
    # state stays (closing the last window by its shell exiting otherwise
    # forgets it).
    Start-Ghostty @{ version = 1; windows = @(@{
        left = 100; top = 100; right = 900; bottom = 600; active_tab = 0
        tabs = @(@{ nodes = @(@{ command = $ping }) })
    }) } 1
    if ((Send $WM_QUERYENDSESSION 0 0) -ne 1) { Fail "WM_QUERYENDSESSION wasn't answered with TRUE" }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { Fail "Ghostty didn't quit when its last terminal's ping ended" }
    $tabs = SavedTabs
    if ($null -eq $tabs -or $tabs.Count -ne 1 -or $tabs[0] -ne 'ping.exe') {
        Fail "the last window closing as the session ends forgot the saved state (saved: $($tabs -join ', '))"
    }
    Write-Host 'The last window closing as the session ends kept the saved state.'
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $state, $log -Force -ErrorAction SilentlyContinue
}
exit 0
