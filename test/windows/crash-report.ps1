# Checks the crash handler (src/crash/windows.zig): Ghostty, with F12
# bound to `crash:main` and its standard error in a file, panics on a
# posted F12. It must exit by itself (with a standard error there's no
# dialog to wait on), save a report in %LOCALAPPDATA%\ghostty\crash with
# the version, the panic message and the return addresses, print the
# panic to standard error, and `+crash-report` must list the report. Keys
# are posted to Ghostty's window, so it runs on a locked desktop.
#
#     ./crash-report.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyCrash -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyCrash.Win32]

$message = 'crash binding action, crashing intentionally'
$dir = Join-Path $env:LOCALAPPDATA 'ghostty\crash'
$before = @(if (Test-Path $dir) { Get-ChildItem $dir -Filter 'crash-*.txt' | ForEach-Object Name })
$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-crash-report-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f12=crash:main'
# Opening the handle now keeps the exit code for later.
$null = $process.Handle

function Fail([string]$message) {
    Write-Host "::error title=crash-report::$message"
    Write-Host "--- Ghostty's standard error ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what"
}

$report = $null
try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', $null); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
    Start-Sleep -Milliseconds 500
    $W::Key($surface, 0x7B, 0x58)   # F12: crash:main

    [void](WaitFor { $process.HasExited } 'Ghostty to exit after crashing (a dialog would keep it open)')
    Write-Host "Ghostty exited by itself after the crash (exit code $($process.ExitCode))."

    $new = @(Get-ChildItem $dir -Filter 'crash-*.txt' | Where-Object { $before -notcontains $_.Name })
    if ($new.Count -ne 1) { Fail "expected one new report in $dir, found $($new.Count)" }
    $report = $new[0]
    $text = Get-Content -Raw $report.FullName
    if ($text -notmatch '^Ghostty \S+ crashed\.') { Fail "the report doesn't start with the version: $($text.Substring(0, [Math]::Min(80, $text.Length)))" }
    if ($text -notmatch "panic: $message") { Fail "the report doesn't have the panic message" }
    if ($text -notmatch 'Return addresses \(ghostty\.exe base 0x[0-9a-f]+\):') { Fail "the report has no return addresses" }
    Write-Host "It saved $($report.Name) with the version, the panic message and the return addresses."

    $stderr = Get-Content -Raw $log
    if ($stderr -notmatch [regex]::Escape($message)) { Fail "standard error doesn't have the panic message" }
    Write-Host 'Standard error has the panic message.'

    $launcher = Join-Path (Split-Path $Exe) 'ghostty.com'
    if (-not (Test-Path $launcher)) { $launcher = $Exe }
    $listed = (& $launcher +crash-report) -join "`n"
    if ($listed -notmatch [regex]::Escape($report.Name)) { Fail "+crash-report doesn't list $($report.Name): $listed" }
    Write-Host "+crash-report lists it."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if ($report) { Remove-Item -LiteralPath $report.FullName -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
