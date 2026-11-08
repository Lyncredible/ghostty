# Windows Port: Working Plan

This file tracks the in-progress native Windows port on the `windows`
branch. It's a working document and not meant to be upstreamed as is.

Prior work and maintainer guidance:
https://github.com/ghostty-org/ghostty/discussions/2563

## Guiding constraints (from upstream maintainers)

- No GTK apprt port and no Qt.
- Rendering goes through a Direct3D backend for the existing generic
  renderer (`src/renderer/generic.zig`), at parity with Metal and OpenGL.
- Windows 10 and 11 only.
- Keep C++ to a minimum. This port is pure Zig plus Win32 and COM. The
  only new C++ is spirv-cross's existing HLSL backend (`spirv_hlsl.cpp`)
  for custom shaders.
- Land small, reviewable, incremental changes.
- Follow Windows' own design language and interaction patterns where the
  frontend allows it.
- Don't use Ghostty branding for unofficial builds of this branch.

As of October 2026 the team says porting the full desktop app to Windows
is on hiatus, and the discussion is closed. They still welcome
contributions that improve Ghostty internals on Windows (for example
libghostty-vt), but "no +10k diff PRs". This branch adds about 33k lines
(25k in `src`, 19k of them the Win32 apprt and the Direct3D renderer,
as of 2026-11-04) and must not go upstream as one PR. Candidates to upstream separately,
roughly in order:

1. Core compile and test fixes (`posix_c`, `Dmabuf`, tinyio symlink
   skips, translate-c MinGW fix).
2. ConPTY shutdown fix (`pty.zig`, `termio/Exec.zig`) and the Windows
   command-line quoting fixes (`Command.zig`, `execCommand`).
3. Small platform helpers (`os/mouse.zig` double-click interval).
4. The Direct3D 11 renderer and HLSL shaders, with the embedded
   `GHOSTTY_PLATFORM_WINDOWS` platform.
5. The Win32 apprt, which has no upstream home while the app port is on
   hiatus.

## Architecture

- **apprt:** a native `win32` runtime (`src/apprt/win32/`) written in Zig
  against raw Win32 APIs, bound with translate-c. It's the default runtime
  on Windows.
  - `Window` is a top-level window with a custom-drawn `TabBar`.
  - Each `Tab` is a `SplitTree` of `Surface` child windows, reusing the
    core's `datastruct/split_tree.zig`.
- **Renderer:** a `direct3d11` backend (`src/renderer/Direct3D11.zig`,
  `src/renderer/direct3d11/`). It implements the same GraphicsAPI contract
  as Metal and OpenGL, and is the default renderer on Windows.
  - Each surface has its own D3D11 device and context. A spare device is
    made ahead on a thread, so new surfaces don't wait for one.
  - Frames render to an offscreen target, which is copied into a flip-model
    swap chain on the surface `HWND`.
  - Embedders can use it through the new `GHOSTTY_PLATFORM_WINDOWS`
    platform, which passes an `HWND`.
- **Shaders:** `src/renderer/shaders/shaders.hlsl` is a hand port of the
  GLSL shaders. Builds on Windows compile it with `D3DCompile` at build
  time and embed the bytecode; builds elsewhere compile it at runtime
  (`d3dcompiler_47.dll` ships with Windows).
  - Built-in shader bytecode is compiled once per process and reused when
    creating pipelines for each surface's D3D device.
  - Custom shaders go GLSL → SPIR-V → HLSL via spirv-cross.
- **PTY:** ConPTY (`src/pty.zig`, `src/termio/Exec.zig`).
- **Fonts:** the existing `freetype_windows` backend. FreeType
  rasterizes, as the discussion's plan has it; DirectWrite finds
  fallback fonts and answers font name queries.

## Building and testing

You only need Zig. The GNU ABI uses the MinGW that ships with Zig:

    zig build -Dtarget=x86_64-windows-gnu          # zig-out/bin/ghostty.exe
    zig build test -Dtarget=x86_64-windows-gnu
    zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe

The default MSVC ABI also needs Visual Studio Build Tools and the Windows
SDK. CI uses it (the `build-windows` job).

Notes:

- On Windows, Zig 0.17 sometimes fails dependency fetches with
  `TlsInitializationFailed`, or hits a transient
  `checking cache failed: file_open Unexpected`. Rerunning works.
- `ghostty.exe` is a GUI app. To see its logs, redirect stderr
  (`Start-Process ... -RedirectStandardError log.txt`).
- `-Doptimize=ReleaseFast` with the GNU ABI used to fail while compiling
  MinGW's CRT (`.seh_ directive must appear within an active frame`),
  because stripping turned off the unwind tables it needs. They're kept
  on Windows now, and ReleaseFast builds work (built again 2026-10-31).
- When scripting input from a DPI-unaware process, Windows scales mouse
  message coordinates for per-monitor-aware windows.

## Status

### Done

- [x] Core compiles on Windows. `zig build test` passes: about 4020 tests,
      with symlink tests skipped when the symlink privilege isn't
      available.
- [x] Direct3D 11 renderer: text, colors, sRGB/linear blending, color emoji
      and images (atlases), background images (verified), and custom
      shaders.
  - [x] A lost device (`DXGI_ERROR_DEVICE_REMOVED` or `_RESET`, as when
        Windows updates or restarts the graphics driver after a GPU
        timeout): after each frame the renderer asks the device
        (`GetDeviceRemovedReason`), and if it's gone, releases the swap
        chain, shaders and images, makes a new device on the adapter
        that's primary now, with its swap chain and composition, and
        draws again. Kitty images come back from the terminal; the
        background image is loaded again. If making the device fails, it
        tries again on the next frame. New surfaces whose saved adapter
        is gone use the default one before WARP. A real removal can't be
        caused here, so debug builds take `GHOSTTY_D3D11_LOSE_DEVICE=N`
        to act as if the Nth present found the device removed:
        `device-lost.ps1` checks the window shows the background and text
        again (passes here, and in CI in run 41919073564). It also runs
        with a custom shader that swaps red and blue, whose colors show
        after the device is replaced (passed in CI run 41927770848),
        and with a solid background image, whose color shows after it
        (passed in CI run 41936310250). Kitty images can't reach a
        terminal through ConPTY (see below), so their reload isn't
        checked. Not checked: a real driver restart.
- [x] Win32 apprt: window, message loop, and cross-thread wakeups.
  - [x] Per-monitor DPI, resizing, focus, and occlusion.
    - [x] A DPI change while running: the fork's CI runs
          `test/windows/dpi-change.ps1`, which switches the runner's
          display to 1920x1080 and raises its scale to 125%
          (`SPI_SETLOGICALDPIOVERRIDE`, as the Settings app does). Cells
          grew with the DPI, and the window took the size `WM_DPICHANGED`
          suggested, which the window now logs (run 41317959654). For a
          scale change Windows suggests the same size in pixels.
    - [ ] Manual check with two monitors at different scales: moving a
          window between them, where Windows suggests a scaled size
  - [x] Keyboard: layouts, dead keys, Ctrl/Alt/AltGr handling, and
        physical keys.
    - [x] Alt codes (Alt held while typing a number on the numpad, such
          as Alt+0233 for é): the digits went to the core as Alt+numpad
          keys (seen in the code, not observed), before the character. Like Windows
          Terminal, numpad digits with only Alt held are now left to
          Windows (by scancode, so Num Lock off works too), and the
          character arrives as `WM_CHAR` when Alt is released. Unit test:
          `altCode`; `desktop-input.ps1` types Alt+0233 with real keys in
          CI. The first run (41815294434) sent virtual keys without
          scancodes: Windows didn't compose é and made "0233" of the
          digits instead (so the digits are now also dropped). With
          scancodes, as a keyboard sends, it passed (run 41819892772). The trade-off, as in Windows Terminal:
          programs can't get Alt+numpad digits.
  - [x] Basic IME: the system composition window, placed at the cursor.
  - [x] Mouse buttons, motion, wheel, and cursor shapes.
    - [x] The wheel follows Windows' "lines to scroll at a time"
          setting (Settings > Bluetooth & devices > Mouse), like other
          Windows apps: notches are scaled by it over its default, 3,
          which `mouse-scroll-multiplier`'s default also is, so nothing
          changes with the defaults. Scrolling a screen at a time counts
          as 3. Unit test: `wheelScale` (rounding must not lose a line,
          which it did for some cell heights without a nudge);
          `wheel-lines.ps1` sets it to 1 and 5 in CI (passed, run
          41819892772).
- [x] High contrast themes (Settings > Accessibility > Contrast
      themes): Windows asks apps to draw their own UI with the theme's
      system colors. Terminal contents keep their colors, as in Windows
      Terminal.
  - [x] The tab bar: with high contrast on (`SPI_GETHIGHCONTRAST`), the
        bar is the theme's window color, the active tab its highlight,
        hovered items its button face, with its text colors, and the
        title bar keeps the theme's colors instead of the terminal's
        (`window-theme=ghostty`). It repaints on `WM_SYSCOLORCHANGE`.
        `high-contrast.ps1` turns high contrast on and off in CI and
        checks the bar's color on screen: it passed (run 41840078517).
        Not checked here, since it changes the whole desktop.
  - [x] The search bar and command palette: the theme's window colors,
        with the field framed, and hovered buttons and the selected
        command in its highlight colors. Badges and the link preview use
        its tooltip colors. Each checks for high contrast as it paints,
        and `WM_SYSCOLORCHANGE` repaints the whole window. Builds, and
        the smoke test passes here without high contrast; not checked
        with it here; `high-contrast.ps1` also checks the search bar in
        CI: it passed (run 41848225367, and in a split in 41888293257). The command palette, badges and
        link preview were not checked with it.
  - [x] Over the terminal, which keeps its own colors: split dividers
        use the terminal's foreground instead of a faint blend of it
        (unless `split-divider-color` is set), the scrollbar thumb is
        solid instead of see-through, and the bell border is the theme's
        highlight color, solid. Split dimming stays as configured: it
        dims with the terminal's own background. Builds, and the smoke
        test passes here without high contrast; `high-contrast.ps1` also
        checks the divider in CI, with high contrast off, on and off
        again: it passed (run 41888293257). The test reads the theme's
        window color again with each check, since a theme's colors can
        arrive after Windows reports high contrast is on. The scrollbar and bell
        border aren't checked with high contrast.
- [x] The cursor blinks at Windows' cursor blink rate (Settings >
      Accessibility > Text cursor, or the keyboard control panel; 530 ms
      by default, where Ghostty uses 600 ms elsewhere), read again on
      every blink, and stays on when blinking is turned off there
      (`GetCaretBlinkTime` is INFINITE), like other Windows apps. This is
      in the renderer thread, which owns the blink timer; programs and
      `cursor-style-blink` still decide whether it blinks at all. Unit
      test: `systemCursorBlinkFrom`. `cursor-blink.ps1` times the blinks
      on screen and turns blinking off in CI. Its first run
      (41819892772) failed before any check, most likely compiling C#
      against System.Drawing, which is split up in PowerShell 7; the
      capture is now in PowerShell, as in `dark-mode.ps1`. It passed
      (run 41832654292): the blinks matched the runner's blink time, and
      the screen stayed still with blinking off. It couldn't be timed
      here, since the cursor only blinks in a focused window, and taking
      focus on this desktop is avoided.
  - [x] Touch screens: a one finger vertical pan scrolls (with inertia)
        through `WM_GESTURE`, instead of selecting text with emulated
        mouse input. Needs a check on a touch screen.
  - [x] Plain text clipboard, with CRLF handling and unsafe paste
        confirmation.
  - [x] Ctrl+C copies when there's a selection, like Windows Terminal,
        and is still an interrupt otherwise (a performable default
        keybind on Windows). Unit tested, and checked with real keys in
        the fork's CI (run 41250076747): with a selection it copied, and
        without one it interrupted `ping -t`.
  - [x] Ctrl+V pastes too, like Windows Terminal: through ConPTY, cmd
        otherwise gets a ^V instead of the console's paste. It's
        performable, and `keybind = ctrl+v=unbind` gives it back to
        programs such as Vim (visual block). The menus still show
        Shift+Insert. Unit tested, and checked with real keys in the
        fork's CI (`test/windows/desktop-input.ps1`, run 41247475902):
        Ctrl+V pasted a command into cmd, which ran.
  - [x] Copying also writes HTML ("HTML Format", CF_HTML) when the core
        provides it (`copy_to_clipboard` with `mixed`), so rich text
        editors paste with colors and styles. Checked: Select All and Copy
        put a well-formed CF_HTML document with the terminal's text on the
        clipboard.
  - [x] Titles, maximize, borderless fullscreen, and initial size.
  - [x] Close confirmation, open URL/config, and config reload.
  - [x] Debug builds say "(debug build)" in the window title, like GTK's
        debug warning banner, since they're much slower.
  - [x] Configuration errors dialog, like GTK's: at startup (once the
        first window is up) and after a reload, a warning lists the
        errors (up to 15) and offers to reload. Checked with two bad CLI
        options: both listed with their sources; No dismissed it.
  - [x] Tabs: new, close (this/other/right), goto, and move.
  - [x] Custom tab bar themed from the terminal colors: close buttons,
        middle-click close, and a new tab button.
  - [x] Splits: new, goto (including spatial), resize, equalize, zoom, and
        draggable dividers.
  - [x] Rearranging splits with drag handles (`drag-handle`), like GTK: a
        handle at the top of each split; dragging it over a terminal in
        the tab highlights the half nearest the pointer, and dropping
        moves the split there. Checked with posted mouse messages: two
        side-by-side splits became stacked after dropping on the left
        one's bottom half.
  - [x] Inline IME preedit and candidate window placement (still needs
        testing with a real IME).
  - [x] Quit timer delay, `initial-window`, and the system double-click
        interval.
- [x] ConPTY: clean shutdown when the shell exits or the surface closes.
- [x] Win32 input mode (DECSET 9001), which ConPTY requests: keys are
      sent as `CSI Vk;Sc;Uc;Kd;Cs;Rc _` key event records, with releases,
      so console programs see real virtual keys, scan codes, and modifier
      state. The mode is only enabled in the Windows app (not
      libghostty-vt); it takes snapshot mode bit 43, a reserved bit that
      earlier decoders ignore. The virtual key comes from the scan code
      with `MapVirtualKeyW` for the current layout. Checked with
      `[Console]::ReadKey` behind ConPTY: Numpad 5 arrives as `NumPad5`
      (the VT fallback can only send a plain `5`), Up as `UpArrow`.
- [x] CI job that builds and tests the app on Windows.
  - It now passes `-Dtarget=x86_64-windows-gnu` for the tests and the
    build: the Windows runner's native target is MSVC, which isn't what
    the app is built and tested with (upstream's CI matrix also leaves
    `x86_64-windows-msvc` commented out).
  - [x] Forks get no CI from it: the Test workflow runs on Namespace
        runners, which only ghostty-org/ghostty has, so on this fork every
        run stayed queued or was cancelled by the next push. A fork-only
        workflow (`.github/workflows/windows-fork.yml`, skipped in
        ghostty-org/ghostty) builds, runs the native tests, and packages
        the zip on GitHub's `windows-latest` runner. Its first run
        (2026-10-31, run 41219931902) passed in 40 minutes: build 13,
        tests 18, and packaging 8.
- [x] libghostty-vt builds on Windows: `zig build -Demit-lib-vt
      -Dtarget=x86_64-windows-gnu` emits `ghostty-vt.dll` with its import
      library `ghostty-vt.lib`, and `ghostty-vt-static.lib`. Checked
      (2026-10-26) by compiling `example/c-vt/src/main.c` with `zig cc`:
      linked against the import library (with the DLL next to it) and
      statically (with `-DGHOSTTY_STATIC`, since the headers otherwise
      declare `dllimport`), both printed the parsed OSC title "hello".
  - [x] The MSVC target: this machine has no Visual Studio or Windows SDK
        ("LibCStdLibHeaderNotFound"), but GitHub's Windows runners have
        both, so the fork workflow also runs upstream's libghostty-vt
        Windows job there (native target, MSVC). Run 41223281228
        (2026-10-31) passed: `test-lib-vt`, `-Demit-lib-vt`, the static
        linking example, and the DLL example run directly.
  - [x] `zig build test-lib-vt -Dtarget=x86_64-windows-gnu`: 6,943
        passed, 68 skipped, 0 failed (2026-10-26).
  - The examples' `build.zig` files don't pass their target to the
    ghostty dependency, so `-Dtarget` on an example still builds the
    library for the native target.
- [x] Windows on ARM: `zig build -Dtarget=aarch64-windows-gnu` builds
      after casting `GetProcAddress` results with `@alignCast` (function
      pointers are 4-byte aligned on ARM64).
  - Still builds after this session's changes (2026-10-26, debug, 64 MB
    `ghostty.exe`).
  - [x] Run it on an ARM64 machine. The fork workflow builds and runs the
        tests natively on GitHub's `windows-11-arm` runner. Run
        41226585460 (2026-10-31) passed: build 9 minutes, tests 25.
    - [x] The app on an ARM64 desktop: the same job runs the cmd smoke
          test (a real window, shell integration and OSC 7), which passed
          in run 41348634447.
    - [x] An ARM64 zip and MSIX from CI: `package.ps1 -Target
          aarch64-windows-gnu -Msix` works cross-compiled here (it made
          `GhosttyWindowsUnofficial_1.0.18744.0_arm64__ddpcdxnmqgtp8`) but
          failed natively on the ARM64 runner (run 41348634447): the MSIX
          tool, which runs on the build machine, cast COM vtable entries
          to function pointers without `@alignCast`, which ARM64 needs
          (as `GetProcAddress` results did). With that fixed, run
          41357100381 packaged it, installed the MSIX on the runner
          (`ghostty-cli.exe +version` ran from it), and uploaded the
          `ghostty-windows-unofficial-arm64` artifact.
- [x] Light and dark themes: the app reports the Windows app mode
      (`AppsUseLightTheme`) to the core at startup and on
      `WM_SETTINGCHANGE`, so `theme = light:X,dark:Y` and color scheme
      reports (mode 2031) follow the system. Checked with
      `--theme=light:Builtin Light,dark:Builtin Dark` in light mode: the
      background was white, and a settings change message kept it.
  - [x] Switch Windows to dark mode while it runs (not done here, since
        it changes the whole desktop): the fork's CI runs
        `test/windows/dark-mode.ps1`, which flips `AppsUseLightTheme`,
        broadcasts the settings change, and checks the terminal's
        background color from the screen, dark and back to light. It
        passed in run 41301043212.
- [x] `toggle_tab_overview`: the command palette lists the window's tabs
      ("Tab N: title") to filter and switch to. Checked with three tabs:
      F9 bound to the action showed them, and choosing "Tab 1" made the
      first tab active. Toggling the command palette from the overview
      switches to the commands.
- [x] `undo`/`redo` for closing tabs (`undo-timeout`), like macOS: a closed
      tab with a running process is hidden instead of destroyed, `undo`
      (or "Reopen Closed Tab" in the tab menu) puts it back where it was,
      and `redo` closes it again. Closed tabs are destroyed when the
      timeout expires or the window closes. Closing a split can be
      undone too: it goes back next to the terminals it was split from,
      on the same side and with the same ratio. Closing a window can be
      undone too, unless it's the last one (the app quits then, and
      closed windows are destroyed with it). Checked with `--undo-timeout=3s` and F9/F8
      bound to undo/redo: close, undo, and redo switched the visible
      terminal as expected; after the timeout the hidden surface was
      destroyed and undo did nothing. The tab menu item reopened a tab.
      For splits: a right split closed and came back at the same
      position (x 1539..2965), redo closed it again, and it expired the
      same way. Closing a split and then its tab, two undos brought back
      the tab and then the split.
  - [x] Undo closing a window: it's hidden and taken out of the app's
        window list until it expires; `undo` reopens whichever of the
        closed windows and the window's own closed tabs and splits closed
        last. Checked with two windows: closing the second hid it, undo
        showed it, redo hid it, and after the timeout it was destroyed.
        With a window waiting for undo, closing the last open one quit
        the app. This found a use-after-free: closing a single-terminal
        window with the close button reset a flag on the freed window.
- [x] `alpha-blending` on Windows (its docs now say `native` is sRGB
      there, as on Linux). Red text on green, captured with PrintWindow
      (the first 300 rows): `native` has 4,185 dark edge pixels (the
      brighter of red and green under 170), `linear` and
      `linear-corrected` none. The corrected mode draws the text a
      little heavier (28,637 mostly red pixels, against 27,400), as its
      docs say: plain linear blending thins dark text.
- [x] `font-thicken` and `font-thicken-strength` with FreeType (so on
      Windows): outlines are emboldened by a quarter of a pixel up to a
      whole pixel overall, by strength. Measured on a screenshot of the
      cmd banner (pixels brighter than half): 6,463 normally, 6,850 at
      strength 0, and 8,403 at 255; the text stays crisp.
- [x] `window-show-tab-bar` is documented as working on Windows.
- [x] A crash report from a stress run (the new crash handler at work):
      Zig's standard library panics on `OBJECT_NAME_INVALID` in debug and
      safe builds, treating it as a programmer error, and the terminal's
      working directory went to `Dir.access` without checking. It can
      come from anywhere (`--working-directory`, a program's OSC 7). On
      Windows it's now checked with GetFileAttributesW (which must also
      find a directory). Unit test: `windowsIsDirectory`. Checked:
      `--working-directory=C:\bad|name` logged "cannot access cwd,
      ignoring" and the window opened, instead of crashing.
- [x] A `COMSPEC` that doesn't name a file broke every terminal ("The
      underlying shell or command was unable to be started", FILE_NOT_FOUND).
      The default shell now only uses COMSPEC when it's a file, and
      otherwise searches for cmd.exe, with a warning. Unit test:
      `windowsIsFile`. Checked: with COMSPEC unset, and with it set to a
      missing file, cmd started (the second logged the warning).
- [x] A `command` that doesn't exist showed "error starting IO thread:
      error.Unexpected ... usually due to exhausting a system resource".
      CreateProcessW's FILE_NOT_FOUND, PATH_NOT_FOUND, and ACCESS_DENIED
      are now FileNotFound and AccessDenied, and the terminal says "The
      shell or command couldn't be started: error.FileNotFound" and to
      check `command`. Checked with `--command=nosuchprogram.exe`.
  - An unquoted `command` path with spaces works: with
    `C:` + backslash + `Program Files` + backslash + `Git` + backslash
    + `bin` + backslash + `bash.exe`, it's split into two arguments, and
    joined again on the command line, where CreateProcessW tries
    `C:\Program` and then the whole path. Git Bash started.
  - Other paths with names that aren't valid don't crash: `config-file`,
    `background-image`, `custom-shader`, and `theme` set to
    `C:` + backslash + `bad|name...` each started normally with no panic.
- [x] Git Bash (and MSYS2's bash) gets shell integration. It wasn't
      detected because the program is `bash.exe`; on Windows a `.exe`
      suffix is now ignored when detecting bash, elvish, fish, nu, and
      zsh. Its OSC 7 also failed ("invalid url in OSC 7:
      error.InvalidMacAddress"): Ghostty exported `PWD` as the Windows
      working directory, MSYS bash kept it as `C:/Code/ghostty` rather
      than `/c/Code/ghostty`, and the URL became
      `kitty-shell-cwd://HOSTC:/...`, whose colon reads as a port.
      `PWD` is no longer exported on Windows. Unit test: `detectShell`.
      Checked: with a quoted Git Bash path, the log showed "shell
      integration automatically injected shell=.bash" and "terminal pwd:
      C:\Code\ghostty".
  - An unquoted path with spaces also gets shell integration. It
    started, but detection took `C:\Program` as the program. Now, on
    Windows, a `command` that starts with an unquoted path whose first
    word isn't a program has its path quoted: the shortest prefix
    ending at a space that's a file (with or without `.exe`), the
    same search CreateProcessW does. Bash's rebuilt command also
    quotes a program path with spaces rather than leave it to that
    search. Unit tests: `windowsQuoteProgram`, "bash: Windows path with
    spaces". Checked: with `C:` + backslash + `Program Files` + ... +
    `bash.exe` unquoted, the log showed the quoted path, "shell
    integration automatically injected shell=.bash", and the terminal
    pwd.
  - Also checked with `bash.exe --login -i` (as Windows Terminal's Git
    Bash profile runs it): the login profile ran (the UCRT64 prompt),
    and after typing `cd /c/Windows/System32` the terminal pwd became
    `C:\Windows\System32` and the title showed the command while it ran,
    then `/c/Windows/System32`.
    A new tab from there (F5 bound to `new_tab`) started Git Bash in
    `C:\Windows\System32`: its first pwd report and prompt were
    that folder.
- [x] Text without a key (an IME's result, the emoji panel, the touch
      keyboard, or a program sending WM_CHAR) was sent as a paste, so with
      bracketed paste on (zsh in WSL) each character arrived wrapped in
      paste markers (`ESC [ 200 ~ e ESC [ 201 ~`). Like GTK, it's now a key
      press with no key and the text, and win32 input mode sends it as a
      down and up character-only event per UTF-16 unit, as Windows
      Terminal does for IME text (the first unit had no up event). Unit
      test: "win32 input: encode". Checked: `echo héllo 日本 $((6*7))` sent
      as WM_CHARs to zsh in WSL printed `héllo 日本 42`, and to cmd
      printed `héllo 日本`.
  - Pasting still uses bracketed paste. Checked with a two line
    clipboard (CRLF) and `paste_from_clipboard` bound to F6: zsh in WSL
    took it as one paste and ran both lines on Enter; cmd ran each line.
    Git Bash ran each line too, which was the missing terminfo below.
- [x] `ghostty +list-themes` run from a shell in a terminal hung on a
      blank screen. Two causes: vaxis's loop doesn't report the console's
      initial size on Windows (only changes), so nothing was drawn (now
      posted at start); and, since `ghostty.exe` is a GUI program, the
      shell that started it doesn't wait and keeps reading the console's
      input, so the preview could never get a key (not even `q`). When
      Ghostty had to attach to the shell's console, it now prints the
      plain list instead. Checked: in cmd in Ghostty it printed the list
      and returned. (Colors were missing at first only because this
      session's environment sets `NO_COLOR`.)
  - [x] A console-subsystem `ghostty.com` next to `ghostty.exe`
        (`src/main_windows_launcher.zig`; shells run `.com` before `.exe`
        for `ghostty`, from PATHEXT). For a CLI action (`+...`) it starts
        `ghostty.exe`, passes on redirected handles, sets
        `GHOSTTY_CONSOLE_LAUNCHER`, and waits, exiting with its code;
        otherwise it starts the GUI and returns at once. Console handles
        don't reach a GUI program through `STARTF_USESTDHANDLES` (they
        arrived empty), so with that variable `ghostty.exe` attaches to
        the launcher's console and opens `CONIN$` and `CONOUT$` itself;
        since the launcher waits, the console's input is its own. The zip
        includes it. Checked in cmd in Ghostty: `ghostty +list-themes`
        showed the interactive preview, Down moved the selection (the
        preview showed "3024 Day"'s palette), and `q` returned to cmd;
        `ghostty.com` with no action opened a window and returned in
        26 ms; piped `+version` output still works. Unit tests:
        `argsAfterProgram`, `isAction`.
        Fork CI run 41254453745 (with the launcher) passed: the x64 and
        ARM64 tests, the smoke and desktop input tests, the MSIX install,
        and libghostty-vt with MSVC. CI now also runs `+version` and
        `+validate-config` (a valid and an invalid config) through
        `ghostty.com`; run 41257271537 passed.
    - [x] The MSIX package's execution alias is `ghostty.exe` (aliases
          must end in `.exe`), so from an MSIX install, `ghostty` in a
          shell runs the GUI program directly: CLI actions work but
          don't make the shell wait, and the theme preview falls back to
          the list. The package now also has the launcher as
          `bin\ghostty-cli.exe`, a second application (hidden from the
          Start menu) with the alias `ghostty-cli.exe`, for
          `ghostty-cli +list-themes` and the like. The package reader
          accepted it; CI installs it and runs `ghostty-cli +version`
          through the alias, which passed in run 41260077738.
- [x] `ghostty +validate-config` always failed (exit 1, no output) when
      its output was a pipe or the console: it finished with
      `File.Writer.end`, which sets the output's length, and Windows
      reports that as FileTooBig for pipes and consoles (other platforms
      give NonResizable, which `end` ignores). It flushes instead now,
      like the other actions, and so does `+explain-config`'s usage
      message. Checked: a valid config exits 0, and a misspelled option
      prints "font-sise: unknown field" and exits 1. The other actions
      (`+list-fonts`, `+list-themes`, `+list-keybinds`, `+show-config`,
      `+list-colors`, `+list-actions`, `+show-face`, `+explain-config`,
      `+help`, `+version`, `+crash-report`) all ran and exited 0.
- [x] The "Process exited. Press any key to close the terminal." message
      (and the abnormal exit banner) didn't show with
      `wait-after-command`: the child's exit is seen at once, but the
      pseudoconsole outlives it and its last output (its redraw) arrived
      after the message and drew over it. When the terminal stays open
      (`wait-after-command`, or an abnormal exit), the IO thread now
      closes the pseudoconsole, which flushes its output and ends the
      stream, and waits up to 2 s for the read thread to reach the end
      before reporting the exit. Resizing after that is a no-op for the
      closed pseudoconsole. Checked: `cmd /c echo bye`, `wsl -e echo
      bye`, PowerShell, and Git Bash all showed their output and then
      the message; `cmd /c exit 7` showed the banner under its output.
      Resizing the window three times after the message logged no
      errors and kept it. Closing with `exit` still takes about 100 ms.
      (The Win32 app
      leaves `show_child_exited` to the core's text message, as macOS
      does.)
- [x] Git Bash paths outside the drive mounts, such as `/tmp` (the
      user's temp folder) or `/usr/bin` (in Git's own folder), were
      reported as-is in OSC 7, which Ghostty can't map to Windows, so it
      forgot the pwd and new tabs started elsewhere. On MSYS2 and Cygwin
      (`$OSTYPE` is `msys*` or `cygwin*`; Git Bash says `cygwin`), the
      bash integration now reports such paths with `cygpath -m`, only
      when the directory changes. Checked: starting in a temp folder
      named `测试 dir`, then `cd /usr/bin` and a new tab, Ghostty's pwd
      followed (`C:\Program Files\Git\usr\bin`) and the new tab opened
      there. Non-ASCII paths also work for `--working-directory` and
      `--config-file` in cmd, PowerShell, and Git Bash (this machine's
      ANSI code page is 936).
- [x] Compiled terminfo on Windows. Windows builds installed only the
      terminfo source (`share/terminfo/ghostty.terminfo`), since `tic`
      isn't available, so MSYS2 programs (Git Bash's bash, vim, less,
      tput) couldn't find `xterm-ghostty` and treated the terminal as
      dumb: readline turned bracketed paste off (a multi-line paste ran
      its first line at once), and `tput colors` failed. The build now
      compiles the entry itself (`src/terminfo/compiled.zig`, with the
      capability order in `src/terminfo/caps.zig` taken from ncurses)
      and installs it as `share/terminfo/78/xterm-ghostty` and
      `67/ghostty`, the hex-named directories tic uses on Windows.
      Checked: byte-identical to Git for Windows' `tic -x` (ncurses 6.5)
      output for Ghostty's entry, and for the unit test's entry. In Git
      Bash in Ghostty, readline has bracketed paste on, `tput colors`
      gives 256, `infocmp -x` shows the extended capabilities, and a two
      line paste waits for Enter. Unit tests: `encode`, `unescape`.
  - vim in Git Bash uses it: `&term` is `xterm-ghostty` and `&t_Co` 256,
    it filled the screen, and quitting restored the shell's screen.
- [x] Tab creation latency (from the discussion's list), ReleaseFast,
      measured from posting a `new_tab` key to the prompt showing in UI
      Automation, five tabs each: cmd 130-145 ms; Windows PowerShell 5.1
      (`-NoProfile`) 750-790 ms; WSL (zsh with a theme) 540 ms. The first
      window took 0.8 s (cmd), 1.2 s (PowerShell), 4.1 s (WSL starting).
  - [x] Startup: sampling the main thread's stack while starting showed
        the first `D3D11CreateDevice` (the driver loading and Windows
        checking its signature) on the main thread just before the window
        showed. A test program took about 115 ms for the first device in a
        process and 24 ms for later ones (67 ms if the first was released).
        The renderer's `Device.warmup`, which the core runs on a thread at
        startup (Metal has one), now creates the first surface's device
        while config and fonts load, and `createDevice` takes it (waiting
        if it isn't done). ReleaseFast, cmd, five warm runs: the window
        showed after 242 ms instead of 330, the prompt after 280 instead
        of 362. (Later surfaces take a spare; see below.)
  - [x] The jump list was written on the main thread at startup (shell
        COM objects and a file replace, a third of the busy samples left).
        It's now written on a thread of its own: the window showed after
        174 ms, the prompt after 220. Checked: the launch still rewrote the
        `CustomDestinations` file with the "New Window" task.
  - [x] Telling whether Explorer started us (which picks the home
        directory) took a snapshot of every process, about 5 ms with 240
        of them. We now ask for the parent directly (0.07 ms). Checked: cmd
        started in the current directory when run from a shell, and in
        `C:\Users\<user>` when started through `explorer.exe`. With all
        three, warm starts showed the window after 166-174 ms (from 330)
        and the prompt after 201-228 ms (from 362).
  - [x] New tabs: sampling the UI thread while opening ten showed about
        34 ms of its own work per tab (the rest is ConPTY and the shell
        starting), a third of it in the kernel moving the new surface,
        which was created over the whole client area and then moved below
        the tab bar. Surfaces are now created where a new tab's surface
        goes. cmd's new tab to prompt: 98-125 ms (from 128-143). Checked:
        the tab bar, a new tab, and right and down splits got the same
        sizes and positions as before.
  - [x] Every new surface still made its Direct3D device on the UI
        thread: a test program took about 24 ms for each device after the
        first, and each added about 4.3 MB of private bytes. We now keep a
        spare: a surface takes it, and a thread makes the next one (the
        startup warmup makes the first). ReleaseFast, a split from the
        system menu (`SendMessage`, so it's the UI thread's time), three
        runs of four: 63-78 ms before, 34-44 ms after. A new tab from
        the system menu, the same way: 54-74 ms before, 30-36 ms after
        (UI Automation counted four tabs after three). The spare costs
        about 5 MB (private bytes after start: 50.5 MB, now 55.3 MB).
        Checked: the device-lost and smoke tests pass (here, and in CI
        run 41946175189), and closing the
        window exits.
  - [x] The rest of a new tab's time on the UI thread (ReleaseFast,
        timed in place): the core's surface took about 10 ms (the
        renderer 3-4, ConPTY and the shell 2.5-3), and our overlays'
        windows about 22: five badges 6-7 ms, the search bar and command
        palette 6-7, the dim overlay and bell border 3, the link preview
        and scrollbar 3, the drop zone and drag handle 2-3. Badges now
        make their windows the first time they show, just below the
        scrollbar, as before (0.5 ms for all five). Tab creation: 28-31 ms
        from 33-39. Test: `test/windows/overlays.ps1`, which fails on the
        build before (it finds five badge windows in a new surface).
    - [x] The search bar and command palette too: they make their windows
          when they first open, and go on top then, as before. A new tab
          from the system menu, three runs of four: 18-23 ms, from 30-36
          with only the spare device. The test opens both from the window
          menu: each shows on top (the palette listing 88 entries) and
          closes with Escape. Passes here, and in CI run 41960209709
          (with the rest of the Windows tests).
    - [x] The dim overlay, bell border and link preview too: each makes
          its window when it first shows, and moves it to where it would
          be had it been made up front (above the scrollbar, the dim
          overlay above the bell border, above the link preview). A new
          tab, three runs of four, alternating with the build before:
          15-20 ms, from 18-24. `overlays.ps1` checks that a new surface
          has none, that a bell (with `bell-features=border`) shows the
          border just above the scrollbar, and that a split dims the first
          terminal with its overlay just above the bell border and below
          the search bar and palette. The link preview needs a real Ctrl
          key held down, so `links.ps1` (CI only) checks it: holding Ctrl
          over a link shows it, just above the scrollbar. Both pass in CI
          run 41968407024.
    - [x] The drop zone too, which shows only while a split is dragged
          (it goes on top when it shows, so when it's made doesn't
          matter). `overlays.ps1` drags the first terminal's handle over
          the second with posted mouse messages: the drop zone shows on
          top, and letting go over the first hides it and moves nothing.
    - [x] The drag handle too, which shows only in a split (and goes on
          top when it does). With the drop zone: a new tab, three runs of
          four, alternating with the build before: 14-18 ms, from 15-21.
          `overlays.ps1` checks that a split shows the first terminal's
          handle, and drags it. Splits, which make the dim overlay and
          handles anyway, gain less: 26-31 ms, from 27-34 (one 39). The drop
          zone and handle changes pass in CI run 41972958123.
    - [x] The scrollbar stays made up front (about 1.5 ms): nearly every
          terminal scrolls, so it would be made anyway, and the overlays
          made later find their places from it.
- [x] Memory per tab: each new tab raised the commit charge (private
      bytes) by about 110 MB, while the working set grew by 10 MB. Listing
      the committed regions showed three 16 MB thread stacks per tab: on
      Windows, Zig's `std.Thread` passes the stack size to
      `NtCreateThreadEx` as the stack to commit, so the 16 MiB default was
      committed up front. Surface threads (renderer, IO, reader, search)
      now commit 64 KiB and grow into the executable's 16 MiB reservation
      as usual (`internal_os.thread_spawn_config`). ReleaseFast, a window
      2854x1456 pixels: 1 tab 88 MB (from 136), 10 tabs 658 MB (from
      1,135). Checked: a flood, a search (30 matches on its thread), and
      the UI Automation events test.
  - [x] Most of what was left per tab scaled with the window (31 MB per
        tab for 80x24 cells, 63 MB for the large window): each surface had
        three copies of its frame state (`swap_chain_count`, as on Metal
        and OpenGL), each with an offscreen target and copies of the glyph
        atlases, and this NVIDIA driver backs them with process memory.
        The copies let Metal and OpenGL build a frame while the GPU draws
        an earlier one, but Direct3D 11 completes a frame when it presents
        it, so only one was ever in use, and the driver orders our updates
        (`Map` with `WRITE_DISCARD`, `UpdateSubresource`) against queued
        draws itself. Direct3D 11 now keeps one. 1 tab 50 MB (from 88), 10
        tabs 296 MB (from 658). Frame rates were the same (light shader 69
        fps, heavy 69, four splits 274 in all, maximized heavy 49), and so
        was output throughput (about 1 MB/s through ConPTY either way).
  - [x] The offscreen target itself: the renderer drew each frame into a
        texture the size of the surface and copied it into the swap
        chain's back buffer. It now draws into the back buffer (one view
        of buffer 0, which Direct3D 11 rotates for a flip model swap
        chain; an sRGB view for linear blending; released before a resize
        or a lost device). ReleaseFast, the same 2854x1456 window, ten
        tabs: 10.8 MB of private bytes a tab (from 28.5) and 34.7 MB of
        dedicated GPU memory (from 52.1); 1 tab 37.6 MB (from 54.8). At
        200x60 cells: 11.7 MB a tab, from 45.5. It also saves a copy of
        the surface each frame. Checked: the device-lost test (plain,
        shader, background image), smoke, the blending capture (the same
        counts as before), and a capture after each of twelve typed
        letters, then a split: the same lit pixel counts as the build
        before, each letter showing in the next frame.
  - PowerShell's integration added about 180 ms per tab (590 ms with
    `shell-integration = none`). Its first prompt used three things that
    are slow the first time in 5.1: `New-Object` (63 ms), a regular
    expression (`-replace`), and `Test-Path` on the `Function:` drive
    (36 ms). Using `[StringBuilder]::new()`, `String.Replace`, and
    `${function:...}` brought it to about 70 ms (650-680 ms per tab).
    Checked: the pwd still followed `cd C:\Windows`, and `cmd /c exit 3`
    still showed "Command Failed" with
    `notify-on-command-finish-action=notify`.
- [x] Resizing and reloading the config with WSL running (from the
      discussion's list). Checked at 200% scale with zsh in WSL: after
      each window resize, and after changing `font-size` from 12 to 20
      in the config file and running `reload_config`, `stty size` in WSL
      matched Ghostty's grid (26x92 at 1774x1129 px, 19x71 at 1374x829 px,
      then 11x42 with the larger cells), so ConPTY passes the new size on.
- [x] Exit detection (from the discussion's list): typing `exit` closed
      the window (ReleaseFast, single tab) after 86 ms in cmd, 99 ms in
      Windows PowerShell, 104 ms in WSL, and 196 ms in Git Bash, each
      with exit code 0.
- [x] Handle leak: opening and closing tabs leaked about four kernel
      handles per terminal (measured: 493, 528, 560, 594, 626 handles
      over four rounds of eight tabs). The child's thread handle from
      CreateProcessW was never closed, nor was its process handle (the
      process watcher duplicates its own), and the read thread's quit pipe
      was closed with the C runtime's `close`, which doesn't know about
      Windows handles. Now: the thread handle is closed right away, the
      process handle when the subprocess ends, and pipes with
      `internal_os.closePipe`. Afterwards: 461, 461, 460, 462 handles.
      Memory and GDI and user objects were already flat after the first
      round.
  - Splits and windows don't leak: three rounds of four splits and three
    windows opened and closed left 474, 472, 472 handles, 35 GDI and 42
    user objects each time, and memory within 3 MB.
  - Shells exiting on their own (typing `exit`, the subprocess's
    external exit path) don't leak either: four rounds of eight tabs left
    472, 471, 471, 464 handles.
  - Config reloads don't leak: three rounds of ten reloads left 460
    handles, 25 GDI and 42 user objects, and 144.4 MB each time.
  - The inspector (its own Direct3D device and swap chain) doesn't leak:
    three rounds of opening and closing it three times left 486, 486, 485
    handles (the first round loads the Direct3D runtime's).
  - Font size changes (new glyph atlases) don't leak: three rounds of 15
    sizes up and back left 459 handles and 142.6-142.9 MB.
  - The quick terminal, command palette, and search bar don't leak: three
    rounds of showing and hiding each four times left 523 handles, 41 GDI
    and 66 user objects, and 242.0 MB each time (the first round creates
    the quick terminal, which is kept while hidden).
- [x] Stress test: a script posts random operations to a debug build
      (new windows, tabs, and splits; closing splits and windows; undo and
      redo; the command palette; dragging tabs out; typing; resizing; and
      shells exiting) and checks the log for panics.
  - [x] Found: `redo` bound to a key could close the terminal handling
        that key, and the core then used the freed surface to finish the
        key event (only the close actions may do that). Redo now closes
        from a posted message. Afterwards, seeds 1, 3, and 4 (400 steps
        each) ran without a panic or fault.
  - [x] `close_all_windows` bound to a key crashed the same way (it
        closed the terminal handling the key). It's posted now too.
        Checked each closing action from a key binding: `close_all_windows`,
        `quit`, and `close_window` quit cleanly, and `close_tab` left the
        other tab, all without a fault.
  - [x] Extended with the inspector, search, full screen, the quick
        terminal, font size changes, the tab overview, moving tabs to new
        windows, split zoom, and equalizing splits (22 operations). Seeds
        5, 6, and 7 (400 steps each) ran without a panic or fault; seed 6
        ended early when its last terminal closed, which quits the app.
  - [x] Leaks: the script now quits through the menu at the end, so the
        debug build's allocator reports leaks at exit (`global.deinit`).
        Seeds 8 and 9 (250 steps each) quit cleanly with no leaks and no
        faults.
  - [x] Extended with config reload, select all, copy, paste, clear, and
        reset (28 operations). Seed 10 reported 11 leaked accessibility
        providers: something on the system had queried the terminals
        through UI Automation, which still held references at exit. The
        app now calls `UiaDisconnectAllProviders` when it terminates, and
        seed 10 then quit with no leaks.
  - Seed 11 didn't exit within 20 s of Quit; its log ended at an unsafe
    paste waiting for confirmation. Reproduced directly: with the
    "Potentially Unsafe Paste" dialog open, Quit from the menu still
    exited. So that run was most likely waiting on a confirmation dialog,
    which is expected.
- [x] Clipboard confirmations show the text, like GTK: the unsafe paste
      warning, a program reading the clipboard (OSC 52; this used the
      unsafe paste wording before), and a program writing it each say
      what's happening, followed by up to 12 lines (800 bytes) of the
      text, with control characters shown as dots. Checked: pasting
      "echo one / echo two" showed both lines under the warning. Unit
      test: `writePreview`.
- [x] Logs: a GUI program's stderr usually isn't visible, so logs (info
      and above) also go to `OutputDebugStringW`, which debuggers and
      DebugView show. It's a new `GHOSTTY_LOG` destination, `windows`, on
      by default on Windows (documented in HACKING.md and ghostty(1)).
      Checked with a small DBWIN listener: 24 lines from a launch, starting
      with "ghostty info: ghostty version=...", and none from Ghostty with
      `GHOSTTY_LOG=no-windows`.
- [x] Crash reports: Ghostty is a GUI program on Windows, so a panic's
      message and stack trace went to an invisible standard error and the
      window just vanished (Sentry isn't built for Windows, as on Linux).
      A panic handler (`src/crash/windows.zig`) now first writes the
      message and stack trace to `%LOCALAPPDATA%\ghostty\crash\crash-<time>.txt`
      and, without a console, shows "Ghostty crashed: ..." with the
      report's path, then runs the default handler. It uses only fixed
      buffers and Win32 calls. Checked with `crash:main`, `crash:io`, and
      `crash:render` keybinds: each showed the dialog, saved a report with
      the version, message, and source locations, and exited.
  - Release builds have no debug info, so their stack trace says
    "stack tracing is disabled" (checked with ReleaseFast). Reports also
    list the raw return addresses (`RtlCaptureStackBackTrace`) as offsets
    into ghostty.exe, which the build's PDB can resolve.
  - `ghostty +crash-report` lists them: on Windows the crash directory
    is the same `%LOCALAPPDATA%\ghostty\crash`. Checked: after a
    `crash:main`, it listed "crash-66322625.txt (5s ago)".
  - [x] The dialog showed whenever there was no console, so a CLI action
        that panicked under Git Bash (no console there) or in a script
        waited for a click that never came: the Git Bash pipe panics
        above hung for an hour. Now standard error that goes to a file,
        pipe, or device also skips the dialog, since the default
        handler's output reaches it. Checked: the app with stderr in a
        file and F12 bound to `crash:main` exited by itself after a posted
        F12, with the panic and stack trace in the file and a report
        saved. Not rechecked: the dialog without a standard error (from
        Explorer), which would show on this desktop; that path is
        unchanged.
- [x] Config, cache, and state directories: with `XDG_CONFIG_HOME` (and
      the others) set but empty, the empty value won over `LOCALAPPDATA`,
      so the config went under `%USERPROFILE%\.config`. Empty now counts
      as unset, as the XDG spec says. Unit test: `windows: LOCALAPPDATA
      when xdg env unset or empty` (the POSIX fallback tests are skipped
      on Windows). Note: `-Dtest-filter` runs always report 78 extra
      tests; 79 means one test matched.
- [x] Opening the config:
  - Open Config (menu, `open_config`) did nothing visible: `.ghostty`
    files have no associated app, and ShellExecute "open" then only asks
    which app to use. Files whose type has no app (`AssocQueryStringW`)
    now open in Notepad. Checked: Notepad started.
  - `ghostty +edit-config` wasn't supported on Windows (and its message
    promised a path it didn't print). It now runs `$VISUAL` or `$EDITOR`
    through `cmd.exe /d /s /c` (so editors can have arguments or be batch
    files), or Notepad, waits, and returns the editor's exit code, with
    our standard handles. Checked with `EDITOR="echo EDITED"`, a Python
    one-liner (the path arrived as one argument), and `cmd /c exit 3`
    (exit code 3).
  - The default config path mixed separators (`ghostty/config.ghostty`);
    it's joined with the platform's separator now.
- [x] Links from terminal output: Ctrl+clicking an OSC 8 hyperlink (or
      text a `link` entry matched) went straight to `ShellExecute`, which
      runs programs and scripts, so any program's output could make a
      click run `file:///C:/.../run.vbs`, send Windows to a network share
      (`file://host/...`, which also signs in to it), or start any app
      registered for a scheme. They now follow the macOS app's policy
      (`UntrustedURL.swift`), in `apprt/win32/link.zig`:
  - `http`, `https` (with a host) and `mailto` open; other schemes ask
    first ("Open Link", No by default).
  - Files open only by an absolute local path (no `\\host`, `\\?\`, or
    alternate data stream), if they exist and are a regular file or
    folder. The type is checked on the file Windows actually opens
    (`GetFinalPathNameByHandleW`, so trailing dots, short names and
    symlinks don't hide it), and that path is what's opened. Types that
    run code are blocked: Windows' list (`AssocIsDangerous`), `PATHEXT`,
    and ours (`.vbs`, `.ps1`, `.lnk`, `.url`, `.msc`, `.appinstaller`,
    `.settingcontent-ms` and others). Folders named `name.{CLSID}` too.
  - Control, invisible and text-reversing characters are refused, and
    the dialogs show them escaped (`\u{202E}`).
  - Blocked links show "Link Blocked" with the reason, and are logged.
    The check and its dialogs run from a posted message: the core asks
    to open a link while it holds the terminal's lock, and in CI the
    dialog then didn't respond to its own button (its message loop
    painted, which needs that lock).
  - Unit tests: `apprt.win32.link` (web, mail and other schemes; unsafe
    characters; remote and relative paths; local files, including
    `run.bat.`, `run.bat .. `, `data.PS1`, a stream, a CLSID folder and
    `calc.exe`). CI test `links.ps1` Ctrl+clicks real links: a `.txt`
    opens in Notepad, a `.vbs` is blocked and doesn't run, and
    `ms-settings:` asks.
  - [x] A local symbolic link to a network share was followed while the
        link was checked (Windows follows local-to-remote links by
        default), and then opened. Each symbolic link on the way is now
        read without following it (`FSCTL_GET_REPARSE_POINT`), through
        relative targets and chains of links; one that points to
        `\\host` blocks the link before anything is opened. Unit test
        `symbolic links to other computers` creates real links (it's
        skipped without developer mode, as on CI); with the check turned
        off it fails, since a link to `\\127.0.0.1\c$\Windows\win.ini`
        was allowed.
  - Mapped network drives (`Z:\`) still open: the user chose that share.
- [x] The child environment (printed by Python under `-e`): `TERM`,
      `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`,
      `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR`, `GHOSTTY_SHELL_FEATURES`,
      and `TERMINFO` are set. Fixed two things it showed:
  - `GHOSTTY_RESOURCES_DIR` and `TERMINFO` mixed separators
    (`zig-out/share\ghostty`); the resources dir lookup and `TERMINFO` now
    join with the platform's separator.
  - `WT_SESSION` was inherited when Ghostty was started from Windows
    Terminal, so programs would think they run in Windows Terminal. It's
    removed now, with `WT_PROFILE_ID`, like `VTE_VERSION`.
- [x] Config files from Windows editors: a UTF-8 BOM (which some editors
      write) and CRLF line endings both validate cleanly with
      `+validate-config` (the loader already skips a BOM), while a bogus
      key in the same setup is reported.
- [x] `config-file` includes with Windows paths: a relative
      `sub\other.ghostty` and an absolute `C:\...\other.ghostty` (setting
      `font-size = 23`) both applied, giving the same 37x81 cells as
      setting it directly (19x42 by default at this DPI).
  - [x] `~/` paths weren't expanded on Windows (home expansion was a
        no-op there), so `config-file = ~/x/other.ghostty` failed as a
        relative path. `~/` and `~\` now expand to the home directory
        (HOMEDRIVE + HOMEPATH) with backslashes, for config files, themes,
        shaders, and `+new-window`/`+new-tab` paths. Optional includes
        (`?missing.ghostty`) were already ignored. Unit test:
        `expandHomeWindows`; checked live: the `~/` include applied
        (37x81 cells).
  - [x] The home directory is now `USERPROFILE` (the local profile, as
        Windows tools use), falling back to HOMEDRIVE + HOMEPATH, which can
        be a network share on domain-joined machines. This is also the
        `working-directory = home` directory.
- [x] Working directories with spaces and non-ASCII names: launched with
      `--working-directory` set to a folder named "dir 中文 é", the first
      tab's cmd prompt and a new tab's (inherited through OSC 7) both
      showed that path exactly (compared with UI Automation).
- [x] `-e` arguments reach the program intact: Python launched with
      `-e py -c "print(sys.argv[1:])" ...` printed exactly the arguments
      given, for spaces, embedded quotes, trailing backslashes, an empty
      argument, and `;` and `&` (read back with UI Automation).
- [x] `window-save-state = default` follows the system setting to restart
      apps after signing in ("Automatically save my restartable apps"):
      Ghostty registers with `RegisterApplicationRestart` to be restarted
      with `--window-save-state=always` after a reboot or an update (not
      after crashes or hangs), and saves its windows on `WM_ENDSESSION`
      (with any setting but `never`, since the process then ends without
      quitting). Checked: GetApplicationRestartSettings showed
      "--window-save-state=always" with flags 3, a posted WM_ENDSESSION
      saved the state with two tabs, and a launch with that argument
      restored both.
  - [x] Each custom class has its own state file
        (`window-state-<class>.json`) and restarts as itself (the restart
        arguments include `--class`). Checked with com.example.work: the
        restart command was `--window-save-state=always
        "--class=com.example.work"`, WM_ENDSESSION wrote its own file
        (the default one wasn't touched), and a launch with those
        arguments restored its two tabs.
- [x] Saved windows on a monitor that's gone: restoring a saved window at
      (-30000, -30000), off every monitor, put it on screen at (0, 0) with
      its saved 1000x600 size (SetWindowPlacement moves windows that would
      be off screen).
  - A saved terminal whose directory no longer exists starts anyway: it
    logged "cannot access cwd, ignoring" and cmd started in the default
    directory.
- [x] Font fallback check (2026-10-26): a UTF-8 file with emoji (with a
      skin tone, a flag, and a variation selector), Chinese, Japanese,
      Korean, box drawing and shades, math symbols, Arabic, Hebrew, and
      combining marks, shown with `type` after `chcp 65001`, all drew
      (right-to-left text in logical order, as in most terminals). Before
      `chcp 65001`, cmd decodes the file with the system code page (936
      here), as in Windows Terminal; that isn't ours to change.
- [x] The CLI from WSL (through interop): `ghostty.exe +version` and
      `+list-themes --plain` run and print from a WSL shell.
  - `ghostty.exe +new-window` from WSL opens a WSL window where it was
    run: interop starts it in the `\\wsl.localhost\...` directory, which
    `+new-window` sends, and a WSL directory starts WSL. Checked from
    `~`: the running instance logged "starting WSL for a WSL working
    directory distribution=Ubuntu-24.04 path=/home/yuan/" and the new
    window showed zsh in `~`.
  - [x] `--working-directory=/linux/path` for `+new-window` and
        `+new-tab` from WSL: a Windows program can't resolve a Linux path
        (it failed with BadPathName), so when our working directory is a
        distribution's share, an absolute Linux path maps into that share
        (`internal_os.wsl.linuxToShare`, unit tested). Checked:
        `--working-directory=/tmp` from WSL opened a window that logged
        "starting WSL ... distribution=Ubuntu-24.04 path=/tmp".
- [x] CLI actions on Windows: `+version`, `+list-fonts`, `+list-themes`,
      `+list-keybinds`, `+list-colors`, `+list-actions`, `+show-config`,
      `+validate-config`, `+help`, `+show-face`, `+explain-config`, and
      `+boo` all ran and exited 0.
  - [x] In CI (2026-11-08): the "Test CLI actions" step only ran
        `+version` and `+validate-config`; it now also runs every action
        that prints and exits (`+list-themes`, `+list-fonts`,
        `+list-keybinds`, `+list-colors`, `+list-actions`, `+show-config
        --default`, `+show-face`, `+explain-config`, `+help`,
        `+ssh-cache`, `+crash-report`), each needing exit 0 and what
        it's for in its output. Passed here. `+edit-config` runs with
        `EDITOR=cmd.exe /c echo`, which prints the quoted config path it's
        given (run 42477878738, 99b6fe4d1, passed every job). Not
        included: `+boo` (a TUI). The ones that talk to a running
        instance have their own tests: `+toggle-quick-terminal` in
        `quick-terminal.ps1`, and now `+new-tab` and `+new-window` in
        `test/windows/cli-ipc.ps1` (in CI: a tab, then a second window,
        counted with UI Automation; passed here). CI run 42473473478
        (9b2b71c45) passed every job, both new CLI steps included.
  - [x] `+list-fonts` printed family names as raw UTF-16BE (a NUL before
        each letter): FreeType faces took the first family name in the
        name table, and only decoded Microsoft BMP names, while Windows
        fonts list a Unicode-platform name first. Now the US English
        Microsoft name is preferred, then any UTF-16 name, decoded
        without assuming alignment. The family name fallback in font
        discovery uses the same function.
  - [x] Output piped in Git Bash: `+show-config --default --docs | wc -c`
        stopped at 69,053 of 187,859 bytes and hung. The pipes of MSYS2
        and Cygwin programs are opened for asynchronous I/O, and Zig's
        `std.Io.File.stdout()` assumes a synchronous handle, so a write to
        a full pipe returned `STATUS_PENDING`, which Zig treats as
        unreachable (a small Zig program writing 235 KB panicked there).
        Reopening the handle synchronously fails (`ERROR_PIPE_BUSY`), so
        `internal_os.stdio` asks how each standard handle was opened
        (`NtQueryInformationFile`, `FileModeInformation`) and marks
        asynchronous ones nonblocking, which makes Zig wait for the write.
        The CLI actions use it, and so does our logging's stderr: the app
        with a config of 3,000 bad lines (614 KB of warnings) and `2>&1`
        piped to a reader that waited 5 s got 165 KB and stuck before;
        now all 614 KB arrive. Checked: all 187,859 bytes arrive through
        `wc` and through a reader that waits 3 s; files, cmd pipes and
        consoles report synchronous handles and are unchanged. Tests:
        `os/stdio.zig` (a file stays synchronous, an overlapped pipe
        becomes nonblocking).
    - [x] libghostty-vt's raw stderr writer (`os/stderr.zig`, for its
          logs and panics) called `NtWriteFile` and returned; on such a
          pipe the write can still be pending then, and the kernel later
          writes its result into the stack frame that's gone. It now waits
          until the write's status block says it's done, and writes the
          rest of a partial write. Test: a 16 KB write to an overlapped
          pipe that's read only after 200 ms must take that long and
          arrive whole; without the wait it crashed.
    - [x] The benchmark data generator: `ghostty-gen +ascii | head -c
          10000000 | wc -c` gave 65,536 bytes and `ghostty-gen` exited 0,
          because its generators treat a failed write as the reader
          having gone away. It now uses `internal_os.stdio` too, and all
          10,000,000 bytes arrive; `ghostty-gen +ascii | ghostty-bench
          +terminal-stream --data=-` runs. Reading a Git Bash pipe was
          already fine: `ghostty-bench --data=-` read all 2,701,756 bytes
          of a piped file, and all 300,000 of a pipe fed in three pauses
          (checked with a temporary byte count, not committed).
- [x] Output throughput (2026-10-26, ReleaseFast, 20 MB of text):
  - `cmd /c type` is slow everywhere: 19-27 s in Ghostty, 27-38 s in a
    conhost window. cmd writes line by line through the console API.
  - A program writing 64 KiB chunks with `WriteFile`: 0.6 s in conhost,
    2.25 s in Ghostty (about 0.5 s of it startup). During a run Ghostty
    used 0.44 s of CPU and the ConPTY host 1.55 s, so ConPTY (which
    renders the output into its own buffer and re-encodes it as VT) is
    the bottleneck, not our parser.
  - The read thread now reads 64 KiB at a time instead of 1 KiB, which
    took the run from 2.25 s to 2.0 s.
  - This found that ReleaseFast builds failed: stripping also turned off
    unwind tables, which MinGW's startup code needs for structured
    exception handling. They're kept on Windows now.
- [x] `split-preserve-zoom = navigation`, like GTK: navigating away from
      a zoomed split zooms the target instead of unzooming. Checked: with
      the option, `goto_split:previous` from the zoomed split showed only
      the first split; without it, both showed.
- [x] `window-title-font-family` sets the tab bar's font (at the system
      UI font's size; it's reapplied on config reload). Checked with
      screenshots: "Courier New" drew the tab title in Courier.
- [x] `window-subtitle = working-directory`: the title bar has one line,
      so the working directory follows the title after a dash, unless the
      title already contains it; it updates on the core's `pwd` action.
      Checked with `--title=Fixed`: "Fixed — C:\Code\ghostty", and
      "Fixed — C:\Code" after typing `cd ..`; without the option the title
      stayed "Fixed".

### Known limitations

- No Kitty keyboard protocol for programs behind ConPTY (including WSL):
  ConPTY answers or drops queries itself. Checked from bash in WSL:
  `CSI ? u` (the Kitty keyboard query) got no reply, and `CSI c` was
  answered by ConPTY (`?61;6;7;21;22;23;24;28;32;42c`), not Ghostty.
  Keys reach console programs through win32 input mode instead.
  - What does pass through ConPTY (checked from bash in WSL): OSC 0
    titles (the window title became "probe-title"), OSC 9 and OSC 777
    desktop notifications (the first showed; the second was rate limited,
    so it arrived too), OSC 9;4 progress reports (state set, value 42),
    OSC 8 hyperlinks, OSC 52 clipboard, and OSC 133 prompt marks.
  - Mouse reporting passes too: a WSL program that enabled SGR mouse
    tracking (DECSET 1000 and 1006) received `ESC [ < 0 ; 21 ; 10 M` and
    `... m` for a posted click at (400, 400) pixels.
  - [x] This found that button presses used the last position from a
        move: after WM_MOUSELEAVE (here sent right after a posted move,
        with the real pointer elsewhere), the core had the cursor outside,
        dropped the press, and put the release at 1;1. Pen and touch can
        also press without a move. Button messages now update the
        position from their own coordinates first.
  - [x] Losing the mouse capture with a button down (another window
        taking it, as with Alt+Tab during a drag) left the button pressed
        in the core, since its release went elsewhere: later moves over
        the terminal kept changing the selection (posted moves without a
        button after `WM_CANCELMODE` emptied it), and a program reporting
        the mouse would get drags and no release. `WM_CAPTURECHANGED` now
        releases the buttons the core has down. Checked: the selection
        stays "aaaa b". Test: `test/windows/mouse-capture.ps1`, which fails
        on the build before the fix. Programs that report the mouse now
        get the release too: a WSL program with button-event tracking
        (DECSET 1002 and 1006) got the press, the drag and
        `ESC [ < 0 ; 32 ; 10 m` after `WM_CANCELMODE`; the build before
        the fix sent no release.
  - [x] Wheel messages too (their coordinates are on the screen). Checked:
        a posted wheel notch reached the WSL program as three wheel-up
        reports at 21;10 (`ESC [ < 64 ; 21 ; 10 M`, three per notch, as
        on other platforms).
- [x] `mouse-hide-while-typing`: checked in CI with real input
      (`desktop-input.ps1`): a typed letter hid the pointer over the
      terminal (`GetCursorInfo` showed no cursor) and moving the mouse
      showed it again.
  - [x] Its default follows Windows' "Hide pointer while typing" (Mouse
        settings > Additional mouse settings > Pointer Options;
        `SPI_GETMOUSEVANISH`), which is on by default and which Notepad
        and other editors follow. It's read when the config is loaded;
        a value in the config still wins. Checked: `+show-config
        --default` says `true` here (the setting is on), and a config
        with `false` gives `false`. Config tests pass (they keep the
        documented default).
- [x] Ctrl+wheel changes the font size, like other Windows apps and
      Windows Terminal, unless a program reports the mouse (it then gets
      the wheel as usual). Checked: two posted Ctrl+wheel-up notches took
      the cells from 19x42 to 21x46 to 22x49; with mouse tracking on in
      WSL, the wheel went to the program instead (its reports lack the
      Ctrl bit only because posted messages can't set the key state the
      core reads).
  - Touchpads and high resolution wheels send fractions of a notch,
    which add up before changing the size (each event changed it by a
    whole step at first). Checked: eight quarter notches made two steps.
- [x] Horizontal touchpad scrolling: the core rounds horizontal wheel
      offsets to whole columns, so a touchpad's fractions of a notch were
      dropped. We now add them up and pass whole notches. Checked: four
      quarter notches right reached a WSL program as one wheel-right
      report (`ESC [ < 67 ; 21 ; 10 M`).
- WSL programs see `TERM=xterm-256color` (WSL's default, as in Windows
  Terminal), not `xterm-ghostty`: `TERM` isn't in `WSLENV`, and
  distributions don't ship the entry yet (Ubuntu 26.04 doesn't). Passing
  it would also need `TERMINFO` pointing at the Windows install through
  `/mnt/c`, and SSH from WSL to hosts without the entry would break. Git
  Bash and other MSYS2 programs do get `xterm-ghostty` (see the compiled
  terminfo above).
  - [x] With the ssh-env or ssh-terminfo features (2026-11-07), whose
        `ssh` wrapper keeps SSH working with hosts that lack the entry,
        WSL shells get `TERM=xterm-ghostty`, as on Linux.
        `wsl/terminfo.sh` (sourced by the WSL launcher) compiles the entry
        from its source with the distribution's `tic`, once per Ghostty
        version, into `~/.cache/ghostty/terminfo`, and sets `TERMINFO`
        there: the entry compiled for Windows can't be used, as Windows
        lays it out by hex directory (`78/`) where Linux's ncurses looks
        in `x/`. Without those features, or without `tic`, TERM stays
        `xterm-256color`. Checked: `test/windows/wsl-ssh.sh` (compiles,
        `infocmp` finds it, `tput Smulx` works, a second start reuses it,
        no change without the features), and in Ghostty with
        `command = wsl.exe`: `TERM=xterm-ghostty`, `tput Smulx` gives
        the undercurl sequence; with `cursor,title` only, TERM stayed
        `xterm-256color`.
- No password input indicator: on Unix the IO thread polls the pty's
  termios for echo being off (`termiosTimer`), but ConPTY doesn't expose
  the console mode of the programs attached to it, so the timer isn't
  started on Windows.
- The inbox ConPTY drops APC sequences, so the Kitty graphics protocol
  doesn't work with it. The ConPTY package (bundled in the tip and
  release packages since 2026-11-07) passes them: see below. OSC 8 hyperlinks do pass through on build 26100 (checked:
  a PowerShell `Write-Host` of an OSC 8 link reached `startHyperlink`).
  `PSEUDOCONSOLE_PASSTHROUGH_MODE` (0x8) is accepted by
  `CreatePseudoConsole` on 26100 but changes nothing: the APC still
  doesn't arrive.
  - [x] Load `conpty.dll` (with `OpenConsole.exe`) when it's next to
        `ghostty.exe`, from the Microsoft.Windows.Console.ConPTY NuGet
        package (MIT, 1.25.260930003 has x64/x86/arm64) or Windows
        Terminal, falling back to the inbox ConPTY. It's created with
        `PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES`, matching our default width
        method. That package's header has no passthrough flag (0x8 is now
        the grapheme width flag).
    - [x] Checked (with permission, 2026-10-26): Ghostty logged "using
          conpty.dll" and the shell ran normally, but the Kitty graphics
          APC still didn't arrive: PowerShell's `Write-Host` of
          `ESC _ G i=31,a=q; ESC \` showed "=31,a=q;" as text. So neither
          the inbox ConPTY nor the 1.25 package passes APCs through, and
          the Kitty graphics protocol can't work through ConPTY for now.
          OSC 8 hyperlinks pass through both.
      - Wrong (corrected 2026-11-07): that check's PowerShell string was
        `"$e_G..."`, which PowerShell reads as a variable `$e_G`, so no
        ESC was sent at all; "=31,a=q;" is what's left of the text. Done
        right (`"${e}_G..."`), the package's ConPTY passes the APC: a
        96 by 48 image drawn with `a=T` showed, from WSL (Python) and
        from native PowerShell alike, and the query got Ghostty's
        `ESC _ G i=31;OK ESC \`. The inbox ConPTY drops it. CI now
        checks the query through the package (`color-query.ps1`); run
        42425252674 (aa5ea3033) passed every job, the query getting
        Ghostty's OK through the ConPTY package and from the packaged
        zip, and nothing through the inbox ConPTY.
    - [x] What else the package's ConPTY passes that the inbox one
          doesn't (2026-11-07, a probe in WSL, raw `/dev/tty`):
          - Answered by Ghostty only with the package: OSC 10/11 colors,
            XTGETTCAP (`TN` = `xterm-ghostty`), Kitty graphics, OSC 52
            clipboard reads (with `clipboard-read = allow`; the reply
            takes over a second, as the read is asynchronous), DA1 and
            DA2 (the inbox one answers them itself, as a VT525 with
            conhost's features), and DECRQM for synchronized output
            (2026), which the inbox one reports as unknown.
          - The same through both: XTVERSION, the Kitty keyboard query
            (`CSI ? u`), DECRQM 2004, DECRQSS, the CSI 14/16/18 t size
            reports and DSR 5.
    - [x] `package.ps1 -BundleConpty` downloads that package (version and
          SHA-256 pinned), and puts its `conpty.dll` and `OpenConsole.exe`
          for the target architecture in `bin`. Checked: the zip has both
          next to `ghostty.exe`. Use it to try the item above.

### Next

- [x] Right-click menu in the terminal area: reported (2026-11-05) that
      right-clicking in a terminal shows no menu. A regression from
      1b21987e5: on the button's release we call `ReleaseCapture`, which
      sends `WM_CAPTURECHANGED` (to no window), and `releaseButtons` then
      cleared the pending menu before the release handler looked at it.
      Now it's only cleared when the right button was still held when
      the capture was lost. `test/windows/context-menu.ps1` (in the
      fork's CI) posts a right-click and waits for the process's popup
      menu (`#32768`); it failed without the fix and passes with it.
- [x] Make GitHub CI pass reliably: in recent runs of the Windows (fork)
      workflow, `build-windows` failed while `build-windows-2022`,
      `build-windows-arm64` and `build-libghostty-vt-windows` passed.
      The latest failure (run 41980624453) was the console handoff
      test's intermittent "owned by 0"; 5b8d2604e resends the console's
      window signals and 5534c5750 fixes the test's racy resize step.
      Go through the recent failed runs step by step, fix each cause or
      make its test robust, and only check this off after several green
      runs in a row.
  - Failures since 2026-11-03, by step: console handoff (4, the latest
    two before 5b8d2604e and 5534c5750), high contrast (3, until
    d4b442474 read the theme's color with each check), and one each for
    quick terminal, cursor blink, desktop input, unsafe paste dialog,
    blur smoke test (Windows 2022) and
    MSIX install, each on the commit that changed that feature and fixed
    by the next. ARM64 builds failed three times on 2026-11-03/04, not
    since.
  - [x] Run 42156713724 (ca326980c, with both handoff fixes): all jobs
        passed. One green run; more needed.
  - [x] Run 42164080425 (`windows-rebased`, the first full run after
        rebasing onto upstream): the Links test timed out waiting for the
        link preview while holding Ctrl over an OSC 8 link. It had never
        failed before; upstream changed how pages store hyperlinks.
        Rerun to tell a flake from a regression. Not a regression: the
        core keeps OSC 8 links on every row after the same 60 lines scroll
        (checked with a unit test at 80, 120 and 200 columns), and the
        next run, 42168399346, passed every job including Links. Two
        green runs (42156713724, 42168399346).
  - [x] Run 42176318349 (f7f532a77, DirectWrite synthetic bold): all
        jobs passed and `tip` moved `windows-tip` to the commit. Three
        green runs in a row.
  - [x] Run 42188659026 (aba736b96, after the second upstream sync): all
        jobs passed. Four in a row.
  - [x] Runs 42195536279 to 42216483721 (from adb3798d6): the overlays
        test timed out waiting for the drop zone on `build-windows` four
        times in a row (Windows 2022 passed). The zone was made, then
        hidden again. Reposting the move or dragging again didn't help.
        The error message now carries the drag state and Ghostty's
        warnings (the job log needs a token, annotations don't), which
        showed the handle still had the capture and the points were
        right. Cause: while it has the capture, the handle also gets
        moves Windows makes itself (when the drop zone shows) at the real
        cursor, which with posted input is elsewhere, so the zone moved
        away at once. The handle now ignores moves without the left
        button down, which a real drag always has. Likely a runner image
        change on `windows-latest`, since `aba736b96` passed just before.
  - [x] Run 42224003628 (7606f8cf7, with the drag handle fix): all jobs
        passed and `windows-tip` moved to it.
  - [x] Since then every run on `windows` passed: 42237363197
        (d7cbffabf), 42247467303 (d6af086d4, with the new window theme
        test), 42258918661 (5855f01fb) and 42317231582 (dfc88fb6a, WSL
        `+ssh`), plus 42268017280 on `windows-rebased` (028b77a03, whose
        run on `windows` was cancelled by the next push). Five green
        runs in a row.
  - [x] Run 42326858247 (dc0a56f4c, the six new UI tests): `build-windows`
        failed in its Build step after 1m39s, too early for a compile
        error (the same tree built on Windows 2022, ARM64 and here), so
        likely the dependency download; every other job passed. Pushed
        again to rerun it, since rerunning a job needs a token.
  - [x] It failed the same way in runs 42331519319 and 42331730301. The
        Build step now puts the end of a failed build in an annotation,
        which showed `pkg/dcimgui/build.zig.zon: error: unable to unpack
        tarball to temporary directory: ReadFailed`: Zig's download
        failing, as it does here (see the curl workaround above). The
        three build jobs now fetch the dependencies first in their own
        step (`zig build --fetch`, up to four tries).
  - [x] Run 42331955236: the fetch failed four times in a row in the
        same job, so it wasn't the network. Like the ARM64 job before
        (9bcfa2bb9), a failed fetch had saved a broken Zig cache that
        every later run restored. The x64 jobs no longer restore the Zig
        cache either.
  - [x] Run 42332304583 (4479e72aa): the build got through, and the new
        session restore and search tests passed on the runner. The
        command palette test measured the split as soon as a second
        terminal showed, before the two were laid out (both had the old
        terminal's rectangle); it now waits for them to be side by side.
  - [x] Run 42334957588 (54327c2ee): every job passed, with all six new
        UI tests on the runner and the UI clean-up (no menu button,
        drag handles on hover, the shorter context menu); `windows-tip`
        moved to it.
  - [x] Run 42339834650 (7c125fa08, the macOS-style menus): every job
        passed, with the translucent and high-contrast tests finding
        their window menu items by label.
  - [x] Run 42354866951 (ab3d3f027, after the fifth upstream sync, the
        noctty-style title bar and the Command/PowerShell titles): every
        job passed and `windows-tip` moved to it. On the way, the high
        contrast test expected the old tab bar color and the PowerShell
        integration test the old prompt title (the folder); both updated.
  - [x] Run 42360505212 (bbce57b5a, the caption buttons for UI
        Automation): every job passed; `windows-tip` moved to it.
  - [x] Runs 42364925647 (475f011eb, icon font glyphs) and 42372742551
        (fdd5f7ca0, the tab reorder test): every job passed. In between,
        the tab reorder test failed once because an elevated console (as
        on the runners) names tabs "Administrator: SECOND"; it now
        matches the end of the name.
  - [x] Run 42384896502 (9327700aa, reverting the Command and PowerShell
        titles): everything passed except the console handoff test, where
        UI Automation failed with E_UNEXPECTED listing the terminals of a
        window that was being made or closed. The test's poll now skips
        such a window, as it already did a terminal. Run 42389933396
        (04edfd329, with that and the sixth upstream sync): every job
        passed.
  - [x] The runs' "Node.js 20 is deprecated" annotation is about
        `mlugg/setup-zig` v2.2.1, which declares `node20`; GitHub runs it
        on Node 24 and it works. It's the latest release (checked
        2026-11-07) and upstream pins the same commit, so there's nothing
        to bump yet.
  - [x] Run 42400147972 (e01b70340, compact tabs and the
        OSC findings; 542903412's own run was cancelled by that push):
        every job passed, including the compact tabs test, and
        `windows-tip` moved.
  - [x] Run 42406031418 (40db76dd7, Chrome-like tabs and the bundled
        ConPTY) failed in the MSIX start menu test: cmd's prompt vanished
        (fixed by `redraw=0`, see the OSC 10/11 item). Run 42413296400
        (9b49d1c1b) passed every job: the color query tests (inbox as a
        notice, the ConPTY package, and the packaged zip, which answered
        `rgb:abab/cdcd/efef` and `rgb:1212/3434/5656`), the MSIX and zip
        installs and the package's tests on the bundled ConPTY.
        `windows-tip` moved, so the tip now ships the ConPTY package.
  - [x] Runs 42434682817 (65987bcfe: restoring each terminal's shell,
        with the extended session restore test, and WSL's
        `TERM=xterm-ghostty`) and 42439780470 (a108ca837: a chosen shell
        doesn't inherit a WSL directory): every job passed, and
        `windows-tip` moved.
  - [x] Run 42444209016 (5b6cb0829, the jump list's shell tasks): every
        job passed, and `windows-tip` moved.
- [ ] Keep the branch on top of upstream: fetch
      `git@github.com:ghostty-org/ghostty.git` from time to time, rebase,
      and check that the build, unit tests and the fork's CI still pass.
  - [x] 2026-11-05: rebased onto upstream/main (277 new upstream commits).
        Conflicts: `modes.zig` (upstream enabled `kitty_paste_events`
        everywhere and dropped the `builtin`/`build_options` imports,
        which `win32_input` still needs) and the bash integration's OSC 7
        (upstream strips control bytes; the MSYS2 path is now stripped
        too). Upstream's new uucode, z2d and themes archives needed the
        curl workaround above. The rebased history replaced `windows`
        (force-pushed with the owner's approval).
        The rebase gave every commit a new committer date; they were set
        back to the originals (matching commits by author date and
        subject), so the history keeps its timestamps. Next time use
        `git rebase --committer-date-is-author-date`. The full unit test
        suite passed on the rebased tree.
  - [x] 2026-11-06: rebased onto upstream/main again (2 commits: hidden
        visibility for simdutf, highway and wuffs). No conflicts; dates
        kept with `--committer-date-is-author-date`. Build and the
        terminal and DirectWrite tests passed.
  - [x] 2026-11-06: a third sync (11 upstream commits: triple-click
        selection over blank lines, kitty image eviction, ssh terminfo
        install, translations). No conflicts. The build and the
        selection, kitty, ssh and DirectWrite tests passed. The repo's
        `.zig-cache` had grown to 153 GB and filled the disk (builds
        failed with `NoSpaceLeft`); deleting it fixed that.
  - [x] 2026-11-06: a fourth sync (3 commits: style runs found in one
        scan in `RowBuilder.scan`). No conflicts; the build and the
        `RowBuilder` tests passed.
  - [x] 2026-11-07: a fifth sync (36 commits: libghostty-vt 1.0 C ABI
        cleanups, an ABI baseline, rewritten Doxygen docs, RefCountedSet
        reusing dead IDs). No conflicts; dates kept. Upstream's new test
        that every terminal mode has a `GHOSTTY_MODE_*` macro failed for
        our `win32_input` (9001), so `modes.h` has
        `GHOSTTY_MODE_WIN32_INPUT`, documented as recognized only by the
        Windows app (a macro, so not part of the ABI baseline). The app
        and libghostty-vt build, and the modes (both), `ghostty/vt.h`,
        RefCountedSet and title bar tabs tests pass.
        The rebased branch went to `windows-rebased` first (the force-push
        was blocked by the permission check) and then to `windows` with
        the owner's go-ahead. The full unit test suite on the synced tree:
        4,266 passed, 64 skipped (other platforms), 0 failed.
  - [x] 2026-11-07: a sixth sync (1 commit, the VOUCHED list). No
        conflicts; dates kept. The app and libghostty-vt build.
  - [x] 2026-11-07: a seventh sync (7 commits: dangling pins after a
        column-growth resize, faster C enum validation, a multi-word
        terminfo description, and `+ssh` running its remote terminfo
        install under `sh -c` for non-POSIX login shells). No conflicts;
        dates kept. Our WSL `ghostty +ssh` had the same bug, so it now
        runs the install under `sh -c` too, and `test/windows/wsl-ssh.sh`
        checks that (all checks pass). The app and libghostty-vt build,
        and the resize tests pass. CI run 42420229730 (225fb5bb7) passed
        every job, and `windows-tip` moved.
  - [x] 2026-11-07: an eighth sync (5 commits: retrying dirty rows after
        a failed render update, and new iTerm2 color schemes). No
        conflicts; dates kept. But the new theme release can't be
        unpacked on Windows: it has themes named `Neon Raincheck: After
        Hours` and `Analog Heartbeat: Phosphor`, and `:` isn't allowed in
        Windows file names (NTFS takes it for an alternate data stream of
        `Neon Raincheck`, which already exists), so `zig fetch` fails
        with "unable to create file 'Neon Raincheck': PathAlreadyExists"
        and no Windows app build works. The fork reverts that bump
        (keeping `ghostty-themes-release-20261026-153024-27cbbb5`) until
        the themes avoid characters Windows forbids (`<>:"/\|?*`). CI
        run 42448875784 (5449e46b6) passed every job, and `windows-tip`
        moved.
    - [ ] Upstream fix needed (in the themes release, which names files
          after the schemes): replace or drop those characters. Until
          then, each themes bump needs this check and maybe a revert.
          Ghostty couldn't load such a theme by name on Windows anyway.
  - [x] 2026-11-07: a ninth sync (3 commits: macOS NSColor tests only).
        No conflicts; dates kept; nothing for Windows to check. CI run
        42457195698 (1720f1a16) passed every job.
- [x] Tip builds, like upstream's `release-tip.yml` (the discussion's
      release workflow item): a rolling prerelease of the latest
      `windows` commit, so people can try it without building. Approved
      by the owner (2026-11-05).
  - [x] The fork workflow's `tip` job: after every job passed for a push
        to `windows`, the packages those jobs built and tested (ReleaseSafe
        zip and MSIX for x64 and ARM64) and their SHA-256 sums replace the
        `windows-tip` prerelease, whose tag moves to the commit.
  - [x] First `windows-tip` (run 42168399346, ce2c8e1d7, 2026-11-05):
        a prerelease with the x64 and ARM64 zip and MSIX and
        `SHA256SUMS.txt`, its tag at the commit. The downloaded x64 zip
        matched its checksum and `ghostty.com +version` printed
        `1.4.1-windows+ce2c8e1`.
- [x] DirectWrite rasterization (the discussion: text should look native
      on Windows). FreeType rasterizes now; a DirectWrite face (with
      ClearType-style gamma and contrast from the system) could be a
      `font-backend` option. Compare screenshots with Windows Terminal.
  - [x] `src/font/face/dwrite_raster.zig` draws an outline glyph's
        coverage with `IDWriteGlyphRunAnalysis` (natural symmetric
        rendering, grayscale antialiasing) from the font data FreeType
        loaded (the whole file, from `FT_Load_Sfnt_Table` tag 0, through
        DirectWrite's in-memory loader, so the embedded fonts work) and
        FreeType's variation coordinates.
  - [x] `font-rasterizer = directwrite` uses it in the FreeType face for
        outline glyphs, with the same placement transform (constraints,
        centering, synthetic italic's skew). FreeType still draws color
        and bitmap glyphs, `font-thicken` and monochrome.
  - [x] Synthetic bold with DirectWrite's bold simulation
        (`DWRITE_FONT_SIMULATIONS_BOLD`) rather than falling back to
        FreeType's emboldening. Test: a bold `l` is drawn by DirectWrite
        and comes out wider.
        Tests: placement of several glyphs within a pixel of FreeType's,
        and synthetic italic. Checked in the app: about 6% of the pixels
        of cmd's banner differ from FreeType's rendering.
  - [x] DirectWrite's enhanced contrast and gamma (from the system's
        rendering parameters), which Windows applies when blending text;
        the mask alone is raw coverage. Windows Terminal does this in its pixel
        shader: the grayscale enhanced contrast is scaled by
        `saturate(3 - 4 * luminance)` of the text color, so it's about
        zero for light text on a dark background and only the gamma
        correction applies there; dark text on light gets the full boost.
        Done as `alpha-blending = directwrite`, for either rasterizer:
        `native` blending, with the text mask corrected in the D3D11 and
        GLSL text shaders (`dwrite_alpha`) by the system's grayscale
        enhanced contrast and gamma (read once from
        `IDWriteFactory::CreateRenderingParams`, in
        `src/renderer/text_blend.zig`, with DirectWrite's gamma ratio
        table as in WT's `dwrite_helpers`; tests check the 1.8 constants
        WT documents). Metal ignores it (same as `native`). Measured
        (MesloLGS NF 13, One Half Dark, mean ink over the text): WT 25.4,
        `native` 22.3, `directwrite` 23.7, so it closes about half the
        gap to WT. Dark text on white changes little overall (the boost
        and the gamma correction nearly cancel). The OpenGL shader isn't
        run here (Windows uses D3D11).
  - [x] DirectWrite's extra 0.5 contrast for "thin" fonts (Courier New,
        Miriam Fixed, Rod, Simplified Arabic Fixed and their
        variants), added after the light text scaling as in WT's
        `DWrite_GrayscaleBlend`, so light text on dark gets it too. The
        renderer checks the primary font's family when it starts and
        when the font changes (`text_boost` uniform). Checked: Courier
        New's family is read from the loaded face; light Courier New on
        dark: ink 22.9 (`native`) to 24.2 (`directwrite`).
  - [x] Side by side with Windows Terminal 1.25 (2026-11-05, captured
        with `PrintWindow`, which works with the desktop locked; a new WT
        window opened with `wt -w new` and closed with `WM_CLOSE`).
        With the same font (MesloLGS NF 13, One Half Dark), Ghostty with
        either rasterizer is very close to WT: same advance and line
        height, same shapes; DirectWrite's strokes are a little lighter
        than WT's (which also applies DirectWrite's contrast and gamma
        when blending). A first comparison with Cascadia Mono looked much
        heavier, but WT was actually using MesloLGS NF from its profile.
        FreeType stays the default; `directwrite` is there for people who
        prefer it.
- [x] Verify IME with Microsoft Pinyin, Japanese IME, and others
- [x] Fix tab-header close crashing the window when there are multiple
      tabs (active index and split focus must be valid during teardown)
- [x] `ssh-terminfo` (and `ssh-env`) in WSL (reported 2026-11-06): with
      `shell-integration-features = ssh-terminfo`, `ssh` in a WSL shell
      fails with `ssh:4: no such file or directory: /ghostty`. `WSLENV`
      passes `GHOSTTY_SHELL_FEATURES` into WSL, so the integration wraps
      `ssh` with `"$GHOSTTY_BIN_DIR/ghostty" +ssh`, but `GHOSTTY_BIN_DIR`
      isn't passed (and the Windows `ghostty.exe +ssh` would use Windows'
      ssh and environment, not the distro's). Make it work inside WSL:
      - [x] Stop the broken wrapper first: bash, zsh, fish, elvish and
            nushell only wrap `ssh` when `ghostty` (or `ghostty.exe`) is
            in `GHOSTTY_BIN_DIR`, so plain `ssh` keeps working wherever
            it isn't set.
      - [x] Support the features from WSL itself: for the ssh features
            the WSL launcher sets `GHOSTTY_BIN_DIR` to
            `shell-integration/wsl/bin`, whose `ghostty` is a POSIX
            `+ssh` with the distro's `ssh` (same flags and behavior as the
            native command): it pipes the resources' `ghostty.terminfo`
            to `tic -x -o ~/.terminfo -` on the remote, uses
            `TERM=xterm-ghostty` or falls back to `xterm-256color` with a
            warning, sends `COLORTERM`, `TERM_PROGRAM` and
            `TERM_PROGRAM_VERSION` with `SendEnv`, and caches installs in
            the native cache file (`host|time|wsl-<cksum>`, mode 600).
            Options that open no session (`-G`, `-V`, `-Q`, `-O`) go
            straight to `ssh`. If the script isn't executable on the
            Windows drive (`metadata` mount option), the launcher uses a
            copy in `~/.cache/ghostty/wsl-bin`. Other `ghostty` commands
            in WSL say to use `ghostty.exe`.
      - [x] Tests: `test/windows/wsl-ssh.sh` (run in a distro, with a
            fake `ssh` that answers `-G` and runs the installer locally,
            in a temporary `HOME`): install and cache, the cache hit, a
            separate port, `--terminfo=false`, `--forward-env=false`, a
            failed install, the cache's mode, `-G` passing through, bad
            flags, the launcher's `GHOSTTY_BIN_DIR`, and bash and zsh
            wrapping `ssh` only with ghostty there. All passed on
            Ubuntu 24.04. In the app (`--command=wsl.exe`,
            `ssh-terminfo,ssh-env`): zsh's `ssh` is the wrapper and
            `GHOSTTY_BIN_DIR` is the WSL script's directory. Not checked:
            a real remote host (no sshd here), fish, elvish and nushell
            (not installed in the distro).
- [x] Shell integration for wsl
  - [x] Map WSL Linux paths (`/home/...`) to `\\wsl$\<distro>\...`
        so new tabs can start there
    - [x] Checked (2026-10-26, Ubuntu-24.04): `-e wsl.exe` injects the
          WSL integration, `/mnt/c/Code/ghostty` reports as
          `C:\Code\ghostty` (a new cmd tab opened there), and `~` reports
          as `\\wsl$\Ubuntu-24.04\home\yuan`.
    - [x] A new tab or split in a WSL directory with cmd (the default)
          showed "UNC paths are not supported" and started in
          `C:\Windows`. Now it starts `wsl.exe -d <distro> --cd <path>`
          there instead. Checked: the new tab opened zsh in `~`.
    - [x] Close confirmation through WSL: an idle zsh (once its prompt
          was up) closed without asking; `wsl.exe -- sleep 100` showed
          "Close terminal?".
    - [x] Typing into WSL through win32 input mode: posted keys for
          `echo hi` and Enter printed "hi" in zsh (read back with UI
          Automation).
- [x] Choose a registered WSL distribution by name from the shell menu
- [x] Choose Command Prompt, Windows PowerShell, PowerShell, WSL, or
      the configured command when opening a new tab from the tab bar
- [x] `unfocused-split-opacity` and `unfocused-split-fill`
- [x] Drag tabs to reorder within a window
- [x] Default tab keys match Windows conventions (reviewed with
      `+list-keybinds --default`): Ctrl+Tab and Ctrl+Shift+Tab,
      Ctrl+PageUp/PageDown, Alt+1..9, Ctrl+Shift+T and Ctrl+Shift+W. No
      default binding uses Ctrl+Alt with a character key, which would
      collide with AltGr (Windows reports AltGr as Ctrl+Alt).
- [x] Tab bar tooltips: a tab's full title (useful when it's cut off),
      "Close Tab", "New Tab" and "New Tab With a Shell" (and "Menu",
      until that button was removed), from one
      common controls tooltip over the tab bar that asks for its text
      (`TTN_GETDISPINFOW`) based on what's under the mouse. Checked that
      the tooltip is created; it follows the real cursor, so showing it
      needs a manual check.
  - [x] Hover a tab and the buttons: the fork's CI runs
        `test/windows/tab-tooltips.ps1`, which moves the real cursor over
        the "New Tab" button and the tab and reads each tooltip through UI
        Automation (run 41303787849).
- [x] Move a tab to a new window (`move_tab_to_new_window`)
- [x] Drag a tab out of the tab bar, like in browsers: dropped well
      above or below the tab bar, it moves to the Ghostty window under
      the pointer, or to a new window placed with its tab bar under the
      pointer. Dragging down starts a drag too. Checked with posted
      mouse messages: dropping 700 px below made a new window with the
      tab, and dropping on that window (where the source didn't cover
      it) moved another tab into it. A window's only tab can be dropped
      on another window too, which closes the emptied window: checked,
      the target ended up with all three tabs.
- [x] Background opacity/blur (DirectComposition swap chain)
  - [x] `toggle_background_opacity`. Checked with `PrintWindow` captures
        (background `#3060c0`, opacity 0.5, toggled by an F12 keybind):
        made opaque, the background first came out as 56,117,236, since
        with linear alpha blending the renderer outputs encode(a·lin(c))
        rather than a·c. Surfaces now paint a compensating color beneath
        it, and it comes out as 47,96,191.
  - [x] Blur on Windows 10 and Windows 11 before 22H2 (no system
        backdrop there): the blur behind accent from the undocumented
        `SetWindowCompositionAttribute`
    - [ ] Manual check on Windows 10 (the dev machine is build 26100,
          which takes the system backdrop path)
      - The path taken is now logged ("background blur=true with the
        blur behind accent build=... ok=..."). The fork's CI runs the
        smoke test with blur on `windows-2022` (Windows Server 2022, build
        20348, which has no system backdrop) and expects the accent path
        to succeed. It passed in run 41296536006. Seeing the blur itself
        still needs a desktop.
- [x] Single instance and IPC
  - [x] `+new-window` and `+new-tab` (with `-e`, `--working-directory`,
        `--title`, `--shell-integration`)
  - [x] CLI action output in the parent console
  - [x] Launching `ghostty.exe` again opens a window in the running
        instance (always on, per app `class`). A named mutex
        (`Local\ghostty-instance-<class>`) detects an instance that is
        still starting. Launches with options the running instance can't
        apply to a new window (anything but `-e`, `--command`,
        `--working-directory`, `--title`, `--shell-integration`,
        `--class`) run as their own instance.
  - [x] Detect terminal launches so `working-directory` defaults to
        `inherit` there and `home` for desktop launches, as on Linux:
        `launchedFromDesktop` is true when the parent process is
        `explorer.exe` (or has exited). Forwarded launches carry the
        directory. `SHELL` is ignored on Windows (Git Bash and MSYS2 set
        POSIX paths).
    - [x] A Start menu launch opens at home: `test/windows/start-menu.ps1`
          checks that the installed MSIX, started by its app ID, shows a
          prompt in the home directory (run 41301043212). The zip's
          shortcut sets its working directory to home anyway.
  - [x] A custom `class` is also the process's AppUserModelID, so its
        windows get their own taskbar group (with their own jump list and
        pins), like the class on Linux. The default class keeps Windows's
        ID from the executable's path, which the Start menu shortcut
        matches. Classes that aren't valid IDs (spaces, over 128
        characters) are skipped with a warning. Checked: "set the
        AppUserModelID id=com.example.work", and a warning for
        "has space".
    - [x] That jump list's "New Window" passes `--class=...`, so its
          windows join the class's instance and taskbar group. Checked:
          the class's jump list file (its own, since the ID differs) has
          "New Window" with `--class=com.example.work`.
- [x] Global keybinds (`RegisterHotKey`)
- [x] Screen readers (UI Automation), like the macOS app's accessibility
      element: each terminal is a read-only Document named "Terminal"
      whose Value is the visible text, served from `WM_GETOBJECT`.
      Checked with the .NET UI Automation client: control type, name,
      read-only, and the cmd banner and prompt as the value.
  - [x] New output is announced like Windows Terminal does, with UI
        Automation notification events: while a terminal has focus and a
        UIA client listens, its visible lines are compared every 500 ms,
        and what was added (after scrolling or on the last line) is
        announced, except for typing echo on the cursor line. The diff is
        unit tested; hearing it in Narrator needs a manual check.
  - [x] Text pattern, for reviewing the screen by character, word, or
        line: ranges over a snapshot of the visible text, the cursor as
        an empty selection (the caret), move/expand/compare, find, line
        bounding rectangles, and "not supported" for formatting
        attributes. Checked with the .NET UIA client: document text, the
        cursor's line ("C:\Code\ghostty>"), moving a line, finding text,
        and the cursor line's rectangle.
  - [x] The tab bar (which we draw ourselves) for screen readers
        (`TabBarAccessibility.zig`): a Tab control named "Tabs" whose
        children are TabItems named by the tabs' titles, with bounding
        rectangles and the SelectionItem pattern (Select switches tabs),
        and an ElementSelected event when the active tab changes. Checked
        with the .NET UIA client: two TabItems with their titles and
        rectangles, the second selected; selecting the first made it the
        active tab.
    - [x] The buttons come after the tabs, as Buttons named like their
          tooltips ("New Tab", "New Tab With a Shell") with the
          Invoke pattern, which presses them from a posted message (the
          menus run a modal loop). Checked: invoking "New Tab" opened a
          second tab.
  - [x] The command palette's list is owner drawn without strings, so the
        list box's UI Automation proxy had no text for screen readers to
        read. Items now carry their titles as text (LBS_HASSTRINGS), with
        the entry index as item data for drawing. Checked: 88 items with
        text (LB_GETTEXTLEN 17, 22, 20, ...), the palette draws as before,
        and choosing an entry still runs it. (The .NET client in PowerShell
        has no proxies for standard Win32 controls, so it can't show this;
        screen readers use the native ones.)
  - [x] The text pattern's selection is the terminal's selection (its
        visible part), or else the cursor as a caret, and selection
        changes raise `TextSelectionChanged` (posted from
        `selection_changed`, since the core holds the renderer mutex
        there). Checked with the .NET UIA client: nothing selected gave
        an empty range, and after `select_all` the selection was the
        screen's 109 characters. Unit test: `viewportSelection`. This
        fixed a crash freeing text snapshots (the UTF-16 text lost its
        sentinel, so the free had the wrong length).
    - [x] Screen readers get the events: `test/windows/uia-events.ps1`
          listens with `uia_events.c`, a client of the native UI
          Automation API (as screen readers are), and gets the output
          notification, `TextSelectionChanged` after `select_all`, and the
          tab bar's `ElementSelected` for a new tab (locally, and in CI).
          Before, no client got any of them: both providers declared
          `ProviderOptions_ServerSideProvider` as 0x1, which is
          `ClientSideProvider` (server-side is 0x2). Every `UiaRaise*`
          returned `S_OK`, but UI Automation then asked the window for its
          provider again and couldn't connect (a UIA trace showed
          `CreateFile` failing for `UIA_PIPE_<pid>_<cookie>`), so the
          events never left Ghostty's process. Found by reducing to a C
          provider that worked and swapping its methods into a Zig one:
          only `get_ProviderOptions` mattered. (The old note here, that a
          locked desktop stops UIA events, was wrong: focus events from
          Windows arrive here too.)
      - [x] The announcement after Enter no longer starts with the rest
            of the typed command ("840 uia-20840"): skipped typing updates
            still became the last snapshot.
      - [x] Characters without a key press (`WM_CHAR` alone, as from an
            IME or the test) count as typing too, so the command isn't
            read back. The test fails if the announcement has it; CI run
            41421935996 got just "uia-9064  D:\a\ghostty\ghostty>".
      - [ ] Hearing it in Narrator (a person, with audio).
- [ ] Be a "default terminal application" (Windows 11, Settings > For
      developers > Terminal), so console programs started from Explorer,
      Run or a shortcut open in Ghostty instead of a console window, as
      Windows Terminal does. Works in CI with the MSIX installed and the
      delegation set; what's left is whether Settings lists us (a person):
  - Windows' console host calls a COM server registered by the terminal's
    package (`com.microsoft.windows.terminal.host` app extension) through
    `ITerminalHandoff3::EstablishPtyHandoff` (microsoft/terminal,
    `src/host/proxy/ITerminalHandoff.idl`; v1 and v2 are older builds).
    The terminal returns the input and output pipes and gets the signal
    pipe (resizes), a reference handle, the server and client processes,
    and a `TERMINAL_STARTUP_INFO` (title, icon, size, show state).
  - The handles cross processes, so the IIDs need a proxy/stub DLL in the
    package (Windows Terminal ships `OpenConsoleProxy.dll`, built by
    MIDL). The ConPTY NuGet package doesn't include it (checked its file
    list), and this machine has no Windows SDK for MIDL. Options: generate
    the proxy C with MIDL once and build it with `zig cc` (mingw has
    `rpcproxy.h`), or build Windows Terminal's (MIT) from source.
  - Then: ghostty.exe as a packaged COM local server
    (`CoRegisterClassObject` when started with `-Embedding`), a termio
    backend that uses handed-off pipes and a process it didn't start,
    and resizes through the signal pipe instead of `ResizePseudoConsole`.
  - The proxy isn't ours to ship after all: Windows Terminal's package
    registers `ITerminalHandoff3` with its proxy (`OpenConsoleProxy.dll`,
    read from its AppxManifest), and its OpenConsole (`{2EACA947-...}`)
    is the console host that calls the terminal. So with
    `DelegationConsole` pointing at Windows Terminal's OpenConsole and
    `DelegationTerminal` at a Ghostty class, OpenConsole calls Ghostty
    through Windows Terminal's proxy. The default terminal setting is
    Windows 11 only, where Windows Terminal is installed.
  - Packing the handles (`ConptyPackPseudoConsole`) is only a struct:
    resizing writes `PTY_SIGNAL_RESIZE_WINDOW` (8), columns and rows to
    the signal pipe, and closing closes the three handles
    (microsoft/terminal `src/winconpty`), so we do that ourselves.
  - [x] The pty and termio side: `Pty.adopt` uses a handed off session
        (our pipes from `Pty.createPipes`, and the console's signal,
        reference and process handles), and `Exec` adopts it instead of
        starting the command when the runtime's surface has one
        (`takeConsoleHandoff`), with the console program as its process.
        Unit test `windows: adopted console`: the signal pipe gets the
        resize packets, and closing the console closes it.
  - [x] The COM class (`apprt/win32/Handoff.zig`): each running Ghostty
        registers it (`CoRegisterClassObject`), and a handoff opens a new
        window whose terminal adopts the session. COM's `-Embedding` is
        ignored by the config parser, a COM launch doesn't forward itself
        to a running instance or open a default window, and it quits
        after 30 s if no session arrives.
    - Checked locally with `test/windows/handoff.ps1`: through Windows
      Terminal's proxy, a session that `handoff_client.c` handed to a
      running Ghostty opened a window showing cmd's output, posted
      typing reached cmd, and `exit` closed that window while the first
      one stayed. (The client first had to start cmd with
      `STARTF_USESTDHANDLES`, or cmd wrote to the client's redirected
      output instead of the pseudoconsole.)
  - [x] The startup info: a window for a program that asked (with
        `STARTF_USESHOWWINDOW`) to start minimized or maximized starts
        that way (a hidden one starts minimized and inactive instead, so
        it can't get lost), and its title is the terminal's title until
        the console sends one (`Handoff.showCommand`, unit tested).
    - Checked locally and in `handoff.ps1`: a session asking for
      `SW_SHOWMINNOACTIVE` got a minimized window, and one asking for
      `SW_SHOWMAXIMIZED` (tried by hand) a maximized one. The title isn't
      checked: the console sends its own title as soon as it starts (the
      test client's is the program's path; Windows' console host's is the
      same title it passes us).
  - [x] Resizing a handed off console in a live session: `handoff.ps1`
        resizes the window and `mode con` in cmd shows fewer columns
        (locally 45, then 24).
  - [x] An `-Embedding` launch (needs the class registered with COM, so
        only the CI test with the MSIX installed covers it): passes in CI
        (43be924f4), see below.
  - Decided: a COM launch doesn't restore saved windows (only the
    handed off session's window opens), and quits with its last window
    as any launch does (`quit-after-last-window-closed` is on by default
    on Windows). A handed off window still open when Ghostty quits is
    saved like any other, so `window-save-state` brings it back as a
    shell in its place; the console program itself can't come back.
  - [x] Register the class and the `com.microsoft.windows.terminal.host`
        extension in the MSIX (with a `console.host` one naming Windows
        Terminal's OpenConsole, in case Settings only lists packages with
        both). The manifest packs (the packaging API validates it; a
        broken element fails). CI test `default-terminal.ps1` sets the
        delegation and starts cmd in a new console.
    - First CI run (033f2b0a2): COM did start the packaged Ghostty, but
      cmd's output never showed up in it within 60 s. The handoff test
      with the unpackaged build passed in the same run. The test now
      collects Ghostty's debugger output and the processes involved,
      and reports them as annotations, to find where it stops.
    - Second run (4878ccef2): COM started `ghostty.exe -Embedding`, the
      handoff arrived (title `C:\Windows\system32\cmd.exe`), a window
      opened and adopted cmd, but its IO thread failed with
      ACCESS_DENIED. The console host hands over cmd's handle with only
      some rights, and libxev's process watcher puts the process in a
      job, which needs more (as does ending it). `handoff_client.c` now
      passes a handle like that (SYNCHRONIZE and
      PROCESS_QUERY_LIMITED_INFORMATION), which reproduced it locally,
      and `Handoff.reopen` opens the program again by its id with the
      rights we need, which fixed it locally.
    - Third run (43be924f4) passes: cmd started in a new console showed
      its output in the packaged Ghostty that COM started.
  - [ ] Manual check (a person, on Windows 11 with the MSIX installed):
        Ghostty is listed in Settings > For developers > Terminal, and
        choosing it makes cmd started from the Run box open in Ghostty.
        Settings' list isn't something a test here can read reliably.
  - [x] The console window's owner: console programs get a hidden
        pseudoconsole window from `GetConsoleWindow` (some use it to own
        dialogs, or to find "their" window), which is now owned by the
        Ghostty window showing the terminal, as in Windows Terminal. For
        our own pseudoconsoles and handed off sessions alike, we send
        PTY_SIGNAL_REPARENT_WINDOW (3, then the window as 8 bytes,
        packed) on the console's signal pipe, as
        `ConptyReparentPseudoConsole` does; Windows doesn't export a
        function for it, but the inbox console host honors it. The
        window goes to the IO thread as a new termio message,
        `parent_window`, when a terminal starts and when its tab moves to
        another window.
    - Checked: with a handed off session, the owner was 0 without the
      signal and Ghostty's window with it (by hand). `handoff.ps1` now
      checks that both the handed off cmd's and the first window's
      console windows are owned by their Ghostty windows (passes
      locally). Unit test: `windows: adopted console` reads the packet.
      It also moves a tab to a new window (`move_tab_to_new_window`)
      and checks that the tab's console window is then owned by the new
      window (passes locally).
    - On Windows Server 2022 (build 20348) in CI, the first smoke test
      (cmd) failed right after this landed (d8e51b58a), with no details
      (smoke.ps1 only printed to the log; it now reports its failure
      and Ghostty's log as annotations). Most likely the older inbox
      console host doesn't know the signal and ends the session, so
      inbox pseudoconsoles only get it from build 26100 on (seen to
      work here and on the Server 2025 runner); handed off sessions
      (Windows Terminal's OpenConsole) and conpty.dll always do. The
      next run (db796e2fb) passed on Server 2022, which supports that
      but doesn't prove it (the failure could also have been a flake).
    - Run 41826029078 once found a console window owned by no window,
      which passed before and after (and always here). The test now
      names the session, asks again 3 s later, and annotates Ghostty's
      log of signals to the pseudoconsole, for the next time it fails.
      The next run (41832654292) passed.
    - It failed again in run 41980624453 (Ghostty's own session: owned
      by 0, then 0 three seconds later), and the log shows the signal
      was sent, once, before cmd started. The inbox console host can
      likely lose a signal that arrives while the program connects (not
      verified against its source), so the IO thread now sends the
      owner and visibility again 1, 3 and 10 s after a terminal starts
      (Windows reuses the termios timer, which it doesn't otherwise
      run). Never reproduced here, so only CI runs can show it helps.
  - [x] `handoff.ps1`'s resize step was flaky here on old and new builds
        alike (3 of 6 runs failed): it typed `mode con` right after
        resizing the window, before the console had the new size (the
        "passing" runs read the size from before: 149 columns, then 45),
        and at 12 rows `mode con`'s output scrolled the marker off the
        screen. It now waits a second, asks up to 5 times for the
        narrower size, and filters `mode con` to its Columns line: 5 of
        5 runs passed (45 columns, then 24).
  - [x] The console window's state: while a terminal isn't visible (its
        window minimized, or another tab selected), its pseudoconsole's
        window shows as minimized, so console programs that check
        (`IsIconic(GetConsoleWindow())`) can tell, as with Windows
        Terminal. We send PTY_SIGNAL_SHOWHIDE_WINDOW (1, then 0 or 1)
        with the same build gate, from a new termio message,
        `pty_visible`, which the win32 runtime sends with each
        visibility change.
    - Checked: by hand, a handed off session's console window was
      minimized after the signal with 0 and not with 1. `handoff.ps1`
      checks that visible terminals' console windows aren't minimized
      and that the session started minimized has a minimized one
      (passes locally, and in CI on 4a38596bb, all four jobs including
      Server 2022). Unit test: `windows: adopted console`.
  - Check in CI (installing the MSIX is fine on throwaway runners): set
    the delegation (`HKCU\Console\%%Startup`, `DelegationConsole` and
    `DelegationTerminal`), start `cmd.exe` through Explorer, and expect a
    Ghostty window running it.
- [x] Taskbar jump list with a "New Window" task, which starts
      `ghostty.exe` again (single instance opens the window in the running
      app). Checked: the shell wrote the custom destinations file with the
      task and the executable's path.
  - [x] A task per shell after it (2026-11-07), like Windows Terminal's
        profiles: the new tab menu's shells (Command Prompt, Windows
        PowerShell, PowerShell 7, WSL and each distribution), each
        running `ghostty.exe -e <shell>` (which opens a window in the
        running instance) with the shell's program as its icon. Arguments
        are quoted as CommandLineToArgvW reads them (unit tested:
        spaces, empty, quotes, trailing backslashes). Checked: `-e
        powershell.exe` from a second launch opened a PowerShell window in
        the first instance, and the custom destinations file of a test
        class had the four tasks here (cmd, Windows PowerShell, WSL,
        `wsl.exe -d Ubuntu-24.04`) after "New Window". Seeing the menu
        needs an unlocked desktop.
    - [x] That file showed Windows PowerShell as
          `...\v1.0\\powershell.exe`: Windows' PATH entries often end
          with a backslash, and `os/path.zig`'s `expand` always added
          another. It now adds one only when the directory doesn't end
          with a separator (on every platform; unit tested with a
          directory ending in one). CI run 42453039745 (2d391cbd7)
          passed every job.
- [x] Terminal inspector (`inspector` toggle/show/hide,
      `render_inspector`): a window per terminal, like GTK's, drawn by
      Dear ImGui through its Win32 and Direct3D 11 backends (now built by
      `pkg/dcimgui` for Windows) on a device and flip model swap chain of
      its own. Redrawn on input, on `render_inspector`, and every 50 ms;
      the style and font scale with the window's DPI. Checked natively:
      opened from the menu (Terminal tab showing the screens), closed, and
      reopened.
- [x] Bell attention flash in the taskbar, honoring `bell-features`;
      system sound is now opt-in via `system`
- [x] Desktop notifications and progress reports (taskbar)
  - [x] OSC 9;4 progress on the active surface's taskbar button
  - [x] Desktop notifications (OSC 9 and OSC 777) as toasts
- [x] Command-finished notifications
  - [x] Configured bell action and duration/focus filtering
  - [x] Desktop notification action
- [x] Bell title/border indicators and custom audio
  - [x] Pending bell marker on tabs with an unfocused ringing surface
  - [x] Window title indicator while any surface has a pending bell
  - [x] Border indicator
  - [x] Custom audio
- [x] Shell integration for PowerShell (5.1 tested; PowerShell 7 isn't
      installed on the dev machine)
- [x] OSC 7 working directory reports on Windows
  - [x] Checked that a program can't use them to make a new tab start in
        another machine's share (which would connect to it): the core
        rejects a URL whose host isn't this machine, drive paths keep
        their drive (`/C://host/share` is `C:\\host\share`, a local
        folder), and WSL paths stay in their distribution's share
        (Windows resolves `\\wsl$\Ubuntu\..\..\evil\share` to
        `\\wsl$\Ubuntu\evil\share`).
- [x] Font discovery: FreeType scans the system and user font folders
      (`+list-fonts --family=Consolas` takes about 0.1 s here)
  - [x] Codepoint fallback asks DirectWrite's system font fallback
        (`IDWriteFontFallback::MapCharacters`, with the user's locale)
        first, then scans the font folders as before. Scanning picked
        whichever file came first: Arial Unicode MS for Japanese here. Now
        Japanese gets Yu Gothic UI and Korean gets Malgun Gothic.
- [x] Automate the UI checks that were only done by hand (2026-11-06).
      Like the other `test/windows` scripts: keys bound to actions are
      posted to the terminal, state is read with UI Automation and
      `PrintWindow` (so they run on a locked desktop and in CI), each
      check waits on state rather than time, and failures put their
      diagnostics in the error annotation. Grouped into a few scripts to
      keep `build-windows` from growing much.
  - [x] Session save and restore: a split and a second tab survive closing
        and starting again (`window-save-state = always`), with the
        test's own `--class`, so its own state file and instance
        (`test/windows/session-restore.ps1`, in CI). It found a bug: after
        a restore, the inactive tabs' terminals showed through, because
        `Tab.setVisible` skipped hiding windows whose `IsWindowVisible` was
        already false, which it is for every child while the window is
        still hidden. It now checks the window's own `WS_VISIBLE`.
  - [x] Search: `start_search`, a typed needle's match count, next and
        previous, and `end_search` (`test/windows/search.ps1`, in CI). The
        count was only drawn, so screen readers couldn't read it either;
        the bar's window text (its accessible name) is now the count:
        "6 matches", "Match 2 of 6" or "No matches".
  - [x] Command palette: typing `new_split:right` narrows 92 entries to
        1, Enter splits the terminal left and right and closes the
        palette, and Escape closes it without running anything
        (`test/windows/command-palette.ps1`, in CI).
  - [x] Tabs: `close_tab:other`, `close_tab:this` and `undo` reopening the
        same terminal, and `move_tab_to_new_window` moving a tab with its
        output into a new window (`test/windows/tabs.ps1`, in CI). Not
        checked: that the new window is in front (a locked desktop has
        no foreground window).
  - [x] New windows: `window-position-x/y` (100,50 at 192 DPI put the
        visible frame at 200,100), a position off every monitor falling
        back to the work area's corner, `maximize` and `fullscreen`
        (`test/windows/window-options.ps1`, in CI).
  - [x] `prompt_surface_title`: the dialog sets the title override, and an
        empty title clears it (`test/windows/title-prompt.ps1`, in CI).
  - [x] `export_terminal_io`: left out. Only a button in the inspector
        starts it, and the inspector is drawn with ImGui, which has no
        windows or UI Automation tree to find the button in; clicking
        at fixed positions in its layout would be the kind of brittle
        test this list avoids. The Save As part is the standard dialog.
  - Six new CI tests (session restore, search, command palette, tabs,
    window options, title prompt). Two of them found bugs, both fixed:
    inactive tabs showing through after a session restore, and the search
    count being invisible to screen readers.
  - Not automated, on purpose: toasts, bell audio and Narrator speech
    (another process shows or plays them, so only a person can check the
    result); two monitors, Windows 10, a real driver restart and a real
    IME (no runner has them); memory and leak checks (too slow and noisy
    for every push).
- [x] Split drag handles only show when the mouse is over them (or while
      dragging), like GTK's (opacity 0 until hovered) and macOS's: they
      were always drawn at the top of each split, over the first line of
      text (2026-11-06). The window stays in place, almost transparent,
      so it can still be found with the mouse. Checked: a capture with a
      split no longer shows them, and the overlays test still drags one.
      Hovering itself needs a real mouse (not on a locked desktop).
- [x] Tabs in the title bar, like Windows Terminal, Edge and File
      Explorer (2026-11-06): the title bar and the tab bar were two rows,
      and the title bar repeated the active tab's title. Whenever the tab
      bar shows in a window with a title bar (not fullscreen, the quick
      terminal or a high contrast theme, which keeps the system's colors),
      `WM_NCCALCSIZE` gives the caption to the client area (the sides and
      bottom of the frame stay, and a maximized window's top moves in by
      its overhang), and the tab bar draws minimize, maximize/restore and
      close (46 by 32, close red on hover, dimmer when inactive) after
      some empty space that always drags the window. `WM_NCHITTEST`: the
      tab bar answers `HTTRANSPARENT` for its empty space, top edge and
      maximize button, and the window answers `HTCAPTION` (drag, double
      click maximizes, right click is the system menu), `HTTOP` and
      `HTMAXBUTTON` (Windows 11's snap layouts; we draw it, track its hover
      with `WM_NCMOUSEMOVE`/`WM_NCMOUSELEAVE` and press it on
      `WM_NCLBUTTONUP`). With one tab under `window-show-tab-bar=auto`,
      the system's title bar comes back (`SWP_FRAMECHANGED`), and the
      window size for a terminal size counts no caption.
  - Changed: a double click on the tab bar's empty space maximizes, like
    a title bar, rather than opening a tab (the + button and Ctrl+Shift+T
    do), and a right click there is the system menu (which has the same
    menu as before).
  - Test: `test/windows/titlebar-tabs.ps1` (in CI). The tabs, session
    restore, window options, search, command palette and overlays tests
    pass with it; a maximized capture shows the tabs and the restore
    glyph unclipped.
  - [x] Restyled like noctty (https://github.com/amanthanvi/noctty,
        requested 2026-11-06): the tabs, then + and ▾ at the right next to
        the caption buttons. Windows Terminal's metrics, as noctty's
        `docs/wt-chrome-reference.md` records them: a 40 point row (32
        when maximized, so the tabs reach the top of the screen) with 32
        point tabs at its bottom, 8 point rounded top corners, 46 by 40
        caption buttons, 31 by 24 new tab and shell buttons, and a line
        under the strip that the active tab breaks to join its terminal
        (which it takes its background from; no accent color). Inactive
        tabs are raised a little with a thin border. Labels are centered,
        numbered and count splits ("2: api (3)"), with the bell first.
        Checked with captures, restored and maximized; the title bar tabs
        test checks the icon's hit test too.
  - [x] Follow-ups from using it (2026-11-06):
    - A right click on the empty space showed nothing: DefWindowProc
      looks for a caption the window no longer has. The window now shows
      its menu itself on `WM_NCRBUTTONUP` (and takes the button down).
    - The tabs are in the title bar with one tab too (under
      `window-show-tab-bar = auto`); `never` keeps the system's title bar.
      Starting with one tab showed both the system's title bar and the
      tabs: the first frame change happened before the window procedure
      could see the window, so it went to DefWindowProc. The switch now
      waits for that.
    - Alignment: the tabs were at the bottom of the bar (Windows
      Terminal's layout), below the buttons' center line. Now, like
      noctty, everything is centered in the 40 point bar: tabs inset 4
      points at the top and bottom (6 point corners), the active one
      running down into its terminal, and the tab close buttons on the
      titles' line.
    - No icon at the left, like the macOS app (it was briefly there).
    - Test: `titlebar-tabs.ps1` now checks one tab, the right click's
      window menu (`#32768`) and `window-show-tab-bar = never`. The
      tabs, session restore, window options, search, command palette,
      window theme and overlays tests pass.
  - [x] Chrome-like tabs (requested 2026-11-07, like Chrome and Windows
        Terminal): the active tab has its terminal's background, rounded
        top corners and, at the bottom, outward curves that join it to
        the terminal (no line under the bar any more). Other tabs aren't
        filled: thin separators part them (hidden beside the active or a
        hovered tab), and hovering shows a rounded highlight. Titles are
        at the left, every tab that has room has a close button, and the
        new tab and shell buttons follow the last tab instead of sitting
        at the right. The curves are antialiased (GDI's RoundRect isn't):
        corner pixels are blended by coverage, 4 by 4 samples. Light
        backgrounds darken the bar by 12% instead of 30%. Checked with
        captures (1, 3 and 4 tabs, dark and light, 200%) and zoomed
        corners; the title bar tabs, tabs, tab reorder, compact tabs,
        overlays, UI Automation events and window theme tests pass. The
        hover highlight can't be seen on a locked desktop (Windows reports
        the mouse leaving at once); the owner checked it with a real
        mouse, and it works.
  - [x] Screen readers can close tabs (2026-11-08): with a close button
        on every tab, UI Automation listed tabs only as selectable
        TabItems, with no way to close one. Each TabItem now has a "Close
        Tab" button as its child (as Chrome and Windows Terminal expose),
        at the close button's place (hit testing there finds it), and
        invoking it closes the tab later, from a posted message, since it
        may ask first. `test/windows/tab-close-uia.ps1` (in CI) checks
        both tabs' buttons and that invoking the second's closes it; the
        title bar tabs, tab reorder, compact tabs, tabs and UI Automation
        events tests still pass. CI run 42483292356 (e7fd49a75) passed
        every job.
    - [x] Tabs also report their position (2026-11-08): PositionInSet and
          SizeOfSet, from which screen readers say "2 of 3", and which
          custom providers must give themselves. The same test checks
          "1 of 2" and "2 of 2" (looked up by ID, since the managed UI
          Automation API predates them). CI run 42489816690 (97e41d531)
          passed every job.
  - [x] Compact tabs (found 2026-11-07 with 20 tabs): tabs narrower
        than 88 points showed "1..." for tabs 10 and up (the title was
        cut before its number ended), and the active tab's close button
        covered its label. Now such tabs show only their number, across
        the whole tab, and have no close button, like Windows Terminal's
        narrow tabs (a click there would close a tab meant to be selected
        or dragged, since closing happens on the button press). The
        tooltip still has the title; a middle click, the tab's menu or a
        keybinding closes them. Checked with captures of 5, 8 and 20 tabs
        at 200%; `test/windows/compact-tabs.ps1` (in CI) clicks where the
        close button would be and checks that the tab is selected and
        none closed (it failed on the previous build, which closed it).
  - [x] Reordering tabs by dragging, with the new layout's margin and
        gaps (`Layout.indexAt`): `test/windows/tab-reorder.ps1` drags a
        tab named with cmd's `title` onto the first and checks UI
        Automation's order (in CI).
  - [x] Glyphs from the system's icon font, like Windows Terminal: Segoe
        Fluent Icons (Windows 11) or Segoe MDL2 Assets (Windows 10), at
        10 points, for minimize (E921), maximize (E922) or restore
        (E923), close (E8BB), new tab (E710), the shell menu (E70D) and
        the tabs' close buttons. The face is checked after creating the
        font (Windows substitutes a missing one); without either, they're
        still drawn with lines. Checked with captures, restored and
        maximized.
  - [x] Expose the caption buttons to UI Automation (screen readers):
        Windows no longer does once we draw them. The tab bar now lists
        Minimize, Maximize (Restore Down when maximized) and Close after
        its own buttons while the tabs are in the title bar, with Invoke.
        The title bar tabs test finds all three and minimizes with
        Invoke; `uia-events.ps1` still passes.
  - [ ] Check by hand with a real mouse (not on a locked desktop): hover
        colors, the snap layouts flyout over maximize, dragging and
        double clicking empty space, and resizing from the top edge.
    - [x] Hover: the owner checked the Chrome-like tabs' hover highlight
          on inactive tabs with a real mouse (2026-11-07); it works.
- [x] Default tab titles "Command" and "PowerShell" (requested
      2026-11-06, reverted 2026-11-07 at the user's request): the paths
      in the tabs came from `shell-integration-features = no-title` in
      the user's config, not from Ghostty. With the shell integration's
      `title` feature, cmd's and PowerShell's prompts set the title to the
      folder again, and Ghostty no longer passes a console title
      (`lpTitle`) when it starts a shell.
- [ ] OSC 10/11 color queries get no reply (reported 2026-11-07: Codex
      in tmux over SSH from WSL drew its input box without a background,
      since it couldn't learn the terminal's colors). Reproduced locally
      without SSH or tmux: a probe in WSL (raw `/dev/tty`, one second
      per query) got nothing for OSC 10, 11, 12 and 4 (BEL or ST), while
      DA1 and CPR were answered by the console host
      (`?61;6;7;21;22;23;24;28;32;42c`, conhost's) and only XTVERSION
      reached Ghostty. Ghostty's log shows no color query at all: the
      inbox ConPTY (conhost 10.0.26100.1) swallows them. With
      `conpty.dll` and `OpenConsole.exe` from the ConPTY package
      (1.25.260930003) next to `ghostty.exe`, every query reached Ghostty
      and its replies reached WSL (OSC 11 `rgb:2828/2c2c/3434`, our
      default background; OSC 4;1 our red; DA1 ours, `?62;22;52c`).
      `osc-color-report-format` is the default (16 bit) and not involved.
      The tip and release packages don't bundle `conpty.dll` (no
      `-BundleConpty` in the workflows), so they use the inbox ConPTY.
  - [x] A test, `test/windows/color-query.ps1` (in CI, no WSL needed):
        PowerShell in Ghostty (started with `#123456` on `#abcdef`) sends
        OSC 10 and 11 and reads the replies as VT input. Locally, the
        inbox ConPTY gave nothing (and conhost's DA1), the package's gave
        `rgb:abab/cdcd/efef` and `rgb:1212/3434/5656`. CI runs it both
        ways: inbox as a notice, and with the package (fetched by the new
        `dist/windows/conpty.ps1`, which `package.ps1 -BundleConpty` now
        uses too) where Ghostty must answer.
  - [x] Bundle `conpty.dll` in the tip and release packages (the
        owner's go-ahead, 2026-11-07): the fork's and release workflows
        package with `-BundleConpty` (x64 and ARM64, zip and MSIX). The
        tests after packaging (install, flood, output frames, minimize,
        mouse capture, context menu) now run on the bundled ConPTY, and
        `color-query.ps1 -Zip` checks that the package answers OSC 10/11.
        The tests on `zig-out/bin` still use the inbox ConPTY.
  - [x] cmd's prompt vanished with the bundled ConPTY (run 42406031418,
        the MSIX start menu test: the banner, then nothing). The bytes
        reached Ghostty intact; the cause is ours. Ghostty assumes a shell
        redraws its prompt after a resize (zsh and fish do) and clears the
        prompt's lines when the window resizes. The inbox ConPTY hid this
        by repainting its whole screen on resize; the package's doesn't,
        so the prompt stayed cleared. cmd and PowerShell never redraw, so
        their integrations now mark the prompt with `133;A;redraw=0`.
        Checked with the package's ConPTY: the cmd smoke test passes
        (it timed out before), and PowerShell without a profile shows its
        prompt; with the inbox one too. The PowerShell integration test
        expects the new mark.
  - Workaround now: put `conpty.dll` (`runtimes\win-x64\native`) and
    `OpenConsole.exe` (`build\native\runtimes\x64`) from the
    Microsoft.Windows.Console.ConPTY 1.25.260930003 package next to
    `ghostty.exe`, or build with `package.ps1 -BundleConpty`.
- [x] Bug (reported 2026-11-07): from a WSL tab, opening a new Command
      Prompt tab (the new tab menu) opened WSL instead. The new terminal
      inherited the WSL tab's directory (a `\\wsl.localhost\...` share
      path), and Exec starts WSL there when the command is cmd, since cmd
      can't start in a UNC path (meant for the configured shell, see
      "starting WSL for a WSL working directory" in `termio/Exec.zig`);
      it can't tell a shell chosen from the menu from the configured one.
      Now a chosen shell that isn't WSL doesn't inherit a WSL directory
      (`dropsWslDirectory` in `Surface.zig`): it starts where new windows
      do (`working-directory`). A WSL shell, or a Windows directory, is
      inherited as before. Unit tested (cmd, PowerShell, `\\wsl$` and
      `\\wsl.localhost` paths, WSL keeps it, Windows paths kept), and
      checked by hand: with `command = wsl.exe`, `cd /tmp`, then Command
      Prompt from the new tab menu (opened with UI Automation, chosen
      with keys) gave cmd at `C:\Code\ghostty>`.
- [x] Remember and restore tabs after a restart (requested 2026-11-07):
      the list of tabs (and their splits), which terminal each one runs
      (cmd, PowerShell, a WSL distribution, a shell from the new tab
      menu, a custom command), and each terminal's working directory.
  - Today: `window-save-state = always` saves windows (placement,
    maximized), tabs, title overrides, split layouts, the focused
    terminal and working directories (`SaveState.zig`, in
    `%LOCALAPPDATA%\ghostty\window-state.json`) and restores them at
    startup. With the default (`default`), Windows only restores after a
    system restart or update (`RegisterApplicationRestart`), not after
    quitting.
  - [x] Save which terminal each one runs: restored terminals all
        started the configured `command`, so a WSL or PowerShell tab
        opened from the new tab menu came back as the default shell. Each
        terminal's chosen shell (`Surface.shell`: from the new tab menu,
        or inherited by its splits) is now saved in `NodeState.command`
        (a command line, or the program and its arguments kept apart, so
        arguments with spaces survive) and started again on restore.
        Terminals running the configured command save none, so they
        follow the config. Unit tested (`state round trip`).
  - [x] WSL working directories: already right. A WSL shell's OSC 7
        path is kept as its `\\wsl.localhost\<distro>\...` share path,
        which is what's saved. Restoring it with a `wsl.exe` command
        starts the shell there, and with the configured cmd, Exec starts
        WSL there instead (`wsl.exe -d <distro> --cd <path>`, as for new
        terminals from a WSL one). Checked by hand: a saved WSL tab and a
        cmd tab, both in `\\wsl.localhost\Ubuntu-24.04\tmp`, came back
        as zsh in `/tmp`.
  - [x] When to restore (the owner's decision, 2026-11-07): only with
        `window-save-state = always` (and, with `default`, after Windows
        restarts us after an update or a reboot), as today.
  - [x] Test: `test/windows/session-restore.ps1` (in CI) now also
        starts from a saved session with a PowerShell tab (its command
        saved) in `C:\Windows` and a cmd tab (the configured command) in
        the temporary directory, checks each prompt with UI Automation,
        quits, and checks the PowerShell tab's command was saved again
        and the cmd tab saved none. WSL isn't on the runners; it was
        checked by hand (above).
- [x] Ctrl+F for Find by default (requested 2026-11-06; decided
      2026-11-07: the owner keeps the default at Ctrl+Shift+F, as in
      Windows Terminal, and users who want Ctrl+F can add
      `keybind = ctrl+f=start_search`). Today Find is
      `ctrl+shift+f` (as on Linux; macOS has Cmd+F), which the menus
      show. Plain Ctrl+F is a terminal key, though: readline, zsh and
      PowerShell's emacs mode move forward a character with it, and
      `less`, `vim` and `man` page forward. A binding would always take it,
      since `start_search` can always be performed. To decide: bind
      Ctrl+F in addition to Ctrl+Shift+F on Windows (Windows Terminal
      binds only Ctrl+Shift+F for this reason), or only when the
      terminal isn't in a mode that wants the key (alternate screen,
      application keypad), or leave it to users
      (`keybind = ctrl+f=start_search`).
- [x] Match the macOS menus (requested 2026-11-06). Windows has no menu
      bar, so the title bar's menu (right click, Alt+Space, or a right
      click on the tab bar's empty space) has macOS's menus as submenus
      after Windows's own items, instead of a long flat list:
  - Ghostty: Open Configuration, Reload Configuration, Quit Ghostty.
  - File: New Window, New Tab, New Window/Tab With Shell, Split Right,
    Left, Down and Up, Close, Close Tab, Close All Windows.
  - Edit: Undo, Redo, Copy, Paste, Paste Selection, Select All, Find…,
    Find Next, Find Previous, Hide Find Bar, Use Selection for Find, Jump
    to Selection.
  - View: Reset, Increase and Decrease Font Size, Command Palette, Change
    Tab/Terminal/Window Title…, Terminal Read-only, Quick Terminal,
    Terminal Inspector, Clear, Reset.
  - Window: Full Screen, Show/Hide All Terminals, Float on Top, Return to
    Default Size, Zoom Split, Select Previous/Next Split and by direction,
    Equalize Splits.
  - Left out: Maximize and Close Window (Windows's own items right above
    have them), About and Help (no actions for them), Check for Updates
    (this fork has none), Make Ghostty the Default Terminal (a Windows
    setting), Resize Split (needs an amount; it's a keybinding).
  - Shortcuts now include performable bindings, which the reverse map
    leaves out so that toolkits don't register them (we only show the
    text): Find shows Ctrl+Shift+F, Hide Find Bar Esc. The command
    palette shows them too.
  - Checked: the menu dumped with its shortcuts; the overlays,
    translucent and high-contrast tests now find their window menu items
    by label (they used fixed command numbers, which the new layout
    changed), and the overlays and command palette tests pass.
- [ ] Packaging and release builds
  - [x] Portable zip (`dist/windows/package.ps1`)
  - [x] Per-user install script in the zip (`dist/windows/install.ps1`):
        copies to `%LOCALAPPDATA%\Programs\ghostty-windows-unofficial`,
        adds a Start menu shortcut and a Settings > Apps entry (which runs
        `install.ps1 -Uninstall`), and optionally adds `bin` to the user
        PATH. No administrator rights or signing. Checked: install,
        uninstall, and `-AddToPath` leave nothing behind.
    - [x] `-ExplorerMenu` adds "Open in Ghostty (unofficial Windows
          build)" to Explorer's right-click menu for folders and folder
          backgrounds (HKCU, `--working-directory=%V`). Checked: the keys
          were created and removed, and the command opened at the folder.
  - [x] CI: the `build-windows` job packages the portable zip and
        uploads it as a 14-day artifact; the ARM64 job does too. Run
        41906782926 uploaded both (about 40 MB each).
  - [x] MSIX package (`package.ps1 -Msix`): `dist/windows/msix.zig` packs
        a layout with the packaging API built into Windows
        (`IAppxPackageWriter`), so no Windows SDK is needed, and checks it
        by opening it with `IAppxPackageReader`, which validates the block
        map and manifest. The manifest is unsigned (publisher with the
        unsigned OID), runs full trust, has logos made from the icon and a
        `ghostty.exe` execution alias. Checked: the reader accepted
        `GhosttyWindowsUnofficial_1.0.18522.0_x64__ddpcdxnmqgtp8`.
    - [ ] Manual check: `Add-AppxPackage -AllowUnsigned <file>.msix` on
          Windows 11 (not done here, since it registers an app), then the
          Start menu entry and the `ghostty` alias
      - The fork workflow installs it on GitHub's runner, which is thrown
        away after the job, checks the package and the `ghostty.exe`
        execution alias, runs `ghostty +version` through the alias, and
        uninstalls it. Its Start menu entry (by app ID) opens a window
        too (run 41263133923). Run
        41230068796 (2026-10-31) passed: `Add-AppxPackage -AllowUnsigned`
        installed it on `windows-latest`, and the alias ran.
    - [ ] A signed package for Windows 10 and the Store (needs a
          certificate)
  - [x] Scoop and winget manifests (2026-11-08, the discussion's
        "installers and packages"): `dist/windows/manifests.ps1` writes,
        from a release's zips, a Scoop manifest (`scoop install <its
        URL>` works without a bucket) and a winget manifest (version,
        installer and locale files, schema 1.6.0, for `winget install
        --manifest` or a winget-pkgs submission). Both use each zip's URL
        and SHA-256 and give the `ghostty` (the app) and `ghostty-cli`
        (the console launcher, for CLI actions) commands; Scoop also adds
        a Start menu shortcut. winget only takes `.exe` files as
        commands, so the zip now has `bin\ghostty-cli.exe` (a copy of
        `ghostty.com`, as in the MSIX). The release workflow attaches
        both to the draft release; the fork's CI makes them from the
        tested zip and runs `winget validate` where winget is installed.
        Checked here: `winget validate` passed (it first caught an
        unquoted `:` in the description and the `.com` command), and the
        unzipped `ghostty-cli.exe +version` ran. Not tried: installing
        with Scoop (not installed here) or winget from a published
        release (none yet). CI run 42461695045 (98a2ef323) passed every
        job; its runner has winget, which validated the manifest made
        from the tested zip under PowerShell 7.
  - [ ] Release builds from CI (the discussion's "GitHub Actions for
        release"): `.github/workflows/windows-release.yml`, run by
        pushing a `windows-unofficial-*` tag (or by hand, once the file is
        on the default branch, which GitHub requires), packages x64 and ARM64 (ReleaseSafe, natively on each
        runner, full history for the version), checks that the zip's
        `ghostty.com +version` runs, writes SHA-256 checksums, and keeps
        it all as a 90 day artifact. For a tag (or with `draft_release`)
        it also creates a draft GitHub release, which stays private until someone
        publishes it. Not run yet: pushing a tag is up to the repository's
        owner.
- [x] Unimplemented apprt actions (as of 2026-10-25)
  - [x] `show_on_screen_keyboard`: toggles the touch keyboard through the
        shell's (undocumented) `ITipInvocation`, starting TabTip.exe if
        needed. Checked that the action runs without errors when bound
        (`--keybind=f12=show_on_screen_keyboard`); seeing the keyboard
        needs an unlocked desktop.
  - [x] `export_terminal_io`: the inspector's export, saved through the
        standard Save As dialog (`GetSaveFileNameW`); the inspector skips
        redraws while the modal dialog pumps messages. Not clicked
        through yet.
    - [x] The inspector asked while it held the terminal's lock, so with
          the dialog open the terminal stopped, and anything else that
          needed the lock on the UI thread (typing in the terminal)
          would hang. The contents are now copied and the dialog shown
          from a posted message (`WM_GHOSTTY_EXPORT`). Builds and the
          unit tests pass; clicking Export still needs a person (the
          inspector has no keyboard navigation, and posted clicks don't
          reach ImGui).
  - Not applicable on Windows: `undo`/`redo`, `secure_input`,
    `check_for_updates`, `toggle_tab_overview`, `show_gtk_inspector`,
    `render` (embedded), `selection_changed` (no primary selection).
    Unhandled, as on GTK: `cell_size`, `pwd`.
  - [x] `color_change`: the tab bar follows the active terminal's
        background and foreground when programs change them (OSC 10/11,
        and their resets). Checked with a screenshot after OSC 11/10.
  - [x] Window management
    - [x] `reset_window_size`, `resize_window`, `size_limit`
    - [x] `goto_window`, `present_terminal`, `float_window`,
          `toggle_window_decorations` (and `window-decoration=none`)
    - [x] `toggle_visibility`
  - [x] Titles: `set_tab_title`, `set_window_title`,
        `copy_title_to_clipboard`, `prompt_title`
  - [x] Hover link preview (`mouse_over_link`)
  - [x] `show_child_exited`: not needed; the core's fallback prints
        "Process exited" in the terminal
  - [x] `readonly` and `renderer_health` indicators
  - [x] Search UI (`start_search`, `end_search`, `search_total`,
        `search_selected`). Checked natively: opened from the menu,
        typing "Microsoft" highlighted both matches in the cmd banner and
        showed 0/2. (A cast in it panicked in debug builds before this.)
  - [x] Scrollbar (`scrollbar`)
  - [x] Key table / sequence indicators (`key_table`, `key_sequence`)
  - [x] Quick terminal (`toggle_quick_terminal`, `+toggle-quick-terminal`)
    - [x] Slide animation (`quick-terminal-animation-duration`): the
          window moves in from its edge, clipped by a window region at
          the screen edge so it never shows on a neighboring monitor, with
          an ease-out over the configured duration (scaled by the distance
          left when reversing). The terminal size never changes. `center`
          appears in place. Sampled while sliding in: top -182, -73, -8,
          -2, then 0 and unclipped after ~140 ms.
      - [x] With Windows' animation effects off (Settings >
            Accessibility > Visual effects; `SPI_GETCLIENTAREAANIMATION`),
            it appears and hides in place instead, like Windows' own
            windows. Read each time it's shown or hidden. Builds;
            `quick-terminal.ps1` turns animations off in CI and checks
            it doesn't slide: it passed (run 41906782926; it showed at
            0 and hid at once, and CI's runners have animations off by
            default). Not checked here, since it's
            a system setting.
      - [x] `quick-terminal-space-behavior` with virtual desktops (the
            counterpart of macOS Spaces): with `move` (the default),
            showing the quick terminal moves it to the virtual desktop
            the user is on (the foreground window's, through
            `IVirtualDesktopManager`), instead of Windows switching to
            the desktop it was on; `remain` leaves it. Checked that the
            quick terminal still shows with one desktop.
        - The fork's CI (`test/windows/quick-terminal.ps1`) adds a desktop
          with Ctrl+Win+D and toggles the quick terminal there: it shows
          in front, and Windows stays on the new desktop (run
          41334351453). But Windows doesn't put the quick terminal on any
          desktop (`GetWindowDesktopId` fails with
          `TYPE_E_ELEMENTNOTFOUND`, as for tool windows), so it follows the
          user without the move, and `remain` has no effect on Windows.
          The same test with `remain` passed too (run 41339529039), so the
          move (`IVirtualDesktopManager.MoveWindowToDesktop`) is removed,
          and the option's docs say Windows always behaves like `move`.
      - [x] Sliding out (toggling hides only when the quick terminal is in
            front, which a locked test desktop never is): the same CI test
            toggles it over IPC and samples its top. Sliding in: -354,
            -275, -152, ... -2, -1, 0. Sliding out: 0, -46, -161, ...
            -396, -400, then hidden.
  - [x] Command palette (`toggle_command_palette`): a field over an
        owner-drawn list of the `command-palette-entry` commands (title,
        description, shortcut) and "Focus: <title>" entries for every
        terminal, like GTK. Every word of the query must appear in the
        title or action (`new_split:right`). Up/Down/PageUp/PageDown move,
        Enter or a click runs, Escape or focus loss closes. A layered
        child of the surface, like the search bar. Checked natively: it
        opened from the menu, filtered, and Enter on `new_split:right`
        split the terminal.
  - [x] `set_window_theme` (new upstream, 2026-11): like GTK, it
        overrides `window-theme` for the session (outlasting config
        reloads until `config` goes back): the title bar and menus follow
        it, and `light` or `dark` also force the color scheme reported to
        the core, which picks `theme = light:...,dark:...`. Test:
        `test/windows/window-theme.ps1` (both directions, after a reload,
        and back to `config`).
  - [x] The other actions Win32 doesn't handle (found 2026-11-06), left
        unhandled on purpose: `show_child_exited` (unhandled, the core
        prints "Process exited. Press any key to close the terminal." in
        the terminal, which says the same as GTK's banner),
        `secure_input` (macOS's secure keyboard entry, which has no
        Windows counterpart) and `show_gtk_inspector` (GTK only).
- [x] Config options the Win32 apprt ignored (found 2026-10-25)
  - [x] `focus-follows-mouse`: hovering a split focuses it when the
        cursor really moves, the window is in front, no button is held,
        and focus is on another terminal (never a search field, palette,
        or dialog). Checked with real mouse moves on the CI runner's
        desktop (`test/windows/desktop-input.ps1`, run 41247475902).
  - [x] Dropping files on a terminal pastes their paths through the
        normal paste path (bracketed paste, unsafe paste checks),
        separated by spaces like Windows Terminal. For cmd/PowerShell,
        paths with spaces or special characters are double quoted; for
        WSL (the command runs `wsl.exe`) they become Linux paths
        (`/mnt/c/...`, `\\wsl$\<distro>\...` to `/...`) in single
        quotes when needed. Unit tested; a real drop needs a manual check.
    - [x] Dropping a file could run a command in PowerShell: paths went
          in double quotes, where PowerShell runs `$(...)` (and expands
          `$name` and backticks), and Windows file names can contain `$`,
          `(` and `)`. A downloaded `$(calc).txt` dropped on PowerShell
          pasted `"C:\...\$(calc).txt"`, which runs calc on Enter (checked
          here with `$(Write-Output RAN)`, which printed `RAN.txt`). Git
          Bash's double quotes do the same. The surface's command now
          picks the quoting: PowerShell (`powershell`, `pwsh`) gets single
          quotes, with `'` and the typographic single quotes U+2018 to
          U+201B doubled (PowerShell takes those as quotes too); POSIX
          shells (`bash`, `sh`, `zsh`, `fish` and others) get single
          quotes with `'\''`; cmd and other commands keep double quotes.
          Checked here: both forms print literally in PowerShell and Git
          Bash. Unit tests: `text` in `drop.zig`, `dropShell`. CI's drag
          test also drops `drop $(Write-Output RAN).txt` on Windows
          PowerShell and expects it single-quoted.
      - [x] The quoting followed the surface's command, so PowerShell
            started from cmd got cmd's double quotes (where `$(...)`
            runs). It now follows the shell that's running: the core's
            `foreground_pid` works on Windows (ConPTY has no foreground
            process group, so it's the newest of the deepest processes
            under the shell, from a process snapshot; a parent must have
            started before its child, since process IDs are reused), and
            the drop walks up from it to the nearest shell it knows. Unit
            test `foregroundProcess` starts `cmd /c powershell` and finds
            PowerShell; CI's drag test drops the `$(...)` file on
            `cmd /k powershell` (`-Nested`), and passed (run
            41717273203).
        - Not covered: a shell that Windows doesn't see, like one in WSL
          or over SSH, still gets the command's quoting.
  - [x] `app-notifications`: "Copied to clipboard" / "Cleared clipboard"
        and "Reloaded the configuration" as a badge at the bottom of the
        terminal for two seconds, like GTK's toasts. Checked with
        screenshots after Reload Configuration and an OSC 52 write.
  - [x] `window-save-state = always`: windows (placement, maximized,
        active tab), tab title overrides, split layouts, the focused
        terminal, and working directories are saved as JSON in
        `%LOCALAPPDATA%\ghostty\window-state.json` on quit, close all,
        or when the user closes the last window, and restored at startup.
        When the last window closes because its shell exited, the state
        is cleared. Checked: a split plus a second tab saved and restored
        as three terminals with their directories and focus.
  - [x] `window-theme = ghostty` colors the title bar with the terminal's
        background and foreground, or `window-titlebar-background` and
        `-foreground` (`DWMWA_CAPTION_COLOR`/`DWMWA_TEXT_COLOR`, Windows
        11). Checked: the caption pixel matched the background.
    - [x] The option's docs (2026-11-08) still said `ghostty` "behaves
          like `auto`" on Windows and is "only supported on Linux
          builds"; they now say what it does here, and that with the
          tabs in the title bar Ghostty draws it in the terminal's
          colors. Checked in `+show-config --docs --default`; CI run
          42466390091 (37805abd8) passed every job.
  - [x] `resize-overlay`, `resize-overlay-position`, and
        `resize-overlay-duration`: "columns x rows" when the grid changes,
        like GTK; with `after-first`, not while a new window is being
        sized before it's shown. Checked: nothing at startup, "82 x 21"
        after a resize, hidden after the duration.
  - [x] `window-step-resize`: dragging a window edge resizes the active
        terminal in whole cells (`WM_SIZING`, with the cell size from the
        `cell_size` action), keeping the leftover padding. Unit tested;
        dragging needs a manual check.
  - [x] `maximize` and `fullscreen` for new windows, like GTK. Checked:
        `--maximize=true` started zoomed; `--fullscreen=true` started
        captionless at 0,0,3840,2160.
  - [x] `window-position-x` and `window-position-y` for the first window:
        points from the top left of the primary monitor's work area, like
        macOS, placing the visible frame (not the invisible resize
        borders) there, and falling back to the work area's corner if
        that's off every monitor. Checked: 100,50 at 200% put the visible
        frame at 200,100.
- [x] Share built-in compiled shader bytecode across surfaces
- [x] Precompile the built-in HLSL at build time when the build host is
      Windows (`src/build/hlsl_compile.zig` calls `D3DCompile` with the
      runtime flags; the bytecode is embedded as `d3d11_shaders`). Other
      hosts still compile at runtime. ReleaseSafe startup: the nine
      shaders took about 190 ms to compile and now take about 0.1 ms to
      load.
- [x] Cache compiled custom shader bytecode across surfaces
- [x] Add Menu support. Need to decide on where to put the menu. I prefer
      hide it in the title bar, where the menu shows up on hover (or clicking
      a hamburger menu icon like Zed). You can reference how the linux version
      works regarding menu. MacOS is not comparable due to the global menu.
  - The window keeps the native caption, so a menu drawn inside the
    caption would need custom non-client painting. Instead the main menu
    (modeled on GTK's) is in the places Windows users look for it:
  - [x] The window's system menu (window icon, right-click on the title
        bar, Alt+Space), rebuilt on each open so that shortcuts and
        disabled items are current
  - [x] ~~A ☰ button at the right end of the tab bar~~, removed
        (2026-11-06): it repeated the title bar's menu (right click or
        Alt+Space), which a right click on the tab bar's empty space shows
        too, and it was missing whenever the tab bar was hidden.
  - [x] A terminal context menu for `right-click-action = context-menu`,
        shown on button release like other Windows apps. Since 2026-11-06
        it only has what applies to the terminal (Copy, Paste, Select All,
        Find…, the Split submenu, Clear, Reset): its Tab, Window and
        Config submenus repeated the tab menu and the title bar's menu.
  - Items run keybind actions and show their shortcuts ("Ctrl+Shift+T").
    Copy shows Ctrl+Ins because ctrl+shift+c is a performable binding,
    which the reverse map skips (same as GTK).
  - [x] Dark menus to match a dark window theme, through uxtheme's
        undocumented `SetPreferredAppMode`/`FlushMenuThemes` (ordinals
        135/136, Windows 10 1903+), set with the title bar theme.
        Verified with a screenshot of the context menu.
  - [x] Command palette item in the main menu
  - [x] Terminal inspector item
  - [x] A tab menu on right clicks in the tab bar, like GTK's: change
        title, new tab, move to a new window, close, close others, close
        to the right. Right clicks elsewhere in the tab bar show the main
        menu. Checked: "Close Other Tabs" from the first tab's menu left
        one terminal.
  - Not planned: opening the context menu from the keyboard (Shift+F10,
    the Menu key). Terminal programs use those keys, and with win32 input
    mode console programs receive them.
- [x] Don't ask for exit confirmation if there is no active progress other than
      the shell itself. This is the behavior on macOS and Linux.
  - The core already skips confirmation when the cursor is at a prompt
    (OSC 133). PowerShell and WSL had shell integration; cmd.exe, the
    default shell, didn't, so every close asked.
  - [x] cmd.exe shell integration (`shell-integration = cmd`, detected
        from `cmd`/`cmd.exe`) through its `PROMPT` variable: 133;A before
        the prompt, 133;I after it, OSC 7 with the raw `$P` path, and the
        `title` and `cursor` features
  - [x] UI check: closing an idle cmd window doesn't ask; closing one
        running `cmd /k ping -t localhost` shows "Close terminal?"
- [x] Reconcile how a user chooses which shell to start for a new tab or
      window. The tab bar's shell dropdown ("New Tab With a Shell") offers
      Command Prompt, PowerShell, WSL, and so on, but the main menu has no
      such choice, and the dropdown only shows in the multi-tab view (when
      the tab bar is visible). So to start a WSL tab from a single-tab
      window, the user first has to open a new tab (Command Prompt), then
      use the dropdown.
  - Now the main menu (the tab bar's menu button and the title bar menu,
    Alt+Space, which a single-tab window still has) has "New Window With
    Shell" and "New Tab With Shell" submenus, and the terminal's Tab
    submenu and a tab's right-click menu have "New Tab With Shell". They
    list the same shells as the dropdown (`shells.zig`): the configured
    default, Command Prompt, Windows PowerShell, PowerShell, WSL, and each
    WSL distribution.
  - Checked by building the title bar menu (`WM_INITMENUPOPUP`) and
    sending its commands (`WM_SYSCOMMAND`) to a single-tab window: "New
    Tab With Shell > Windows PowerShell" opened a second tab running
    `powershell.exe`, and "New Window With Shell > Command Prompt" opened
    a second window running `cmd.exe`.

## Development log (2026-10-24)

- Reproduced the tab-header close crash with two tabs in the existing
  Debug build. Closing the active last tab leaves `Window.active` outside
  the shortened tab array during synchronous Win32 focus callbacks.
  Select the surviving tab before destroying the old tab. Also publish
  the replacement focused split before releasing its old tree.
  Verified the fix through the UI: active last-tab close and inactive
  tab middle-click leave the remaining terminal open and focused.
  `zig build test -Dtarget=x86_64-windows-gnu -Dtest-filter=split_tree`
  passes.
- Native GNU Debug build passes with Zig 0.17.0. The first build hit a
  transient MinGW dependency-file parse failure; rerunning succeeded.
- Windows `command` values now use Windows CRT quoting rules, including
  executable paths with spaces, quoted arguments, empty arguments,
  backslashes before quotes, and Unicode. For example, a command value
  can contain `shell:"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo`.
  The `shell:` prefix prevents the config file's outer-quote handling
  from consuming the executable's quotes.
  This launches the executable directly; shell operators such as `|`
  still require explicitly invoking a shell. Direct argv commands are
  unchanged. Empty executable names are rejected.
  `zig build test -Dtarget=x86_64-windows-gnu -Dtest-filter="execCommand windows"`
  passes, including ownership and quoting regression cases.
- Close confirmation callbacks now verify their window/surface still exists
  after the modal dialog returns. Multi-tab close also ignores tabs that
  disappeared while the dialog was open. A native test with a short-lived
  child confirmed the close dialog appears and the window closes cleanly
  when that child exits before the user answers.
- Clipboard confirmation callbacks also verify that their surface survives
  the modal dialog. Confirmed clipboard writes copy their text before opening
  the dialog so a process exit cannot invalidate the payload. Native build
  passes. A disposable child sent OSC 52 with `clipboard-write=ask`, then
  exited while the permission dialog was open; Ghostty closed cleanly.
  The unsafe-paste dialog still needs the same live race test.
  - [x] Done in CI (`test/windows/paste-race.ps1`), and it crashed:
        Cancel worked, but when the shell exited with the dialog open,
        Ghostty crashed. The surface's own check was fine, but the dialog
        ran inside the core's paste call, which went on using the
        destroyed core surface once the dialog returned (the clipboard
        permission dialogs were called the same way). All three dialogs
        now run from a message the surface posts to itself
        (`WM_GHOSTTY_CONFIRM_CLIPBOARD`), with no core code on the stack;
        a second request while one waits is denied. CI then passed
        (run 41705029879): the shell exited with the dialog open and
        Ghostty closed cleanly, and Ctrl+V pasting still works.
  - [x] Two more dialogs ran inside the core's key handling, which goes
        on using the core surface afterwards: "Close terminal?"
        (`close_surface`) and "Change Terminal Title"
        (`prompt_*_title`). Both now run from messages the surface posts
        to itself (`WM_GHOSTTY_CONFIRM_CLOSE`, `WM_GHOSTTY_PROMPT_TITLE`).
        CI test `dialog-race.ps1`: OK closes, and the shell exiting with
        either dialog open must not crash. Passed (run 41736532621); it
        wasn't run on the build before the fix, so whether that one
        crashed is unconfirmed.
  - [x] The same for "Quit Ghostty?" (`quit`) and the configuration
        errors dialog after a reload (`reload_config`, which shows the
        new config's errors): both now run from messages posted to the
        app's message window (`WM_GHOSTTY_QUIT`, and
        `WM_GHOSTTY_CONFIG_ERRORS` with the message already written).
        `dialog-race.ps1` also quits with F6 while `ping` runs and lets
        the shell exit with the dialog open. Passed (run 41743000103).
  - [x] `dialog-race.ps1` also reloads (F5) after writing an unknown
        option into its own config file (`XDG_CONFIG_HOME`), and lets the
        shell exit with "Configuration Errors" open. Passed (run
        41748622636).
- Bell handling now copies each surface's `bell-features` (including on
  reload), gates `MessageBeep` on `system`, and requests taskbar attention
  only for background windows. `FLASHW_TIMERNOFG` stops the flash on
  activation. Native Debug build passes; visual taskbar verification is
  still pending.
  - [x] CI test `bell-flash.ps1`: a shell hook window sees the flash
        (`HSHELL_FLASH`) for a bell from the background, none from the
        foreground, and none with `no-attention`. Passed (run
        41727336416).
- A real ConPTY smoke test exposed the Windows process command-line
  serializer dropping empty arguments. Fixed by quoting empty strings;
  round-trip regression tests cover adjacent/trailing empty arguments,
  spaced paths, embedded quotes, Unicode, and trailing backslashes.
  The rebuilt app passed a real ConPTY launch: all four argv entries
  (including the empty one) matched exactly, and the child and Ghostty
  exited with status 0. Targeted `windowsCreateCommandLine` tests pass.
- Mouse capture now uses the button state carried by each mouse message,
  including XBUTTON1/XBUTTON2, so releasing one button during a multi-button
  drag doesn't prematurely release capture. Native Debug build passes;
  physical side-button testing remains pending.
- Full native Debug test snapshot after the tab, command parsing, and
  bell changes: 4,029 passed, 65 skipped, 0 failed. The suite is slow in
  terminal/search tests; running its compiled executable directly gives
  per-test progress. Later serializer changes have separate targeted
  tests and real ConPTY validation.
- Unfocused splits use a click-through layered child overlay, honoring
  each surface's fill color and opacity. The manifest declares Windows
  10/11 compatibility, required for layered child windows. Verified
  default dimming, mouse focus transfer, nested splits, and zoom via the
  native UI. The focused split stays undimmed when its window loses focus.
  Also verified custom fill, disabling with opacity 1, re-enabling via
  live config reload, and closing the focused split without a crash.
  Performance with heavy custom shaders and images: see below.
- [x] Profiled custom shaders and background images (ReleaseFast, an
      NVIDIA GT 750M at 1024x768 and 59 Hz, the window about 800x600).
      Frames counted from the DXGI ETW provider's Present events (no admin
      needed), CPU from the process, GPU from the `GPU Engine` 3D counter:
      | Case | Frames/s | CPU | GPU 3D |
      | --- | --- | --- | --- |
      | No shader, idle (cursor blink) | 1.8 | 0% | 3% |
      | Background image 3840x2160, cover | 1.6 | 0.4% | 4% |
      | Pass-through shader, animated | 65-71 | 5-7% | 43% |
      | Light shader (tint by time) | 65 | 5% | 42% |
      | Heavy shader (64 samples per pixel) | 65 | 5% | 82% |
      | Heavy shader, 4 splits | 65 each | 20% | 84% |
      | Heavy shader, maximized | 43 | 6% | 100% |
      | Background image + heavy, maximized | 42 | 8% | 100% |
      Animated shaders hold the refresh rate until the GPU is full, and an
      image costs nothing while idle. Each split has its own swap chain and
      runs the shader itself, as on other platforms. The 43% for a shader
      that only copies its input is this old GPU's base cost per frame (it
      doesn't grow with the shader's work until the GPU is full).
  - [x] Found while profiling: the window stopped responding while cmd
        flooded output (`for /l %i in (1,1,999999999) do @echo %i`):
        0 of 40 `WM_NULL` messages answered within 5 s. Sampling the UI
        thread's stack showed every title change setting the window text
        and invalidating the tab bar, while cmd changed the title with each
        line ("cmd.exe - echo 10813"), and the core's tick handles every
        queued message before returning to the message loop. Title changes
        now post one message that updates the title bar later. Checked:
        median 0.6 ms, max 21 ms, and the title still follows cmd.
        `test/windows/flood.ps1` runs this in CI on the package's release
        build (the debug build was too slow to hang). In CI it also
        presses Ctrl+C during the flood: run 41468741186 answered in
        0.4 ms (median) and the flood stopped within 249 ms.
  - [x] Resizing: each resize of the window (60 `SetWindowPos` calls
        from another process, one split) took 24 ms (median), more than a
        60 Hz frame. Stack samples put most of it in resizing each
        surface's dim overlay and bell border, layered windows whose
        bitmaps Windows resizes even while they're hidden. Hidden
        overlays now take the new size when they're shown: 12-13 ms per
        resize (max 23-26 ms, was 39-44), with about two frames each as
        before. Checked natively that a dimmed split's overlay matches its
        split after resizes, also when it's first shown afterward, and
        that the bell border does too. Most of what's left is the
        surface's own paint (`FillRect` under the swap chain), which
        translucency needs.
  - [x] Output wasn't drawn until the next cursor blink. Typing into cmd
        showed a frame 0.2 ms after each key (the key's own redraw) and
        none for the echo, which reached the terminal about 2 ms later;
        with an echo delayed by 50 ms, the letter appeared only with the
        next blink, 100-600 ms later, and a program printing once a second
        gave frames on the blink's 605 ms beat alone. Timestamped logs
        showed output processed without a draw. The IO thread had a copy
        of the renderer thread's wakeup handle, made before the renderer
        waited on it; libxev's IOCP `Async` keeps its waiter in the
        struct, so the copy never woke anything (eventfd and mach port
        handles copy fine on other platforms). Termio now holds a pointer
        to the renderer's handle. After: cmd's echo is drawn 0.5 ms after
        the key, the delayed echo 63 ms after (when it arrives), and output
        gets its own frames. `test/windows/output-frames.ps1` (in CI on
        the package) counts frames while a letter prints every 250 ms: 24
        of 24 now, 10 (blinks only) on a build without the fix. Drawing
        with output didn't slow output down (release builds differing only
        by the fix, alternating): 20 MB with `cmd /c type` took 24.4-25.0 s
        (median 24.6) with it and 17.2-29.4 s (median 23.4) without, and
        a program writing 64 KiB chunks took 1.9 s with both.
  - [x] With output drawn as it arrives, a flood drew 307 frames a second
        here (133% CPU, 86% GPU, at 59 Hz): every present on this locked
        desktop returns `DXGI_STATUS_OCCLUDED` at once instead of at the
        next refresh. While occluded, a present that comes within 10 ms
        of the last now sleeps first (a timer tick, about 15.6 ms): 64
        frames a second (44% CPU, 23% GPU), with animated shaders still
        at 63-65 and throughput unchanged. `output-frames.ps1` reports
        the flood's frame rate, which shows what an unlocked desktop does:
        54 a second in run 41549447897 (CI). Tried and dropped: a frame latency waitable object didn't
        limit occluded presents, and
        `D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS`
        took NVIDIA's 11 threads per surface device down to 1 (10 idle
        tabs: 150 threads to 50) but raised CPU with GPU-bound shaders
        from 9% to 41%, and would keep WARP to one thread.
  - [x] Minimizing: the window laid out its empty client area, which
        resized each terminal of the active tab to a tiny grid ("very
        small terminal grid" in the log, two extra resizes for ConPTY),
        and the renderer kept rebuilding frames for output with nothing to
        draw them on: 78% CPU during a flood, more than the 45-52% shown.
        Minimizing now skips the layout and tells the active tab's
        surfaces they aren't seen (their windows stay, for the taskbar
        preview): no resize, 36% CPU (parsing the output), and drawing
        resumes on restore. `test/windows/minimize.ps1` checks this in CI;
        it fails on the build before ("minimized 0x0").
  - [x] Scrollback memory, checked: after 20 MB of output into one tab,
        private memory was 98 MB against 49 MB for an empty tab, which is
        the default 50 MB limit (146 MB with a 100 MB limit). Scrollback
        compression works here: the working set was 73-74 MB with it and
        113-120 MB with `scrollback-compression=false`. Private bytes stay
        the same either way, since `DiscardVirtualMemory` keeps the commit
        charge (see `src/terminal/mem.zig`).
  - [x] Leaks from opening and closing tabs, checked: 5 and 40 rounds
        of opening a tab and closing it (posted keys) both ended, once
        the closed tabs' undo time had passed, at 55-59 MB private (51 at
        the start), about 524 handles (501), 22-24 threads (23), 34 GDI
        objects (22) and 46-47 USER objects (45). The difference is the
        same after 5 rounds as after 40, so it's kept once (the tab
        bar's resources, for example), not per tab. Splits, 5 and 30
        rounds: 54 MB, 520-523 handles, 35 GDI objects both times.
  - [x] Characters no font has: 2 MB of random text from ten scripts
        (CJK, Thai, Arabic, emoji and others, including unassigned
        codepoints, as in a binary file) took 3.8 s to show (8.7 s the
        first time) against 0.5 s for ASCII. Stack samples of the renderer
        thread showed discovery opening every font file with FreeType for
        each codepoint DirectWrite's fallback didn't serve, about 25 ms
        each: 20 characters from scripts no Windows font covers (Tangut,
        Mro and others) cost about 500 ms of CPU. Codepoint queries past
        DirectWrite now use an index of every face's characters (sorted
        ranges), built once per process on the first such query: the 2 MB
        took 0.58 s, the 20 rare characters about 170 ms (mostly building
        the index), for about 2 MB of memory. Fonts installed later are
        only found through DirectWrite. Test: "windows codepoint
        coverage" in `src/font/discovery.zig`.
  - [x] Bold and italic of a configured `font-family` were drawn regular:
        name queries matched the family only, so every style got the first
        face found (`consola.ttf` for all four Consolas styles), and with
        every style filled none was synthesized. Name queries now also
        match FreeType's bold and italic style flags: Consolas loads
        consolab, consolai and consolaz, and Inconsolata (regular and bold
        files here) synthesizes italic and bold italic. Startup with
        Consolas is unchanged (181-192 ms). Test: "windows styles".
  - [x] Font family lookups: a family the folder walk didn't find took a
        walk per style (Cascadia Mono: 540 ms to the window against 170),
        as did a style a family lacks (Inconsolata's italics: 413-422 ms)
        and would a per-user font, which comes after all of the system
        fonts. Name queries now ask DirectWrite's index of installed fonts
        for the family's face for the style first (`findFamily` in
        `src/font/dwrite_fallback.zig`, a simulated style counts as
        missing), and look up anything else in the coverage index, which
        now also notes each face's names and style: Cascadia Mono 277-286
        ms, Inconsolata 271-273 ms (most of it building the index), and
        Consolas 171-181 ms. DirectWrite also knows fonts that packaged apps
        register, which the walk never saw: here Cascadia Mono comes from
        Windows Terminal's package.
  - [x] Variable font weights: Cascadia Mono is one variable font whose
        weights are named instances of one face. DirectWrite matches its
        Bold instance without a simulation, but FreeType opens the face's
        default (Regular) instance and gives every instance the same style
        flags, so bold and bold italic were synthesized ("synthetic bold
        face created" in the log). Discovery now opens the named instance
        with the weight DirectWrite matched (instance 6, wght 700) and,
        like CoreText discovery, counts a named instance with a weight of
        600 or more as bold. The log no longer shows synthetic faces for
        Cascadia Mono. Test: "windows variable font weights" (skipped where
        Cascadia Mono isn't installed). Variable fonts found only through
        the folder walk or the coverage index still synthesize bold.
  - [x] `+list-fonts` didn't list fonts outside the font folders, such as
        Cascadia Mono from Windows Terminal's package, though
        `font-family = Cascadia Mono` finds it, and it named every face by
        its family ("Consolas" four times). Listing every font now also
        takes the fonts in DirectWrite's system font set that aren't in
        the folders (each named instance of a variable font by its weight
        axis), and Windows faces are named by their full name ("Consolas
        Bold"; a named instance by its family and instance names, since
        the name table describes the default instance), like fontconfig
        and CoreText. Here Cascadia Code and Cascadia Mono now appear with
        all 12 styles (327 families, from 325). The font set gives each
        font's file without parsing it: the system collection's fonts took
        780 ms to list, the font set 31 ms. `+list-fonts` (ReleaseFast)
        takes 168-179 ms, from 149-163. Tests: "otherFonts" and "windows
        lists fonts outside the font directories".
- The tab bar now has a shell dropdown next to the new-tab button. It lists
  shells whose executables are found in PATH and always offers the configured
  default. An explicit choice uses the resolved executable path and is
  inherited by splits; the normal new-tab action still uses the configured
  command. Verified in the native UI that selecting PowerShell 7 starts it,
  splitting that tab starts PowerShell again, and selecting the configured
  default opens cmd.exe. The tab bar uses `window-show-tab-bar=auto` by
  default, so the dropdown appears after opening a second tab; `always`
  makes it available from the first tab.
- The WSL entry checks the current user's registered distributions, so an
  installed `wsl.exe` alone does not produce a dead-end menu item. The menu
  now enumerates those distributions by name. The selected command and its
  arguments are cloned into the surface and inherited by splits. Verified
  `WSL: Ubuntu` launches `wsl.exe -d Ubuntu`, including in a new split.
  Shell integration still needs work beyond launching bare `wsl.exe`.
- The WSL menu entry launched the installed Ubuntu distribution in the
  native UI, and splitting that tab launched another Ubuntu shell. Both
  inherited the Windows working directory as `/mnt/c/Users/Yuan` on this
  machine. Consider offering the Linux home directory as a launch choice.
- Tabs can be dragged within the tab bar. A drag starts only after the
  system drag threshold and uses the existing tab-move path, preserving the
  active terminal. Verified moving a PowerShell tab from last to first and
  a cmd.exe tab from middle to last in the native UI.
- The D3D11 renderer now keeps one copy of each built-in compiled shader
  blob for the process, guarded across render threads. Each surface still
  creates its own device-specific shader objects. Native build passes and
  multiple tabs and splits rendered correctly in the UI. Custom shader
  bytecode is cached too (see below). A custom shader adds nothing to a
  new tab's time on the UI thread (ReleaseFast, three runs of four: 13-17
  ms with and without), since shaders load on the renderer's thread.
- The documented plain `zig build` selects the MSVC ABI and fails on this
  machine with `WindowsSdkNotFound`. The GNU target build succeeds with Zig
  alone. Keep the explicit `-Dtarget=x86_64-windows-gnu` command in the
  local development instructions; MSVC CI has its own SDK.
- ConEmu OSC 9;4 reports now drive Windows taskbar progress through
  `ITaskbarList3`. The active tab's focused split supplies the state;
  `progress-style=false` hides it, and a stalled report clears after 15
  seconds. The GNU Debug build passes. A native ConPTY PowerShell fixture
  delivered normal 45%, error 70%, indeterminate, paused 80%, and remove
  reports; the window received `TaskbarButtonCreated`, and the COM calls
  reported no failures. Visual verification of taskbar states and switching
  surfaces is pending.
- A paused report without a percentage keeps the last reported value,
  matching the GTK progress behavior. An error without a percentage also
  uses that value when available; a remove report discards it. A second
  native ConPTY fixture confirmed a pause without a percentage and logged
  the 15-second expiration; its child exited with status 0.
- OSC 133 command completion now reaches the Win32 configured bell action.
  It respects `notify-on-command-finish`, the duration threshold, and
  `bell-features`; config reload updates these settings. A native fixture logged
  a 509 ms command and its bell with `always`/`0ms`, while a `10s` threshold
  suppressed the bell for the same command. Desktop notifications and
  visual indicators for inactive splits remain to do.
- Tabs now show an amber marker when a surface in them rings while unfocused.
  Selecting the ringing surface clears it, and disabling the title bell
  feature on reload clears pending markers. A native UI test opened a second
  tab before a timed BEL, saw the marker on the first tab, and confirmed it
  disappeared when that tab was selected.
- A pending bell also prefixes the top-level window title with `[!]`, so
  it remains visible when the tab bar is hidden. A native UI test saw the
  prefix and tab marker appear together after a timed BEL in an inactive
  tab, then clear together when that tab was selected. The GNU Debug build
  passes.

## Review log (2026-10-25)

Reviewed the branch against this file and discussion #2563.

- The title bar was always dark, contrary to its comment. It now follows
  `window-theme` like the GTK apprt: `auto` and `ghostty` use the
  background luminance, `system` reads the Windows app mode (and updates
  on `WM_SETTINGCHANGE`), and `light`/`dark` force it. App config
  reloads now also re-apply the theme, tab bar colors, and tab bar
  visibility to open windows.
- Pending bells now use the documented `bell-features` `title` behavior:
  a 🔔 prefix on the tab title and window title, replacing the `[!]`
  prefix and the amber tab dot.
- The tab bar's `CS_DBLCLKS` swallowed quick second clicks on the
  new-tab button, tabs, and close buttons. Double clicks on those now act
  as clicks; only empty space opens a tab on double click.
- The D3D11 debug layer was requested in ReleaseSafe builds too. It's
  now limited to Debug builds.
- The GNU Debug build, `zig fmt`, and targeted tests (`physicalKey`,
  `shadertoy to hlsl`, `execCommand windows`,
  `windowsCreateCommandLine`) pass. UI behavior of these changes wasn't
  tested in this review.

## Development log (2026-10-25)

- Desktop notifications use `Shell_NotifyIconW` balloons, which Windows
  10/11 show as toasts. Unlike WinRT toasts they need no AppUserModelID or
  Start menu shortcut, which unpackaged builds lack. The notification area
  icon is only added while a notification is showing and is removed when
  it's clicked, dismissed, or times out (so it doesn't linger in Action
  Center). Clicking a toast restores the window and focuses the surface that
  sent it, if that surface still exists. A newer notification replaces the
  current one. ConPTY passes OSC 9 and OSC 777 through. Native tests: an
  OSC 9 toast appeared with the app icon; clicking it restored a minimized
  window to the foreground; an OSC 133 fixture with
  `notify-on-command-finish-action=notify` showed "Command Failed".
  `zig build test -Dtest-filter=copyTruncated` passes.
- The `border` bell feature draws a click-through layered child window
  over the surface: a 3px (DPI-scaled) frame in the system accent color at
  half opacity, matching GTK. Like GTK and the documented behavior, a
  pending bell (title and border) is now set even for the focused surface
  and clears on focus or on any key the core consumes. The title marker
  only counts surfaces with the `title` feature. Native test: BEL with
  `bell-features=border,title` showed the frame and 🔔 title, and a key
  press cleared both.
- The `audio` bell feature plays `bell-audio-path` through MCI's
  `mpegvideo` device (winmm), which decodes common formats via the system
  media stack and supports `bell-audio-volume`. The file stays open across
  bells and reopens when the path changes. A missing `optional` path is
  silent; a missing required path logs a warning. Native test: two BELs
  played `C:\Windows\Media\chord.wav` at volume 300/1000 with no MCI
  errors (audible output not verified from the session).
- Custom shader bytecode is cached per process in an 8-entry ring keyed by
  the SHA-256 of the translated HLSL, under a lock so concurrent surfaces
  compile once. Native test with a custom shader: the first tab logged a
  compile and two new tabs reused the bytecode.
- `move_tab_to_new_window` moves a tab into a new window by reparenting
  its surface child windows; the renderers keep their swap chains since the
  `HWND`s don't change. Like GTK it's a no-op for a window's only tab.
  The new window is presented after the old window selects its next tab,
  which would otherwise take activation back. Native test: a typed command's
  output stayed in the moved tab, the new window was in front, the
  single-tab case did nothing, and exiting the moved shell closed only the
  new window.
- Title overrides follow GTK: a surface override beats the terminal title,
  a tab override beats its focused surface's title, and a window override
  beats the active tab's title. Empty values clear them.
  `copy_title_to_clipboard` copies the surface's effective title. Native
  test with keybinds: the tab and window overrides showed in the tab bar
  and title bar, clearing each restored the previous title, and the
  clipboard received the cmd.exe title.
- `prompt_title` shows a modal dialog built from an in-memory
  `DLGTEMPLATE` (no resource script): GTK's "Change … Title" caption and
  hint, an edit box with the current title selected, and OK/Cancel. An
  empty title clears the override. Native test: the dialog rendered with
  visual styles; typing a tab title and pressing Enter applied it; Esc on
  the surface prompt left it unchanged and returned focus to the window.
- `initial_size` is in points, but was applied as pixels and without the
  tab bar; it now scales by the window DPI and adds the tab bar. It's also
  remembered for `reset_window_size` (restores a maximized window first).
  `resize_window` follows GTK's restrictions (one unsplit tab, not
  maximized or fullscreen; zero keeps a dimension). `size_limit`'s minimum
  becomes the window's minimum track size. Native test at 200% scale:
  `window-width=80`/`window-height=24` gave a 1540x1028 terminal, which
  `reset_window_size` restored after a manual resize, and a 50x50
  `SetWindowPos` was clamped to the 232x168 minimum. ConPTY consumes
  CSI 8 t itself, so `resize_window` from a program isn't reachable
  through ConPTY.
- `window-decoration=none` and `toggle_window_decorations` remove the
  caption but keep the resize border; toggling follows GTK (back to the
  config, or the opposite of it). Fullscreen re-applies it on restore.
  `float_window` uses `HWND_TOPMOST`; those special handles aren't valid
  Zig pointers, so `util.SetWindowPos` takes an integer. `goto_window`
  cycles windows in creation order (window removal is now ordered) and
  `present_terminal` restores and focuses the surface. Native test: the
  caption and topmost style bits toggled both ways, and `goto_window:next`
  alternated the foreground between two windows.
- `global:` keybinds register with `RegisterHotKey` on the message window
  (with `MOD_NOREPEAT`) and re-register on app config reload. Like GTK,
  only single-action binds are supported. Physical keys map through their
  scancode; unicode keys through `VkKeyScanW`, adding the modifiers needed
  to type the character. A hot key owned by another app logs a warning.
  `toggle_visibility` follows macOS: hide every window when one of ours is
  active, otherwise show them and activate the previously active one.
  Native test: `global:ctrl+alt+shift+g=toggle_visibility` hid, showed
  (in the foreground), and hid the window on three presses.
- `mouse_over_link` shows the URL in a GTK-style box in the surface's
  bottom-left corner (terminal colors, 1px #555 outline, system message
  font), moving to the bottom right while the mouse is over it.
  Overlays above the surface must be layered windows: the surface's
  flip-model swap chain covers plain child windows. Native test with
  `link-previews=true`: hovering a URL with Ctrl showed the preview and
  leaving the link hid it. The move-to-right case is untested.
- OSC 7 was stubbed out on Windows. It now converts file URI paths
  (`/C:/Users/me`) to Windows paths and compares the hostname
  case-insensitively. New tabs and splits inherit the reported directory.
- PowerShell shell integration (`shell-integration=detect` or
  `powershell`): `pwsh`/`powershell` (with or without `.exe`, quoted
  paths parsed with Windows rules) start as
  `-NoExit -Command ". ([ScriptBlock]::Create([IO.File]::ReadAllText('…')))"`
  so the script loads after the profile under any execution policy. The
  script reports OSC 133 A/B/C/D, OSC 7 (`kitty-shell-cwd`), and the
  `title` and `cursor` features. PSReadLine's `PSConsoleHostReadLine` is
  wrapped to emit 133;C (the user's Enter binding is untouched); without
  PSReadLine new history entries are used. Exit codes come from `$?`, and
  from `$LASTEXITCODE` only if it changed during the command, so a native
  command failing twice in a row with the same code reports 1 the second
  time. Native test with Windows PowerShell 5.1: integration injected;
  `cd C:\Windows` was reported and inherited by a new tab; the bar cursor
  and cwd/command titles worked; command-finished notifications reported
  success/failure for `Get-Date`, `cmd /c exit 3`, `Get-Item nope`, and
  `cmd /c exit 0`, and nothing for an empty line.
- WSL shell integration: `wsl.exe` with only `-d`/`--distribution`,
  `-u`/`--user`, `--cd`, or `~` runs
  `--exec /bin/sh -c '. "$GHOSTTY_RESOURCES_DIR/shell-integration/wsl/ghostty.sh"'`.
  `WSLENV` passes `GHOSTTY_RESOURCES_DIR` (translated with `/p`), the
  features, `TERM_PROGRAM*`, and `COLORTERM`. The POSIX sh launcher reads
  the login shell from passwd and applies the native injection for bash
  (`ENV`/`--posix`), zsh (`ZDOTDIR`), and fish/elvish/nushell
  (`XDG_DATA_DIRS`), then execs it as a login shell. OSC 7 now maps
  `/mnt/c/...` (and MSYS2's `/c/...`) to `C:\...`; other Linux paths reset
  the pwd instead of producing a bogus Windows directory.
- Found that `core.autocrlf=true` checked out the zsh/bash/fish/elvish/nu
  scripts with CRLF, which breaks them in WSL (zsh: `command not found: ^M`).
  Git Bash's `grep` hides the CRs; `git ls-files --eol` shows them.
  `.gitattributes` now forces LF under `src/shell-integration/`. Native
  test with Ubuntu (zsh with a custom theme): no startup errors;
  `cd /mnt/c/Windows` was inherited by a new tab; `false`/`pwd` produced
  failed/succeeded notifications; `cd ~` reset the pwd.
- The `scrollbar` action drives a Windows 11 style overlay scrollbar: a
  thin rounded thumb in the foreground color that appears while scrolling
  or with the mouse near the right edge, widens on hover, and can be
  dragged (or the track clicked) to scroll via `scroll_to_row`. It hides
  after 1.2 s unless "Always show scrollbars" is on (the `DynamicScrollbars`
  accessibility setting); `scrollbar=never` disables it. The track is
  color-keyed, so clicks there reach the terminal. Native test: 300 lines
  of output, wheel scrolling showed the thumb, hovering widened it, a
  drag scrolled to line 1, and it hid afterwards. Note for test scripts:
  `SetCursorPos` from another process didn't produce `WM_MOUSEMOVE` during
  a captured drag; absolute `mouse_event` moves do.
- A reusable `Badge` overlay (layered, click-through, terminal colors,
  system message font) shows "🔒 Read-only" in the top right, the active
  key tables and pending sequence in the bottom center (GTK's
  "table > inner › ctrl+a b" format), and a centered message when the
  renderer reports itself unhealthy. Native test: `toggle_readonly` showed
  and hid the read-only badge; activating a `resize` table and pressing
  the first key of a `ctrl+a>b` sequence showed "resize › ctrl+a", and
  Escape cleared it. The renderer health badge is untested.
- Search: a Windows Terminal style find box in the surface's top right.
  It's a layered child window (so it shows above the swap chain and takes
  focus without deactivating the window) with an EDIT control, a
  "selected/total" count like GTK, and previous/next/close buttons using
  Segoe Fluent Icons (or Segoe MDL2 Assets on Windows 10). Typing searches
  live; Enter/Shift+Enter navigate; Escape ends the search and refocuses
  the terminal. Builds; the live UI test was stopped before it ran, so
  it hasn't been exercised in the app yet.
- OSC 7 Linux paths from a WSL shell now map to `\\wsl$\<distro>\...`
  (supported on Windows 10 and 11, unlike `\\wsl.localhost`). The exec
  backend gets the distribution from `wsl.exe -d`/`--distribution`, or the
  registry default (`HKCU\...\Lxss` `DefaultDistribution` →
  `DistributionName`), and hands it to the stream handler. Other Linux
  paths (MSYS2 outside its drive mounts) still reset the pwd. Tests: the
  `os.wsl` unit tests (argument parsing, path building, registry smoke
  test) and the uri and shell integration tests pass. On this machine the
  registry gives `Ubuntu`, and `wsl.exe` started with the working directory
  `\\wsl$\Ubuntu\home\yuan` reports `/home/yuan`. Since then also checked
  through the Ghostty UI (see "Shell integration for wsl" above): `~`
  reports as `\\wsl$\Ubuntu-24.04\home\yuan`, and a new tab there opens
  WSL in `~`.
- `+new-window` and `+new-tab`: each instance's hidden message window is
  titled with its app class (`class`, default `ghostty`), so the CLI finds
  it with `FindWindowW` (any instance for `detect`). It grants foreground
  rights with `AllowSetForegroundWindow` and sends the request with
  `WM_COPYDATA` (kind, surface ID, NUL-separated arguments). Arguments
  become overrides for the new surface only, matching GTK. `+new-tab`
  uses the surface ID's window, or the active window. Unit tests cover the
  encoding and override parsing. Native test (no input): with a running
  instance, `+new-window -e cmd.exe /k echo hi` opened a second window
  running that command, `+new-tab` added a tab, and the log showed both
  requests.
- CLI actions (`+version`, `+new-window`, errors) printed nothing from
  cmd or PowerShell, since `ghostty.exe` is a GUI program. They now attach
  to the parent console when stdout/stderr aren't redirected; pipes and
  files are unchanged. Verified that `+version` prints in a console
  window. Console shells still don't wait for a GUI program, so the
  output can appear after the next prompt.
- The D3D11 renderer now presents through a composition swap chain
  (`CreateSwapChainForComposition`, premultiplied alpha, stretch scaling)
  shown on the surface `HWND` by a DirectComposition visual. That's needed
  for transparency; the shaders already output premultiplied alpha.
  `dcomp.h` is C++ only, so `direct3d11/dcomp.zig` declares the few
  vtable slots we use (with comptime checks of their offsets). The visual
  isn't topmost, so overlay child windows stay above it.
- `background-opacity < 1`: without blur, an empty-region
  `DwmEnableBlurBehindWindow` gives the window per-pixel alpha (an
  extended frame without a backdrop is drawn as a solid color since
  Windows 8). With `background-blur`, the frame extends over the client
  area with the Windows 11 acrylic backdrop (`DWMSBT_TRANSIENTWINDOW`).
  Surfaces paint black (zero alpha in GDI) beneath their visual; the tab
  bar and dividers paint through `BufferedPaint` and set alpha to 255 so
  they stay opaque. App config reloads re-apply this. Native test
  (launch-only screenshots): opaque rendering unchanged, the bell border
  overlay still above the terminal, and the desktop visible through 60%
  opacity with and without blur. Splits and the scrollbar over a
  translucent terminal: `test/windows/translucent.ps1` (in CI) puts a 50%
  black window over an opaque red one and splits it. In run 41372237868
  both panes showed red through them (rgb(96, 0, 0), and rgb(67, 0, 0) for
  the unfocused one, which `unfocused-split-opacity` dims), and the
  scrollbar's thumb was drawn with red showing around it. With blur the
  runner drew the acrylic as solid gray (rgb(29, 29, 29)) even with
  transparency effects on: its only display adapter is Microsoft Hyper-V
  Video, and Windows doesn't blur without a GPU. So blur is only checked
  for the split and scrollbar there. The same test opens the search bar
  and the command palette, which stayed opaque in run 41376035602 (no
  red pixels across the search bar; 23 of 481 across the palette, the
  same count as over the gray blur, so they're its own content). Not yet
  tested: Windows 10.
- Quick terminal: a `WS_POPUP` + `WS_EX_TOOLWINDOW` + topmost window,
  so it has no frame or taskbar button. It's placed in the work area of
  the primary monitor (or the mouse's, with `quick-terminal-screen = mouse`)
  using the core's `QuickTerminalSize.calculate`, with pixel sizes and
  defaults scaled by the monitor DPI. Toggling hides it when it's in
  front, otherwise places and focuses it; `quick-terminal-autohide` (off
  by default on Windows, as on Linux) hides it on deactivation. Closing
  its last tab destroys it. Popup windows start out 0x0, which gave the
  first shell a one-column pty, so the window is placed before its first
  surface is created. `+toggle-quick-terminal` works over IPC. Tests: a
  `quickRect` unit test, and native IPC toggles that showed it
  (full-width, 30% tall, in front), hid it, and showed it again with the
  cmd banner laid out correctly.
- Full native test run (GNU Debug, built after the WSL path mapping):
  4,045 passed, 65 skipped, 0 failed. `zig build test` prints "failed
  command" for the test step because a test writes `terminal-snapshot`
  diagnostics to stderr, but the step and the test binary both exit 0.
- `toggle_background_opacity` follows macOS: it switches every window
  between translucent and opaque, and does nothing when
  `background-opacity` is 1. The renderer keeps drawing with the configured
  alpha; when opaque, surfaces paint the background color beneath the
  composition visual instead of zero-alpha black, so the result looks like
  an opaque terminal. The translucent and default paths were rechecked
  with screenshots; the toggle itself needs a keybind, so it hasn't been
  tested in the app yet.
- `dist/windows/package.ps1` builds a ReleaseSafe GNU build into a staging
  prefix and zips `bin/ghostty.exe` and `share/` (themes, shell
  integration, terminfo) as `ghostty-windows-unofficial-<describe>-<arch>.zip`
  with a README saying it's an unofficial build. Resources are found
  relative to the executable, so the folder is portable. Verified: an
  18 MB zip whose extracted `ghostty.exe +list-themes` finds its bundled
  themes.

- cmd.exe shell integration and menus were checked natively with a
  script that only sends window messages (no synthetic keys): the system
  menu after `WM_INITMENUPOPUP` lists our items with shortcuts and a
  grayed Copy; its New Tab command opened a second tab; the ☰ button and a
  right click open their popups; and `WM_CLOSE` on a window with two idle
  cmd tabs closed it without a confirmation dialog.
- Testing notes: make UI scripts per-monitor DPI aware
  (`SetProcessDpiAwarenessContext(-4)`), or window sizes are scaled and
  `PrintWindow` screenshots are cropped. When the desktop is locked,
  `GetCursorPos` and screen captures fail, so menus are placed from the
  message's coordinates instead of the cursor position.
- Zig 0.17 on this machine: its TLS client failed every dependency fetch
  after the package cache was cleared. Workaround: download the archive
  with curl, extract it (stripping a single top-level folder), and
  `zig fetch <dir>`. `zig fetch <file>` repacks a local tarball with the
  extra folder and gets the wrong hash.
- Full native test run (GNU Debug, test binary run directly so it prints
  progress): 4,064 passed, 61 skipped, 0 failed, but the runner exited 1
  because two HarfBuzz shaper tests (Devanagari, Bengali) leaked their
  discovered `DeferredFace`; fixed. The run takes about 40 minutes here,
  most of it in the debug-build PageList compression tests, which can
  look like a hang.
- Full native test run after the menus, palette, inspector, win32 input
  mode, DirectWrite fallback, and precompiled shaders: 4,067 passed,
  61 skipped, 0 failed, no leaks, exit 0.
- Third full native test run, after save state, split dragging, drag and
  drop, resize overlay, toasts, jump list, and HTML copy: 4,073 passed,
  61 skipped, 0 failed, exit 0. `package.ps1` then built a ReleaseSafe zip
  with `install.ps1`, the README, and a 31 MB `ghostty.exe`.
- Fourth full native test run, after the config errors dialog, MSIX
  tool, and UI Automation (value, notifications, text pattern): 4,076
  passed, 61 skipped, 0 failed, exit 0.
- Fifth full native test run, after light/dark mode, the tab overview,
  undo for tabs, splits, and windows, the UIA selection, `font-thicken`,
  and dragging tabs between windows: 4,079 passed, 61 skipped, 0 failed,
  exit 0. (The "failed command" line in the log is the test binary's
  stderr output, not a failure.) An earlier attempt was stopped by Claude
  Code for low memory; running the lib-vt tests and the full suite one
  at a time worked.
- Sixth full native test run, after `window-subtitle`,
  `window-title-font-family`, `split-preserve-zoom`, the unwind tables
  fix, and the 64 KiB read buffer: 4,079 passed, 61 skipped, 0 failed,
  exit 0. Claude Code stops idle background jobs when memory runs low,
  so this ran in the background while foreground calls waited on it.
- Seventh full native test run, after the FreeType family name fix:
  4,079 passed, 61 skipped, 0 failed, exit 0.
- Eighth full native test run, after the stress test fixes (redo and
  closing all windows from a posted message): 4,079 passed, 61 skipped,
  0 failed, exit 0.
- Ninth full native test run, after releasing UI Automation's references
  at exit: 4,079 passed, 61 skipped, 0 failed, exit 0.
- Tenth full native test run, after the clipboard confirmation previews
  (with the new `writePreview` test): 4,080 passed, 61 skipped, 0 failed,
  exit 0.
- Eleventh full native test run, after Ctrl+V pastes on Windows (with
  its default keybind test): 4,081 passed, 61 skipped, 0 failed, exit 0.
- Twelfth full native test run, after the child environment fixes:
  4,081 passed, 61 skipped, 0 failed, exit 0.
- Thirteenth full native test run, after opening the config in an
  editor: 4,081 passed, 61 skipped, 0 failed, exit 0.
- Fourteenth full native test run, after the Windows crash reports (with
  the `Utf16Buf` test): 4,082 passed, 61 skipped, 0 failed, exit 0. A
  ReleaseFast build also succeeded.
- Fifteenth full native test run, after logging to the debug output:
  4,082 passed, 61 skipped, 0 failed, exit 0.
- Sixteenth full native test run, after the XDG fix (with its Windows
  test): 4,083 passed, 61 skipped, 0 failed, exit 0.
- Seventeenth full native test run, after expanding `~/` on Windows (with
  the `expandHomeWindows` test): 4,084 passed, 61 skipped, 0 failed, exit 0.
- Eighteenth full native test run, after using USERPROFILE as the home
  directory: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Nineteenth full native test run, after the tab bar tooltips (linking
  comctl32): 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twentieth full native test run, after UI Automation for the tab bar:
  4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-first full native test run, after the tab bar buttons for UI
  Automation: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-second full native test run, after giving command palette items
  text: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-third full native test run, after the handle leak fix:
  4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-fourth full native test run, after quick-terminal-space-behavior
  for virtual desktops: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-fifth full native test run, after restoring windows after a
  reboot: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-sixth full native test run, after using a custom class as the
  AppUserModelID: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-seventh full native test run, after the jump list's class
  argument: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-eighth full native test run, after per-class window state and
  restarts: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Twenty-ninth full native test run, after using the button message's
  position for mouse presses: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Thirtieth full native test run, after using the wheel message's
  position: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Thirty-first full native test run, after Ctrl+wheel changing the font
  size: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Thirty-second full native test run, after adding up partial notches for
  Ctrl+wheel: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Thirty-third full native test run, after adding up horizontal wheel
  fractions: 4,084 passed, 61 skipped, 0 failed, exit 0.
- Thirty-fourth full native test run, after mapping Linux working
  directories from WSL (with the `linuxToShare` test): 4,085 passed, 61
  skipped, 0 failed, exit 0.
- Package check (2026-10-26): `package.ps1` built a ReleaseSafe zip
  from c3364da81 with `bin\ghostty.exe` (32 MB), `install.ps1`, the
  README, and `share` (resources, terminfo, shell completions). The
  extracted `ghostty.exe +version` reported that commit, and the app ran
  with GHOSTTY_RESOURCES_DIR and TERMINFO pointing into the package's
  `share` (with backslashes).
- Thirty-fifth full native test run, after the invalid working directory
  fix (with the `windowsIsDirectory` test): 4,086 passed, 61 skipped, 0
  failed, exit 0. The packaged ReleaseSafe build also ran stress seeds 12
  and 13 (350 steps) without a fault.
- Thirty-sixth full native test run, after the COMSPEC fallback (with
  the `windowsIsFile` test): 4,087 passed, 61 skipped, 0 failed, exit 0.
- Thirty-seventh full native test run, after the "command couldn't be
  started" message: 4,087 passed, 61 skipped, 0 failed, exit 0.
- Thirty-eighth full native test run, after the Git Bash shell
  integration fix: 4,087 passed, 61 skipped, 0 failed, exit 0.
- Thirty-ninth full native test run, after quoting an unquoted command
  path: 4,089 passed, 61 skipped, 0 failed, exit 0.
- Fortieth full native test run, after sending text without a key as a
  key press: 4,089 passed, 61 skipped, 0 failed, exit 0.
- Forty-first full native test run, after compiling the terminfo entry:
  4,091 passed, 61 skipped, 0 failed, exit 0.
- A local pass of the UI tests (2026-11-08, at 994c08031 plus the screen
  reader tab work, debug build, locked desktop): the 25 that run outside
  CI all passed (cli-ipc, color-query, command-palette, compact-tabs,
  context-menu, device-lost, handoff, minimize, mouse-capture,
  output-frames, overlays, search, flood, session-restore, tab-close-uia,
  tab-reorder, tabs, titlebar-tabs, uia-events, window-options,
  window-theme, smoke with cmd, and the PowerShell integration) except
  translucent, which captures the screen (`CopyFromScreen`: "The handle is
  invalid" on a locked desktop) and passes in CI. The other 18 only run in
  CI, where they passed (run 42489816690).
- Fork CI run 41232795840 (2026-10-31), after the exit message and Git
  Bash path fixes: the x64 and ARM64 test suites, the MSIX install, and
  libghostty-vt with MSVC all passed.
- The fork CI's ARM64 job failed twice in a row within seconds while
  configuring ("configuration failed: FileNotFound"), after one run failed
  to fetch a dependency: setup-zig had saved that run's incomplete cache,
  and later runs restored it. The ARM64 job no longer uses the saved
  cache (`use-cache: false`), and run 41278668829 passed in full. If the
  x64 jobs ever fail the same way, do the same there.
- IME in CI (`test/windows/ime.ps1`, allowed to fail while new): run
  41284416999 installed the Japanese language capability on the runner
  (about 15 minutes) and added the Microsoft IME, but the keys arrived as
  plain "nihonn": the IME wasn't on. A language change request posted
  from another process left the terminal's layout US (04090409), so the
  script now switches with Win+Space, as a user does (the terminal leaves
  WM_INPUTLANGCHANGEREQUEST to DefWindowProc), then opens the IME in
  Hiragana. Run 41293609693 passed: the layout became 04110411, and
  typing "nihon", Space, and Enter put the kanji (U+65E5 U+672C) into cmd
  through the IME's composition and result strings. This is the IME
  check from the discussion's list, done with a real IME; the step stays
  allowed to fail since it depends on the runner image's languages.
- The inspector's buttons can't be clicked with posted messages: ImGui's
  Win32 backend calls `TrackMouseEvent` on mouse moves, and with the real
  cursor elsewhere Windows sends `WM_MOUSELEAVE` right away, so clicks
  have no position. The export dialog needs a manual check.
- Single instance, checked natively: with one instance running, a second
  plain launch logged "opened this launch in the running instance",
  exited, and the first instance showed a second window; a launch with
  `--font-size=20` logged "running as a separate instance" and kept its
  own window. Unit test: `launchArguments`. After terminal launch
  detection, launches from PowerShell in `C:\Users` and then `C:\Code`
  opened windows in those directories (the second via forwarding).

## Next steps (2026-10-26)

- UI tests that type need a focus guard. Twice, `SetForegroundWindow`
  from the test script failed, and the synthetic keys ("line 3") went to
  the Claude Code terminal instead, interrupting the session. Prefer
  posting messages to Ghostty's own windows (`WM_KEYDOWN`/`WM_CHAR` to a
  surface or edit control, `WM_SYSCOMMAND` for menu items, mouse messages
  to overlays), which is how most features here were checked. Posted keys
  can't carry modifiers, since those come from `GetKeyState`. UI
  Automation (the .NET client) works for checking accessibility.
- Pending manual checks (they need an unlocked desktop, real input, a
  screen reader, or another machine):
  - Quick terminal sliding out, the touch keyboard showing, the terminal
    IO export dialog
  - Done in CI: touch scrolling (a software finger injected with
    `InjectTouchInput` panned down, and earlier lines scrolled into view,
    `test/windows/touch-scroll.ps1`, run 41281536372),
    `window-step-resize` while dragging the
    window's corner (a real 137x91 px drag changed the client area by
    whole cells, `test/windows/desktop-input.ps1`, run 41273699216),
    dragging a file onto a terminal (a real OLE drag with the
    real mouse, `test/windows/drag-drop.ps1`, run 41270878360, which
    pasted its quoted path into cmd), and `focus-follows-mouse` (real
    mouse moves between splits, run 41247475902)
  - Narrator announcing new output
  - A Start menu or Explorer launch opening at home: checked by starting
    `ghostty.exe` through `explorer.exe` (as a shortcut or double-click
    does); cmd opened in `C:\Users\<user>`. Starting it the way the
    Start menu does is checked in the fork's CI
    (`test/windows/start-menu.ps1`, run 41263133923): the MSIX by its app
    ID, and the zip's `install.ps1` shortcut, each opened a window from
    the installed location, and `install.ps1 -Uninstall` removed the
    shortcut and the files.
  - Installing the MSIX (`Add-AppxPackage -AllowUnsigned`): done in the
    fork's CI, on a throwaway runner
  - Blur on Windows 10
  - (Done: `conpty.dll` from the ConPTY package works, and passes Kitty
    graphics APCs; an earlier check that said otherwise had a bug)
  - PowerShell 7: the fork's CI now runs
    `test/windows/powershell-integration.ps1` with both 5.1 and 7, which
    loads the integration and checks its prompt's escape sequences
    (OSC 7, 2, 133 with a failed command's exit code, and the cursor).
    It passed with both in run 41238800703 (2026-10-31).
  - PowerShell 7 in the app: `test/windows/smoke.ps1` starts Ghostty with
    a shell on the CI runner's desktop (no GPU, so the WARP software
    renderer), waits for the prompt through UI Automation, types a `cd`,
    and checks the log for shell integration and the new pwd. In run
    41242035483 it passed with PowerShell 7 and Windows PowerShell. (The
    cmd run failed because cmd's `cd` doesn't change drives, and the
    runner's checkout is on D:; it now uses `cd /d`.) Run 41244466094
    passed with all three, and everything else.
  - Switching the Windows app mode to dark while Ghostty runs
- Remaining work: a signed package, which needs a certificate.
