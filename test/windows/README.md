# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info + ghostty_init to
verify the MSVC C runtime is properly initialized.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```
copy ..\..\zig-out\lib\ghostty-internal.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".

## unit-tests.ps1

Runs `zig build test` for a target and, if it fails, repeats the failing
tests' output as a GitHub Actions error annotation, which anyone can read
from the run without signing in (job logs need a sign-in). CI's Test steps
use it. `-Filter` passes a test filter.

```
pwsh -NoProfile -File unit-tests.ps1 -Target x86_64-windows-gnu -Filter windows
```

## powershell-integration.ps1

Loads the PowerShell shell integration without a terminal and checks the
escape sequences its prompt writes (OSC 7, 2, and 133, and the cursor
shape), including a failed command's exit code. CI runs it with both
Windows PowerShell 5.1 and PowerShell 7.

```
powershell -NoProfile -ExecutionPolicy Bypass -File powershell-integration.ps1
pwsh -NoProfile -File powershell-integration.ps1
```

## smoke.ps1

Starts the app with a shell, waits for its prompt (through UI
Automation), types `cd` to a directory by posting messages to the
window, and checks Ghostty's debug log for shell integration and the new
pwd. It needs a debug build and a desktop session, but not focus. CI
runs it with PowerShell 7, Windows PowerShell, and cmd.

```
./smoke.ps1 -Exe ../../zig-out/bin/ghostty.exe -Command "pwsh.exe -NoLogo -NoProfile" -Prompt "PS "
./smoke.ps1 -Exe ../../zig-out/bin/ghostty.exe -Command "cmd.exe" -Prompt ">" -Cd "cd /d"
```

## desktop-input.ps1

Checks typing, Ctrl+V pasting, Ctrl+C copying (with a selection) and
interrupting (without), focus-follows-mouse between splits,
mouse-hide-while-typing, and window-step-resize while dragging the window's corner
with real (synthesized) keyboard and mouse input. Since that input goes to
the foreground window, it refuses to run unless `CI` is `true`; CI runs it
on the runner's desktop.

## links.ps1

Ctrl+clicks OSC 8 hyperlinks and checks the checks for links from
terminal output: a link to a text file opens it in Notepad, a link to a
`.vbs` script shows "Link Blocked" and the script doesn't run, and an
`ms-settings:` link asks first (the script answers No). Before each
click, holding Ctrl over the link must show the link preview, just above
the scrollbar in the surface's child windows. It sends real
input and opens apps, so it refuses to run unless `CI` is `true`.

## paste-race.ps1

Pastes two lines (an unsafe paste) with a key bound to
`paste_from_clipboard` and checks the warning dialog: Cancel closes it
without pasting, and when the shell exits while it's open, the dialog
goes away and Ghostty exits cleanly (or stays responsive). It sets the
clipboard and shows dialogs, so it refuses to run unless `CI` is `true`.

## bell-flash.ps1

Rings the bell from a script in the terminal and watches for taskbar
flashes with a shell hook window of its own (`HSHELL_FLASH`): with
`bell-features=attention`, Ghostty's button flashes while it's in the
background and not while it's in front; with `no-attention`, it doesn't
flash. It changes the foreground window, so it only runs in CI.

## dialog-race.ps1

Opens the dialogs that keybindings show, with keys posted to the
terminal: "Close terminal?" (`close_surface` while `ping` runs), whose OK
must close the terminal, and then that dialog and "Change Terminal
Title" (`prompt_surface_title`) "Quit Ghostty?" (`quit`), and
"Configuration Errors" (`reload_config` after its own config file gained
an unknown option) while the shell exits, after which
Ghostty must exit cleanly or stay responsive. It shows dialogs, so it
refuses to run unless `CI` is `true`.

## handoff.ps1

Hands a console session to a running Ghostty the way Windows' console
host does when Ghostty is the default terminal application:
`handoff_client.c` (built with `zig cc`) creates a pseudoconsole running
cmd and calls Ghostty's terminal handoff class (`ITerminalHandoff3`) with
its handles, relaying the pipes Ghostty returns. A new window must show
cmd's output, typed input (posted `WM_CHAR`s) must reach cmd, and when cmd
exits its window must close while Ghostty keeps running. It needs Windows
Terminal (for the interface's proxy) and skips without it. It doesn't
change the default terminal, so it can run locally.

## default-terminal.ps1

With the MSIX installed, sets the console delegation to Windows
Terminal's OpenConsole and the terminal delegation to Ghostty's handoff
class (what Settings > For developers > Terminal sets), starts cmd in a
new console, and checks that its output shows up in the packaged Ghostty.
It changes the default terminal (and restores it), so it only runs in CI.

## start-menu.ps1

Starts an installed Ghostty the way the Start menu does (the MSIX by its
app ID, or the zip's `install.ps1` shortcut) and checks that a window
opens from the installed location with its shell in the home directory;
for the zip it also uninstalls. It only runs in CI.

## drag-drop.ps1

Drags a file (a real OLE drag, as from Explorer) from a window of its own
onto a terminal running cmd, and checks that its path was pasted. It moves
the mouse and holds its button, so it only runs in CI, with Windows
PowerShell (an STA thread). `-PowerShell` drops a file named
`drop $(Write-Output RAN).txt` on PowerShell and expects it single-quoted;
with `-Nested`, that PowerShell runs under cmd.

## touch-scroll.ps1

Fills cmd with numbered lines, drags a software finger down the terminal
with `InjectTouchInput`, and checks that earlier lines scrolled into
view. It only runs in CI.

## wheel-lines.ps1

Fills cmd with numbered lines, sets Windows' "lines to scroll at a time"
to 1 and then 5 (for the session, not saved), posts a wheel notch for
each, and checks the view scrolled that many lines. It changes a desktop
setting, so it only runs in CI.

## context-menu.ps1

Posts a right-click to a terminal and waits for the process's popup menu
(`#32768`) to show. Releasing the mouse capture on the button's release
once canceled the pending menu, so it never opened.

## cursor-blink.ps1

Focuses a small Ghostty window, times the cursor's blinks on screen
against Windows' cursor blink rate, then turns blinking off
(`SetCaretBlinkTime(INFINITE)`, restored afterwards) and checks the
screen stays still. It takes focus and changes a desktop setting, so it
only runs in CI.

## high-contrast.ps1

Starts Ghostty with the tab bar shown and a blue background, checks the
tab bar's color on screen comes from the terminal's background, turns a
high contrast theme on (`SPI_SETHIGHCONTRAST`) and expects the theme's
window color, then turns it off and expects the terminal's again. It
changes the whole desktop, so it only runs in CI.

## device-lost.ps1

Starts a debug build with `GHOSTTY_D3D11_LOSE_DEVICE=3`, which acts as if
the Direct3D device was removed at the third present (as when Windows
updates or restarts the graphics driver), and checks the log says the
device was replaced and the renderer is healthy again, and that the window
(read with `PrintWindow`) shows the background and cmd's banner. It runs
again with a custom shader that swaps red and blue, and expects the
swapped background, and with a solid background image (stretched), and
expects its color. It only opens Ghostty's own window, so it can run
anywhere.

## dark-mode.ps1

Starts Ghostty with a light and a dark theme, switches Windows between
light and dark app mode while it runs, and checks the terminal's
background color from the screen. It changes the whole desktop, so it
only runs in CI.

## tab-tooltips.ps1

Opens a terminal with the tab bar shown, moves the real cursor over the
"New Tab" button and then the tab, and checks that each shows a tooltip
with its name. It moves the mouse, so it only runs in CI.

## uia-events.ps1

Listens for the UI Automation events a screen reader gets: types `echo`
(as `WM_CHAR` messages) and waits for the output's notification event,
runs `select_all` for `TextSelectionChanged`, and opens a tab for the tab
bar's `ElementSelected` (with the tab bar shown from the start). The listener is `uia_events.c`, a client of the
native UI Automation COM API (as screen readers are), which the script
builds with `zig cc`. It only sends messages to Ghostty's windows, but
needs an unlocked desktop.

## quick-terminal.ps1

Toggles the quick terminal over IPC, samples its position while it slides
in and out with Windows' animation effects turned on (they're off on CI's
runners), and checks that it ends up hidden. With them off, it checks that
it appears and hides without sliding. The setting is restored after. Then
it adds a virtual desktop (Ctrl+Win+D) and checks that showing the quick
terminal shows it there, without Windows switching back. It sends real
keys and changes a system setting, so it only runs in CI.

## translucent.ps1

Opens an opaque red Ghostty window, then a half transparent one on top of
it (`-Blur` adds `background-blur`), splits it, and scrolls the left pane.
Both panes must show red through them, and the scrollbar's thumb must be
drawn with the red still showing around it. A posted
`toggle_background_opacity` must hide the red, and a second one show it
again. Then it opens the search bar
and the command palette, which must hide the red behind them. With `-Blur` it only reports
the colors, since Windows draws acrylic as a solid color without a GPU (as
on GitHub's runners). It only sends messages to
Ghostty's windows, so it can run locally, but it reads the screen, so the
desktop must be unlocked.

## dpi-change.ps1

Raises the display's scale while a terminal runs (as the Settings app
does), which sends the window the same `WM_DPICHANGED` as moving it to a
monitor with another scale, and checks that its cells grew with the DPI
and that the window took the size Windows suggested. It changes the display's resolution and scale, so it only
runs in CI.

## ime.ps1

Installs the Japanese IME, switches a terminal running cmd to it, types
"nihon" with real keys, converts and commits it, and checks that the kanji
reached cmd. It only runs in CI.

## flood.ps1

Floods a terminal with output from cmd, which changes the title with each
line, and sends the window `WM_NULL` messages meanwhile: most must be
answered within 200 ms. Run it on a release build (`-Exe`, or the
package's with `-Zip`); the debug build is too slow to show a hang. It
only sends messages to Ghostty's window, so it can run locally; in CI it
also presses Ctrl+C and checks that the flood stops.

## output-frames.ps1

Starts a program that prints a letter every 250 ms and counts Ghostty's
frames with the DXGI ETW provider (`logman`, no input needed): there must
be about one frame per letter. Cursor blinks alone give about 10 in the 6
seconds, which is what a build gets when output doesn't wake the renderer.
It also reports the frame rate while output floods in.

## minimize.ps1

Minimizes and restores a window (posted `WM_SYSCOMMAND`s) while output
floods in. The terminal must keep its size while minimized, nothing may be
drawn, and drawing must resume after restoring.

## mouse-capture.ps1

Starts a drag selection (posted button and move messages), then takes the
mouse capture away with `WM_CANCELMODE`, as when another window takes it
mid-drag. Later moves must not change the selection, which is read through
UI Automation.

## overlays.ps1

Checks that a new surface has no badge, search bar, command palette, dim
overlay, bell border, link preview, drop zone or drag handle windows
(they're made when they first show), then toggles read-only mode with a posted key: the read-only badge
must show in the top right, just below the scrollbar in the surface's child
windows (where it was when badges were made up front), and hide again. A
posted F8 types `echo` and a BEL into cmd: the bell border must show just
above the scrollbar. Then it opens the search bar and the command palette
from the window menu: each must show on top (the palette with its commands
listed) and close with a posted Escape. Last, a split from the window menu
must dim the first terminal, with its dim overlay just above the bell
border and below the search bar and palette. Then it drags the first
terminal's drag handle over the second with posted mouse messages: the
second's drop zone must show on top, and letting go over the first must
hide it and move nothing. It only posts messages to
Ghostty's own window. (The link preview needs a real Ctrl key, so
`links.ps1` checks it.)

## window-theme.ps1

Checks `set_window_theme` with `theme = light:Builtin Light,dark:Builtin
Dark`: forcing the window theme opposite to Windows's app mode shows the
other theme, it outlasts a config reload, forcing the other one and back
works, and `config` follows the app mode again. Keys bound to the actions
are posted to the terminal and the background is read with `PrintWindow`,
so it runs on a locked desktop and changes no desktop settings.

## wsl-ssh.sh

Runs inside a WSL distribution and checks the WSL version of `ghostty +ssh`
(`shell-integration/wsl/bin/ghostty`) with a fake `ssh` that answers
`ssh -G` and runs the terminfo installer locally, in a temporary `HOME`:
the first connection installs `xterm-ghostty` and caches the host, the next
one uses the cache, `--terminfo=false` and `--forward-env=false` work, a
failed install falls back to `xterm-256color`, `-G` goes straight to ssh,
and the launcher and the bash and zsh integrations only wrap `ssh` when the
script is there. It needs no sshd and changes nothing outside the
temporary directory. Pass the resources directory as a Linux path:

    wsl.exe -e sh test/windows/wsl-ssh.sh /mnt/c/.../zig-out/share/ghostty

## session-restore.ps1

Checks `window-save-state = always` with its own `--class` (so its own state
file and instance): a split and a second tab are saved when Ghostty quits
(the JSON has one window, a split tab and a plain tab), and starting again
restores three terminals with only the active tab's showing, and the first
tab's split left and right. Inactive tabs' terminals once showed through
after a restore. Keys bound to the actions are posted to the terminal.
Then a saved session with a PowerShell tab (its command saved, as for a
shell chosen from the new tab menu) in `C:\Windows` and a cmd tab in the
temporary directory comes back with those shells and directories (read from
the prompts with UI Automation), and quitting saves the PowerShell tab's
command again.

## search.ps1

Checks the search bar: cmd prints a marker three times (six matches with
the command line), `start_search` opens the bar, typing the marker into its
field counts six matches, `navigate_search:next` selects a match and then
another, `:previous` goes back, and `end_search` closes it. The count is
read from the bar's window text ("Match 2 of 6"), which is also what screen
readers see.

## splits.ps1

Checks the split actions from keybinds: `new_split:right` makes two even
terminals side by side with the new one focused, `goto_split:left` and
`goto_split:right` move the keyboard focus (read from Ghostty's thread
with `GetGUIThreadInfo`), `resize_split:right,200` moves the divider 200
pixels, `equalize_splits` evens them out, and `toggle_split_zoom` gives
the focused terminal the whole tab and then puts both back. Keys are
posted, so it runs on a locked desktop.

## window-actions.ps1

Checks the window actions from keybinds, each there and back:
`toggle_maximize`, `toggle_fullscreen` (the window covers its monitor,
then returns, and so does its terminal's size, with the tabs back in the
title bar), `toggle_window_float_on_top` (`WS_EX_TOPMOST`), and
`reset_window_size` after a resize and after maximizing. The first
window must already be the size `reset_window_size` gives. Last,
`close_window` must close the window, and Ghostty must quit. Keys are
posted to the terminal, so it runs on a locked desktop.

## window-cycle.ps1

Checks `goto_window` and `toggle_visibility` with a hidden quick terminal.
Two windows and the quick terminal are opened with posted keys, and the
quick terminal is hidden again. `goto_window:next` must go from one window
to the other and back without going to the quick terminal, and
`toggle_visibility` must hide both windows and bring back only them, with
the quick terminal still hidden. With the windows hidden again, `+new-tab`
must bring back the window it adds its tab to, and only that one. Hiding
the quick terminal and the windows
needs a Ghostty window in front. Outside CI, Windows may refuse that, and
then the test stops early with a message. In CI that counts as a failure.

## scrollbar.ps1

Checks the scrollbar: cmd prints 301 numbered lines (`L1000` to `L1300`),
and clicks posted to the scrollbar's track scroll the terminal, as the
thumb jumps to the click: the top shows cmd's banner, the middle lines from
the middle of the output, and the bottom `L1300` again. What's in view is
the surface's UI Automation value.

## gdi-leak.ps1

Checks that Ghostty's own drawn UI doesn't leak GDI or USER objects (a
process may have 10,000 of each, so a leak on every paint or every new tab
breaks drawing after a long session): after a warm-up, 25 rounds of the
search bar, the command palette, a new tab and a split (each closed again),
a resize, hovering the tab bar, fullscreen and back, and a split zoomed
and back may add at most half an object a round
(`GetGuiResources`), and kernel handles at most four a round (each
terminal has a pseudoconsole, pipes, threads and a process). `-Steps` runs
only some of them, to find a leak. It
found one: each surface whose search bar or command palette had been shown
leaked a GDI object when it closed.

## memory-leak.ps1

Checks for memory leaks with the debug allocator of Debug builds, which
reports every allocation still live when Ghostty exits normally (other
tests end it with `Stop-Process`, which skips that): it prints 400 lines of
scrollback, opens and closes the search bar and the command palette, opens
a tab and a split and closes both (they're still kept for undo at exit),
resizes, opens and closes the inspector, changes the font size and back,
toggles read-only mode and the quick terminal, has cmd set a title and ring
the bell, then quits with the `quit` action (a hidden quick terminal
still has a terminal, so closing the main window alone doesn't quit), and
fails if standard error reports a leak. Checked that it reports one: a 7-byte allocation
planted in `Surface.init` showed up three times, with where it was made.

## crash-report.ps1

Checks the crash handler: Ghostty, with F12 bound to `crash:main` and its
standard error in a file, panics on a posted F12, exits by itself (with a
standard error there's no dialog), saves a report in
`%LOCALAPPDATA%\ghostty\crash` with the version, the panic message and the
return addresses, prints the panic to standard error, and `+crash-report`
lists the report. The report is deleted afterwards.

## win-key-defaults.ps1

Reports (as a notice, never failing) which of the default keybindings with
the Windows key another program has registered as a hotkey, which Windows
then never passes to Ghostty: it tries to register each with
`RegisterHotKey`, which fails with `ERROR_HOTKEY_ALREADY_REGISTERED` when
the combination is taken. On a clean runner that's what Windows' shell
takes; a free combination can still be caught by a keyboard hook.

## command-palette.ps1

Checks the command palette: `toggle_command_palette` opens it with many
entries, typing `new_split:right` narrows the list, Enter runs it (the
terminal splits left and right) and closes the palette, and Escape closes
it without running anything.

## tabs.ps1

Checks tab operations, one terminal per tab: `close_tab:other` keeps only
the current tab, `close_tab:this` and then `undo` brings back the same
terminal, and `move_tab_to_new_window` moves the current tab, with its
output, into a second window while the other tab stays. A closed tab is
kept hidden for `undo-timeout`, so the checks follow which terminal is
shown rather than counting windows.

## window-options.ps1

Checks the options for new windows, starting Ghostty once for each:
`window-position-x/y` of 100,50 puts the visible frame (DWM's extended
frame bounds) that many points from the primary monitor's work area at its
DPI, a position off every monitor falls back to the work area's corner,
`maximize` maximizes the window, and `fullscreen` covers its monitor.

## title-prompt.ps1

Checks `prompt_surface_title`: the "Change Terminal Title" dialog sets the
title (the window's title follows), and an empty title clears the override,
bringing back the shell's title. The field is set with `WM_SETTEXT` and OK
pressed with `BM_CLICK`. It shows a dialog, so it only runs in CI (set
`CI=true` to run it elsewhere).

## titlebar-tabs.ps1

Checks the tabs in the title bar: with one tab the window has the system's
title bar; with two the client area starts at the window's top. Hit tests
sent to the tab bar and the window: empty space is the caption
(`HTCAPTION`), the top edge resizes (`HTTOP`), the maximize button is
`HTMAXBUTTON` (Windows 11's snap layouts), and the tab bar passes those to
the window (`HTTRANSPARENT`) while keeping tabs and its other buttons. A
click on minimize minimizes, maximize (`WM_NCLBUTTONUP`) maximizes, and
with one tab again the system's title bar comes back.

## tab-reorder.ps1

Checks reordering tabs by dragging: the second tab, named `SECOND` with
cmd's `title` (the shell integration's titles are off), is dragged onto the
first with posted mouse messages, and UI Automation then lists it first,
still shown. The tabs' positions come from UI Automation, so the test
follows the tab bar's layout.

## compact-tabs.ps1

Checks compact tabs: with 12 tabs in a narrow window, each tab shows only
its number and has no close button, so a click where the close button
would be selects the tab and closes nothing; a middle click still closes
it. Positions come from UI Automation and clicks are posted messages, so
it runs on a locked desktop.

## color-query.ps1

Checks OSC 10 and 11 color queries (which Codex, Neovim and tmux use) and
a Kitty graphics query (an APC): a
PowerShell inside Ghostty, started with distinctive colors, sends them and
reads the replies as VT input. With `conpty.dll` next to `ghostty.exe`
(`dist/windows/conpty.ps1`) the replies must be Ghostty's colors and
its `OK` for the Kitty query. The
ConPTY built into Windows swallows these queries, so without it the test
only reports what came back.

## cli-ipc.ps1

Checks the CLI actions that talk to a running Ghostty: `+new-tab` adds a tab
to its window and `+new-window` opens another window, through the console
launcher (`ghostty.com`) with the instance's `--class`. Then `+new-tab` with
`--title` and `-e` must open a tab with that title running that command.
The overrides are parsed into memory that's freed once the request is
handled, so this also checks nothing keeps pointing into it. Tabs and
windows are counted with UI Automation.

## tab-close-uia.ps1

Checks that screen readers can close tabs: each tab (a TabItem) has a
"Close Tab" button as its only child, inside the tab, and invoking it closes
that tab and leaves the other. The tabs also report their position ("1 of
2"), from which screen readers say where a tab is.

## tab-rename.ps1

Checks that double clicking a tab renames it, as in Windows Terminal: a
double click on the second tab opens "Change Tab Title", and the title given
there becomes that tab's name (read with UI Automation) while the first keeps
its own. It shows a dialog, so it only runs in CI (or with `$env:CI = 'true'`).

## notification.ps1

Checks desktop notifications (OSC 9): one shows from the notification area
icon, and another still shows after the icon is deleted, as Explorer's
restart would delete it while a notification is up. (CI's Explorer times
notifications out at once, taking the icon, so there those two checks are
notices and only the second notification is checked.) Last, clicking the
notification (its message, posted to Ghostty) brings back the minimized
window it came from. It shows notifications, so it only runs in CI (or with
`$env:CI = 'true'`).

## uia-ranges.ps1

Checks that screen readers can mix text ranges taken at different times:
the document's range is taken on an empty screen, the shell prints, and the
range's ends are moved to the newer selection's end (`MoveEndpointByRange`)
and read. That end is past the old range's text, which crashed Ghostty. It
uses UI Automation only, so it runs on a locked desktop.
