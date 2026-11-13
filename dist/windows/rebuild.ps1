# Pull and rebuild this checkout, including the pinned Microsoft ConPTY.
# Run from the checkout root:
#   .\rebuild.cmd
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dist\windows\rebuild.ps1
# Use -SkipPull to rebuild the current checkout, or -ZigPath for a compiler
# outside PATH. Only backup/windows-before-pull-* branches are deleted.
param(
    [string]$ZigPath,
    [switch]$SkipPull
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $args failed (exit $LASTEXITCODE)" }
}

# Resolve an explicit compiler path relative to the caller's directory.
if ($ZigPath) { $ZigPath = (Resolve-Path -LiteralPath $ZigPath).Path }

Push-Location $repo
try {
    # Find the compiler before changing the checkout or installed executable.
    if (-not $ZigPath) {
        $command = Get-Command zig -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { $ZigPath = $command.Source }
    }
    if (-not $ZigPath) { throw 'Zig was not found. Add zig to PATH or supply -ZigPath.' }
    $ZigPath = (Resolve-Path -LiteralPath $ZigPath).Path
    & $ZigPath version
    if ($LASTEXITCODE -ne 0) { throw 'Could not run Zig' }

    if (-not $SkipPull) {
        if ((Invoke-Git branch --show-current) -ne 'windows') {
            throw 'Switch to the windows branch before pulling.'
        }
        # Untracked files can stay in the checkout.
        if (@(Invoke-Git status --porcelain --untracked-files=no).Count) {
            throw 'Commit or stash tracked changes before pulling, or use -SkipPull.'
        }
        $headBefore = Invoke-Git rev-parse HEAD
        $remoteBefore = Invoke-Git rev-parse origin/windows
        Invoke-Git fetch origin
        $remoteAfter = Invoke-Git rev-parse origin/windows
        & git merge-base --is-ancestor HEAD origin/windows
        $ancestorExit = $LASTEXITCODE
        if ($ancestorExit -eq 0) {
            Invoke-Git merge --ff-only origin/windows
        } elseif ($ancestorExit -eq 1 -and $headBefore -eq $remoteBefore -and $remoteAfter -ne $remoteBefore) {
            # The local branch was exactly the previous remote tip. Rebase an
            # empty local range onto the new history, retaining no backup branch.
            Invoke-Git rebase --onto origin/windows $headBefore windows
        } else {
            throw 'Local and remote history diverged with local commits. Resolve it before rebuilding.'
        }
    }

    foreach ($branch in @(Invoke-Git for-each-ref '--format=%(refname:short)' refs/heads)) {
        if ($branch -like 'backup/windows-before-pull-*') {
            Invoke-Git branch -D -- $branch
        }
    }

    # Build into a separate prefix so the current executable stays available
    # throughout compilation, including if compilation fails.
    $cacheRoot = [IO.Path]::GetFullPath((Join-Path $repo '.zig-cache'))
    $stage = Join-Path $cacheRoot ('rebuild-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $stage | Out-Null
    try {
        & $ZigPath build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast --summary failures --prefix $stage
        if ($LASTEXITCODE -ne 0) { throw 'Ghostty build failed' }

        # Reuse the repository's version pin, download and SHA-256 validation.
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'dist\windows\conpty.ps1') -Destination (Join-Path $stage 'bin') -Arch x64
        if ($LASTEXITCODE -ne 0) { throw 'ConPTY bundling failed' }

        $output = Join-Path $repo 'zig-out'
        $bin = Join-Path $output 'bin'
        New-Item -ItemType Directory -Force $bin | Out-Null
        $exe = Join-Path $bin 'ghostty.exe'
        $oldExe = $null
        if (Test-Path -LiteralPath $exe) {
            $newExe = Join-Path $stage 'bin\ghostty.exe'
            $exeChanged = (Get-FileHash -LiteralPath $exe).Hash -ne (Get-FileHash -LiteralPath $newExe).Hash
            $running = @(Get-Process ghostty -ErrorAction SilentlyContinue | Where-Object Path -eq $exe)
            if ($running.Count -and $exeChanged) {
                $oldExe = "$exe.running-$([guid]::NewGuid().ToString('N')).old"
                Move-Item -LiteralPath $exe -Destination $oldExe
            }
        }
        try {
            # Skip identical files, especially DLLs loaded by an open session.
            foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
                $relative = $file.FullName.Substring($stage.Length + 1)
                $destination = Join-Path $output $relative
                if ((Test-Path -LiteralPath $destination) -and
                    (Get-FileHash -LiteralPath $destination).Hash -eq (Get-FileHash -LiteralPath $file.FullName).Hash) {
                    continue
                }
                New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            }
        } catch {
            if ($oldExe -and -not (Test-Path -LiteralPath $exe)) {
                Move-Item -LiteralPath $oldExe -Destination $exe
            }
            throw
        }

        & (Join-Path $bin 'ghostty.com') +version
        if ($LASTEXITCODE -ne 0) { throw 'Ghostty version check failed' }

        # The query test exits its PowerShell process. Run it in a child and
        # hide the temporary test window, leaving the checked-in test intact.
        $querySource = Get-Content -Raw (Join-Path $repo 'test\windows\color-query.ps1')
        $querySource = $querySource.Replace('Start-Process -FilePath $Exe', 'Start-Process -WindowStyle Hidden -FilePath $Exe')
        $queryScript = Join-Path $stage 'color-query.ps1'
        Set-Content -LiteralPath $queryScript -Value $querySource -Encoding utf8
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $queryScript -Exe $exe -TimeoutSeconds 45
        if ($LASTEXITCODE -ne 0) { throw 'ConPTY query checks failed' }

        Invoke-Git for-each-ref '--format=%(refname:short)' refs/heads
        Write-Host "Built $exe with bundled ConPTY."
        if ($oldExe) { Write-Host "Restart Ghostty to use the new build. The running session uses $oldExe" }
    } finally {
        # Restrict recursive cleanup to this invocation's cache directory.
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        if ($resolvedStage.StartsWith($cacheRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
} finally {
    Pop-Location
}
