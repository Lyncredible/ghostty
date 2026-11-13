# Checks the `set_window_theme` action: with a light and a dark theme
# (`theme = light:...,dark:...`), forcing the dark window theme must show the
# dark theme and forcing the light one the light theme, whatever Windows's
# app mode is. The choice must outlast a config reload, and `config` must go
# back to following the app mode. Then, started with `window-theme` set to
# the opposite of the app mode, that theme must show (as on GTK, a light or
# dark window theme forces the scheme), until `set_window_theme:system`
# follows the app mode again. Keys bound to the actions are posted to
# the terminal, and the background is read with PrintWindow, so it works
# with the desktop locked and doesn't change any desktop settings.
#
#     ./window-theme.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=window-theme::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace GhosttyWindowTheme -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr dc, uint flags);
[DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyWindowTheme.Win32]
[void]$W::SetThreadDpiAwarenessContext([IntPtr]-4)   # per monitor v2

$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$light = (Get-ItemProperty $personalize -ErrorAction SilentlyContinue).AppsUseLightTheme
$systemDark = $null -ne $light -and $light -eq 0

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-window-theme-$PID.log"
function Launch([string[]]$more) {
    $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList (@('--command=cmd.exe',
        '--window-save-state=never', '"--theme=light:Builtin Light,dark:Builtin Dark"',
        '--keybind=f8=set_window_theme:system', '--keybind=f9=set_window_theme:dark', '--keybind=f10=set_window_theme:light',
        '--keybind=f11=set_window_theme:config', '--keybind=f12=reload_config') + $more)
    $script:window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $script:surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
}

function Fail([string]$message) {
    Write-Host "::error title=window-theme::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process -and $process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what (the background's brightness is $script:last)"
}

# The brightness (0 to 255) of the terminal's background, from a pixel near
# the surface's bottom right corner, away from the prompt.
function Brightness {
    $wr = New-Object GhosttyWindowTheme.Win32+RECT; [void]$W::GetWindowRect($window, [ref]$wr)
    $sr = New-Object GhosttyWindowTheme.Win32+RECT; [void]$W::GetWindowRect($surface, [ref]$sr)
    $bitmap = New-Object System.Drawing.Bitmap ($wr.r - $wr.l), ($wr.b - $wr.t)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $dc = $g.GetHdc(); [void]$W::PrintWindow($window, $dc, 2); $g.ReleaseHdc($dc); $g.Dispose()
    $pixel = $bitmap.GetPixel($sr.r - $wr.l - 20, $sr.b - $wr.t - 20)
    $bitmap.Dispose()
    $script:last = [int](($pixel.R + $pixel.G + $pixel.B) / 3)
    $script:last
}

function Expect([bool]$dark, [string]$what) {
    if ($dark) { [void](WaitFor { (Brightness) -lt 60 } "the dark theme $what") }
    else { [void](WaitFor { (Brightness) -gt 200 } "the light theme $what") }
    Write-Host "The $(if ($dark) { 'dark' } else { 'light' }) theme $what (brightness $script:last)."
}

try {
    Launch @()
    Expect $systemDark "at startup, following the app mode ($(if ($systemDark) { 'dark' } else { 'light' }))"

    # Force the opposite of the app mode first, so the change shows.
    $first = if ($systemDark) { 0x79 } else { 0x78 }   # F10 light, F9 dark
    $W::Key($surface, $first, $(if ($systemDark) { 0x44 } else { 0x43 }))
    Expect (-not $systemDark) 'after set_window_theme'

    $W::Key($surface, 0x7B, 0x58)   # F12: reload_config
    Start-Sleep -Seconds 2
    Expect (-not $systemDark) 'after reloading the config'

    $other = if ($systemDark) { 0x78 } else { 0x79 }
    $W::Key($surface, $other, $(if ($systemDark) { 0x43 } else { 0x44 }))
    Expect $systemDark 'after forcing the other theme'

    $W::Key($surface, $first, $(if ($systemDark) { 0x44 } else { 0x43 }))
    Expect (-not $systemDark) 'after forcing it back'
    $W::Key($surface, 0x7A, 0x57)   # F11: set_window_theme:config
    Expect $systemDark "after going back to the config's window theme"
    Stop-Process -Id $process.Id -Force; $process.WaitForExit()

    # The config's window theme, the opposite of the app mode, forces it.
    $theme = if ($systemDark) { 'light' } else { 'dark' }
    Launch @("--window-theme=$theme")
    Expect (-not $systemDark) "at startup with window-theme = $theme"
    $W::Key($surface, 0x77, 0x42)   # F8: set_window_theme:system
    Expect $systemDark 'after set_window_theme:system'
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
