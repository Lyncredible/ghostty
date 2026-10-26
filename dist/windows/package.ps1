# Builds a portable zip of the Windows port: ghostty.exe and its resources
# (themes and shell integration), which it finds relative to the executable.
#
# These are unofficial builds of the windows branch, so the archive is
# named as such.
#
# Usage (from the repository root):
#
#     powershell -ExecutionPolicy Bypass -File dist\windows\package.ps1
#
# Options:
#
#     -Target    Zig target (default x86_64-windows-gnu, which needs only Zig)
#     -Optimize  Zig optimize mode (default ReleaseSafe; ReleaseFast fails
#                with the GNU ABI in Zig 0.17, see WINDOWS.md)
#     -OutDir    Where to put the zip (default zig-out\dist)
#     -BundleConpty
#                Include conpty.dll and OpenConsole.exe from Microsoft's
#                Microsoft.Windows.Console.ConPTY NuGet package (MIT), which
#                ghostty.exe uses instead of the ConPTY built into Windows
#                when they're next to it. The package version and hash are
#                pinned below.

param(
    [string]$Target = "x86_64-windows-gnu",
    [string]$Optimize = "ReleaseSafe",
    [string]$OutDir = "zig-out\dist",
    [switch]$BundleConpty
)

$conptyVersion = "1.25.260930003"
$conptySha256 = "02B07B349AF66D801159BDF9E440D4A1CE78BB951F37FC8609731665AFDAE7EE"

$ErrorActionPreference = "Stop"

$version = (git describe --tags --always --dirty).Trim()
$name = "ghostty-windows-unofficial-$version-$($Target.Split('-')[0])"
$staging = Join-Path ([System.IO.Path]::GetTempPath()) $name
$prefix = Join-Path $staging "build"

if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force $staging | Out-Null

zig build "-Dtarget=$Target" "-Doptimize=$Optimize" --prefix $prefix
if ($LASTEXITCODE -ne 0) { throw "zig build failed" }

# The app only needs the executable and its resources, not the
# libghostty-vt library and headers that the build also installs.
$package = Join-Path $staging $name
New-Item -ItemType Directory -Force (Join-Path $package "bin") | Out-Null
Copy-Item (Join-Path $prefix "bin\ghostty.exe") (Join-Path $package "bin")
Copy-Item -Recurse (Join-Path $prefix "share") $package
Copy-Item (Join-Path $PSScriptRoot "install.ps1") $package

if ($BundleConpty) {
    $arch = switch ($Target.Split('-')[0]) {
        "x86_64" { "x64" }
        "aarch64" { "arm64" }
        "x86" { "x86" }
        default { throw "No ConPTY package build for $Target" }
    }
    $nupkg = Join-Path $staging "conpty.nupkg"
    Invoke-WebRequest -UseBasicParsing -OutFile $nupkg `
        "https://www.nuget.org/api/v2/package/Microsoft.Windows.Console.ConPTY/$conptyVersion"
    $hash = (Get-FileHash $nupkg -Algorithm SHA256).Hash
    if ($hash -ne $conptySha256) { throw "Unexpected ConPTY package hash $hash" }

    $extracted = Join-Path $staging "conpty"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extracted)
    Copy-Item (Join-Path $extracted "runtimes\win-$arch\native\conpty.dll") (Join-Path $package "bin")
    Copy-Item (Join-Path $extracted "build\native\runtimes\$arch\OpenConsole.exe") (Join-Path $package "bin")
}

@"
This is an unofficial build of the Windows port on the windows branch.
It isn't supported by the Ghostty project.

Run bin\ghostty.exe from this folder, or install it for the current user
(Start menu shortcut, and uninstall from Settings > Apps):

    powershell -ExecutionPolicy Bypass -File install.ps1 [-AddToPath] [-ExplorerMenu]
"@ | Set-Content -Encoding utf8 (Join-Path $package "README.txt")

New-Item -ItemType Directory -Force $OutDir | Out-Null
$zip = Join-Path (Resolve-Path $OutDir) "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $package -DestinationPath $zip
Remove-Item -Recurse -Force $staging

Write-Output $zip
