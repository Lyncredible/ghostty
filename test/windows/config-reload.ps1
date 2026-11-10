# Checks that reload_config takes up changes to the config file: Ghostty
# starts with only a config file of ours, the test then adds a keybind for
# new_tab to it and reloads with a key, and the new keybind must open a
# tab, which it doesn't before the reload. Then the keybind is taken out
# again, and after another reload the key does nothing. Keys are posted
# to the terminal, so it runs on a locked desktop.
#
#     ./config-reload.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyConfigReload -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));
}
'@
$W = [GhosttyConfigReload.Win32]

$dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-config-reload-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
$config = Join-Path $dir 'config'
$base = @(
    'command = cmd.exe',
    'window-save-state = never',
    'confirm-close-surface = false',
    'keybind = f12=reload_config'
)
Set-Content -Encoding utf8 $config $base

$log = Join-Path $dir 'ghostty.log'
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--config-default-files=false',
    "`"--config-file=$config`""

function Fail([string]$message) {
    Write-Host "::error title=config-reload::$message"
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 30 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 200
    }
    Fail "timed out waiting for $what"
}

# The window's terminals (one per tab), and the shown one.
function Terminals {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) { $list += $h }
    $list
}
function Shown { @(Terminals | Where-Object { $W::IsWindowVisible($_) }) | Select-Object -First 1 }
# reload_config runs while its key is handled, so a key posted after it
# comes after the reload.

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    [void](WaitFor { @(Terminals).Count -eq 1 } 'the first terminal')
    Start-Sleep -Seconds 1

    # F6 isn't bound yet.
    $W::Key((Shown), 0x75, 0x40)   # F6
    Start-Sleep -Seconds 2
    if (@(Terminals).Count -ne 1) { Fail 'F6 opened a tab before it was bound' }

    # Bind it and reload.
    Set-Content -Encoding utf8 $config ($base + 'keybind = f6=new_tab')
    $W::Key((Shown), 0x7B, 0x58)   # F12: reload_config
    $W::Key((Shown), 0x75, 0x40)   # F6
    [void](WaitFor { @(Terminals).Count -eq 2 } 'the reloaded keybind to open a tab')
    Write-Host 'After a keybind for new_tab was added to the config file and the config reloaded, it opened a tab.'

    # Unbind it and reload: F6 does nothing again.
    Set-Content -Encoding utf8 $config $base
    $W::Key((Shown), 0x7B, 0x58)
    $W::Key((Shown), 0x75, 0x40)
    Start-Sleep -Seconds 2
    if (@(Terminals).Count -ne 2) { Fail 'F6 still opened a tab after its keybind was taken out' }
    Write-Host 'With the keybind taken out again and the config reloaded, F6 did nothing.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
