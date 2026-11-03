# Checks the unsafe paste dialog: Cancel closes it without pasting, and
# when the shell exits while the dialog is open, Ghostty closes cleanly
# (the dialog's surface is destroyed during its message loop). It posts a
# key bound to paste_from_clipboard to Ghostty's own window, but it sets
# the clipboard and shows dialogs, so it only runs in CI.
#
#     $env:CI = 'true'; ./paste-race.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this sets the clipboard and shows dialogs, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyPasteRace -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
'@
$W = [GhosttyPasteRace.Win32]
$title = 'Warning: Potentially Unsafe Paste'

$script:process = $null
$script:log = $null

function Fail([string]$message) {
    Write-Host "::error title=paste-race::$message"
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

function Dialog {
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

# Start Ghostty running $command, wait for $ready on screen, and paste
# with F7 until the unsafe paste dialog shows.
function StartAndPaste([string]$command, [string]$ready) {
    $script:log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-paste-race-$([guid]::NewGuid()).log"
    $env:GHOSTTY_LOG = 'debug'
    $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $script:log -ArgumentList `
        '--window-save-state=never', '--keybind=f7=paste_from_clipboard', "`"--command=$command`""
    # Keep a handle, so the exit code is still there after it exits.
    [void]$script:process.Handle
    $surface = WaitFor { $s = SurfaceElement; if ($s -and (Text $s).Contains($ready)) { $s } } "'$ready' on screen"
    $hwnd = [IntPtr]$surface.Current.NativeWindowHandle
    [void]$W::PostMessageW($hwnd, 0x0100, [IntPtr]0x76, [IntPtr]0x00410001)   # WM_KEYDOWN F7
    [void]$W::PostMessageW($hwnd, 0x0101, [IntPtr]0x76, [IntPtr]0xC0410001)   # WM_KEYUP F7
    $dialog = WaitFor { Dialog } 'the unsafe paste dialog'
    return @{ Surface = $surface; Dialog = $dialog }
}

function Close {
    if ($script:process -and -not $script:process.HasExited) {
        Stop-Process -Id $script:process.Id -Force -ErrorAction SilentlyContinue
    }
    $script:process = $null
}

# Two lines, so the paste is unsafe (it would run the first one).
Set-Clipboard -Value "echo pasted-one`r`necho pasted-two"

try {
    # Cancel closes the dialog and pastes nothing.
    $started = StartAndPaste 'cmd.exe /k echo ready-%USERNAME:~0,0%ok' 'ready-ok'
    $cancel = $W::FindWindowExW($started.Dialog, [IntPtr]::Zero, 'Button', 'Cancel')
    if ($cancel -eq [IntPtr]::Zero) { Fail "the dialog has no Cancel button" }
    [void]$W::PostMessageW($cancel, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
    [void](WaitFor { -not (Dialog) } 'the dialog to close after Cancel')
    Start-Sleep 1
    if ((Text $started.Surface).Contains('pasted-one')) { Fail "Cancel still pasted" }
    if ($script:process.HasExited) { Fail "Ghostty exited after Cancel" }
    Write-Host 'Cancel closed the unsafe paste dialog without pasting.'
    Close

    # The shell exits while the dialog is open.
    $started = StartAndPaste 'cmd.exe /c echo ready-%USERNAME:~0,0%ok & ping -n 4 127.0.0.1 >nul' 'ready-ok'
    Write-Host 'The dialog is open; waiting for the shell to exit.'
    [void](WaitFor { $script:process.HasExited -or -not (Dialog) } 'the shell to exit and the dialog to go')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $script:process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not $script:process.HasExited) {
        # The window may stay open (for example, waiting after the
        # command), but the dialog must be gone and Ghostty responsive.
        if (Dialog) { Fail "the dialog is still open after the shell exited" }
        if (-not $script:process.Responding) { Fail "Ghostty isn't responding after the shell exited" }
        Write-Host 'The shell exited with the dialog open; the dialog closed and Ghostty still responds.'
    } else {
        $crash = Select-String -Path $script:log -Pattern 'panic|reached unreachable|Segmentation' | Select-Object -First 3
        if ($crash) { Fail "Ghostty crashed after the shell exited: $(($crash | ForEach-Object { $_.Line.Trim() }) -join ' / ')" }
        Write-Host "The shell exited with the dialog open; Ghostty exited cleanly (exit code $($script:process.ExitCode))."
        if ($script:process.ExitCode -ne 0) { Fail "Ghostty exited with code $($script:process.ExitCode)" }
    }
} finally {
    Close
}
