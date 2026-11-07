# Checks that programs can ask for the terminal's colors (OSC 10 and 11,
# which Codex, Neovim and tmux use to pick colors that suit the
# background): a PowerShell inside Ghostty sends the queries and reads the
# replies as VT input. Ghostty runs with distinctive colors, so a reply
# with them comes from Ghostty and not from the console host.
#
# The ConPTY built into Windows (build 26100) swallows these queries, so
# they only get through with the ConPTY package's conpty.dll next to
# ghostty.exe (dist/windows/conpty.ps1). With it, the replies must be
# Ghostty's; without it, the test reports what came back and passes.
#
#     ./color-query.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

$work = Join-Path ([IO.Path]::GetTempPath()) "ghostty-color-query-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$inner = Join-Path $work 'inner.ps1'
$result = Join-Path $work 'result.json'
$log = Join-Path $work 'ghostty.log'

# Runs in Ghostty: VT output and input, each query in turn, and whatever
# arrives as input in the next two seconds is its reply.
Set-Content -Encoding utf8 -Path $inner -Value @'
param([string]$Result)
trap { "error: $($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" | Set-Content $Result; exit 1 }
Add-Type -Namespace ColorQuery -Name Kernel32 -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
"@
$K = [ColorQuery.Kernel32]
$stdin = $K::GetStdHandle(-10); $stdout = $K::GetStdHandle(-11)
$mode = 0; [void]$K::GetConsoleMode($stdout, [ref]$mode)
[void]$K::SetConsoleMode($stdout, $mode -bor 4)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
[void]$K::SetConsoleMode($stdin, 0x200)           # ENABLE_VIRTUAL_TERMINAL_INPUT only (raw)
$e = [char]27
$replies = [ordered]@{}
foreach ($q in @(@('OSC 10', "$e]10;?$e\"), @('OSC 11', "$e]11;?`a"), @('DA1', "$e[c"))) {
    [Console]::Out.Write($q[1]); [Console]::Out.Flush()
    $got = ''
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        while ([Console]::KeyAvailable) { $got += [Console]::ReadKey($true).KeyChar }
        Start-Sleep -Milliseconds 20
    }
    $replies[$q[0]] = ($got -replace $e, '\e' -replace "`a", '\a')
}
$replies | ConvertTo-Json | Set-Content -Encoding utf8 $Result
'@

$bundled = Test-Path (Join-Path (Split-Path $Exe) 'conpty.dll')
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--window-save-state=never',
    '--background=#123456', '--foreground=#abcdef', '-e',
    'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $inner, $result

function Fail([string]$message) {
    Write-Host "::error title=color-query::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path $result) -and (Get-Date) -lt $deadline) {
        if ($process.HasExited -and -not (Test-Path $result)) { Fail 'Ghostty exited before the queries were answered' }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $result)) { Fail 'timed out waiting for the queries' }
    $text = Get-Content -Raw $result
    if ($text.StartsWith('error:')) { Fail "the script in Ghostty failed: $text" }
    $replies = $text | ConvertFrom-Json
    Write-Host "ConPTY: $(if ($bundled) { "conpty.dll next to $Exe" } else { 'the one built into Windows' })"
    foreach ($name in 'OSC 10', 'OSC 11', 'DA1') { Write-Host "  $name -> '$($replies.$name)'" }

    $fg = '\e]10;rgb:abab/cdcd/efef\e\'
    $bg = '\e]11;rgb:1212/3434/5656\a'
    if ($bundled) {
        # Each reply ends like its query (ST or BEL).
        if ($replies.'OSC 10' -ne $fg) { Fail "OSC 10 got '$($replies.'OSC 10')', not Ghostty's foreground '$fg'" }
        if ($replies.'OSC 11' -ne $bg) { Fail "OSC 11 got '$($replies.'OSC 11')', not Ghostty's background '$bg'" }
        Write-Host 'Ghostty answered OSC 10 and 11 with its colors.'
    } elseif ($replies.'OSC 11' -eq $bg) {
        Write-Host "The inbox ConPTY passed the queries through, and Ghostty answered."
    } else {
        Write-Host "::notice title=color-query::The ConPTY built into Windows didn't pass OSC 10/11 through (known; conpty.dll does)."
    }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
exit 0
