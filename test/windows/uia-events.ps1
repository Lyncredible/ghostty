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
    [int]$TimeoutSeconds = 20,
    # Where to write Ghostty's log.
    [string]$Log = (Join-Path ([IO.Path]::GetTempPath()) "ghostty-uia-$PID.log")
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

  // Registers from an MTA thread: handlers registered on PowerShell's STA
  // thread get their events through it, and it doesn't pump messages while
  // the script waits.
  static void OnMta(Action action) {
    Exception error = null;
    var thread = new System.Threading.Thread(() => { try { action(); } catch (Exception e) { error = e; } });
    thread.SetApartmentState(System.Threading.ApartmentState.MTA);
    thread.Start();
    thread.Join();
    if (error != null) throw error;
  }

  // Any window opening, to tell whether events reach this client at all.
  public static void ListenForWindows() { OnMta(ListenForWindowsMta); }
  static void ListenForWindowsMta() {
    Automation.AddAutomationEventHandler(WindowPattern.WindowOpenedEvent, AutomationElement.RootElement, TreeScope.Subtree,
      (s, e) => { string name = "?"; try { name = ((AutomationElement)s).Current.ClassName; } catch {} Events.Enqueue("window:" + name); });
  }

  public static void Listen(AutomationElement surface, AutomationElement window) { OnMta(() => ListenMta(surface, window)); }
  static void ListenMta(AutomationElement surface, AutomationElement window) {
    Automation.AddAutomationEventHandler(TextPattern.TextSelectionChangedEvent, surface, TreeScope.Element,
      (s, e) => Events.Enqueue("selection"));
    Automation.AddAutomationEventHandler(AutomationElement.NotificationEvent, surface, TreeScope.Element,
      (s, e) => Events.Enqueue("notification:" + ((NotificationEventArgs)e).DisplayString));
    Automation.AddAutomationEventHandler(SelectionItemPattern.ElementSelectedEvent, window, TreeScope.Descendants,
      (s, e) => { string name = "?"; try { name = ((AutomationElement)s).Current.Name; } catch {} Events.Enqueue("tab:" + name); });
  }

  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize;
    public IntPtr hwndCaret; public RECT rcCaret; }
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);

  // The window with keyboard focus on a window's thread.
  public static IntPtr Focus(IntPtr w) {
    uint pid; uint tid = GetWindowThreadProcessId(w, out pid);
    var i = new GUITHREADINFO(); i.cbSize = Marshal.SizeOf(i);
    GetGUIThreadInfo(tid, ref i); return i.hwndFocus;
  }

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

$U::ListenForWindows()
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $Log -ArgumentList '--command=cmd.exe', '--window-save-state=never',
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

$script:seen = @()
# Moves the events that arrived into $seen, and returns them all.
function Drain {
    $item = $null
    while ($U::Events.TryDequeue([ref]$item)) { $script:seen += $item }
    $script:seen
}

function WaitFor([scriptblock]$condition, [string]$what, [int]$seconds = $TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what (events: $((Drain) -join '; '))"
}

try {
    $found = WaitFor { Find } 'the prompt' 60
    $windowHandle = [IntPtr]$found.Window.Current.NativeWindowHandle
    $surfaceHandle = [IntPtr]$found.Surface.Current.NativeWindowHandle
    [void]$U::SetForegroundWindow($windowHandle)
    $U::Listen($found.Surface, $found.Window)
    Start-Sleep -Seconds 1
    Write-Host ("::notice title=uia-events::before the checks: foreground is ours: $($U::GetForegroundWindow() -eq $windowHandle), " +
        "focus is the surface: $($U::Focus($windowHandle) -eq $surfaceHandle), events: $((Drain) -join '; ')")

    # Each check runs even if one before it failed.
    $failures = @()

    # New output is announced (the typed command itself isn't, on the
    # cursor's line, but its output is).
    try {
        $U::Type($surfaceHandle, "echo uia-$PID`r")
        $note = WaitFor { Drain | Where-Object { $_ -like 'notification:*' -and $_ -match "uia-$PID" } | Select-Object -First 1 } 'a notification with the output'
        Write-Host "::notice title=uia-events::$note"
    } catch {
        $text = $found.Surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        $ran = ([regex]::Matches($text, "uia-$PID")).Count
        $failures += "$($_.Exception.Message); the screen has uia-$PID $ran times"
    }

    try {
        $U::Key($surfaceHandle, 0x74, 0x3F)   # F5: select_all
        [void](WaitFor { Drain | Where-Object { $_ -eq 'selection' } } 'TextSelectionChanged after select_all')
        Write-Host "::notice title=uia-events::TextSelectionChanged after select_all"
    } catch { $failures += $_.Exception.Message }

    try {
        $script:seen = @()
        $U::Key($surfaceHandle, 0x75, 0x40)   # F6: new_tab
        $tab = WaitFor { Drain | Where-Object { $_ -like 'tab:*' } | Select-Object -First 1 } 'ElementSelected for the new tab'
        Write-Host "::notice title=uia-events::ElementSelected: $tab"
    } catch { $failures += $_.Exception.Message }

    if ($failures) { throw ($failures -join ' / ') }
} catch {
    Write-Host "::error title=uia-events::$($_.Exception.Message)"
    throw
} finally {
    [System.Windows.Automation.Automation]::RemoveAllEventHandlers()
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
