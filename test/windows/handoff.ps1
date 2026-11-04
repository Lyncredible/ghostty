# Checks that a running Ghostty takes console sessions handed to it, as
# Windows' console host does when Ghostty is the default terminal
# application: `handoff_client.c` creates a pseudoconsole running cmd and
# hands it to Ghostty's terminal handoff class, and a new Ghostty window
# must show cmd's output and pass typed input back to it. It needs Windows
# Terminal installed (for the interface's proxy), but it doesn't change
# the default terminal or send input outside Ghostty, so it can run
# locally.
#
#     ./handoff.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if (-not (Get-AppxPackage Microsoft.WindowsTerminal)) {
    Write-Host "::notice title=handoff::Windows Terminal isn't installed, so there's no proxy for the handoff interface; skipped"
    exit 0
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyHandoff -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint flags);
'@

$work = Join-Path ([IO.Path]::GetTempPath()) "ghostty-handoff-$([guid]::NewGuid())"
New-Item -ItemType Directory $work | Out-Null
$client = Join-Path $work 'handoff_client.exe'
& zig cc (Join-Path $PSScriptRoot 'handoff_client.c') -o $client -target x86_64-windows-gnu -lole32 -loleaut32
if ($LASTEXITCODE -ne 0) { throw "couldn't build handoff_client.c" }

$log = Join-Path $work 'ghostty.log'
$clientLog = Join-Path $work 'client.log'
$ghostty = $null
$handoff = $null

function Fail([string]$message) {
    Write-Host "::error title=handoff::$message"
    Write-Host '--- handoff_client ---'
    if (Test-Path $clientLog) { Get-Content $clientLog | Write-Host }
    if (Test-Path "$clientLog.err") { Get-Content "$clientLog.err" | Write-Host }
    try { foreach ($s in Surfaces) { Write-Host "--- a terminal shows ---"; Write-Host $s.Text.Trim() } } catch {}
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
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

# The text of each of Ghostty's terminals, with its window handle.
function Surfaces {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ghostty.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
            @{
                Handle = [IntPtr]$surface.Current.NativeWindowHandle
                Text = $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
            }
        }
    }
}

# Type into the handed off session's terminal.
function TypeText([string]$text) {
    foreach ($ch in $text.ToCharArray()) {
        [void][GhosttyHandoff.Win32]::PostMessageW($surface.Handle, 0x0102, [IntPtr][int]$ch, [IntPtr]1)   # WM_CHAR
    }
}

try {
    # A class of our own, so that this doesn't go to another running
    # Ghostty as a new window.
    $env:GHOSTTY_LOG = 'debug'
    $ghostty = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList `
        '--window-save-state=never', '--class=com.example.ghostty-handoff-test', '"--command=cmd.exe /k echo first-%USERNAME:~0,0%window"'
    [void](WaitFor { Surfaces | Where-Object { $_.Text.Contains('first-window') } } "Ghostty's first window")
    [void](WaitFor { Select-String -Path $log -Pattern 'registered the terminal handoff class' -Quiet } 'the handoff class to be registered')

    $handoff = Start-Process -FilePath $client -PassThru -NoNewWindow -RedirectStandardOutput $clientLog `
        -RedirectStandardError "$clientLog.err" -ArgumentList '"cmd.exe /k echo handoff-%USERNAME:~0,0%ok"', ($TimeoutSeconds * 2)
    $surface = WaitFor {
        if ($handoff.HasExited) { Fail "handoff_client exited with $($handoff.ExitCode)" }
        Surfaces | Where-Object { $_.Text.Contains('handoff-ok') } | Select-Object -First 1
    } "the handed off session's output in a Ghostty window"
    Write-Host 'A new Ghostty window shows the handed off cmd.'

    # Typing goes back through the handed off pipes.
    TypeText "echo typed-%USERNAME:~0,0%back`r"
    [void](WaitFor { Surfaces | Where-Object { $_.Handle -eq $surface.Handle -and $_.Text.Contains('typed-back') } } 'typed input to reach the handed off cmd')
    Write-Host 'Typing in it reached cmd.'

    # Resizing the window resizes the console (through its signal pipe),
    # as `mode con` in it shows.
    function Columns {
        param([string]$marker)
        TypeText "cls & echo $marker-%USERNAME:~0,0%cols & mode con`r"
        $text = WaitFor { Surfaces | Where-Object { $_.Handle -eq $surface.Handle -and $_.Text -match "$marker-cols[\s\S]*Columns:\s+(\d+)" } } "cmd's columns ($marker)"
        [void]($text.Text -match "$marker-cols[\s\S]*Columns:\s+(\d+)")
        [int]$Matches[1]
    }
    $top = [GhosttyHandoff.Win32]::GetAncestor($surface.Handle, 2)   # GA_ROOT
    [void][GhosttyHandoff.Win32]::SetWindowPos($top, [IntPtr]::Zero, 0, 0, 900, 600, 0x16)   # SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE
    $wide = Columns 'wide'
    [void][GhosttyHandoff.Win32]::SetWindowPos($top, [IntPtr]::Zero, 0, 0, 500, 600, 0x16)
    $narrow = Columns 'narrow'
    if ($narrow -ge $wide) { Fail "resizing the window didn't resize the console: $wide columns, then $narrow" }
    Write-Host "Resizing the window resized the console ($wide columns, then $narrow)."

    # When the program exits, its window closes, and Ghostty keeps running
    # with its first window.
    TypeText "exit`r"
    [void](WaitFor { -not (Surfaces | Where-Object { $_.Handle -eq $surface.Handle }) } "the handed off session's window to close")
    if ($ghostty.HasExited) { Fail "Ghostty exited after the handed off session ended" }
    $crash = Select-String -Path $log -Pattern 'panic|reached unreachable' | Select-Object -First 3
    if ($crash) { Fail "Ghostty crashed: $(($crash | ForEach-Object { $_.Line.Trim() }) -join ' / ')" }
    if (-not (Surfaces | Where-Object { $_.Text.Contains('first-window') })) { Fail "Ghostty's first window went away" }
    Write-Host 'When cmd exited, its window closed, and the first window stayed.'

    # A program that asks to start minimized (SW_SHOWMINNOACTIVE) gets a
    # minimized window.
    $handoff = Start-Process -FilePath $client -PassThru -NoNewWindow -RedirectStandardOutput $clientLog `
        -RedirectStandardError "$clientLog.err" -ArgumentList '"cmd.exe /k echo minimized-%USERNAME:~0,0%ok"', ($TimeoutSeconds * 2), 'handoff', 7
    $surface = WaitFor {
        if ($handoff.HasExited) { Fail "handoff_client exited with $($handoff.ExitCode)" }
        Surfaces | Where-Object { $_.Text.Contains('minimized-ok') } | Select-Object -First 1
    } "the minimized session's output in a Ghostty window"
    if (-not [GhosttyHandoff.Win32]::IsIconic([GhosttyHandoff.Win32]::GetAncestor($surface.Handle, 2))) {   # GA_ROOT
        Fail "the window of a session that asked to start minimized isn't minimized"
    }
    Write-Host 'A session that asked to start minimized got a minimized window.'
} finally {
    if ($handoff -and -not $handoff.HasExited) { Stop-Process -Id $handoff.Id -Force -ErrorAction SilentlyContinue }
    if ($ghostty -and -not $ghostty.HasExited) { Stop-Process -Id $ghostty.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
