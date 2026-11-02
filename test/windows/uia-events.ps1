# Checks the UI Automation events a screen reader listens for: new output
# announced as a notification event, TextSelectionChanged when the
# selection changes (select_all), and the tab bar's ElementSelected when a
# new tab becomes active. The listener is uia_events.c, built here with
# `zig cc`: a client of the native UI Automation API, as screen readers
# are. It only sends messages to Ghostty's windows, but needs an unlocked
# desktop (as in CI).
#
#     ./uia-events.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 20,
    # Where to write Ghostty's log.
    [string]$Log = (Join-Path ([IO.Path]::GetTempPath()) "ghostty-uia-$PID.log")
)

$ErrorActionPreference = 'Stop'

$work = Join-Path ([IO.Path]::GetTempPath()) "ghostty-uia-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$client = Join-Path $work 'uia-events.exe'
& zig cc -target x86_64-windows-gnu (Join-Path $PSScriptRoot 'uia_events.c') -o $client -lole32 -loleaut32 -luuid
if ($LASTEXITCODE -ne 0) { throw "building uia_events.c failed" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyUia -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
public static void Type(System.IntPtr h, string text) {
  foreach (char c in text) { PostMessageW(h, 0x0102, (System.IntPtr)c, (System.IntPtr)1); System.Threading.Thread.Sleep(20); }  // WM_CHAR
}
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyUia.Win32]
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $Log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--window-show-tab-bar=always', '--keybind=f5=select_all', '--keybind=f6=new_tab'
$listener = $null
$out = Join-Path $work 'events.txt'

function Find {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $process.Id)
    foreach ($window in $AE::RootElement.FindAll($Scope::Children, $condition)) {
        if ($window.Current.ClassName -ne 'GhosttyWindow') { continue }
        $surface = $window.FindFirst($Scope::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'GhosttySurface')))
        if (-not $surface) { continue }
        $text = $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        if ($text.Contains('>')) { return @{ Window = $window; Surface = $surface } }
    }
}

function Events { if (Test-Path $out) { @(Get-Content $out) } else { @() } }

function WaitFor([scriptblock]$condition, [string]$what, [int]$seconds = $TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what (events: $((Events) -join '; '))"
}

try {
    $found = WaitFor { Find } 'the prompt' 60
    $windowHandle = [IntPtr]$found.Window.Current.NativeWindowHandle
    $surfaceHandle = [IntPtr]$found.Surface.Current.NativeWindowHandle
    [void]$W::SetForegroundWindow($windowHandle)

    $listener = Start-Process -FilePath $client -ArgumentList "$surfaceHandle", ($TimeoutSeconds * 4) -PassThru -NoNewWindow -RedirectStandardOutput $out
    [void](WaitFor { (Events) -contains 'ready' -or ((Events) -like 'error:*') } 'the listener')
    if ((Events) -like 'error:*') { throw "the listener failed: $((Events) -join '; ')" }

    # Each check runs even if one before it failed.
    $failures = @()

    # New output is announced (the typed command itself isn't, on the
    # cursor's line, but its output is).
    try {
        $W::Type($surfaceHandle, "echo uia-$PID`r")
        $note = WaitFor { Events | Where-Object { $_ -like 'notification:*' -and $_ -match "uia-$PID" } | Select-Object -First 1 } 'a notification with the output'
        Write-Host "::notice title=uia-events::$note"
        # Screen readers speak typing themselves, so only the output is new.
        if (([regex]::Matches($note, "uia-$PID")).Count -ne 1) { throw "the announcement repeats the typed command: $note" }
    } catch {
        $text = $found.Surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        $failures += "$($_.Exception.Message); the screen has uia-$PID $(([regex]::Matches($text, "uia-$PID")).Count) times"
    }

    try {
        $W::Key($surfaceHandle, 0x74, 0x3F)   # F5: select_all
        [void](WaitFor { (Events) -contains 'selection' } 'TextSelectionChanged after select_all')
        Write-Host "::notice title=uia-events::TextSelectionChanged after select_all"
    } catch { $failures += $_.Exception.Message }

    try {
        $W::Key($surfaceHandle, 0x75, 0x40)   # F6: new_tab
        $tab = WaitFor { Events | Where-Object { $_ -like 'tab:*' } | Select-Object -First 1 } 'ElementSelected for the new tab'
        Write-Host "::notice title=uia-events::ElementSelected: $tab"
    } catch { $failures += $_.Exception.Message }

    if ($failures) { throw ($failures -join ' / ') }
} catch {
    Write-Host "::error title=uia-events::$($_.Exception.Message)"
    throw
} finally {
    if ($listener -and -not $listener.HasExited) { Stop-Process -Id $listener.Id -Force }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
