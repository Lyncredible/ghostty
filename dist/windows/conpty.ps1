# Puts conpty.dll and OpenConsole.exe from Microsoft's
# Microsoft.Windows.Console.ConPTY NuGet package (MIT) in a folder. Next to
# ghostty.exe, Ghostty uses them instead of the ConPTY built into Windows
# (see `Conpty` in src/pty.zig). The package version and hash are pinned.
#
#     ./conpty.ps1 -Destination zig-out\bin [-Arch x64|arm64|x86]
#
# Used by package.ps1 -BundleConpty, and by the fork's CI to run tests with
# the package's ConPTY.

param(
    [Parameter(Mandatory)] [string]$Destination,
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"

$conptyVersion = "1.25.260930003"
$conptySha256 = "02B07B349AF66D801159BDF9E440D4A1CE78BB951F37FC8609731665AFDAE7EE"

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ghostty-conpty-$conptyVersion-$PID"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null
try {
    $nupkg = Join-Path $work "conpty.nupkg"
    Invoke-WebRequest -UseBasicParsing -OutFile $nupkg `
        "https://www.nuget.org/api/v2/package/Microsoft.Windows.Console.ConPTY/$conptyVersion"
    $hash = (Get-FileHash $nupkg -Algorithm SHA256).Hash
    if ($hash -ne $conptySha256) { throw "Unexpected ConPTY package hash $hash" }

    $extracted = Join-Path $work "conpty"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extracted)
    New-Item -ItemType Directory -Force $Destination | Out-Null
    Copy-Item (Join-Path $extracted "runtimes\win-$Arch\native\conpty.dll") $Destination
    Copy-Item (Join-Path $extracted "build\native\runtimes\$Arch\OpenConsole.exe") $Destination
    Write-Host "ConPTY $conptyVersion ($Arch) is in $Destination"
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
