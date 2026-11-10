# Checks that Ctrl+clicking an OSC 8 hyperlink goes through the checks for
# links from terminal output (src/apprt/win32/link.zig): a text file opens
# (in Notepad), a script is blocked with a dialog and doesn't run, and an
# ms-settings: link asks first (we answer No). Holding Ctrl over a link
# must show its URL, in a link preview window made then, just above the
# scrollbar (where it was when it was made up front). It Ctrl+clicks with
# SendInput, which goes to whatever window is in the foreground, and it
# opens Notepad, so this only runs in CI, never on a developer's machine.
#
#     $env:CI = 'true'; ./links.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this sends real input to the desktop and opens apps, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyLinks -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
[DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, System.IntPtr extra);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindow(System.IntPtr h, uint cmd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
public static void Key(ushort vk, bool up) {
  var i = new INPUT[1]; i[0].type = 1; i[0].u.ki.wVk = vk; i[0].u.ki.dwFlags = up ? 2u : 0u;
  SendInput(1, i, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT))); }
'@
$W = [GhosttyLinks.Win32]
[void]$W::SetProcessDPIAware()

$dir = Join-Path ([IO.Path]::GetTempPath()) "ghostty-links-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
Set-Content -Path (Join-Path $dir 'notes.txt') -Value 'notes'
$marker = Join-Path $dir 'ran.txt'
Set-Content -Path (Join-Path $dir 'run.vbs') -Value "CreateObject(""Scripting.FileSystemObject"").CreateTextFile(""$marker"").Close"
# Fills the screen with one hyperlink, so a click anywhere on its left
# side lands on it.
$print = Join-Path $dir 'print.ps1'
Set-Content -Path $print -Value @'
param([string]$Url)
$e = [char]27
1..60 | ForEach-Object { Write-Host "$e]8;;$Url$e\OPEN-THIS-LINK-OPEN-THIS-LINK-OPEN-THIS-LINK$e]8;;$e\" }
Start-Sleep 3600
'@

$script:process = $null
$log = $null

function Fail([string]$message) {
    Write-Host "::error title=links::$message"
    Write-Host "--- Ghostty's log ---"
    if ($log -and (Test-Path $log)) { Get-Content $log -Tail 40 | Write-Host }
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

# A top-level dialog of Ghostty's with this title.
function Dialog([string]$title) {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, '#32770', $title)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $script:process.Id) { return $h }
    }
}

# Click $button in each of Ghostty's dialogs titled $title until none are
# left, and return how many there were.
function CloseDialogs([string]$title, [string]$button) {
    $closed = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $dialog = Dialog $title
        if (-not $dialog) {
            # Wait a moment in case another one is about to appear.
            Start-Sleep -Milliseconds 1000
            if (-not (Dialog $title)) { return $closed }
            continue
        }
        $b = $W::FindWindowExW($dialog, [IntPtr]::Zero, 'Button', $button)
        if ($b -eq [IntPtr]::Zero) { Fail "the $title dialog has no $button button" }
        [void]$W::PostMessageW($b, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
        $closed++
        [void](WaitFor { (Dialog $title) -ne $dialog } "the $title dialog to close")
    }
    Fail "the $title dialog kept coming back"
}

# Start Ghostty showing a screen of links to $url and Ctrl+click one.
function ClickLink([string]$url) {
    $script:log = Join-Path $dir "ghostty-$([guid]::NewGuid()).log"
    $env:GHOSTTY_LOG = 'debug'
    $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $script:log -ArgumentList `
        '--window-save-state=never', `
        "`"--command=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $print -Url $url`""

    $surfaceClass = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')
    $surface = WaitFor {
        $process.Refresh()
        if ($process.MainWindowHandle -ne 0) {
            $s = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle).FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants, $surfaceClass)
            if ($s -and $s.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value.Contains('OPEN-THIS-LINK')) { $s }
        }
    } 'the links to show'
    $window = $process.MainWindowHandle
    [void]$W::SetForegroundWindow($window)
    [void](WaitFor { $W::GetForegroundWindow() -eq $window } 'the window to be in the foreground')

    $rect = $surface.Current.BoundingRectangle
    $x = [int]($rect.Left + 40); $y = [int]($rect.Top + $rect.Height / 2)
    $h = [IntPtr]$surface.Current.NativeWindowHandle
    try {
        # Each check nudges the mouse a pixel and back, as a hand on it
        # would: a single move can reach Ghostty before it has the link or
        # sees Ctrl held, and then nothing asks again (this timed out twice
        # in CI, in runs 42164080425 and 42614152414). And if none of it
        # reaches Ghostty for a while (run 42827995514, where its log has
        # nothing in 30 s), start over: Ctrl up, the window to the front,
        # Ctrl down and the mouse back on the link.
        $preview = $null
        for ($attempt = 1; $attempt -le 3 -and -not $preview; $attempt++) {
            if ($attempt -gt 1) {
                $W::Key(0x11, $true)
                Write-Host "::notice title=links::No link preview after 10 s; trying again (attempt $attempt)."
                [void]$W::SetCursorPos($x + 200, $y + 100)
                [void]$W::SetForegroundWindow($window)
                Start-Sleep -Milliseconds 500
            }
            $W::Key(0x11, $false)                                 # Ctrl down
            [void]$W::SetCursorPos($x, $y)
            $W::mouse_event(0x0001, 1, 0, 0, [IntPtr]::Zero)      # a move, so Ghostty sees the link
            Start-Sleep -Milliseconds 300
            $script:nudge = 1
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                if ($process.HasExited) { Fail 'Ghostty exited while waiting for the link preview' }
                $p = $W::FindWindowExW($h, [IntPtr]::Zero, 'GhosttyLinkPreview', [NullString]::Value)
                if ($p -ne [IntPtr]::Zero -and $W::IsWindowVisible($p)) { $preview = $p; break }
                $W::mouse_event(0x0001, $script:nudge, 0, 0, [IntPtr]::Zero)
                $script:nudge = -$script:nudge
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $preview) { Fail 'timed out waiting for the link preview to show' }
        $name = New-Object System.Text.StringBuilder 64
        [void]$W::GetClassNameW($W::GetWindow($preview, 2), $name, $name.Capacity)   # GW_HWNDNEXT
        if ($name.ToString() -ne 'GhosttyScrollbar') { Fail "the link preview is just above $name, not the scrollbar" }
        # Its name (for screen readers) is the URL it shows.
        $text = New-Object System.Text.StringBuilder 512
        [void]$W::GetWindowTextW($preview, $text, $text.Capacity)
        if (-not $text.ToString().StartsWith($url)) { Fail "the link preview is named '$text', not the URL $url" }

        $W::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)      # left down
        $W::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)      # left up
        Start-Sleep -Milliseconds 300
    } finally {
        $W::Key(0x11, $true)                                  # Ctrl up
    }
}

function Close {
    if ($script:process) { Stop-Process -Id $script:process.Id -Force -ErrorAction SilentlyContinue }
    $script:process = $null
}

try {
    # A text file opens. This also shows that the Ctrl+click reaches the link.
    $notes = (Join-Path $dir 'notes.txt').Replace('\', '/')
    ClickLink "file:///$notes"
    $notepad = WaitFor {
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*notes*' } | Select-Object -First 1
    } 'Notepad to open notes.txt'
    Write-Host "Holding Ctrl over a link showed its URL, and a link to a text file opened it ($($notepad.ProcessName): '$($notepad.MainWindowTitle)')."
    Stop-Process -Id $notepad.Id -Force -ErrorAction SilentlyContinue
    Close

    # A script is blocked and doesn't run.
    $vbs = (Join-Path $dir 'run.vbs').Replace('\', '/')
    ClickLink "file:///$vbs"
    $dialog = WaitFor { Dialog 'Link Blocked' } 'the Link Blocked dialog'
    Start-Sleep 2
    if (Test-Path $marker) { Fail "the script ran" }
    if (-not (Select-String -Path $log -Pattern 'not opening link reason=unsafe_file' -Quiet)) {
        Fail "the log doesn't say why the link was blocked"
    }
    $count = CloseDialogs 'Link Blocked' 'OK'
    if ($count -ne 1) { Fail "one click showed $count Link Blocked dialogs" }
    Write-Host 'A link to a script was blocked, and the script did not run.'
    Close

    # Another app's scheme asks first. No (the default) doesn't open it.
    ClickLink 'ms-settings:about'
    $dialog = WaitFor { Dialog 'Open Link' } 'the Open Link dialog'
    $count = CloseDialogs 'Open Link' '&No'
    if ($count -ne 1) { Fail "one click showed $count Open Link dialogs" }
    Write-Host 'A link to ms-settings: asked first.'
    Close
} finally {
    Close
}
