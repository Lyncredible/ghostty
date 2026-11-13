# Checks `prompt_surface_title`: the "Change Terminal Title" dialog sets the
# terminal's title (the window's title follows it), and an empty title
# clears the override so the shell's title comes back. Ctrl+Backspace in
# the field deletes a word. The dialog's field is set with WM_SETTEXT and OK
# pressed with BM_CLICK. It shows a dialog, so it only runs in CI.
#
#     $env:CI = 'true'; ./title-prompt.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this shows dialogs, so it only runs in CI" }
trap {
    if (-not $script:reported) { Write-Host "::error title=title-prompt::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyTitlePrompt -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, string l);
[DllImport("user32.dll")] public static extern System.IntPtr GetDlgItem(System.IntPtr h, int id);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll", EntryPoint = "SendMessageW")] public static extern System.IntPtr SendInt(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendBuffer(System.IntPtr h, uint m, System.IntPtr w, System.Text.StringBuilder l);
public static string Text(System.IntPtr h) { var s = new System.Text.StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }
// An edit field's text (GetWindowText doesn't read another process's).
public static string FieldText(System.IntPtr h) { var s = new System.Text.StringBuilder(512); SendBuffer(h, 0x000D, (System.IntPtr)512, s); return s.ToString(); }
// A key press and release, with the scan code in lParam.
public static void Key(System.IntPtr h, int vk, int scan) {
  PostMessageW(h, 0x0100, (System.IntPtr)vk, (System.IntPtr)(1 | (scan << 16)));                       // WM_KEYDOWN
  System.Threading.Thread.Sleep(30);
  uint up = 1u | ((uint)scan << 16) | (3u << 30);
  PostMessageW(h, 0x0101, (System.IntPtr)vk, (System.IntPtr)unchecked((int)up));                        // WM_KEYUP
}
'@
$W = [GhosttyTitlePrompt.Win32]

$log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-title-$PID.log"
$process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $log -ArgumentList '--command=cmd.exe',
    '--window-save-state=never', '--keybind=f9=prompt_surface_title'

function Fail([string]$message) {
    Write-Host "::error title=title-prompt::$message"
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
    Fail "timed out waiting for $what (the window's title is '$($W::Text($window))')"
}

# Ghostty's "Change Terminal Title" dialog.
function Dialog {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, '#32770', 'Change Terminal Title')) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $process.Id) { return $h }
    }
}

# Open the dialog, type the title and press OK. With $extra after the
# title, Ctrl+Backspace (its character, U+007F) deletes it first.
function SetTitle([string]$title, [string]$extra = '') {
    $W::Key($surface, 0x78, 0x43)   # F9: prompt_surface_title
    $dialog = WaitFor { Dialog } 'the title dialog'
    # The dialog can be found before its controls are made.
    $edit = WaitFor { $e = $W::FindWindowExW($dialog, [IntPtr]::Zero, 'Edit', [NullString]::Value); if ($e -ne [IntPtr]::Zero) { $e } } "the title dialog's text field"
    [void]$W::SendMessageW($edit, 0x000C, [IntPtr]::Zero, "$title$extra")   # WM_SETTEXT
    if ($extra) {
        [void]$W::SendInt($edit, 0x00B1, [IntPtr]1000, [IntPtr]1000)   # EM_SETSEL: the caret at the end
        [void]$W::PostMessageW($edit, 0x0102, [IntPtr]0x7F, [IntPtr]1)   # WM_CHAR
        [void](WaitFor { $W::FieldText($edit) -eq $title } "Ctrl+Backspace to delete '$extra' (the field has '$($W::FieldText($edit))')")
        Write-Host "Ctrl+Backspace deleted '$extra' in the field."
    }
    $ok = $W::GetDlgItem($dialog, 1)   # IDOK
    if ($ok -eq [IntPtr]::Zero) { Fail 'the title dialog has no OK button' }
    [void]$W::PostMessageW($ok, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
    [void](WaitFor { -not (Dialog) } 'the title dialog to close')
}

try {
    $window = WaitFor { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { $process.MainWindowHandle } } 'the window'
    $surface = WaitFor { $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value); if ($h -ne [IntPtr]::Zero) { $h } } 'the surface'
    $shell = WaitFor { $t = $W::Text($window); if ($t -and $t -notmatch '^Ghostty') { $t } } "the shell's title"
    Write-Host "The shell's title: '$shell'."

    SetTitle 'Title From The Test ' 'Extra'
    [void](WaitFor { $W::Text($window) -match 'Title From The Test' } 'the new title')
    Write-Host "The dialog set the title: '$($W::Text($window))'."

    SetTitle ''
    [void](WaitFor { $t = $W::Text($window); $t -notmatch 'Title From The Test' -and $t -match [regex]::Escape($shell) } "the shell's title to come back")
    Write-Host "An empty title cleared the override: '$($W::Text($window))'."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}
exit 0
