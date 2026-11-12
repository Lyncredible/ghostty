# Checks the command palette: `toggle_command_palette` opens it with many
# entries, typing `new_split:right` narrows the list, Enter runs the entry
# (the terminal splits left and right) and closes the palette, and Escape
# closes it again without doing anything. Then `close_surface`, `undo` and
# `redo` from the palette close the split, reopen it and close it again. Keys and characters are posted to
# Ghostty's windows, so it runs on a locked desktop.
#
#     ./command-palette.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=command-palette::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyPalette -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
// Characters, as WM_CHAR.
public static void Type(System.IntPtr h, string s) {
  foreach (char ch in s) { PostMessageW(h, 0x0102, (System.IntPtr)ch, (System.IntPtr)1); System.Threading.Thread.Sleep(5); }
}
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyPalette.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-palette-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f9=toggle_command_palette',
    '--confirm-close-surface=false', '--undo-timeout=60s'

function Fail([string]$message) {
    Write-Host "::error title=command-palette::$message"
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

# The window's visible terminals.
function Terminals {
    $list = @(); $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW($window, $h, 'GhosttySurface', [NullString]::Value)) -ne [IntPtr]::Zero) {
        if ($W::IsWindowVisible($h)) { $list += $h }
    }
    $script:note = "$($list.Count) terminals"
    , $list
}

function Open([IntPtr]$surface) {
    $W::Key($surface, 0x78, 0x43)   # F9: toggle_command_palette
    $palette = WaitFor { $h = $W::FindWindowExW($surface, [IntPtr]::Zero, 'GhosttyCommandPalette', [NullString]::Value); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the command palette'
    @{
        Palette = $palette
        Edit = $W::FindWindowExW($palette, [IntPtr]::Zero, 'Edit', [NullString]::Value)
        List = $W::FindWindowExW($palette, [IntPtr]::Zero, 'ListBox', [NullString]::Value)
    }
}
function Entries($p) { [int]$W::SendMessageW($p.List, 0x018B, [IntPtr]0, [IntPtr]0) }   # LB_GETCOUNT

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $surface = WaitFor { $t = Terminals; if ($t.Count -eq 1) { $t[0] } } 'the terminal'

    $p = Open $surface
    if ($p.Edit -eq [IntPtr]::Zero -or $p.List -eq [IntPtr]::Zero) { Fail 'the command palette has no field or list' }
    $all = WaitFor { $n = Entries $p; $script:note = "$n entries"; if ($n -ge 10) { $n } } 'the full list'

    $W::Type($p.Edit, 'new_split:right')
    $narrowed = WaitFor { $n = Entries $p; $script:note = "$n of $all entries"; if ($n -ge 1 -and $n -lt $all) { $n } } 'the list to narrow'
    Write-Host "Typing new_split:right narrows $all entries to $narrowed."

    $W::Key($p.Edit, 0x0D, 0x1C)   # Enter
    # Wait for the layout too: the new terminal can show before the two are
    # placed side by side (on a runner, both had the old one's rectangle).
    $split = WaitFor {
        $t = Terminals
        if ($t.Count -ne 2) { return }
        $rects = @($t | ForEach-Object { $r = New-Object GhosttyPalette.Win32+RECT; [void]$W::GetWindowRect($_, [ref]$r); $r } | Sort-Object l)
        $script:note = "($($rects[0].l),$($rects[0].t)-$($rects[0].r),$($rects[0].b)) and ($($rects[1].l),$($rects[1].t)-$($rects[1].r),$($rects[1].b))"
        if ($rects[0].r -le $rects[1].l -and $rects[0].t -eq $rects[1].t) { $t }
    } 'the split, left and right'
    [void](WaitFor { $script:note = 'still shown'; -not $W::IsWindowVisible($p.Palette) } 'the palette to close')
    Write-Host 'Enter ran it: the terminal split left and right, and the palette closed.'

    # Escape closes it and runs nothing.
    $p = Open $split[0]
    $W::Type($p.Edit, 'new_split')
    [void](WaitFor { $n = Entries $p; $script:note = "$n entries"; $n -ge 1 } 'matches for new_split')
    $W::Key($p.Edit, 0x1B, 0x01)   # Escape
    [void](WaitFor { $script:note = 'still shown'; -not $W::IsWindowVisible($p.Palette) } 'Escape to close the palette')
    Start-Sleep -Milliseconds 500
    if ((Terminals).Count -ne 2) { Fail "Escape ran something: $note" }
    Write-Host 'Escape closes it without running anything.'

    # Undo and redo are listed: close a split, reopen it, close it again.
    function Run([IntPtr]$surface, [string]$query) {
        $p = Open $surface
        $W::Type($p.Edit, $query)
        [void](WaitFor { $n = Entries $p; $script:note = "$n entries for $query"; if ($n -ge 1 -and $n -lt $all) { $n } } "matches for $query")
        $W::Key($p.Edit, 0x0D, 0x1C)   # Enter
        [void](WaitFor { $script:note = 'still shown'; -not $W::IsWindowVisible($p.Palette) } 'the palette to close')
    }
    Run $split[1] 'close_surface'
    $one = WaitFor { $t = Terminals; if ($t.Count -eq 1) { $t } } 'the split to close'
    Run $one[0] 'undo'
    $two = WaitFor { $t = Terminals; if ($t.Count -eq 2) { $t } } 'undo to reopen the split'
    Run $two[0] 'redo'
    [void](WaitFor { $t = Terminals; if ($t.Count -eq 1) { $t } } 'redo to close the split again')
    Write-Host 'Undo from the palette reopened a closed split, and redo closed it again.'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
