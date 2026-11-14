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
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern System.IntPtr GetDlgItem(System.IntPtr h, int id);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
// A dialog (a message box) of this process, if it has one.
public static System.IntPtr Dialog(uint pid) {
  System.IntPtr h = System.IntPtr.Zero;
  while ((h = FindWindowExW(System.IntPtr.Zero, h, "#32770", null)) != System.IntPtr.Zero) {
    uint p; GetWindowThreadProcessId(h, out p); if (p == pid) return h;
  }
  return System.IntPtr.Zero;
}
// A message box's text: its static control's (ID 0xFFFF).
public static string DialogText(System.IntPtr h) {
  var s = new System.Text.StringBuilder(2048);
  GetWindowTextW(GetDlgItem(h, 0xFFFF), s, s.Capacity);
  return s.ToString();
}
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
    $surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
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

# Without a standard error, a dialog says where the report is. It runs on
# a thread of its own: on the thread that panicked, its message loop would
# go on handling our windows' messages, and a second panic there (another
# F12 here; the same paint or timer panicking again in real life) ended
# the process with the dialog still up. Ghostty exits once it's closed.
$before = @(if (Test-Path $dir) { Get-ChildItem $dir -Filter 'crash-*.txt' | ForEach-Object Name })
$report = $null
$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f12=crash:main'
$null = $process.Handle
try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
    Start-Sleep -Milliseconds 500
    $W::Key($surface, 0x7B, 0x58)   # F12: crash:main
    $dialog = WaitFor {
        if ($process.HasExited) { Fail "Ghostty exited without a dialog (exit code $($process.ExitCode))" }
        $h = $W::Dialog([uint32]$process.Id); if ($h -ne [IntPtr]::Zero) { $h }
    } 'the crash dialog'
    $new = @(Get-ChildItem $dir -Filter 'crash-*.txt' | Where-Object { $before -notcontains $_.Name })
    if ($new.Count -ne 1) { Fail "expected one new report in $dir, found $($new.Count)" }
    $report = $new[0]
    $text = $W::DialogText($dialog)
    if ($text -notmatch [regex]::Escape($message) -or $text -notmatch [regex]::Escape($report.FullName)) {
        Fail "the dialog doesn't have the message and the report's path: $text"
    }
    Write-Host "A dialog has the panic message and the report's path ($($report.Name))."

    $W::Key($surface, 0x7B, 0x58)   # F12 again, while the dialog is up
    Start-Sleep -Seconds 2
    if ($process.HasExited) { Fail "a second panic ended Ghostty with the dialog up (exit code $($process.ExitCode))" }
    if ($W::Dialog([uint32]$process.Id) -ne $dialog) { Fail "the dialog went away after a second F12" }
    Write-Host 'A second F12 changed nothing: the dialog is still up.'

    [void]$W::PostMessageW($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    [void](WaitFor { $process.HasExited } 'Ghostty to exit after the dialog closed')
    Write-Host "Ghostty exited once the dialog closed (exit code $($process.ExitCode))."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if ($report) { Remove-Item -LiteralPath $report.FullName -Force -ErrorAction SilentlyContinue }
}
exit 0
