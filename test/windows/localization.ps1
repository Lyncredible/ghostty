# Checks the app's translations: with `LANGUAGE=de` the command palette's
# entries and the terminal's context menu are German, with `LANGUAGE=en`
# (and for a language we have nothing for) they're English, whatever the
# display language of the machine, and the config's `language` wins over
# both. A dialog's title and buttons follow too (the configuration errors
# one). The texts are read from the palette's
# list box, the popup menu and the dialog's windows, and keys and clicks are posted to Ghostty's
# windows, so it runs on a locked desktop.
#
#     ./localization.ps1 -Exe zig-out/bin/ghostty.exe

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
trap {
    if (-not $script:reported) { Write-Host "::error title=localization::$($_.Exception.Message) (at line $($_.InvocationInfo.ScriptLineNumber))" }
    break
}

Add-Type -Namespace GhosttyLocalization -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")] public static extern System.IntPtr SendMessageText(System.IntPtr h, uint m, System.IntPtr w, System.Text.StringBuilder l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindowExW(System.IntPtr parent, System.IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindowLongPtrW(System.IntPtr h, int index);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr context);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(System.IntPtr menu);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(System.IntPtr menu, uint item, System.Text.StringBuilder s, int max, uint flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int max);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int max);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr parent, EnumProc f, System.IntPtr l);
public static string Title(System.IntPtr h) {
  var s = new System.Text.StringBuilder(256); GetWindowTextW(h, s, s.Capacity); return s.ToString();
}
// The labels of a dialog's buttons, at any depth (a task dialog's are
// inside other windows).
public static string[] Buttons(System.IntPtr dialog) {
  var found = new System.Collections.Generic.List<string>();
  EnumChildWindows(dialog, (h, l) => {
    var cls = new System.Text.StringBuilder(64); GetClassNameW(h, cls, cls.Capacity);
    if (cls.ToString() == "Button" && IsWindowVisible(h)) found.Add(Title(h));
    return true;
  }, System.IntPtr.Zero);
  return found.ToArray();
}
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
$W = [GhosttyLocalization.Win32]
# Per-monitor aware (-4), so that rectangles are in real pixels.
[void]$W::SetProcessDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function Fail([string]$message) {
    Write-Host "::error title=localization::$message"
    $script:reported = $true
    Write-Host "--- Ghostty's log ---"
    if (Test-Path $script:log) { Get-Content $script:log -Tail 40 | Write-Host }
    throw $message
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($script:process.HasExited) { Fail "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    Fail "timed out waiting for $what ($script:note)"
}

# The process's visible top-level window of a class.
function TopLevel([string]$class) {
    $h = [IntPtr]::Zero
    while (($h = $W::FindWindowExW([IntPtr]::Zero, $h, $class, [NullString]::Value)) -ne [IntPtr]::Zero) {
        $id = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$id)
        if ($id -eq $script:process.Id -and $W::IsWindowVisible($h)) { return $h }
    }
    [IntPtr]::Zero
}

# Start Ghostty with LANGUAGE set (or unset, for null), and read: the log's
# line about translations, the title of the palette's entry for
# `new_split:right`, and the context menu's first item.
function Texts([string]$language, [string[]]$options = @()) {
    $old = $env:LANGUAGE
    $env:LANGUAGE = $language
    $script:log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-localization-$PID.log"
    try {
        $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $script:log -ArgumentList (@('--command=cmd.exe') +
            (@('--window-save-state=never', '--keybind=f9=toggle_command_palette', '--keybind=f8=start_search', '--keybind=f7=end_search', "--class=ghostty-localization-$PID") + $options))
    } finally { $env:LANGUAGE = $old }

    try {
        $window = WaitFor { $h = TopLevel 'GhosttyWindow'; if ($h -ne [IntPtr]::Zero) { $h } } 'the window'
        $surface = WaitFor {
            $h = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttySurface', [NullString]::Value)
            if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h }
        } 'the terminal'

        # The command palette's entry.
        $W::Key($surface, 0x78, 0x43)   # F9: toggle_command_palette
        $palette = WaitFor { $h = $W::FindWindowExW($surface, [IntPtr]::Zero, 'GhosttyCommandPalette', [NullString]::Value); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the command palette'
        $edit = $W::FindWindowExW($palette, [IntPtr]::Zero, 'Edit', [NullString]::Value)
        $list = $W::FindWindowExW($palette, [IntPtr]::Zero, 'ListBox', [NullString]::Value)
        # Laid out right to left: the field's text at the right
        # (WS_EX_RIGHT) and the list's scrollbar on the left
        # (WS_EX_LEFTSCROLLBAR). GWL_EXSTYLE is -20.
        $fieldRight = ([long]$W::GetWindowLongPtrW($edit, -20) -band 0x1000) -ne 0
        $barLeft = ([long]$W::GetWindowLongPtrW($list, -20) -band 0x4000) -ne 0
        $all = WaitFor { $n = [int]$W::SendMessageW($list, 0x018B, [IntPtr]0, [IntPtr]0); $script:note = "$n entries"; if ($n -ge 10) { $n } } 'the full list'   # LB_GETCOUNT
        $W::Type($edit, 'new_split:right')
        [void](WaitFor { $n = [int]$W::SendMessageW($list, 0x018B, [IntPtr]0, [IntPtr]0); $script:note = "$n of $all entries"; $n -eq 1 } 'the list to narrow to one entry')
        $length = [int]$W::SendMessageW($list, 0x018A, [IntPtr]0, [IntPtr]0)   # LB_GETTEXTLEN
        if ($length -le 0 -or $length -gt 500) { Fail "the palette's entry has a title of length $length" }
        $title = New-Object Text.StringBuilder ($length + 1)
        [void]$W::SendMessageText($list, 0x0189, [IntPtr]0, $title)   # LB_GETTEXT
        $W::Key($edit, 0x1B, 0x01)   # Escape
        [void](WaitFor { $script:note = 'still shown'; -not $W::IsWindowVisible($palette) } 'the palette to close')

        # The search bar: mirrored (WS_EX_LAYOUTRTL) and in the terminal's
        # left half for a right-to-left language, in the right half
        # otherwise.
        $W::Key($surface, 0x77, 0x42)   # F8: start_search
        $bar = WaitFor { $script:note = 'no search bar'; $h = $W::FindWindowExW($surface, [IntPtr]::Zero, 'GhosttySearchBar', [NullString]::Value); if ($h -ne [IntPtr]::Zero -and $W::IsWindowVisible($h)) { $h } } 'the search bar'
        $barRect = New-Object GhosttyLocalization.Win32+RECT; [void]$W::GetWindowRect($bar, [ref]$barRect)
        $surfaceRect = New-Object GhosttyLocalization.Win32+RECT; [void]$W::GetWindowRect($surface, [ref]$surfaceRect)
        $barMirrored = ([long]$W::GetWindowLongPtrW($bar, -20) -band 0x400000) -ne 0
        $barOnLeft = ($barRect.Left + $barRect.Right) -lt ($surfaceRect.Left + $surfaceRect.Right)
        $W::Key($surface, 0x76, 0x41)   # F7: end_search
        [void](WaitFor { $script:note = 'still shown'; -not $W::IsWindowVisible($bar) } 'the search bar to close')

        # The tab bar: mirrored for a right-to-left language, so the tab
        # is in the window's right half and the maximize button (found
        # by the window's hit test, HTMAXBUTTON, in the middle of the
        # three 46-wide caption buttons) is near its left edge.
        $bar = $W::FindWindowExW($window, [IntPtr]::Zero, 'GhosttyTabBar', [NullString]::Value)
        $tabsMirrored = ([long]$W::GetWindowLongPtrW($bar, -20) -band 0x400000) -ne 0
        $barRect = New-Object GhosttyLocalization.Win32+RECT; [void]$W::GetWindowRect($bar, [ref]$barRect)
        $middle = ($barRect.Left + $barRect.Right) / 2
        $tab = WaitFor {
            $script:note = 'no tab item'
            [System.Windows.Automation.AutomationElement]::FromHandle($window).FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)))
        } 'the tab, through UI Automation'
        $tabRect = $tab.Current.BoundingRectangle
        if ($tabRect.Width -le 0 -or $tabRect.Left -lt $barRect.Left -or $tabRect.Right -gt $barRect.Right) { Fail "LANGUAGE=$language`: the tab's rectangle $tabRect isn't inside the tab bar ($($barRect.Left)..$($barRect.Right))" }
        $tabOnRight = ($tabRect.Left + $tabRect.Width / 2) -gt $middle
        $dpi = $W::GetDpiForWindow($window)
        $inset = [int](46 * 1.5 * $dpi / 96)
        $y = $barRect.Top + [int](16 * $dpi / 96)
        $hits = foreach ($x in @(($barRect.Left + $inset), ($barRect.Right - $inset))) {
            [int]$W::SendMessageW($window, 0x0084, [IntPtr]0, [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)))   # WM_NCHITTEST
        }
        $maximizeOnLeft = "$($hits[0] -eq 9)/$($hits[1] -eq 9)"   # HTMAXBUTTON

        # The context menu's first item, without its shortcut.
        [void]$W::PostMessageW($surface, 0x0204, [IntPtr]2, [IntPtr]((40 -shl 16) -bor 40))   # WM_RBUTTONDOWN, MK_RBUTTON
        [void]$W::PostMessageW($surface, 0x0205, [IntPtr]0, [IntPtr]((40 -shl 16) -bor 40))   # WM_RBUTTONUP
        $popup = WaitFor { $script:note = 'no popup menu'; $h = TopLevel '#32768'; if ($h -ne [IntPtr]::Zero) { $h } } 'the context menu'
        $menu = $W::SendMessageW($popup, 0x01E1, [IntPtr]0, [IntPtr]0)   # MN_GETHMENU
        if ($menu -eq [IntPtr]::Zero) { Fail 'the popup has no menu' }
        $count = $W::GetMenuItemCount($menu)
        $item = New-Object Text.StringBuilder 256
        [void]$W::GetMenuStringW($menu, 0, $item, $item.Capacity, 0x400)   # MF_BYPOSITION
        [void]$W::PostMessageW($popup, 0x0100, [IntPtr]0x1B, [IntPtr]0x00010001)   # Escape closes the menu

        # The last: the config's language is applied after the system's.
        $line = Get-Content $script:log -ErrorAction SilentlyContinue | Where-Object { $_ -match 'translations locale=' } | Select-Object -Last 1
        @{
            Log = "$line"
            Title = $title.ToString()
            Item = ($item.ToString() -split "`t")[0]
            ItemCount = $count
            RightToLeft = "$fieldRight/$barLeft"
            Search = "$barMirrored/$barOnLeft"
            Tabs = "$tabsMirrored/$tabOnRight/$maximizeOnLeft"
        }
    } finally {
        if (-not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
        Remove-Item -LiteralPath $script:log -Force -ErrorAction SilentlyContinue
    }
}

function Expect($texts, [string]$language, [string]$title, [string]$item, [string]$locale) {
    $got = "palette '$($texts.Title)', menu '$($texts.Item)' ($($texts.ItemCount) items), log '$($texts.Log)'"
    if ($texts.Title -cne $title) { Fail "LANGUAGE=$language`: the palette's entry should be '$title': $got" }
    if ($texts.Item -cne $item) { Fail "LANGUAGE=$language`: the menu's first item should be '$item': $got" }
    if ($locale -and $texts.Log -notmatch "translations locale=$locale ") { Fail "LANGUAGE=$language`: the log should say locale=$locale`: $got" }
    if (-not $locale -and $texts.Log) { Fail "LANGUAGE=$language`: no translations should load: $got" }
    Write-Host "LANGUAGE=$language`: $got"
}

# German, by its language alone and as a POSIX locale after one we don't
# have.
$german = Texts 'de'
Expect $german 'de' 'Nach rechts teilen' 'Kopieren' 'de'
Expect (Texts 'tlh:de_DE.UTF-8') 'tlh:de_DE.UTF-8' 'Nach rechts teilen' 'Kopieren' 'de'

# English, and a language we have nothing for: the messages as written,
# with the menu's access keys.
$english = Texts 'en'
Expect $english 'en' 'Split Right' '&Copy' ''
if ($english.ItemCount -ne $german.ItemCount) { Fail "the menu has $($german.ItemCount) items in German and $($english.ItemCount) in English" }
Expect (Texts 'tlh') 'tlh' 'Split Right' '&Copy' ''

# Hebrew is written right to left, so the palette is laid out that way
# too; German and English aren't.
$hebrew = Texts 'he'
if ($hebrew.Log -notmatch 'translations locale=he ') { Fail "LANGUAGE=he: the log should say locale=he: '$($hebrew.Log)'" }
if ($hebrew.Title -ceq 'Split Right' -or -not $hebrew.Title) { Fail "LANGUAGE=he: the palette's entry isn't translated: '$($hebrew.Title)'" }
if ($hebrew.ItemCount -ne $english.ItemCount) { Fail "the menu has $($hebrew.ItemCount) items in Hebrew and $($english.ItemCount) in English" }
if ($hebrew.RightToLeft -ne 'True/True') { Fail "LANGUAGE=he: the palette should be laid out right to left (field/scrollbar): $($hebrew.RightToLeft)" }
if ($hebrew.Search -ne 'True/True') { Fail "LANGUAGE=he: the search bar should be mirrored and on the left (mirrored/left): $($hebrew.Search)" }
if ($hebrew.Tabs -ne 'True/True/True/False') { Fail "LANGUAGE=he: the tab bar should be mirrored, the tab on the right and the maximize button on the left (mirrored/tab right/maximize left/maximize right): $($hebrew.Tabs)" }
foreach ($other in @($german, $english)) {
    if ($other.Tabs -ne 'False/False/False/True') { Fail "the tab bar should be unmirrored outside Hebrew (mirrored/tab right/maximize left/maximize right): $($other.Tabs)" }
    if ($other.Search -ne 'False/False') { Fail "the search bar should be unmirrored and on the right outside Hebrew (mirrored/left): $($other.Search)" }
    if ($other.RightToLeft -ne 'False/False') { Fail "the palette should be laid out left to right outside Hebrew (field/scrollbar): $($other.RightToLeft)" }
}
Write-Host "LANGUAGE=he: the palette is translated and laid out right to left, the search bar is mirrored on the left, and the tab bar is mirrored."

# The config's `language` wins over the environment's, both ways.
$forced = Texts 'en' @('--language=de')
Expect $forced 'en --language=de' 'Nach rechts teilen' 'Kopieren' 'de'
$forced = Texts 'de' @('--language=en')
if ($forced.Title -cne 'Split Right' -or $forced.Item -cne '&Copy') { Fail "LANGUAGE=de --language=en should be English: palette '$($forced.Title)', menu '$($forced.Item)'" }
Write-Host "LANGUAGE=de --language=en: palette '$($forced.Title)', menu '$($forced.Item)'"
$forced = Texts 'he' @('--language=en')
if ($forced.Title -cne 'Split Right' -or $forced.RightToLeft -ne 'False/False') { Fail "LANGUAGE=he --language=en should be English, left to right: palette '$($forced.Title)', field/scrollbar $($forced.RightToLeft)" }
Write-Host "LANGUAGE=he --language=en: palette '$($forced.Title)', laid out left to right"

# A dialog: the configuration errors one, which an option that doesn't
# exist brings up at start. Its title and both buttons are in the
# language (they're GTK's messages), or all English.
function DialogTexts([string]$language) {
    $old = $env:LANGUAGE
    $env:LANGUAGE = $language
    $script:log = Join-Path ([IO.Path]::GetTempPath()) "ghostty-localization-$PID.log"
    try {
        $script:process = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $script:log -ArgumentList '--command=cmd.exe',
            '--window-save-state=never', '--not-a-real-option=1', "--class=ghostty-localization-$PID"
    } finally { $env:LANGUAGE = $old }
    try {
        $dialog = WaitFor { $script:note = 'no dialog'; $h = TopLevel '#32770'; if ($h -ne [IntPtr]::Zero) { $h } } 'the configuration errors dialog'
        $buttons = WaitFor { $b = @($W::Buttons($dialog) | Where-Object { $_ }); $script:note = "$($b.Count) buttons"; if ($b.Count -ge 2) { , $b } } "the dialog's buttons"
        $title = $W::Title($dialog)
        # The reject button (ID 2), by TDM_CLICK_BUTTON, until it goes.
        [void](WaitFor {
            [void]$W::PostMessageW($dialog, 0x0466, [IntPtr]2, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 300
            $script:note = 'still open'
            (TopLevel '#32770') -eq [IntPtr]::Zero
        } 'the dialog to close')
        "$title`: $($buttons -join ' / ')"
    } finally {
        if (-not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
        Remove-Item -LiteralPath $script:log -Force -ErrorAction SilentlyContinue
    }
}
foreach ($case in @(@('de', 'Konfigurationsfehler: Konfiguration neu laden / Ignorieren'), @('en', 'Configuration Errors: Reload Configuration / Ignore'))) {
    $got = DialogTexts $case[0]
    if ($got -cne $case[1]) { Fail "LANGUAGE=$($case[0]): the configuration errors dialog should read '$($case[1])': '$got'" }
    Write-Host "LANGUAGE=$($case[0]): dialog '$got'"
}
exit 0
