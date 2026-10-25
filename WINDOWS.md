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
- [x] CI job that builds and tests the app on Windows.

### Known limitations

- ConPTY (as used with no flags) doesn't pass through APC or OSC 8
  sequences. Kitty graphics payloads leak into the terminal as text and
  hyperlinks are dropped. Fixing this needs a ConPTY passthrough mode (if
  the OS supports one) or bypassing ConPTY for capable programs.
- ConPTY requests win32-input-mode (DECSET 9001), which Ghostty doesn't
  implement yet; ConPTY falls back to plain VT input.

### Next

- [x] Verify IME with Microsoft Pinyin, Japanese IME, and others
- [x] Fix tab-header close crashing the window when there are multiple
      tabs (active index and split focus must be valid during teardown)
- [x] Shell integration for wsl
  - [ ] Map WSL Linux paths (`/home/...`) to `\\wsl.localhost\<distro>\...`
        so new tabs can start there
- [x] Choose a registered WSL distribution by name from the shell menu
- [x] Choose Command Prompt, Windows PowerShell, PowerShell, WSL, or
      the configured command when opening a new tab from the tab bar
- [x] `unfocused-split-opacity` and `unfocused-split-fill`
- [x] Drag tabs to reorder within a window
- [x] Move a tab to a new window (`move_tab_to_new_window`)
- [ ] Background opacity/blur (needs a DirectComposition swap chain)
- [ ] Single instance and IPC (`+new-window`)
- [ ] Terminal inspector (needs a Dear ImGui D3D11 backend)
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
- [ ] DirectWrite font discovery and rendering
- [ ] Packaging (installer and MSIX) and release builds
- [ ] Unimplemented apprt actions (as of 2026-10-25)
  - [ ] Window management
    - [x] `reset_window_size`, `resize_window`, `size_limit`
    - [x] `goto_window`, `present_terminal`, `float_window`,
          `toggle_window_decorations` (and `window-decoration=none`)
    - [x] `toggle_visibility`
- [x] Global keybinds (`RegisterHotKey`)
  - [x] Titles: `set_tab_title`, `set_window_title`,
        `copy_title_to_clipboard`, `prompt_title`
  - [x] Hover link preview (`mouse_over_link`)
  - [x] `show_child_exited`: not needed; the core's fallback prints
        "Process exited" in the terminal
  - [ ] `readonly` and `renderer_health` indicators
  - [ ] Search UI (`start_search`, `end_search`, `search_total`,
        `search_selected`)
  - [x] Scrollbar (`scrollbar`)
  - [ ] Key table / sequence indicators (`key_table`, `key_sequence`)
  - [ ] Command palette and quick terminal
- [x] Share built-in compiled shader bytecode across surfaces
- [x] Cache compiled custom shader bytecode across surfaces

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
