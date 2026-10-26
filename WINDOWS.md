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
  - [x] Plain text clipboard, with CRLF handling and unsafe paste
        confirmation.
  - [x] Titles, maximize, borderless fullscreen, and initial size.
  - [x] Close confirmation, open URL/config, and config reload.
  - [x] Tabs: new, close (this/other/right), goto, and move.
  - [x] Custom tab bar themed from the terminal colors: close buttons,
        middle-click close, and a new tab button.
  - [x] Splits: new, goto (including spatial), resize, equalize, zoom, and
        draggable dividers.
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
    - [ ] Not verified: running the downloaded package's binaries was
          blocked in the dev session. Check that `using conpty.dll` is
          logged, shells work, and a Kitty graphics APC (`ESC _ G a=q ;
          ESC \`) reaches Ghostty ("executing kitty graphics command").
    - [ ] If it works, add an opt-in to `dist/windows/package.ps1` that
          bundles the package's `conpty.dll` and `OpenConsole.exe`.

### Next

- [x] Verify IME with Microsoft Pinyin, Japanese IME, and others
- [x] Fix tab-header close crashing the window when there are multiple
      tabs (active index and split focus must be valid during teardown)
- [x] Shell integration for wsl
  - [x] Map WSL Linux paths (`/home/...`) to `\\wsl$\<distro>\...`
        so new tabs can start there (end-to-end UI check pending)
- [x] Choose a registered WSL distribution by name from the shell menu
- [x] Choose Command Prompt, Windows PowerShell, PowerShell, WSL, or
      the configured command when opening a new tab from the tab bar
- [x] `unfocused-split-opacity` and `unfocused-split-fill`
- [x] Drag tabs to reorder within a window
- [x] Move a tab to a new window (`move_tab_to_new_window`)
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
  - [ ] Installer or MSIX (needs signing and an app identity)
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
- Single instance, checked natively: with one instance running, a second
  plain launch logged "opened this launch in the running instance",
  exited, and the first instance showed a second window; a launch with
  `--font-size=20` logged "running as a separate instance" and kept its
  own window. Unit test: `launchArguments`. After terminal launch
  detection, launches from PowerShell in `C:\Users` and then `C:\Code`
  opened windows in those directories (the second via forwarding).

## Next steps (2026-10-25, evening)

- UI tests that type need a focus guard. Twice, `SetForegroundWindow`
  from the test script failed, and the synthetic keys ("line 3") went to
  the Claude Code terminal instead, interrupting the session. Prefer
  posting messages to Ghostty's own windows (`WM_KEYDOWN`/`WM_CHAR` to a
  surface or edit control, `WM_SYSCOMMAND` for menu items), which is how
  the menus, palette, search, inspector, and win32 input mode were
  checked. Posted keys can't carry modifiers, since those come from
  `GetKeyState`.
- Pending manual checks (they need an unlocked desktop, real input, or
  another machine):
  - Quick terminal sliding out, the touch
    keyboard showing, the terminal IO export dialog
  - A Start menu or Explorer launch opening at home
  - Blur on Windows 10
  - `conpty.dll` from the ConPTY package (Kitty graphics APCs)
  - WSL `\wsl$` working directory inheritance through the UI,
    PowerShell 7
- Remaining work: an MSIX package (needs the Windows SDK and signing),
  and bundling `conpty.dll` once it's verified.
