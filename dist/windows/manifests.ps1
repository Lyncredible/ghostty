# Writes package manager manifests for a release of the unofficial Windows
# build: a Scoop manifest (installable straight from its URL with
# `scoop install <url>`) and a winget manifest (to validate with
# `winget validate`, install with `winget install --manifest <dir>`, or
# submit to winget-pkgs). Both point at the release's portable zips, by
# their SHA-256.
#
#     ./manifests.ps1 -Dist <folder with the zips> -Version 2026.11.08 `
#         -BaseUrl https://github.com/<owner>/ghostty/releases/download/<tag> `
#         -Repository <owner>/ghostty -OutDir <folder>
#
# The zips are package.ps1's: `ghostty-windows-unofficial-<version>-x86_64.zip`
# and `...-aarch64.zip`, each with one folder holding bin\ghostty.exe (the
# `ghostty` command, which opens a window, as the MSIX's alias does) and
# bin\ghostty-cli.exe (the console launcher, for CLI actions such as
# `ghostty-cli +list-themes`). Either architecture may be missing.

param(
    [Parameter(Mandatory)] [string]$Dist,
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$BaseUrl,
    [Parameter(Mandatory)] [string]$Repository,
    [Parameter(Mandatory)] [string]$OutDir,
    # winget's Publisher.Package identifier.
    [string]$Identifier = "$(($Repository -split '/')[0]).GhosttyWindowsUnofficial"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$homepage = "https://github.com/$Repository"
$description = "Ghostty, a fast, native terminal emulator: an unofficial Windows build, not supported by the Ghostty project."

# The zips, by architecture, with their hash and top folder.
$builds = @()
foreach ($arch in @(@{ Suffix = 'x86_64'; Scoop = '64bit'; Winget = 'x64' }, @{ Suffix = 'aarch64'; Scoop = 'arm64'; Winget = 'arm64' })) {
    $zip = Get-ChildItem -LiteralPath $Dist -Filter "*-$($arch.Suffix).zip" | Select-Object -First 1
    if (-not $zip) { continue }
    $archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        # Compress-Archive in Windows PowerShell writes backslashes.
        $top = ($archive.Entries | ForEach-Object { ($_.FullName -replace '\\', '/').Split('/')[0] } | Select-Object -Unique)
        $names = $archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }
    } finally { $archive.Dispose() }
    if (@($top).Count -ne 1) { throw "$($zip.Name) should have one top folder, not: $($top -join ', ')" }
    foreach ($file in 'bin/ghostty.exe', 'bin/ghostty-cli.exe') {
        if ($names -notcontains "$top/$file") { throw "$($zip.Name) has no $top/$file" }
    }
    $builds += [pscustomobject]@{
        Scoop = $arch.Scoop
        Winget = $arch.Winget
        Url = "$($BaseUrl.TrimEnd('/'))/$($zip.Name)"
        Sha256 = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash
        Top = $top
    }
}
if ($builds.Count -eq 0) { throw "no ghostty-windows-unofficial-*-x86_64.zip or -aarch64.zip in $Dist" }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $false

# Scoop: architecture blocks with each zip's URL, hash and folder; the
# `ghostty` and `ghostty-cli` commands (shims) and a Start menu shortcut.
$architecture = [ordered]@{}
foreach ($b in $builds) {
    $architecture[$b.Scoop] = [ordered]@{ url = $b.Url; hash = $b.Sha256.ToLower(); extract_dir = $b.Top }
}
$scoop = [ordered]@{
    version = $Version
    description = $description
    homepage = $homepage
    license = "MIT"
    architecture = $architecture
    bin = @(@("bin\ghostty.exe", "ghostty"), @("bin\ghostty-cli.exe", "ghostty-cli"))
    shortcuts = @(, @("bin\ghostty.exe", "Ghostty (unofficial)"))
}
$scoopFile = Join-Path $OutDir "ghostty-windows-unofficial.json"
[IO.File]::WriteAllText($scoopFile, ($scoop | ConvertTo-Json -Depth 10), $utf8)

# winget: the version, installer and default locale manifests (schema
# 1.6.0). A zip with portable programs in it: winget extracts the whole
# zip (bin and share) and links `ghostty` and `ghostty-cli` to them.
$wingetDir = Join-Path $OutDir "winget"
New-Item -ItemType Directory -Force $wingetDir | Out-Null
# A YAML string in single quotes, which take anything but doubled quotes.
function Quote([string]$value) { "'" + $value.Replace("'", "''") + "'" }

$header = "# yaml-language-server: `$schema=https://aka.ms/winget-manifest.{0}.1.6.0.schema.json`n"
$common = "PackageIdentifier: $Identifier`nPackageVersion: $Version`n"

$installers = ($builds | ForEach-Object {
    "- Architecture: $($_.Winget)`n  InstallerUrl: $($_.Url)`n  InstallerSha256: $($_.Sha256.ToUpper())`n  NestedInstallerFiles:`n  - RelativeFilePath: $($_.Top)\bin\ghostty.exe`n    PortableCommandAlias: ghostty`n  - RelativeFilePath: $($_.Top)\bin\ghostty-cli.exe`n    PortableCommandAlias: ghostty-cli`n"
}) -join ''
$files = @{
    "$Identifier.yaml" = ($header -f 'version') + $common + "DefaultLocale: en-US`nManifestType: version`nManifestVersion: 1.6.0`n"
    "$Identifier.installer.yaml" = ($header -f 'installer') + $common +
        "InstallerType: zip`nNestedInstallerType: portable`nMinimumOSVersion: 10.0.19041.0`nInstallers:`n" + $installers +
        "ManifestType: installer`nManifestVersion: 1.6.0`n"
    "$Identifier.locale.en-US.yaml" = ($header -f 'defaultLocale') + $common +
        "PackageLocale: en-US`nPublisher: $(Quote (($Repository -split '/')[0]))`nPackageName: $(Quote 'Ghostty (unofficial Windows build)')`n" +
        "PackageUrl: $homepage`nLicense: MIT`nLicenseUrl: $homepage/blob/HEAD/LICENSE`n" +
        "ShortDescription: $(Quote $description)`nMoniker: ghostty-unofficial`nTags:`n- terminal`n- terminal-emulator`n" +
        "ManifestType: defaultLocale`nManifestVersion: 1.6.0`n"
}
foreach ($name in $files.Keys) { [IO.File]::WriteAllText((Join-Path $wingetDir $name), $files[$name], $utf8) }

Write-Host "Scoop manifest: $scoopFile"
Write-Host "winget manifest: $wingetDir ($($builds.Winget -join ', '))"
