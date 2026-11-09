# Checks the scrollbar: cmd prints 301 numbered lines, and clicks posted
# to the scrollbar's track scroll the terminal (the thumb jumps there,
# centered on the click): the top shows the start of the scrollback, the
# bottom the last line, and the middle a line in between. The surface's UI
# Automation value is the text in view. Clicks are posted, so it runs on a
# locked desktop.
#
#     ./scrollbar.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=scrollbar::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyScrollbarTest -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
public static void Type(System.IntPtr h, string s) {
  foreach (char ch in s) { PostMessageW(h, 0x0102, (System.IntPtr)ch, (System.IntPtr)1); System.Threading.Thread.Sleep(5); }
}
// A left click at a point in the window's client area. With strayY >= 0,
// a move without a button comes in between, at that height: taking the
// capture makes Windows send one at the real cursor, wherever it is.
public static void Click(System.IntPtr h, int x, int y, int strayY) {
  System.IntPtr at = (System.IntPtr)((y << 16) | (x & 0xFFFF));
  PostMessageW(h, 0x0201, (System.IntPtr)1, at);   // WM_LBUTTONDOWN, MK_LBUTTON
  if (strayY >= 0) PostMessageW(h, 0x0200, System.IntPtr.Zero, (System.IntPtr)((strayY << 16) | (x & 0xFFFF))); // WM_MOUSEMOVE
  System.Threading.Thread.Sleep(30);
  PostMessageW(h, 0x0202, System.IntPtr.Zero, at); // WM_LBUTTONUP
}
'@
$W = [GhosttyScrollbarTest.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-scrollbar-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never'

function Fail([string]$message) {
    Write-Host "::error title=scrollbar::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what ($script:note)"
}

function ScreenText {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($surface)
    $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}

# The numbered lines in view (L1000 to L1300), or none.
function Numbers {
    $text = ScreenText
    $script:note = "in view: $(($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' / ') ..."
    @([regex]::Matches($text, '(?m)^L(\d{4})\s*$') | ForEach-Object { [int]$_.Groups[1].Value })
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', $null); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
    [void](WaitFor { $script:note = 'no prompt yet'; (ScreenText) -match '>\s*$' } 'the prompt')

    $W::Type($surface, "for /L %i in (1000,1,1300) do @echo L%i`r")
    [void](WaitFor { (Numbers) -contains 1300 -and (ScreenText) -match '>\s*$' } 'the last line, L1300, and the prompt')
    $bar = WaitFor { $h = $W::FindWindowExW($surface, [IntPtr]::Zero, 'GhosttyScrollbar', $null); if ($h -ne [IntPtr]::Zero) { $h } } 'the scrollbar'
    $rect = New-Object GhosttyScrollbarTest.Win32+RECT
    [void]$W::GetClientRect($bar, [ref]$rect)
    if ($rect.b -lt 100) { Fail "the scrollbar is only $($rect.b) px tall" }
    $x = [int]($rect.r / 2)
    Write-Host "The scrollbar is $($rect.r) by $($rect.b) px, and L1300 is in view."

    # The top of the track: the start of the scrollback, cmd's banner.
    $W::Click($bar, $x, 3, -1)
    [void](WaitFor { (ScreenText) -match 'Microsoft Windows' -and -not ((Numbers) -contains 1300) } 'the start of the scrollback')
    Write-Host "A click at the top of the track scrolled to cmd's banner."

    # The middle: a line from the middle of the output (the scrollback has
    # the banner and the command before it, so a little before L1150).
    $W::Click($bar, $x, [int]($rect.b / 2), -1)
    $middle = WaitFor { $n = Numbers; if ($n.Count -gt 0 -and $n[0] -gt 1050 -and $n[-1] -lt 1250) { $n } } 'the middle of the output'
    Write-Host "A click in the middle of the track shows L$($middle[0]) to L$($middle[-1])."

    # The bottom: the end again, even with a stray move at the top of the
    # track while the button is down (it isn't a drag without the button;
    # it once threw the thumb to the real cursor on CI's runner).
    $W::Click($bar, $x, $rect.b - 3, 3)
    [void](WaitFor { (Numbers) -contains 1300 } 'the end of the output')
    Write-Host 'A click at the bottom of the track scrolled back to L1300.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
