# Checks the UI Automation events a screen reader listens for: new output
# announced as a notification event, TextSelectionChanged when the
# selection changes (select_all), and the tab bar's ElementSelected when a
# new tab becomes active. It only sends messages to Ghostty's windows, but
# UIA events don't reach clients on a locked desktop, so it needs an
# unlocked one (as in CI).
#
#     ./uia-events.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
# UIA calls event handlers on its own threads, where PowerShell can't run
# script blocks, so a C# listener queues what arrives.
Add-Type -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Windows.Automation;

public static class GhosttyUiaEvents {
  public static readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();

  public static void Listen(AutomationElement surface, AutomationElement window) {
    Automation.AddAutomationEventHandler(TextPattern.TextSelectionChangedEvent, surface, TreeScope.Element,
      (s, e) => Events.Enqueue("selection"));
    Automation.AddAutomationEventHandler(AutomationElement.NotificationEvent, surface, TreeScope.Element,
      (s, e) => Events.Enqueue("notification:" + ((NotificationEventArgs)e).DisplayString));
    Automation.AddAutomationEventHandler(SelectionItemPattern.ElementSelectedEvent, window, TreeScope.Descendants,
      (s, e) => { string name = "?"; try { name = ((AutomationElement)s).Current.Name; } catch {} Events.Enqueue("tab:" + name); });
  }

  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);

  public static void Type(IntPtr h, string text) {
    foreach (char c in text) { PostMessageW(h, 0x0102, (IntPtr)c, (IntPtr)1); System.Threading.Thread.Sleep(20); }  // WM_CHAR
  }

  // A key press and release, with the scan code in lParam.
  public static void Key(IntPtr h, int vk, int scan) {
    PostMessageW(h, 0x0100, (IntPtr)vk, (IntPtr)(1 | (scan << 16)));                                  // WM_KEYDOWN
    System.Threading.Thread.Sleep(30);
    uint up = 1u | ((uint)scan << 16) | (3u << 30);
    PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)unchecked((int)up));                                   // WM_KEYUP
  }
}
'@
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$U = [GhosttyUiaEvents]

$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', '--window-save-state=never',
    '--keybind=f5=select_all', '--keybind=f6=new_tab'

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

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what (events: $($script:seen -join '; '))"
}

$script:seen = @()
# The events that arrived since the last call, kept in $seen.
function Drain {
    $item = $null
    while ($U::Events.TryDequeue([ref]$item)) { $script:seen += $item }
    $script:seen
}

try {
    $found = WaitFor { Find } 'the prompt'
    $surfaceHandle = [IntPtr]$found.Surface.Current.NativeWindowHandle
    [void]$U::SetForegroundWindow([IntPtr]$found.Window.Current.NativeWindowHandle)
    $U::Listen($found.Surface, $found.Window)
    Start-Sleep -Seconds 1

    # New output is announced (the typed command itself isn't, on the
    # cursor's line, but its output is).
    $U::Type($surfaceHandle, "echo uia-$PID`r")
    $note = WaitFor { Drain | Where-Object { $_ -like 'notification:*' -and $_ -match "uia-$PID" } | Select-Object -First 1 } 'a notification with the output'
    Write-Host "::notice title=uia-events::$note"

    $U::Key($surfaceHandle, 0x74, 0x3F)   # F5: select_all
    [void](WaitFor { Drain | Where-Object { $_ -eq 'selection' } } 'TextSelectionChanged after select_all')
    Write-Host "::notice title=uia-events::TextSelectionChanged after select_all"

    $script:seen = @()
    $U::Key($surfaceHandle, 0x75, 0x40)   # F6: new_tab
    $tab = WaitFor { Drain | Where-Object { $_ -like 'tab:*' } | Select-Object -First 1 } 'ElementSelected for the new tab'
    Write-Host "::notice title=uia-events::ElementSelected: $tab"
} catch {
    Write-Host "::error title=uia-events::$($_.Exception.Message)"
    throw
} finally {
    [System.Windows.Automation.Automation]::RemoveAllEventHandlers()
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
