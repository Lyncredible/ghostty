# Checks that the bell flashes the taskbar button, as `bell-features`
# says: when Ghostty is in the background with `attention` it flashes, in
# the foreground it doesn't, and with `no-attention` it doesn't. A window
# of its own registers as a shell hook window, which Windows tells about
# each flash (HSHELL_FLASH). It changes the foreground window and flashes
# the taskbar, so it only runs in CI.
#
#     ./bell-flash.ps1 -Exe zig-out/bin/ghostty.exe
#
# Run it with Windows PowerShell (for Windows Forms).

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this changes the foreground window and flashes the taskbar, so it only runs in CI" }

Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class GhosttyFlashWatcher : Form {
    [DllImport("user32.dll")] static extern bool RegisterShellHookWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool DeregisterShellHookWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessageW(string s);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);

    uint shellMessage;
    // The windows that flashed, in order.
    public List<long> Flashes = new List<long>();

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        shellMessage = RegisterWindowMessageW("SHELLHOOK");
        RegisterShellHookWindow(Handle);
    }

    protected override void OnHandleDestroyed(EventArgs e) {
        DeregisterShellHookWindow(Handle);
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message m) {
        // HSHELL_FLASH is HSHELL_REDRAW with HSHELL_HIGHBIT.
        if (shellMessage != 0 && (uint)m.Msg == shellMessage && ((long)m.WParam & 0xFFFF) == 0x8006) {
            Flashes.Add((long)m.LParam);
        }
        base.WndProc(ref m);
    }

    // Bring a window to the front. Windows only lets the foreground
    // window's thread do that, so join its input first.
    public static bool Activate(IntPtr h) {
        IntPtr fg = GetForegroundWindow();
        uint ours = GetCurrentThreadId();
        uint theirs = GetWindowThreadProcessId(fg, IntPtr.Zero);
        if (theirs != 0 && theirs != ours) AttachThreadInput(ours, theirs, true);
        SetForegroundWindow(h);
        if (theirs != 0 && theirs != ours) AttachThreadInput(ours, theirs, false);
        return GetForegroundWindow() == h;
    }
}
'@

$dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-bell-$([guid]::NewGuid())"
New-Item -ItemType Directory $dir | Out-Null
# Rings the bell once for each file named ring1, ring2, ... that appears.
$ring = Join-Path $dir 'ring.ps1'
Set-Content -LiteralPath $ring @'
param([string]$Dir)
Write-Host 'bell-ready'
for ($i = 1; ; $i++) {
    while (-not (Test-Path (Join-Path $Dir "ring$i"))) { Start-Sleep -Milliseconds 100 }
    [Console]::Write([char]7)
    Write-Host "rang-$i"
}
'@

$watcher = New-Object GhosttyFlashWatcher
$watcher.Text = 'Ghostty bell test'
$watcher.StartPosition = 'Manual'
$watcher.Location = New-Object System.Drawing.Point(0, 0)
$watcher.Size = New-Object System.Drawing.Size(200, 150)
$watcher.Show()

$script:process = $null

function Fail([string]$message) {
    Write-Host "::error title=bell-flash::$message"
    throw $message
}

function Pump([int]$milliseconds) {
    $deadline = (Get-Date).AddMilliseconds($milliseconds)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
}

function WaitFor([scriptblock]$check, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($script:process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $check
        if ($result) { return $result }
        Pump 200
    }
    Fail "timed out waiting for $what"
}

function SurfaceText {
    $script:process.Refresh()
    if ($script:process.MainWindowHandle -eq 0) { return }
    $surface = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle).FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))
    if ($surface) { $(try { $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' }) }
}

# Start Ghostty and return its top-level window once the script is ready.
function StartGhostty([string]$features) {
    $script:rings = 0
    Get-ChildItem -LiteralPath $dir -Filter 'ring?*' | Where-Object Name -ne 'ring.ps1' | Remove-Item
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ring`" -Dir `"$dir`""
    $script:process = Start-Process -FilePath $Exe -PassThru -ArgumentList `
        '--window-save-state=never', "--bell-features=$features", "`"--command=$command`""
    [void](WaitFor { (SurfaceText) -match 'bell-ready' } 'the bell script to start')
    return [IntPtr]$script:process.MainWindowHandle
}

# Ring the bell and return the windows that flashed in the next seconds.
function Ring {
    $script:rings++
    $watcher.Flashes.Clear()
    New-Item -ItemType File (Join-Path $dir "ring$($script:rings)") | Out-Null
    [void](WaitFor { (SurfaceText) -match "rang-$($script:rings)" } "bell $($script:rings) to ring")
    Pump 3000
    return @($watcher.Flashes)
}

function Close {
    if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
    $script:process = $null
}

try {
    # In the background, the bell flashes the taskbar button.
    $window = StartGhostty 'attention,no-title,no-border'
    if (-not [GhosttyFlashWatcher]::Activate($watcher.Handle)) { Fail "couldn't bring the test's window to the front" }
    $flashes = Ring
    if ($flashes -notcontains [long]$window) {
        Fail "the bell didn't flash Ghostty's taskbar button from the background (flashes: $($flashes -join ', '); window: $([long]$window))"
    }
    Write-Host "In the background, the bell flashed the taskbar button ($($flashes.Count) flash messages)."

    # In the foreground, it doesn't.
    if (-not [GhosttyFlashWatcher]::Activate($window)) { Fail "couldn't bring Ghostty to the front" }
    Pump 1000
    $flashes = Ring
    if ($flashes -contains [long]$window) { Fail "the bell flashed the taskbar button while Ghostty was in the foreground" }
    Write-Host 'In the foreground, the bell did not flash.'
    Close

    # With no-attention, it doesn't flash even in the background.
    $window = StartGhostty 'no-attention,no-title,no-border'
    if (-not [GhosttyFlashWatcher]::Activate($watcher.Handle)) { Fail "couldn't bring the test's window to the front" }
    $flashes = Ring
    if ($flashes -contains [long]$window) { Fail "the bell flashed the taskbar button with bell-features=no-attention" }
    Write-Host 'With no-attention, the bell did not flash.'
} finally {
    Close
    $watcher.Close()
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
