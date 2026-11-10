# Checks that the installed MSIX works as Windows' default terminal
# application: with the console delegation set to Windows Terminal's
# OpenConsole and the terminal delegation to Ghostty's handoff class (as
# Settings > For developers > Terminal does), a console program started in
# a new console must show up in a Ghostty window that COM started
# (`-Embedding`). It changes the user's default terminal (and restores it),
# so it only runs in CI, after the MSIX is installed.
#
#     ./default-terminal.ps1

param([int]$TimeoutSeconds = 60)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this changes the default terminal application, so it only runs in CI" }
if (-not (Get-AppxPackage Microsoft.WindowsTerminal)) {
    Write-Host "::notice title=default-terminal::Windows Terminal isn't installed, so there's no OpenConsole to delegate to; skipped"
    exit 0
}
$package = Get-AppxPackage GhosttyWindowsUnofficial
if (-not $package) { throw "the MSIX isn't installed" }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# Ghostty logs to the debugger output (OutputDebugString), which is the
# only log a Ghostty that COM starts has, so we listen to it (DBWIN).
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public static class GhosttyDbWin {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateEventW(IntPtr a, bool manual, bool initial, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateFileMappingW(IntPtr file, IntPtr a, uint protect, uint high, uint low, string name);
    [DllImport("kernel32.dll")] static extern IntPtr MapViewOfFile(IntPtr map, uint access, uint high, uint low, UIntPtr size);
    [DllImport("kernel32.dll")] static extern bool SetEvent(IntPtr e);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    static readonly List<string> lines = new List<string>();
    public static bool Start() {
        IntPtr ready = CreateEventW(IntPtr.Zero, false, false, "DBWIN_BUFFER_READY");
        IntPtr data = CreateEventW(IntPtr.Zero, false, false, "DBWIN_DATA_READY");
        IntPtr map = CreateFileMappingW(new IntPtr(-1), IntPtr.Zero, 4, 0, 4096, "DBWIN_BUFFER");
        if (ready == IntPtr.Zero || data == IntPtr.Zero || map == IntPtr.Zero) return false;
        IntPtr view = MapViewOfFile(map, 4, 0, 0, new UIntPtr(4096));
        if (view == IntPtr.Zero) return false;
        var thread = new Thread(() => {
            while (true) {
                SetEvent(ready);
                if (WaitForSingleObject(data, 1000) != 0) continue;
                int pid = Marshal.ReadInt32(view);
                string text = Marshal.PtrToStringAnsi(view + 4);
                lock (lines) lines.Add(pid + ": " + (text ?? "").TrimEnd());
            }
        });
        thread.IsBackground = true;
        thread.Start();
        return true;
    }
    public static string[] Lines() { lock (lines) return lines.ToArray(); }
}
'@
$listening = [GhosttyDbWin]::Start()

$key = 'HKCU:\Console\%%Startup'
$names = 'DelegationConsole', 'DelegationTerminal'
$saved = @{}
if (Test-Path $key) {
    foreach ($name in $names) { $saved[$name] = (Get-ItemProperty $key -ErrorAction SilentlyContinue).$name }
}

# A warning annotation, which (unlike the step's log) the public API
# shows, split into a few, since each one's message is limited.
function Annotate([string]$title, [string[]]$lines) {
    $chunk = @()
    $size = 0
    foreach ($line in $lines + $null) {
        if ($null -eq $line -or $size + $line.Length -gt 3000) {
            if ($chunk.Count -gt 0) {
                $text = ($chunk -join "`n").Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
                Write-Host "::warning title=$title::$text"
            }
            $chunk = @()
            $size = 0
        }
        if ($null -ne $line) { $chunk += $line; $size += $line.Length + 1 }
    }
}

function Fail([string]$message) {
    Write-Host "::error title=default-terminal::$message"
    $details = @()
    foreach ($process in Get-CimInstance Win32_Process -Filter "Name = 'ghostty.exe' or Name = 'OpenConsole.exe' or Name = 'cmd.exe' or Name = 'WindowsTerminal.exe'") {
        $details += "process $($process.ProcessId) (parent $($process.ParentProcessId)): $($process.CommandLine)"
    }
    foreach ($process in Get-Process ghostty -ErrorAction SilentlyContinue) {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        foreach ($window in [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Children, $condition)) {
            $details += "Ghostty $($process.Id) has a window: $($window.Current.Name)"
        }
    }
    Annotate 'default-terminal processes' $details
    if ($listening) {
        $ids = @(Get-Process ghostty, OpenConsole -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id):" })
        $lines = @([GhosttyDbWin]::Lines() | Where-Object { $line = $_; $ids | Where-Object { $line.StartsWith($_) } })
        if ($lines.Count -eq 0) { $lines = @([GhosttyDbWin]::Lines()) }
        Annotate 'default-terminal log' @($lines | Select-Object -Last 60)
    } else {
        Write-Host "::warning title=default-terminal log::couldn't listen to the debugger output"
    }
    throw $message
}

# The text of a running Ghostty's terminals.
function GhosttyText {
    foreach ($process in Get-Process ghostty -ErrorAction SilentlyContinue) {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
            foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    (New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
                @{ Process = $process; Text = $(try { $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' }) }
            }
        }
    }
}

$cmd = $null
try {
    Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    Set-ItemProperty $key DelegationConsole '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    Set-ItemProperty $key DelegationTerminal '{7EC9F94F-09DD-4C7F-A79B-57532EBAFCDD}'

    # A new console, as when a console program starts from Explorer.
    $cmd = Start-Process -FilePath cmd.exe -PassThru -ArgumentList '/k echo default-%USERNAME:~0,0%terminal'
    $found = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $found -and (Get-Date) -lt $deadline) {
        $found = GhosttyText | Where-Object { $_.Text.Contains('default-terminal') } | Select-Object -First 1
        if (-not $found) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $found) {
        $running = (Get-Process ghostty -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) $($_.Path)" }) -join '; '
        Fail "cmd's output didn't show up in Ghostty (Ghostty processes: $running)"
    }
    $path = $found.Process.Path
    if (-not $path.StartsWith($package.InstallLocation, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "the Ghostty showing cmd isn't the installed package's: $path"
    }
    Write-Host "cmd started in a new console showed up in the packaged Ghostty ($path)."
} finally {
    if ($cmd -and -not $cmd.HasExited) { Stop-Process -Id $cmd.Id -Force -ErrorAction SilentlyContinue }
    Get-Process ghostty -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($name in $names) {
        if ($null -eq $saved[$name]) {
            Remove-ItemProperty $key $name -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty $key $name $saved[$name]
        }
    }
}
