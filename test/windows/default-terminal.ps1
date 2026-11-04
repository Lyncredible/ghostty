# Checks that the installed MSIX works as Windows' default terminal
# application: with the console delegation set to Windows Terminal's
# OpenConsole and the terminal delegation to Ghostty's handoff class (as
# Settings > For developers > Terminal does), a console program started in
# a new console must show up in a Ghostty window that COM started
# (`-Embedding`). It changes the user's default terminal (and restores it),
# so it only runs in CI, after the MSIX is installed.
#
#     ./default-terminal.ps1

param([int]$TimeoutSeconds = 60)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this changes the default terminal application, so it only runs in CI" }
if (-not (Get-AppxPackage Microsoft.WindowsTerminal)) {
    Write-Host "::notice title=default-terminal::Windows Terminal isn't installed, so there's no OpenConsole to delegate to; skipped"
    exit 0
}
$package = Get-AppxPackage GhosttyWindowsUnofficial
if (-not $package) { throw "the MSIX isn't installed" }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$key = 'HKCU:\Console\%%Startup'
$names = 'DelegationConsole', 'DelegationTerminal'
$saved = @{}
if (Test-Path $key) {
    foreach ($name in $names) { $saved[$name] = (Get-ItemProperty $key -ErrorAction SilentlyContinue).$name }
}

function Fail([string]$message) {
    Write-Host "::error title=default-terminal::$message"
    throw $message
}

# The text of a running Ghostty's terminals.
function GhosttyText {
    foreach ($process in Get-Process ghostty -ErrorAction SilentlyContinue) {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
            foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    (New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
                @{ Process = $process; Text = $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
            }
        }
    }
}

$cmd = $null
try {
    Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    Set-ItemProperty $key DelegationConsole '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    Set-ItemProperty $key DelegationTerminal '{7EC9F94F-09DD-4C7F-A79B-57532EBAFCDD}'

    # A new console, as when a console program starts from Explorer.
    $cmd = Start-Process -FilePath cmd.exe -PassThru -ArgumentList '/k echo default-%USERNAME:~0,0%terminal'
    $found = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $found -and (Get-Date) -lt $deadline) {
        $found = GhosttyText | Where-Object { $_.Text.Contains('default-terminal') } | Select-Object -First 1
        if (-not $found) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $found) {
        $running = (Get-Process ghostty -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) $($_.Path)" }) -join '; '
        Fail "cmd's output didn't show up in Ghostty (Ghostty processes: $running)"
    }
    $path = $found.Process.Path
    if (-not $path.StartsWith($package.InstallLocation, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "the Ghostty showing cmd isn't the installed package's: $path"
    }
    Write-Host "cmd started in a new console showed up in the packaged Ghostty ($path)."
} finally {
    if ($cmd -and -not $cmd.HasExited) { Stop-Process -Id $cmd.Id -Force -ErrorAction SilentlyContinue }
    Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($name in $names) {
        if ($null -eq $saved[$name]) {
            Remove-ItemProperty $key $name -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty $key $name $saved[$name]
        }
    }
}
