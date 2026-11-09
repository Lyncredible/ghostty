# Checks the CLI actions that talk to a running Ghostty: `+new-tab` adds a
# tab to its window and `+new-window` opens another window, through the
# console launcher (ghostty.com) with the instance's `--class`. Then
# `+new-tab --title=... -e cmd.exe ...` must open a tab with that title,
# running that command, which last after the request's memory is freed.
# Tabs and windows are counted with UI Automation, so it runs on a locked
# desktop.
#
#     ./cli-ipc.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$cli = Join-Path (Split-Path $Exe) 'ghostty.com'
$class = "com.example.ghostty-cli-ipc-$PID"
$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-cli-ipc-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList "--class=$class",
    '--window-save-state=never', '--command=cmd.exe', '--confirm-close-surface=false'

function Fail([string]$message) {
    Write-Host "::error title=cli-ipc::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

$AE = [System.Windows.Automation.AutomationElement]
# The instance's windows and tabs (tab bar items), as "windows/tabs".
function Count {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $process.Id)
    $windows = @($AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition))
    $tabs = 0
    foreach ($window in $windows) {
        $tabs += @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)))).Count
    }
    "$($windows.Count)/$tabs"
}

function WaitFor([string]$expected, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $script:count = Count
        if ($count -eq $expected) { return }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what (windows/tabs: $count, wanted $expected)"
}

function Run([string]$action, [string[]]$arguments = @()) {
    $out = & $cli $action "--class=$class" @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$action exited with $LASTEXITCODE`: $out" }
}

# The names of the instance's tabs.
function TabNames {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $process.Id)
    foreach ($window in @($AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition))) {
        foreach ($tab in @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem))))) {
            $tab.Current.Name
        }
    }
}

try {
    WaitFor '1/1' 'the first window'
    Run '+new-tab'
    WaitFor '1/2' '+new-tab to add a tab'
    Write-Host '+new-tab added a tab to the window.'
    Run '+new-window'
    WaitFor '2/3' '+new-window to open a window'
    Write-Host '+new-window opened a second window.'

    # Overrides: a title and a command. They're parsed into memory that's
    # freed once the request is handled, so a tab that kept pointing into
    # it would show garbage (Debug builds overwrite freed memory) or crash.
    Run '+new-tab' @('--title=IPC override title', '-e', 'cmd.exe', '/k', 'echo IPC-OVERRIDE-MARKER')
    WaitFor '2/4' '+new-tab with overrides to add a tab'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and (TabNames) -notcontains 'IPC override title') { Start-Sleep -Milliseconds 250 }
    if ((TabNames) -notcontains 'IPC override title') { Fail "no tab is titled 'IPC override title': $((TabNames) -join ', ')" }
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'GhosttySurface')
    $marker = $false
    while ((Get-Date) -lt $deadline -and -not $marker) {
        foreach ($s in @($AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))) {
            if ($s.Current.ProcessId -ne $process.Id) { continue }
            $value = $s.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
            if ($value -match 'IPC-OVERRIDE-MARKER') { $marker = $true }
        }
        if (-not $marker) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $marker) { Fail "the tab's command didn't print its marker" }
    Start-Sleep -Seconds 1
    if ((TabNames) -notcontains 'IPC override title') { Fail "the override title didn't last: $((TabNames) -join ', ')" }
    Write-Host "+new-tab with --title and -e opened a tab titled 'IPC override title' running the command."
    if ($process.HasExited) { Fail "Ghostty exited" }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
