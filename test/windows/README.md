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
interrupting (without), focus-follows-mouse between splits, and
window-step-resize while dragging the window's corner
with real (synthesized) keyboard and mouse input. Since that input goes to
the foreground window, it refuses to run unless `CI` is `true`; CI runs it
on the runner's desktop.

## start-menu.ps1

Starts an installed Ghostty the way the Start menu does (the MSIX by its
app ID, or the zip's `install.ps1` shortcut) and checks that a window
opens from the installed location; for the zip it also uninstalls. It
only runs in CI.

## drag-drop.ps1

Drags a file (a real OLE drag, as from Explorer) from a window of its own
onto a terminal running cmd, and checks that its path was pasted. It moves
the mouse and holds its button, so it only runs in CI, with Windows
PowerShell (an STA thread).

## touch-scroll.ps1

Fills cmd with numbered lines, drags a software finger down the terminal
with `InjectTouchInput`, and checks that earlier lines scrolled into
view. It only runs in CI.

## ime.ps1

Installs the Japanese IME, switches a terminal running cmd to it, types
"nihon" with real keys, converts and commits it, and checks that the kanji
reached cmd. It only runs in CI.
