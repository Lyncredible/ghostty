# Checks the dialogs that keybindings open: "Close terminal?" (from
# close_surface while a program runs), "Change Terminal Title" (from
# prompt_surface_title) and "Quit Ghostty?" (from quit while a program
# runs), and "Configuration Errors" (from reload_config after the config
# file gained an error). OK in the first closes the terminal, and when the shell exits
# while any of them is open, Ghostty closes cleanly (the
# terminal is destroyed during the dialog's message loop). It posts keys
# to Ghostty's own window, but it shows dialogs, so it only runs in CI.
#
#     $env:CI = 'true'; ./dialog-race.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this shows dialogs, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyDialogRace -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
'@
$W = [GhosttyDialogRace.Win32]

$script:process = $null
$script:log = $null

function Fail([string]$message) {
    Write-Host "::error title=dialog-race::$message"
    Write-Host "--- Ghostty's log ---"
    if ($script:log -and (Test-Path $script:log)) { Get-Content $script:log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$check, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $result = & $check
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what"
}

function Dialog([string]$title) {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, '#32770', $title)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $script:process.Id) { return $h }
    }
}

function SurfaceElement {
    $script:process.Refresh()
    if ($script:process.MainWindowHandle -eq 0) { return }
    [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle).FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))
}

function Text($surface) {
    $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}

# Start Ghostty running $command, wait for its output, press the key
# (F8 closes, F9 asks for a title, F6 quits), and wait for the dialog.
function StartAndPress([string]$command, [int]$vk, [string]$title, [scriptblock]$beforePress) {
    $script:log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-dialog-race-$([guid]::NewGuid()).log"
    $env:GHOSTTY_LOG = 'debug'
    $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $script:log -ArgumentList `
        '--window-save-state=never', '--confirm-close-surface=true', '--keybind=f8=close_surface',
        '--keybind=f9=prompt_surface_title', '--keybind=f6=quit',
        '--keybind=f5=reload_config', "`"--command=$command`""
    # Keep a handle, so the exit code is still there after it exits.
    [void]$script:process.Handle
    $surface = WaitFor { $s = SurfaceElement; if ($s -and (Text $s).Contains('ready-ok')) { $s } } "'ready-ok' on screen"
    $hwnd = [IntPtr]$surface.Current.NativeWindowHandle
    if ($beforePress) { & $beforePress }
    $scan = @{ 0x77 = 0x00420001; 0x78 = 0x00430001; 0x75 = 0x00400001; 0x74 = 0x003F0001 }[$vk]
    [void]$W::PostMessageW($hwnd, 0x0100, [IntPtr]$vk, [IntPtr]$scan)                  # WM_KEYDOWN
    [void]$W::PostMessageW($hwnd, 0x0101, [IntPtr]$vk, [IntPtr]($scan -bor 0xC0000000)) # WM_KEYUP
    return WaitFor { Dialog $title } "the '$title' dialog"
}

# Wait for the shell to exit with the dialog open, and check that Ghostty
# exited cleanly, or still responds with the dialog gone.
function CheckShellExit([string]$title) {
    Write-Host "The '$title' dialog is open; waiting for the shell to exit."
    [void](WaitFor { $script:process.HasExited -or -not (Dialog $title) } 'the shell to exit and the dialog to go')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $script:process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not $script:process.HasExited) {
        if (Dialog $title) { Fail "the '$title' dialog is still open after the shell exited" }
        if (-not $script:process.Responding) { Fail "Ghostty isn't responding after the shell exited ('$title')" }
        Write-Host "The shell exited with '$title' open; the dialog closed and Ghostty still responds."
        return
    }
    $crash = Select-String -Path $script:log -Pattern 'panic|reached unreachable|Segmentation' | Select-Object -First 3
    if ($crash) { Fail "Ghostty crashed after the shell exited with '$title' open: $(($crash | ForEach-Object { $_.Line.Trim() }) -join ' / ')" }
    if ($script:process.ExitCode -ne 0) { Fail "Ghostty exited with code $($script:process.ExitCode) after the shell exited with '$title' open" }
    Write-Host "The shell exited with '$title' open; Ghostty exited cleanly."
}

function Close {
    if ($script:process -and -not $script:process.HasExited) {
        Stop-Process -Id $script:process.Id -Force -ErrorAction SilentlyContinue
    }
    $script:process = $null
}

$long = 'cmd.exe /c echo ready-%USERNAME:~0,0%ok & ping -n 60 127.0.0.1 >nul'
$short = 'cmd.exe /c echo ready-%USERNAME:~0,0%ok & ping -n 4 127.0.0.1 >nul'
$closeTitle = 'Close terminal?'
$titleTitle = 'Change Terminal Title'
$quitTitle = 'Quit Ghostty?'
$errorsTitle = 'Configuration Errors'

# A config of our own, which starts out without errors.
$configHome = Join-Path ([IO.Path]::GetTempPath()) "ghostty-dialog-race-$([guid]::NewGuid())"
$configFile = Join-Path $configHome 'ghostty\config.ghostty'
New-Item -ItemType Directory (Split-Path $configFile) | Out-Null
Set-Content -LiteralPath $configFile '# no errors yet'
$env:XDG_CONFIG_HOME = $configHome

try {
    # OK closes the terminal.
    $dialog = StartAndPress $long 0x77 $closeTitle
    $ok = $W::FindWindowExW($dialog, [IntPtr]::Zero, 'Button', 'OK')
    if ($ok -eq [IntPtr]::Zero) { Fail "the close dialog has no OK button" }
    [void]$W::PostMessageW($ok, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
    [void](WaitFor { $script:process.HasExited -or -not (SurfaceElement) } 'the terminal to close after OK')
    Write-Host 'OK in "Close terminal?" closed the terminal.'
    Close

    # The shell exits while each dialog is open.
    [void](StartAndPress $short 0x77 $closeTitle)
    CheckShellExit $closeTitle
    Close

    [void](StartAndPress $short 0x78 $titleTitle)
    CheckShellExit $titleTitle
    Close

    [void](StartAndPress $short 0x75 $quitTitle)
    CheckShellExit $quitTitle
    Close

    [void](StartAndPress $short 0x74 $errorsTitle { Set-Content -LiteralPath $configFile 'not-a-real-option = 1' })
    CheckShellExit $errorsTitle
} finally {
    Close
    Remove-Item -LiteralPath $configHome -Recurse -Force -ErrorAction SilentlyContinue
}
