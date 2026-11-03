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

## start-menu.ps1

Starts an installed Ghostty the way the Start menu does (the MSIX by its
app ID, or the zip's `install.ps1` shortcut) and checks that a window
opens from the installed location with its shell in the home directory;
for the zip it also uninstalls. It only runs in CI.

## drag-drop.ps1

Drags a file (a real OLE drag, as from Explorer) from a window of its own
onto a terminal running cmd, and checks that its path was pasted. It moves
the mouse and holds its button, so it only runs in CI, with Windows
PowerShell (an STA thread).

## touch-scroll.ps1

Fills cmd with numbered lines, drags a software finger down the terminal
with `InjectTouchInput`, and checks that earlier lines scrolled into
view. It only runs in CI.

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
in and out, and checks that it ends up hidden. Then it adds a virtual
desktop (Ctrl+Win+D) and checks that showing the quick terminal shows it
there, without Windows switching back. It sends real keys, so it only runs in CI.

## translucent.ps1

Opens an opaque red Ghostty window, then a half transparent one on top of
it (`-Blur` adds `background-blur`), splits it, and scrolls the left pane.
Both panes must show red through them, and the scrollbar's thumb must be
drawn with the red still showing around it. Then it opens the search bar
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
