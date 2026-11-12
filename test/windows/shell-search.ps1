# Checks that a shell named alone (`command = powershell.exe`) is never
# taken from the directory Ghostty was started in. Windows looks there
# before its own directories and PATH, and that directory can be anyone's:
# a downloaded project whose folder was opened from Explorer's menu, say.
#
# Ghostty is started in a directory holding a stand-in `powershell.exe`
# (a copy of cmd.exe) and must start the real one, and a program that is
# only there must not start at all. Needs no input or foreground.
#
#     ./shell-search.ps1 -Exe ../../zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)][string]$Exe
)

$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path

$dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-shell-search-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
$only = "ghostty-test-planted-$PID.exe"
Copy-Item "$env:SystemRoot\System32\cmd.exe" (Join-Path $dir 'powershell.exe')
Copy-Item "$env:SystemRoot\System32\cmd.exe" (Join-Path $dir $only)

$script:process = $null

# With this set (some environments do), Windows doesn't look in the
# current directory at all, and the test would pass whatever Ghostty did.
Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue

# Ghostty's children with this name, some seconds after starting it in
# the directory with the command.
function Children($command, $name, $seconds) {
    $script:process = Start-Process -FilePath $Exe -PassThru -WorkingDirectory $dir `
        -ArgumentList '--window-save-state=never', '--confirm-close-surface=false', "`"--command=$command`""
    $found = @()
    for ($i = 0; $i -lt $seconds * 2; $i++) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) { break }
        $found = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id) and Name='$name'")
        if ($found.Count -gt 0) { break }
    }
    $found
}

function Stop-Ghostty {
    if ($script:process -and -not $script:process.HasExited) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($script:process.Id)" |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $script:process.Id -Force -ErrorAction SilentlyContinue
        $script:process.WaitForExit(5000) | Out-Null
    }
    $script:process = $null
}

try {
    $shells = Children 'powershell.exe -NoLogo -NoProfile' 'powershell.exe' 20
    if ($shells.Count -eq 0) { throw "no powershell.exe was started" }
    $path = $shells[0].ExecutablePath
    if (-not $path) { throw "couldn't read the shell's path" }
    if ($path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) {
        throw "the shell came from the starting directory: $path"
    }
    if ($path -notmatch '\\WindowsPowerShell\\') { throw "an unexpected powershell.exe: $path" }
    Write-Host "powershell.exe: $path"
    Stop-Ghostty

    # A program that is only in the starting directory isn't found, as if
    # it were nowhere. Named with the directory (.\name) it runs.
    $shells = Children $only $only 6
    if ($shells.Count -ne 0) { throw "a program in the starting directory ran: $($shells[0].ExecutablePath)" }
    Write-Host "${only}: not started"
    Stop-Ghostty

    $shells = Children ".\$only" $only 20
    if ($shells.Count -eq 0) { throw ".\$only wasn't started" }
    Write-Host ".\${only}: $($shells[0].ExecutablePath)"
    Write-Host "::notice title=shell-search::a shell named alone isn't taken from the starting directory"
} catch {
    Write-Host "::error title=shell-search::$($_.Exception.Message)"
    throw
} finally {
    Stop-Ghostty
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}
