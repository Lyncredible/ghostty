# A check of the PowerShell integration's prompt
# (src/shell-integration/powershell/ghostty.ps1), for CI. It runs in both
# Windows PowerShell 5.1 and PowerShell 7+ without a terminal: it loads the
# integration and checks the escape sequences its prompt writes.

$ErrorActionPreference = 'Stop'
$env:GHOSTTY_SHELL_FEATURES = 'cursor,title'
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../src/shell-integration/powershell/ghostty.ps1'))))

$esc = [char]0x1b
$bel = [char]0x07
$out = prompt

$path = (Get-Location).ProviderPath.Replace('\', '/')
if (-not $path.StartsWith('/')) { $path = "/$path" }
$expected = @(
    "$esc]7;kitty-shell-cwd://$([Environment]::MachineName)$path$bel",
    "$esc]2;$(Get-Location)$bel",
    "$esc]133;A$bel",
    "$esc[5 q",
    "$esc]133;B$bel"
)
foreach ($sequence in $expected) {
    if (-not $out.Contains($sequence)) {
        throw "missing $($sequence.Replace($esc, '\e').Replace($bel, '\a')) in the prompt"
    }
}

# A failed command reports its exit code.
$global:__GhosttyCommandRunning = $true
$global:LASTEXITCODE = 0
$global:__GhosttyStartExitCode = 0
cmd /c exit 3
$out = prompt
if (-not $out.Contains("$esc]133;D;3$bel")) { throw "missing the exit code in the prompt" }

"PowerShell $($PSVersionTable.PSVersion): the integration's prompt is as expected"
