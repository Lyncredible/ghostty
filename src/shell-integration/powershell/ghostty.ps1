# Ghostty shell integration for PowerShell.
#
# This works with Windows PowerShell 5.1 and PowerShell 7+, so it avoids
# syntax that's newer than 5.1 (such as the `e escape).
#
# Ghostty loads this automatically by starting PowerShell with
# `-NoExit -Command`, after the user's profile has run. To load it manually,
# dot-source it from your profile:
#
#     . "$env:GHOSTTY_RESOURCES_DIR\shell-integration\powershell\ghostty.ps1"

if ($global:__GhosttyIntegrated) { return }
$global:__GhosttyIntegrated = $true

$global:__GhosttyFeatures = @(($env:GHOSTTY_SHELL_FEATURES -split ',') | Where-Object { $_ })
$global:__GhosttyOriginalPrompt = $function:prompt

# Whether we've marked the start of a command's output, and the exit
# code of the last native command when it started.
$global:__GhosttyCommandRunning = $false
$global:__GhosttyStartExitCode = $null

# Without PSReadLine we can't see commands start, so we detect them from
# new history entries instead.
# (Test-Path on the Function: drive is slow the first time.)
$global:__GhosttyReadLine = $null -ne ${function:PSConsoleHostReadLine}
$global:__GhosttyLastHistoryId = $null

function global:__GhosttyOsc([string]$value) {
    "$([char]0x1b)]$value$([char]0x07)"
}

function global:__GhosttyHasFeature([string]$name) {
    foreach ($feature in $global:__GhosttyFeatures) {
        if ($feature -eq $name -or $feature.StartsWith("${name}:")) { return $true }
    }
    return $false
}

function global:prompt {
    # These must be read before running anything else.
    $success = $?
    $exitCode = $global:LASTEXITCODE

    # New-Object and regular expressions are slow the first time, which
    # delays the first prompt, so we avoid them here.
    $out = [System.Text.StringBuilder]::new()

    # Report the previous command's result. $? only says whether it
    # failed. $LASTEXITCODE is only set by native commands, so we only use
    # it if it changed while the command ran.
    if (-not $global:__GhosttyReadLine) {
        $last = Get-History -Count 1
        $lastId = 0
        if ($last) { $lastId = $last.Id }
        if ($null -ne $global:__GhosttyLastHistoryId -and
            $lastId -ne $global:__GhosttyLastHistoryId) {
            $global:__GhosttyCommandRunning = $true
        }
        $global:__GhosttyLastHistoryId = $lastId
    }
    if ($global:__GhosttyCommandRunning) {
        $global:__GhosttyCommandRunning = $false
        $code = 0
        if (-not $success) {
            $code = 1
            if ($exitCode -and $exitCode -ne $global:__GhosttyStartExitCode) { $code = $exitCode }
        }
        [void]$out.Append((__GhosttyOsc "133;D;$code"))
    }

    # Report the working directory. kitty-shell-cwd takes the raw path.
    $location = $executionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -eq 'FileSystem') {
        $path = $location.ProviderPath.Replace('\', '/')
        if (-not $path.StartsWith('/')) { $path = "/$path" }
        [void]$out.Append((__GhosttyOsc "7;kitty-shell-cwd://$([Environment]::MachineName)$path"))
    }

    if (__GhosttyHasFeature 'title') {
        [void]$out.Append((__GhosttyOsc "2;$location"))
    }

    [void]$out.Append((__GhosttyOsc "133;A"))

    # Run the original prompt with the previous command's exit code.
    $global:LASTEXITCODE = $exitCode
    if ($global:__GhosttyOriginalPrompt) {
        [void]$out.Append((& $global:__GhosttyOriginalPrompt))
    } else {
        [void]$out.Append("PS $location$('>' * ($nestedPromptLevel + 1)) ")
    }

    # A bar cursor at the prompt, like the other shell integrations.
    if (__GhosttyHasFeature 'cursor') {
        $shape = 5
        if ($global:__GhosttyFeatures -contains 'cursor:steady') { $shape = 6 }
        [void]$out.Append("$([char]0x1b)[$shape q")
    }

    [void]$out.Append((__GhosttyOsc "133;B"))
    $global:LASTEXITCODE = $exitCode
    $out.ToString()
}

# PSReadLine reads the command line through PSConsoleHostReadLine. Wrap it
# to mark the start of the command's output once a line is accepted.
if ($global:__GhosttyReadLine) {
    $global:__GhosttyOriginalReadLine = $function:PSConsoleHostReadLine

    function global:PSConsoleHostReadLine {
        $line = & $global:__GhosttyOriginalReadLine

        # Nothing runs for an empty line.
        if (-not $line -or -not $line.Trim()) { return $line }

        $global:__GhosttyCommandRunning = $true
        $global:__GhosttyStartExitCode = $global:LASTEXITCODE
        $out = ''
        if (__GhosttyHasFeature 'cursor') { $out += "$([char]0x1b)[0 q" }
        if ((__GhosttyHasFeature 'title') -and $line) {
            $out += __GhosttyOsc "2;$($line -replace '[\x00-\x1f]', ' ')"
        }
        $out += __GhosttyOsc "133;C"
        [Console]::Write($out)
        $line
    }
}
