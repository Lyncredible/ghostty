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
#     -Msix      Also build an unsigned MSIX package of the build, next to
#                the zip, with dist\windows\msix.zig (which uses the
#                packaging API built into Windows). Windows 11 installs
#                unsigned packages with
#                `Add-AppxPackage -AllowUnsigned <file>`.

param(
    [string]$Target = "x86_64-windows-gnu",
    [string]$Optimize = "ReleaseSafe",
    [string]$OutDir = "zig-out\dist",
    [switch]$BundleConpty,
    [switch]$Msix
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

if ($Msix) {
    $layout = Join-Path $staging "msix"
    New-Item -ItemType Directory -Force $layout | Out-Null
    Copy-Item -Recurse (Join-Path $package "bin"), (Join-Path $package "share"), (Join-Path $package "README.txt") $layout

    # Logos, from the executable's icon.
    $assets = Join-Path $layout "Assets"
    New-Item -ItemType Directory -Force $assets | Out-Null
    Add-Type -AssemblyName System.Drawing
    $icon = New-Object System.Drawing.Icon (Join-Path $PSScriptRoot "ghostty.ico"), 256, 256
    $source = $icon.ToBitmap()
    foreach ($logo in @(@("Square44x44Logo.png", 44), @("StoreLogo.png", 50), @("Square150x150Logo.png", 150))) {
        $bitmap = New-Object System.Drawing.Bitmap $logo[1], $logo[1]
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($source, 0, 0, $logo[1], $logo[1])
        $graphics.Dispose()
        $bitmap.Save((Join-Path $assets $logo[0]), [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
    }

    # MSIX versions are four numbers up to 65535.
    $commits = [int](git rev-list --count HEAD)
    $msixVersion = "1.0.$($commits % 65535).0"
    $msixArch = switch ($Target.Split('-')[0]) { "x86_64" { "x64" } "aarch64" { "arm64" } "x86" { "x86" } default { "neutral" } }

    # The publisher's OID marks the package as unsigned, which Windows 11
    # allows installing with -AllowUnsigned.
    @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         IgnorableNamespaces="uap uap5 rescap">
  <Identity Name="GhosttyWindowsUnofficial"
            Publisher="CN=Unofficial Build, OID.2.25.311729368913984317654407730594956997722=1"
            Version="$msixVersion"
            ProcessorArchitecture="$msixArch" />
  <Properties>
    <DisplayName>Ghostty (unofficial Windows build)</DisplayName>
    <PublisherDisplayName>Unofficial build</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
  <Applications>
    <Application Id="App" Executable="bin\ghostty.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="Ghostty (unofficial Windows build)"
                          Description="An unofficial build of the Windows port of Ghostty."
                          BackgroundColor="transparent"
                          Square150x150Logo="Assets\Square150x150Logo.png"
                          Square44x44Logo="Assets\Square44x44Logo.png" />
      <Extensions>
        <uap5:Extension Category="windows.appExecutionAlias">
          <uap5:AppExecutionAlias>
            <uap5:ExecutionAlias Alias="ghostty.exe" />
          </uap5:AppExecutionAlias>
        </uap5:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
"@ | Set-Content -Encoding utf8 (Join-Path $layout "AppxManifest.xml")

    $msixFile = Join-Path (Resolve-Path $OutDir) "$name.msix"
    if (Test-Path $msixFile) { Remove-Item -Force $msixFile }
    $tool = Join-Path $PSScriptRoot "msix.zig"
    # The tool reports on stderr, which Windows PowerShell would otherwise
    # treat as an error.
    $ErrorActionPreference = "Continue"
    zig run $tool -lc -lole32 -lshlwapi -lurlmon -- pack $layout $msixFile 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "creating the MSIX package failed" }
    zig run $tool -lc -lole32 -lshlwapi -lurlmon -- check $msixFile 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "the MSIX package is invalid" }
    $ErrorActionPreference = "Stop"
    Write-Output $msixFile
}

Remove-Item -Recurse -Force $staging

Write-Output $zip
