# Runs the unit tests and, when they fail, repeats the failures as a GitHub
# Actions error annotation. Annotations can be read without signing in,
# unlike job logs, so a failure on CI can be diagnosed from the run's page
# or the API.
param(
    [Parameter(Mandatory)][string]$Target,
    [string]$Filter
)

$zigArgs = @('build', 'test', "-Dtarget=$Target", '--summary', 'all')
if ($Filter) { $zigArgs += "-Dtest-filter=$Filter" }
$output = & zig @zigArgs 2>&1 | ForEach-Object {
    $line = "$_"
    Write-Host $line
    $line
}
$code = $LASTEXITCODE
if ($code -eq 0) { exit 0 }

# Each failing test prints "error: 'name' failed" followed by its output.
# Keep from the first error, without the build summary's step tree.
$first = 0
for ($i = 0; $i -lt $output.Count; $i++) {
    if ($output[$i] -match "error: '.*' failed|error:") { $first = $i; break }
}
$lines = $output[$first..($output.Count - 1)] |
    Where-Object { $_ -notmatch '^\s*[|+]' -and $_ -ne 'System.Management.Automation.RemoteException' } |
    Select-Object -First 60
# Annotations are one line: escape as the workflow command syntax requires.
$message = ($lines -join "`n") -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
Write-Host "::error title=Unit tests failed ($Target)::$message"
exit $code
