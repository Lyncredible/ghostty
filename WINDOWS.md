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
libghostty-vt), but "no +10k diff PRs". This branch is about 7.4k lines
and must not go upstream as one PR. Candidates to upstream separately,
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
  - Each surface has its own D3D11 device and context.
  - Frames render to an offscreen target, which is copied into a flip-model
    swap chain on the surface `HWND`.
  - Embedders can use it through the new `GHOSTTY_PLATFORM_WINDOWS`
    platform, which passes an `HWND`.
- **Shaders:** `src/renderer/shaders/shaders.hlsl` is a hand port of the
  GLSL shaders. It's compiled at runtime with `D3DCompile`
  (`d3dcompiler_47.dll` ships with Windows).
  - Built-in shader bytecode is compiled once per process and reused when
    creating pipelines for each surface's D3D device.
  - Custom shaders go GLSL → SPIR-V → HLSL via spirv-cross.
- **PTY:** ConPTY (`src/pty.zig`, `src/termio/Exec.zig`).
- **Fonts:** the existing `freetype_windows` backend.

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
- `-Doptimize=ReleaseFast` with the GNU ABI fails inside Zig 0.17 while
  compiling MinGW's own CRT (`.seh_ directive must appear within an active
  frame`). This is a Zig bug. Use ReleaseSafe, or the MSVC ABI.
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
- [x] Win32 apprt: window, message loop, and cross-thread wakeups.
  - [x] Per-monitor DPI, resizing, focus, and occlusion.
  - [x] Keyboard: layouts, dead keys, Ctrl/Alt/AltGr handling, and
        physical keys.
  - [x] Basic IME: the system composition window, placed at the cursor.
  - [x] Mouse buttons, motion, wheel, and cursor shapes.
  - [x] Touch screens: a one finger vertical pan scrolls (with inertia)
        through `WM_GESTURE`, instead of selecting text with emulated
        mouse input. Needs a check on a touch screen.
  - [x] Plain text clipboard, with CRLF handling and unsafe paste
        confirmation.
  - [x] Ctrl+C copies when there's a selection, like Windows Terminal,
        and is still an interrupt otherwise (a performable default
        keybind on Windows). Unit tested; needs a check with real keys.
  - [x] Ctrl+V pastes too, like Windows Terminal: through ConPTY, cmd
        otherwise gets a ^V instead of the console's paste. It's
        performable, and `keybind = ctrl+v=unbind` gives it back to
        programs such as Vim (visual block). The menus still show
        Shift+Insert. Unit tested; needs a check with real keys.
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
- [x] libghostty-vt builds on Windows: `zig build -Demit-lib-vt
      -Dtarget=x86_64-windows-gnu` emits `ghostty-vt.dll` with its import
      library `ghostty-vt.lib`, and `ghostty-vt-static.lib`. Checked
      (2026-10-26) by compiling `example/c-vt/src/main.c` with `zig cc`:
      linked against the import library (with the DLL next to it) and
      statically (with `-DGHOSTTY_STATIC`, since the headers otherwise
      declare `dllimport`), both printed the parsed OSC title "hello".
  - [ ] The MSVC target: this machine has no Visual Studio or Windows SDK
        ("LibCStdLibHeaderNotFound").
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
  - [ ] Run it on an ARM64 machine
- [x] Light and dark themes: the app reports the Windows app mode
      (`AppsUseLightTheme`) to the core at startup and on
      `WM_SETTINGCHANGE`, so `theme = light:X,dark:Y` and color scheme
      reports (mode 2031) follow the system. Checked with
      `--theme=light:Builtin Light,dark:Builtin Dark` in light mode: the
      background was white, and a settings change message kept it.
  - [ ] Switch Windows to dark mode while it runs (not done here, since
        it changes the whole desktop)
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
- [x] `font-thicken` and `font-thicken-strength` with FreeType (so on
      Windows): outlines are emboldened by a quarter of a pixel up to a
      whole pixel overall, by strength. Measured on a screenshot of the
      cmd banner (pixels brighter than half): 6,463 normally, 6,850 at
      strength 0, and 8,403 at 255; the text stays crisp.
- [x] `window-show-tab-bar` is documented as working on Windows.
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
- [x] Font fallback check (2026-10-26): a UTF-8 file with emoji (with a
      skin tone, a flag, and a variation selector), Chinese, Japanese,
      Korean, box drawing and shades, math symbols, Arabic, Hebrew, and
      combining marks, shown with `type` after `chcp 65001`, all drew
      (right-to-left text in logical order, as in most terminals). Before
      `chcp 65001`, cmd decodes the file with the system code page (936
      here), as in Windows Terminal; that isn't ours to change.
- [x] CLI actions on Windows: `+version`, `+list-fonts`, `+list-themes`,
      `+list-keybinds`, `+list-colors`, `+list-actions`, `+show-config`,
      `+validate-config`, `+help`, `+show-face`, `+explain-config`, and
      `+boo` all ran and exited 0.
  - [x] `+list-fonts` printed family names as raw UTF-16BE (a NUL before
        each letter): FreeType faces took the first family name in the
        name table, and only decoded Microsoft BMP names, while Windows
        fonts list a Unicode-platform name first. Now the US English
        Microsoft name is preferred, then any UTF-16 name, decoded
        without assuming alignment. The family name fallback in font
        discovery uses the same function.
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

- The inbox ConPTY drops APC sequences, so the Kitty graphics protocol
  doesn't work. OSC 8 hyperlinks do pass through on build 26100 (checked:
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
    - [x] `package.ps1 -BundleConpty` downloads that package (version and
          SHA-256 pinned), and puts its `conpty.dll` and `OpenConsole.exe`
          for the target architecture in `bin`. Checked: the zip has both
          next to `ghostty.exe`. Use it to try the item above.

### Next

- [x] Verify IME with Microsoft Pinyin, Japanese IME, and others
- [x] Fix tab-header close crashing the window when there are multiple
      tabs (active index and split focus must be valid during teardown)
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
      "Close Tab", "New Tab", "New Tab With a Shell", and "Menu", from one
      common controls tooltip over the tab bar that asks for its text
      (`TTN_GETDISPINFOW`) based on what's under the mouse. Checked that
      the tooltip is created; it follows the real cursor, so showing it
      needs a manual check.
  - [ ] Manual check: hover a tab and the buttons
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
    - [ ] Manual check: a Start menu or Explorer launch opens at home
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
          tooltips ("New Tab", "New Tab With a Shell", "Menu") with the
          Invoke pattern, which presses them from a posted message (the
          menus run a modal loop). Checked: invoking "New Tab" opened a
          second tab.
  - [x] The text pattern's selection is the terminal's selection (its
        visible part), or else the cursor as a caret, and selection
        changes raise `TextSelectionChanged` (posted from
        `selection_changed`, since the core holds the renderer mutex
        there). Checked with the .NET UIA client: nothing selected gave
        an empty range, and after `select_all` the selection was the
        screen's 109 characters. Unit test: `viewportSelection`. This
        fixed a crash freeing text snapshots (the UTF-16 text lost its
        sentinel, so the free had the wrong length).
    - [ ] Manual check that screen readers get the event: on this
          locked desktop no UIA events reach the .NET client, even from
          a standard Edit control.
- [x] Taskbar jump list with a "New Window" task, which starts
      `ghostty.exe` again (single instance opens the window in the running
      app). Checked: the shell wrote the custom destinations file with the
      task and the executable's path.
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
- [x] Font discovery: FreeType scans the system and user font folders
      (`+list-fonts --family=Consolas` takes about 0.1 s here)
  - [x] Codepoint fallback asks DirectWrite's system font fallback
        (`IDWriteFontFallback::MapCharacters`, with the user's locale)
        first, then scans the font folders as before. Scanning picked
        whichever file came first: Arial Unicode MS for Japanese here. Now
        Japanese gets Yu Gothic UI and Korean gets Malgun Gothic.
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
        uploads it as a 14-day artifact (not run yet; needs a push)
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
    - [ ] A signed package for Windows 10 and the Store (needs a
          certificate)
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
      - [ ] Manual check: sliding out (toggling hides only when the quick
            terminal is in front, which a locked test desktop never is)
  - [x] Command palette (`toggle_command_palette`): a field over an
        owner-drawn list of the `command-palette-entry` commands (title,
        description, shortcut) and "Focus: <title>" entries for every
        terminal, like GTK. Every word of the query must appear in the
        title or action (`new_split:right`). Up/Down/PageUp/PageDown move,
        Enter or a click runs, Escape or focus loss closes. A layered
        child of the surface, like the search bar. Checked natively: it
        opened from the menu, filtered, and Enter on `new_split:right`
        split the terminal.
- [x] Config options the Win32 apprt ignored (found 2026-10-25)
  - [x] `focus-follows-mouse`: hovering a split focuses it when the
        cursor really moves, the window is in front, no button is held,
        and focus is on another terminal (never a search field, palette,
        or dialog). Needs a check on an unlocked desktop.
  - [x] Dropping files on a terminal pastes their paths through the
        normal paste path (bracketed paste, unsafe paste checks),
        separated by spaces like Windows Terminal. For cmd/PowerShell,
        paths with spaces or special characters are double quoted; for
        WSL (the command runs `wsl.exe`) they become Linux paths
        (`/mnt/c/...`, `\\wsl$\<distro>\...` to `/...`) in single
        quotes when needed. Unit tested; a real drop needs a manual check.
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
  - [x] A ☰ button at the right end of the tab bar (the tab bar is hidden
        with one tab under `window-show-tab-bar=auto`)
  - [x] A terminal context menu for `right-click-action = context-menu`,
        shown on button release like other Windows apps
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
- Bell handling now copies each surface's `bell-features` (including on
  reload), gates `MessageBeep` on `system`, and requests taskbar attention
  only for background windows. `FLASHW_TIMERNOFG` stops the flash on
  activation. Native Debug build passes; visual taskbar verification is
  still pending.
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
  Performance with heavy custom shaders and images still needs profiling.
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
  bytecode remains uncached; startup timing has not been benchmarked.
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
  `\\wsl$\Ubuntu\home\yuan` reports `/home/yuan`. Not yet tested through
  the Ghostty UI.
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
  opacity with and without blur. Not yet tested: splits, the scrollbar
  and other overlays over a translucent terminal, and Windows 10.
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
  - Dragging files onto a terminal, `focus-follows-mouse`,
    `window-step-resize` while dragging an edge, and touch scrolling
  - Narrator announcing new output
  - A Start menu or Explorer launch opening at home
  - Installing the MSIX (`Add-AppxPackage -AllowUnsigned`)
  - Blur on Windows 10
  - (Done: `conpty.dll` from the ConPTY package works, but doesn't pass
    Kitty graphics APCs either)
  - PowerShell 7
  - Switching the Windows app mode to dark while Ghostty runs
- Remaining work: a signed package, which needs a certificate.
