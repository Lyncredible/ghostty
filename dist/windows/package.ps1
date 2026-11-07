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
#                pinned in conpty.ps1.
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
# The console launcher that shells run for `ghostty` (see
# src/main_windows_launcher.zig).
Copy-Item (Join-Path $prefix "bin\ghostty.com") (Join-Path $package "bin")
Copy-Item -Recurse (Join-Path $prefix "share") $package
Copy-Item (Join-Path $PSScriptRoot "install.ps1") $package

if ($BundleConpty) {
    $arch = switch ($Target.Split('-')[0]) {
        "x86_64" { "x64" }
        "aarch64" { "arm64" }
        "x86" { "x86" }
        default { throw "No ConPTY package build for $Target" }
    }
    & (Join-Path $PSScriptRoot "conpty.ps1") -Destination (Join-Path $package "bin") -Arch $arch
}

@"
This is an unofficial build of the Windows port on the windows branch.
It isn't supported by the Ghostty project.

Run bin\ghostty.exe from this folder, or install it for the current user
(Start menu shortcut, and uninstall from Settings > Apps):

    powershell -ExecutionPolicy Bypass -File install.ps1 [-AddToPath] [-ExplorerMenu]

From a shell, "ghostty" runs bin\ghostty.com, which waits for CLI actions
such as "ghostty +list-themes" and opens a window otherwise.
"@ | Set-Content -Encoding utf8 (Join-Path $package "README.txt")

New-Item -ItemType Directory -Force $OutDir | Out-Null
$zip = Join-Path (Resolve-Path $OutDir) "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $package -DestinationPath $zip

if ($Msix) {
    $layout = Join-Path $staging "msix"
    New-Item -ItemType Directory -Force $layout | Out-Null
    Copy-Item -Recurse (Join-Path $package "bin"), (Join-Path $package "share"), (Join-Path $package "README.txt") $layout
    # Packaged applications and their aliases must be .exe files, so the
    # console launcher (ghostty.com) is also bin\ghostty-cli.exe here.
    Copy-Item (Join-Path $package "bin\ghostty.com") (Join-Path $layout "bin\ghostty-cli.exe")

    # The app extensions' public folder (for the default terminal
    # application), which they must name. Empty folders aren't packed.
    $public = Join-Path $layout "Public"
    New-Item -ItemType Directory -Force $public | Out-Null
    Set-Content -LiteralPath (Join-Path $public "README.txt") "Ghostty's terminal handoff (Windows' default terminal application)."

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
         xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3"
         xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5"
         xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         IgnorableNamespaces="uap uap3 uap5 com rescap">
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
        <!-- Windows' default terminal application (Windows 11): console
             sessions are handed to our class (apprt/win32/Handoff.zig)
             by Windows Terminal's OpenConsole, through its proxy. -->
        <com:Extension Category="windows.comServer">
          <com:ComServer>
            <com:ExeServer DisplayName="Ghostty terminal handoff" Executable="bin\ghostty.exe">
              <com:Class Id="7EC9F94F-09DD-4C7F-A79B-57532EBAFCDD" />
            </com:ExeServer>
          </com:ComServer>
        </com:Extension>
        <uap3:Extension Category="windows.appExtension">
          <uap3:AppExtension Name="com.microsoft.windows.terminal.host" Id="Terminal"
                             DisplayName="Ghostty (unofficial Windows build)" PublicFolder="Public">
            <uap3:Properties>
              <Clsid>{7EC9F94F-09DD-4C7F-A79B-57532EBAFCDD}</Clsid>
            </uap3:Properties>
          </uap3:AppExtension>
        </uap3:Extension>
        <uap3:Extension Category="windows.appExtension">
          <uap3:AppExtension Name="com.microsoft.windows.console.host" Id="OpenConsole"
                             DisplayName="Windows Terminal's OpenConsole" PublicFolder="Public">
            <uap3:Properties>
              <Clsid>{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}</Clsid>
            </uap3:Properties>
          </uap3:AppExtension>
        </uap3:Extension>
      </Extensions>
    </Application>
    <Application Id="Cli" Executable="bin\ghostty-cli.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="Ghostty CLI (unofficial Windows build)"
                          Description="Runs Ghostty's CLI actions from a shell, such as ghostty-cli +list-themes."
                          BackgroundColor="transparent"
                          AppListEntry="none"
                          Square150x150Logo="Assets\Square150x150Logo.png"
                          Square44x44Logo="Assets\Square44x44Logo.png" />
      <Extensions>
        <uap5:Extension Category="windows.appExecutionAlias">
          <uap5:AppExecutionAlias>
            <uap5:ExecutionAlias Alias="ghostty-cli.exe" />
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
