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
- Keep C++ to a minimum. This port is pure Zig plus Win32 and COM.
- Land small, reviewable, incremental changes.

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
      and images (atlases), background images, and custom shaders.
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

### Next

- [ ] Verify IME with Microsoft Pinyin, Japanese IME, and others
- [ ] `unfocused-split-opacity`
- [ ] Tab drag to reorder, and moving a tab to a new window
- [ ] Background opacity/blur (needs a DirectComposition swap chain)
- [ ] Single instance and IPC (`+new-window`)
- [ ] Terminal inspector (needs a Dear ImGui D3D11 backend)
- [ ] Desktop notifications, progress reports (taskbar), and the bell
      attention flash
- [ ] Shell integration for PowerShell
- [ ] DirectWrite font discovery and rendering
- [ ] Packaging (installer and MSIX) and release builds
- [ ] Share compiled shader bytecode across surfaces (each surface
      currently compiles its shaders)
