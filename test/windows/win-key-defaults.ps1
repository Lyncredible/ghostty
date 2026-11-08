# Reports which of Ghostty's default keybindings with the Windows key
# (`super`) another program has taken as a hotkey: Windows' shell
# registers its Win key shortcuts with RegisterHotKey, and a registered
# hotkey never reaches the focused window. Registering one ourselves fails
# with ERROR_HOTKEY_ALREADY_REGISTERED (1409) when it's taken; a free one
# is registered and released at once. Only a report (a notice), since a
# free combination can still be caught by a keyboard hook. Needs no
# window or input.
#
#     ./win-key-defaults.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace GhosttyWinKeys -Name Win32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(System.IntPtr h, int id, uint mods, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(System.IntPtr h, int id);
'@
$W = [GhosttyWinKeys.Win32]

$mods = @{ alt = 1; ctrl = 2; shift = 4; super = 8 }
$keys = @{
    'arrow_left' = 0x25; 'arrow_up' = 0x26; 'arrow_right' = 0x27; 'arrow_down' = 0x28
    '[' = 0xDB; ']' = 0xDD; 'bracket_left' = 0xDB; 'bracket_right' = 0xDD
    'comma' = 0xBC; 'period' = 0xBE; 'equal' = 0xBB; 'minus' = 0xBD
    'enter' = 0x0D; 'tab' = 0x09; 'page_up' = 0x21; 'page_down' = 0x22; 'home' = 0x24; 'end' = 0x23
}

# Ghostty's console launcher prints the defaults.
$launcher = Join-Path (Split-Path $Exe) 'ghostty.com'
if (-not (Test-Path $launcher)) { $launcher = $Exe }
$lines = & $launcher +list-keybinds --default | Where-Object { $_ -match '^keybind = (\S*super\S*?)=(.+)$' }

$taken = @(); $free = @(); $skipped = @()
$id = 0x6800
foreach ($line in $lines) {
    [void]($line -match '^keybind = (\S*super\S*?)=(.+)$')
    $trigger = $Matches[1]; $action = $Matches[2]
    $parts = $trigger -split '\+'
    $key = $parts[-1]
    $vk = if ($keys.ContainsKey($key)) { $keys[$key] } elseif ($key -match '^[a-z0-9]$') { [int][char]$key.ToUpper() } else { $null }
    $modifiers = 0
    foreach ($m in $parts[0..($parts.Count - 2)]) { $modifiers += $mods[$m] }
    if ($null -eq $vk) { $skipped += $trigger; continue }

    $id++
    $ok = $W::RegisterHotKey([IntPtr]::Zero, $id, [uint32]($modifiers + 0x4000), [uint32]$vk)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($ok) { [void]$W::UnregisterHotKey([IntPtr]::Zero, $id); $free += "$trigger ($action)" }
    elseif ($err -eq 1409) { $taken += "$trigger ($action)" }
    else { $skipped += "$trigger (error $err)" }
}

Write-Host "Default keybindings with the Windows key: $($lines.Count)."
Write-Host "Free: $($free -join ', ')"
if ($skipped) { Write-Host "Not checked: $($skipped -join ', ')" }
if ($taken) {
    Write-Host "::notice title=win-key-defaults::Taken by another program as hotkeys, so they never reach Ghostty: $($taken -join ', ')"
} else {
    Write-Host 'None is taken.'
}
exit 0
