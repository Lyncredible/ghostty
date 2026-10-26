# Installs (or uninstalls) an unofficial Windows build for the current
# user, without administrator rights: it copies the build to
# %LOCALAPPDATA%\Programs, adds a Start menu shortcut, and registers it in
# Settings > Apps so that it can be uninstalled from there.
#
# Usage, from the extracted zip:
#
#     powershell -ExecutionPolicy Bypass -File install.ps1 [-AddToPath] [-ExplorerMenu]
#     powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# Options:
#
#     -AddToPath    Also add the bin folder to the user's PATH, so that
#                   `ghostty +new-window` and other CLI actions work from
#                   any terminal.
#     -ExplorerMenu Also add "Open in Ghostty (unofficial Windows build)" to the right-click menu of
#                   folders (and of a folder's background) in Explorer.
#     -Uninstall    Remove the installation, shortcut, PATH entry, and the
#                   Settings > Apps entry.
#     -Destination  Where to install (default
#                   %LOCALAPPDATA%\Programs\ghostty-windows-unofficial).

param(
    [switch]$AddToPath,
    [switch]$ExplorerMenu,
    [switch]$Uninstall,
    [string]$Destination = (Join-Path $env:LOCALAPPDATA "Programs\ghostty-windows-unofficial")
)

$ErrorActionPreference = "Stop"

$id = "ghostty-windows-unofficial"
$displayName = "Ghostty (unofficial Windows build)"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$id"
$shortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "$displayName.lnk"
$bin = Join-Path $Destination "bin"

# Explorer's right-click menu for folders and a folder's background.
$explorerKeys = @(
    "HKCU:\Software\Classes\Directory\shell\$id",
    "HKCU:\Software\Classes\Directory\Background\shell\$id"
)

function Remove-FromPath([string]$dir) {
    $path = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $path) { return }
    $parts = $path.Split(";") | Where-Object { $_ -and ($_.TrimEnd("\") -ne $dir.TrimEnd("\")) }
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}

function Test-Running([string]$exe) {
    Get-Process ghostty -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and ($_.Path -ieq $exe) }
}

$exe = Join-Path $bin "ghostty.exe"
if (Test-Running $exe) {
    throw "Ghostty is running from $Destination. Quit it first."
}

if ($Uninstall) {
    if (Test-Path $shortcut) { Remove-Item -Force $shortcut }
    if (Test-Path $uninstallKey) { Remove-Item -Recurse -Force $uninstallKey }
    foreach ($key in $explorerKeys) { if (Test-Path $key) { Remove-Item -Recurse -Force $key } }
    Remove-FromPath $bin
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    Write-Output "Uninstalled $displayName."
    return
}

# The build is next to this script: bin\ghostty.exe and share\.
$source = $PSScriptRoot
if (-not (Test-Path (Join-Path $source "bin\ghostty.exe"))) {
    throw "Run this script from the extracted build, next to bin\ghostty.exe."
}

# Replace an earlier installation.
if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
New-Item -ItemType Directory -Force $Destination | Out-Null
foreach ($item in "bin", "share", "README.txt", "install.ps1") {
    $path = Join-Path $source $item
    if (Test-Path $path) { Copy-Item -Recurse $path $Destination }
}

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $env:USERPROFILE
$link.Description = $displayName
$link.Save()

$version = (Get-Item $exe).VersionInfo.ProductVersion
New-Item -Force $uninstallKey | Out-Null
$script = Join-Path $Destination "install.ps1"
$values = @{
    DisplayName     = $displayName
    DisplayVersion  = if ($version) { $version } else { "" }
    DisplayIcon     = $exe
    InstallLocation = $Destination
    Publisher       = "Unofficial build"
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" -Uninstall -Destination `"$Destination`""
}
foreach ($entry in $values.GetEnumerator()) {
    New-ItemProperty -Force -Path $uninstallKey -Name $entry.Key -Value $entry.Value | Out-Null
}
New-ItemProperty -Force -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord | Out-Null
New-ItemProperty -Force -Path $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord | Out-Null

if ($ExplorerMenu) {
    foreach ($key in $explorerKeys) {
        New-Item -Force "$key\command" | Out-Null
        New-ItemProperty -Force -Path $key -Name "(default)" -Value "Open in $displayName" | Out-Null
        New-ItemProperty -Force -Path $key -Name "Icon" -Value $exe | Out-Null
        # %V is the folder: the clicked one, or the one whose background
        # was clicked.
        New-ItemProperty -Force -Path "$key\command" -Name "(default)" -Value "`"$exe`" `"--working-directory=%V`"" | Out-Null
    }
}

if ($AddToPath) {
    Remove-FromPath $bin
    $path = [Environment]::GetEnvironmentVariable("Path", "User")
    [Environment]::SetEnvironmentVariable("Path", (@($path, $bin) | Where-Object { $_ }) -join ";", "User")
}

Write-Output "Installed $displayName to $Destination."
