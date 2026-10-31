# An end-to-end check of the Windows app, for CI: start Ghostty with a
# shell, wait for its prompt (read through UI Automation), type `cd` to a
# directory, and check from Ghostty's debug log that shell integration
# was injected and the terminal's pwd followed.
#
#     ./smoke.ps1 -Exe zig-out/bin/ghostty.exe -Command pwsh -Prompt 'PS '
#
# It needs a debug build (for the debug log) and a desktop session. It
# types by posting messages to Ghostty's window, so it doesn't need focus.

param(
    [Parameter(Mandatory)] [string]$Exe,
    [string]$Command = 'pwsh.exe -NoLogo -NoProfile',
    [string]$Prompt = 'PS ',
    [string]$Directory = $env:SystemRoot,
    # cmd needs `cd /d` to change drives.
    [string]$Cd = 'cd',
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttySmoke -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
'@

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-smoke-$PID.log"
$env:GHOSTTY_LOG = 'debug'
# Start-Process joins its arguments without quoting them, so quote the
# command (escaping its own quotes) for the Windows command line.
$commandArg = '"--command=' + $Command.Replace('"', '\"') + '"'
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log `
    -ArgumentList $commandArg, '--window-save-state=never'

function Fail([string]$message) {
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 60 | Write-Host }
    throw $message
}

# The terminal surface's text, from UI Automation, or $null.
function SurfaceText {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        $surfaces = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))
        foreach ($surface in $surfaces) {
            $pattern = $null
            if ($surface.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                return @{ Handle = [IntPtr]$surface.Current.NativeWindowHandle; Text = $pattern.Current.Value }
            }
        }
    }
    return $null
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited (code $($process.ExitCode)) while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what"
}

try {
    $surface = WaitFor {
        $s = SurfaceText
        if ($s -and $s.Text.Contains($Prompt)) { $s }
    } "the prompt ($Prompt)"
    Write-Host "The prompt appeared:"
    Write-Host (($surface.Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join "`n")

    foreach ($ch in "$Cd `"$Directory`"".ToCharArray()) {
        [void][GhosttySmoke.Win32]::SendMessageW($surface.Handle, 0x0102, [IntPtr][int]$ch, [IntPtr]1) # WM_CHAR
    }
    [void][GhosttySmoke.Win32]::PostMessageW($surface.Handle, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001) # WM_KEYDOWN Enter
    [void][GhosttySmoke.Win32]::PostMessageW($surface.Handle, 0x0101, [IntPtr]0x0D, [IntPtr]0xC01C0001) # WM_KEYUP

    $escaped = [regex]::Escape("terminal pwd: $Directory")
    [void](WaitFor { Select-String -Path $log -Pattern "$escaped\s*$" -Quiet } "the pwd to become $Directory")
    if (-not (Select-String -Path $log -Pattern 'shell integration automatically injected' -Quiet)) {
        Fail "shell integration wasn't injected"
    }
    Write-Host "Shell integration was injected and the pwd followed cd to $Directory."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
