# Checks, for CI, that an installed Ghostty starts the way the Start menu
# starts it, and opens a window from the installed location whose shell
# starts in the home directory (desktop launches default to
# working-directory=home):
#
#     ./start-menu.ps1 -Msix       # the installed MSIX, by its app ID
#     ./start-menu.ps1 -Zip <zip>  # install.ps1 from the zip, by its shortcut
#
# The zip check also uninstalls (install.ps1 -Uninstall) and checks that
# the shortcut is gone. It changes the user's Start menu, so it only runs
# in CI.

param(
    [switch]$Msix,
    [string]$Zip,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this installs Ghostty for the current user, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# The text of the process's first terminal.
function SurfaceText($process) {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
            return $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        }
    }
}

# Wait for the shell's prompt to show the home directory (cmd's and
# PowerShell's prompts both end with the directory and ">").
function WaitForHome($process) {
    $home_prompt = "$env:USERPROFILE>"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $text = SurfaceText $process
        if ($text -and $text.Contains($home_prompt)) {
            Write-Host "The shell started in $env:USERPROFILE."
            return
        }
        Start-Sleep -Milliseconds 500
    }
    $screen = ($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '
    Stop-Process -Id $process.Id -Force
    $message = "the shell didn't start in $env:USERPROFILE (screen: $screen)"
    Write-Host "::error title=start-menu::$message"
    throw $message
}

# Wait for a Ghostty window whose executable is under $root, check that
# its shell is in the home directory, then close it.
function WaitForWindow([string]$root) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process ghostty -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -and $_.Path.StartsWith($root, 'OrdinalIgnoreCase') } |
            Select-Object -First 1
        if ($process) {
            Write-Host "A window opened: $($process.Path) ($($process.MainWindowTitle))"
            WaitForHome $process
            Stop-Process -Id $process.Id -Force
            [void]$process.WaitForExit(10000)
            return
        }
        Start-Sleep -Milliseconds 500
    }
    $running = Get-Process ghostty -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Path) window=$($_.MainWindowHandle)" }
    throw "no Ghostty window from $root opened (running: $running)"
}

if ($Msix) {
    $package = Get-AppxPackage GhosttyWindowsUnofficial
    if (-not $package) { throw "the MSIX package isn't installed" }
    # Start menu entries start packaged apps by their application user model ID.
    Start-Process explorer.exe "shell:AppsFolder\$($package.PackageFamilyName)!App"
    WaitForWindow $package.InstallLocation
}

if ($Zip) {
    $extracted = Join-Path ([IO.Path]::GetTempPath()) "ghostty-zip-$PID"
    Expand-Archive -Path $Zip -DestinationPath $extracted
    $source = Get-ChildItem $extracted -Directory | Select-Object -First 1
    $destination = Join-Path $env:LOCALAPPDATA 'Programs\ghostty-windows-unofficial'
    & (Join-Path $source.FullName 'install.ps1')

    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ghostty (unofficial Windows build).lnk'
    if (-not (Test-Path $shortcut)) { throw "install.ps1 didn't add the Start menu shortcut" }
    Start-Process $shortcut
    WaitForWindow $destination

    & (Join-Path $destination 'install.ps1') -Uninstall
    if (Test-Path $shortcut) { throw "install.ps1 -Uninstall left the shortcut" }
    if (Test-Path $destination) { throw "install.ps1 -Uninstall left $destination" }
    Write-Host 'Uninstalled.'
}
