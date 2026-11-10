# Checks, for CI, that the mouse wheel follows Windows' "lines to scroll at
# a time" setting: it fills cmd with numbered lines, sets the setting to 1
# and then 5 (for this session only, not saved), posts a wheel notch to the
# terminal for each, and checks how far the view scrolled. Changing the
# setting affects the whole desktop, so this only runs in CI.
#
#     ./wheel-lines.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this changes a desktop setting, so it only runs in CI" }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyWheel -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfoW(uint action, uint param, ref uint value, uint ini);
[DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")] public static extern bool SetParam(uint action, uint param, System.IntPtr value, uint ini);
'@
[void][GhosttyWheel.Win32]::SetProcessDPIAware()

$SPI_GETWHEELSCROLLLINES = 0x68
$SPI_SETWHEELSCROLLLINES = 0x69
$saved = [uint32]3
[void][GhosttyWheel.Win32]::SystemParametersInfoW($SPI_GETWHEELSCROLLLINES, 0, [ref]$saved, 0)

$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', '--window-save-state=never'

function Fail([string]$message) {
    Write-Host "::error title=wheel-lines::$message"
    $script:reported = $true
    throw $message
}

function Surface {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
            return @{
                Handle = [IntPtr]$surface.Current.NativeWindowHandle
                Text = $(try { $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '' })
            }
        }
    }
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what"
}

# The first numbered line on screen.
function FirstLine {
    $m = [regex]::Match((Surface).Text, '(?m)^line(\d+)\s*$')
    if ($m.Success) { [int]$m.Groups[1].Value }
}

# Sets the setting, posts one notch up, and checks the view moved by $lines.
function Notch([int]$lines) {
    if (-not [GhosttyWheel.Win32]::SetParam($SPI_SETWHEELSCROLLLINES, $lines, [IntPtr]::Zero, 0)) {
        Fail "couldn't set the wheel lines to $lines"
    }
    $start = FirstLine
    $rect = New-Object GhosttyWheel.Win32+RECT
    [void][GhosttyWheel.Win32]::GetWindowRect($surface.Handle, [ref]$rect)
    $x = [int](($rect.l + $rect.r) / 2); $y = [int](($rect.t + $rect.b) / 2)
    [void][GhosttyWheel.Win32]::PostMessageW($surface.Handle, 0x020A, [IntPtr](120 -shl 16), [IntPtr](($y -shl 16) -bor $x))
    $end = WaitFor { $f = FirstLine; if ($f -and $f -ne $start) { $f } } "a notch to scroll with $lines line(s) set"
    Start-Sleep -Milliseconds 500
    $end = FirstLine
    Write-Host "With $lines line(s) a notch, the first visible line went from $start to $end."
    if ($start - $end -ne $lines) { Fail "a notch with $lines line(s) set scrolled $($start - $end)" }
}

try {
    $surface = WaitFor { $s = Surface; if ($s -and $s.Text.Contains('>')) { $s } } 'the prompt'
    foreach ($ch in 'for /l %i in (1,1,200) do @echo line%i'.ToCharArray()) {
        [void][GhosttyWheel.Win32]::SendMessageW($surface.Handle, 0x0102, [IntPtr][int]$ch, [IntPtr]1)
    }
    [void][GhosttyWheel.Win32]::PostMessageW($surface.Handle, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)
    [void][GhosttyWheel.Win32]::PostMessageW($surface.Handle, 0x0101, [IntPtr]0x0D, [IntPtr]0xC01C0001)
    [void](WaitFor { (Surface).Text -match '(?m)^line200\s*$' } 'the lines to print')

    Notch 1
    Notch 5
} catch {
    if (-not $script:reported) { Write-Host "::error title=wheel-lines::$($_.Exception.Message)" }
    throw
} finally {
    [void][GhosttyWheel.Win32]::SetParam($SPI_SETWHEELSCROLLLINES, $saved, [IntPtr]::Zero, 0)
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
