//! The Win32 application runtime. This owns the main thread message loop
//! and the top-level windows.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");
const cli = @import("../../cli.zig");
const global = @import("../../global.zig");

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");
const DimOverlay = @import("DimOverlay.zig");
const BellBorder = @import("BellBorder.zig");
const LinkPreview = @import("LinkPreview.zig");
const Scrollbar = @import("Scrollbar.zig");
const Badge = @import("Badge.zig");
const SearchBar = @import("SearchBar.zig");
const CommandPalette = @import("CommandPalette.zig");
const InspectorWindow = @import("InspectorWindow.zig");
const SaveState = @import("SaveState.zig");
const JumpList = @import("JumpList.zig");
const SplitDrag = @import("SplitDrag.zig");
const shell = @import("shell.zig");
const Ipc = @import("Ipc.zig");
const Overrides = @import("Overrides.zig");
const Taskbar = @import("Taskbar.zig");
const Notifier = @import("Notifier.zig");
const BellAudio = @import("BellAudio.zig");
const GlobalKeys = @import("GlobalKeys.zig");

const log = std.log.scoped(.win32);

/// Posted to our message window to wake up the event loop.
const WM_GHOSTTY_WAKEUP = c.WM_APP + 1;

/// Posted at startup to show configuration errors once a window is up.
const WM_GHOSTTY_CONFIG_ERRORS = c.WM_APP + 3;

/// The ID of the timer on our message window for the quit timer.
const quit_timer_id = 1;

/// The window class names we register.
pub const window_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
pub const surface_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");
pub const tab_bar_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTabBar");
const message_class = Ipc.message_class;

core_app: *CoreApp,

/// The configuration for the app.
config: Config,

/// The module instance handle, used to register window classes.
hinstance: c.HINSTANCE,

/// A hidden window that we post wakeups to. Wakeups can come from
/// any thread and PostMessage is thread-safe.
///
/// This would ideally be a message-only window, but HWND_MESSAGE (-3)
/// isn't a validly aligned pointer for Zig. A window that is never
/// shown works just as well for posted messages.
msg_hwnd: c.HWND,

/// Taskbar COM interface and the Explorer notification message.
taskbar: Taskbar,
taskbar_button_created: c.UINT,

/// Desktop notifications.
notifier: Notifier,

/// The custom bell sound, for the `audio` bell feature.
bell_audio: BellAudio = .{},

/// System-wide (`global:`) keybinds.
global_keys: GlobalKeys,

/// The window to activate when toggle_visibility shows our windows.
hidden_active: ?*Window = null,

/// The quick terminal, once it's been opened.
quick_terminal: ?*Window = null,

/// Set by toggle_background_opacity to make translucent windows opaque.
background_opaque: bool = false,

/// All of our open top-level windows.
windows: std.ArrayList(*Window) = .empty,

/// True once we've started quitting, so we don't quit twice.
quitting: bool = false,

/// True while closing every window at once, which saves the session first.
closing_all: bool = false,

/// The single instance lock for our app class, held while we run.
instance_mutex: ?c.HANDLE = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;
    const alloc = core_app.alloc;

    // Load our configuration
    var config = Config.load(alloc) catch |err| err: {
        log.err("error loading config, using default err={}", .{err});
        break :err try Config.default(alloc);
    };
    errdefer config.deinit();

    // If we had configuration errors, log them.
    if (config._diagnostics.items().len > 0) {
        for (config._diagnostics.items()) |diag| {
            log.warn("configuration error: {f}", .{diag});
        }
    }

    // Single instance: a launch that the running instance of our class can
    // open as a new window is handed to it, and we exit without a window.
    const class = config.class orelse Ipc.default_class;
    var instance_mutex: ?c.HANDLE = null;
    switch (Ipc.claim(class)) {
        .primary => |mutex| instance_mutex = mutex,
        .failed => log.warn("unable to create the single instance lock", .{}),
        .secondary => if (forwardLaunch(alloc, &config, class)) {
            log.info("opened this launch in the running instance", .{});
            std.process.exit(0);
        } else {
            log.info("running as a separate instance", .{});
        },
    }
    errdefer if (instance_mutex) |mutex| {
        _ = c.CloseHandle(mutex);
    };

    // Note: we render at the native resolution of each monitor. The
    // per-monitor DPI awareness for that is set by our application
    // manifest (dist/windows/ghostty.manifest).

    // For util.paintOpaque.
    _ = c.BufferedPaintInit();
    errdefer _ = c.BufferedPaintUnInit();

    const hinstance: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    try registerClasses(hinstance);
    errdefer unregisterClasses(hinstance);

    // The message window's title is our class, so +new-window can find us.
    var title_buf: [256]u16 = undefined;
    const title = Ipc.windowTitle(&title_buf, config.class orelse Ipc.default_class);
    const msg_hwnd = c.CreateWindowExW(
        0,
        message_class,
        if (title) |t| t.ptr else null,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(msg_hwnd);

    const taskbar = Taskbar.init();
    const taskbar_button_created = c.RegisterWindowMessageW(
        std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated"),
    );

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .msg_hwnd = msg_hwnd,
        .taskbar = taskbar,
        .taskbar_button_created = taskbar_button_created,
        .notifier = .init(msg_hwnd, util.loadIcon(hinstance, 1)),
        .global_keys = .init(alloc, msg_hwnd),
        .instance_mutex = instance_mutex,
    };

    _ = c.SetWindowLongPtrW(msg_hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.global_keys.update(&self.config);
    JumpList.update();
    if (self.config._diagnostics.items().len > 0) {
        _ = c.PostMessageW(msg_hwnd, WM_GHOSTTY_CONFIG_ERRORS, 0, 0);
    }
}

/// Hand this launch to the running instance of our class. Returns false if
/// we should run as our own instance instead, for example because the
/// launch has options that only apply to a new instance.
fn forwardLaunch(alloc: Allocator, config: *const Config, class: []const u8) bool {
    // With no initial window there's nothing to open, and an instance is
    // already running.
    if (!config.@"initial-window") return true;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    {
        var it = cli.args.argsIterator(arena_alloc, global.args()) catch return false;
        defer it.deinit();
        while (it.next()) |arg| {
            args.append(arena_alloc, arena_alloc.dupe(u8, arg) catch return false) catch return false;
        }
    }

    // Open the window where this launch would have.
    const working_directory: ?[]const u8 = if (config.@"working-directory") |wd| switch (wd) {
        .path => |path| path,
        .inherit => std.Io.Dir.cwd().realPathFileAlloc(global.io(), ".", arena_alloc) catch null,
        .home => null,
    } else null;

    const arguments = (Ipc.launchArguments(arena_alloc, args.items, working_directory) catch
        return false) orelse return false;
    return Ipc.forwardLaunch(arena_alloc, class, arguments);
}

fn registerClasses(hinstance: c.HINSTANCE) !void {
    // The icon ID is from dist/windows/ghostty.rc
    const icon = util.loadIcon(hinstance, 1);

    const classes = [_]c.WNDCLASSEXW{
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = Window.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = icon,
            .hCursor = util.loadSystemCursor(util.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = window_class,
            .hIconSm = icon,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            // The core does its own click counting, so we don't set
            // CS_DBLCLKS: every click should be a button down message.
            .style = 0,
            .lpfnWndProc = Surface.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = surface_class,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            // Double clicking empty space in the tab bar opens a tab.
            .style = c.CS_DBLCLKS,
            .lpfnWndProc = TabBar.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = util.loadSystemCursor(util.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = tab_bar_class,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = DimOverlay.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = DimOverlay.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = BellBorder.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = BellBorder.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = LinkPreview.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = LinkPreview.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = Scrollbar.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = util.loadSystemCursor(util.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = Scrollbar.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = Badge.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = Badge.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = SearchBar.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = util.loadSystemCursor(util.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = SearchBar.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = CommandPalette.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = util.loadSystemCursor(util.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CommandPalette.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = SplitDrag.Handle.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = SplitDrag.Handle.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = SplitDrag.DropZone.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = SplitDrag.DropZone.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = InspectorWindow.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = icon,
            .hCursor = util.loadSystemCursor(util.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = InspectorWindow.class_name,
            .hIconSm = null,
        },
        .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = msgWndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = message_class,
            .hIconSm = null,
        },
    };

    for (&classes) |*class| {
        if (c.RegisterClassExW(class) == 0) {
            log.err("failed to register window class err={}", .{c.GetLastError()});
            return error.RegisterClassFailed;
        }
    }
}

fn unregisterClasses(hinstance: c.HINSTANCE) void {
    _ = c.UnregisterClassW(window_class, hinstance);
    _ = c.UnregisterClassW(surface_class, hinstance);
    _ = c.UnregisterClassW(tab_bar_class, hinstance);
    _ = c.UnregisterClassW(DimOverlay.class_name, hinstance);
    _ = c.UnregisterClassW(BellBorder.class_name, hinstance);
    _ = c.UnregisterClassW(LinkPreview.class_name, hinstance);
    _ = c.UnregisterClassW(Scrollbar.class_name, hinstance);
    _ = c.UnregisterClassW(Badge.class_name, hinstance);
    _ = c.UnregisterClassW(SearchBar.class_name, hinstance);
    _ = c.UnregisterClassW(CommandPalette.class_name, hinstance);
    _ = c.UnregisterClassW(InspectorWindow.class_name, hinstance);
    _ = c.UnregisterClassW(SplitDrag.Handle.class_name, hinstance);
    _ = c.UnregisterClassW(SplitDrag.DropZone.class_name, hinstance);
    _ = c.UnregisterClassW(message_class, hinstance);
}

pub fn run(self: *App) !void {
    // Surfaces start with the app's color scheme, so we report it first.
    self.updateColorScheme();

    // Create our initial window, if requested. Otherwise we start the
    // quit timer, as if the last window was just closed.
    if (self.config.@"initial-window") {
        if (!try self.restoreWindows()) _ = try self.newWindow(.{ .parent = null });
    } else {
        self.armQuitTimer();
    }

    var msg: c.MSG = undefined;
    while (true) {
        const ret = c.GetMessageW(&msg, null, 0, 0);
        if (ret == 0) break; // WM_QUIT
        if (ret < 0) {
            log.err("GetMessageW failed err={}", .{c.GetLastError()});
            return error.GetMessageFailed;
        }

        // TranslateMessage queues the WM_CHAR messages for key down
        // events, which our key handling reads from the queue.
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

/// Restore the saved session, for window-save-state. Returns false if
/// there wasn't one.
fn restoreWindows(self: *App) !bool {
    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    const state = SaveState.load(arena.allocator(), self) orelse return false;
    for (state.windows) |*window_state| {
        _ = self.newWindow(.{ .restored = window_state }) catch |err| {
            log.warn("error restoring a window err={}", .{err});
            continue;
        };
    }
    return self.windows.items.len > 0;
}

/// The only window other than the quick terminal, if there's just one.
pub fn lastWindow(self: *const App) ?*Window {
    var last: ?*Window = null;
    for (self.windows.items) |window| {
        if (window.quick) continue;
        if (last != null) return null;
        last = window;
    }
    return last;
}

pub fn terminate(self: *App) void {
    // Close any windows that are still open. This deinitializes their
    // surfaces, which must happen before the core app is destroyed.
    while (self.windows.items.len > 0) {
        self.windows.items[self.windows.items.len - 1].destroy();
    }
    self.windows.deinit(self.core_app.alloc);

    self.taskbar.deinit();
    self.notifier.deinit();
    self.bell_audio.deinit(self.core_app.alloc);
    self.global_keys.deinit();

    _ = c.DestroyWindow(self.msg_hwnd);
    unregisterClasses(self.hinstance);
    if (self.instance_mutex) |mutex| _ = c.CloseHandle(mutex);
    _ = c.BufferedPaintUnInit();
    self.config.deinit();
}

/// Called by CoreApp to wake up the event loop. This can be called
/// from any thread.
pub fn wakeup(self: *App) void {
    _ = c.PostMessageW(self.msg_hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
}

fn msgWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr != 0) {
        const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
        switch (msg) {
            WM_GHOSTTY_CONFIG_ERRORS => {
                self.showConfigErrors(&self.config);
                return 0;
            },

            WM_GHOSTTY_WAKEUP => {
                self.core_app.tick(self) catch |err| {
                    log.err("error ticking app err={}", .{err});
                };
                return 0;
            },

            c.WM_HOTKEY => {
                if (self.global_keys.action(wparam)) |action| {
                    self.core_app.performAllAction(self, action) catch |err| {
                        log.warn("error performing global keybind err={}", .{err});
                    };
                }
                return 0;
            },

            c.WM_COPYDATA => {
                const copy: *const c.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (copy.dwData != Ipc.magic) return 0;
                const data: [*]const u8 = @ptrCast(copy.lpData orelse return 0);
                return @intFromBool(self.handleIpc(data[0..copy.cbData]));
            },

            Notifier.WM_NOTIFY_ICON => {
                if (self.notifier.handleMessage(lparam)) |surface| {
                    self.presentSurface(surface);
                }
                return 0;
            },

            c.WM_TIMER => if (wparam == quit_timer_id) {
                _ = c.KillTimer(hwnd, quit_timer_id);
                // Only quit if no surfaces were opened in the meantime.
                if (self.core_app.surfaces.items.len == 0) self.quit();
                return 0;
            },

            else => {},
        }
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Create a new window. If a parent surface is given, the new
/// window inherits relevant properties from it (font size, cwd).
pub fn newWindow(self: *App, initial: Window.Initial) !*Window {
    const alloc = self.core_app.alloc;

    // Reserve space first: once a window adopts a moved tab, destroying
    // it on failure would also destroy that tab.
    try self.windows.ensureUnusedCapacity(alloc, 1);
    const window = try alloc.create(Window);
    window.init(self, initial) catch |err| {
        alloc.destroy(window);
        return err;
    };

    // From here on the window owns itself: destroying it frees it.
    self.windows.appendAssumeCapacity(window);
    window.show();
    return window;
}

/// The window that was most recently active, if any.
fn activeWindow(self: *App) ?*Window {
    const fg = c.GetForegroundWindow();
    for (self.windows.items) |window| {
        if (window.hwnd == fg) return window;
    }
    if (self.core_app.focusedSurface()) |surface| return surface.rt_surface.window;
    if (self.windows.items.len > 0) return self.windows.items[self.windows.items.len - 1];
    return null;
}

/// Play the configured bell sound, if any.
pub fn playBellAudio(self: *App) void {
    const path = self.config.@"bell-audio-path" orelse return;
    self.bell_audio.play(self.core_app.alloc, path, self.config.@"bell-audio-volume");
}

/// Handle a request from +new-window or +new-tab. The data is only valid
/// during this call.
fn handleIpc(self: *App, data: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const request = Ipc.decode(alloc, data) catch |err| {
        log.warn("invalid IPC request err={}", .{err});
        return false;
    };
    const overrides: Overrides = if (request.arguments) |args|
        Overrides.parse(alloc, args) catch return false
    else
        .none;
    log.debug("IPC request kind={} surface={}", .{ request.kind, request.surface_id });

    switch (request.kind) {
        .new_window => {
            const window = self.newWindow(.{ .overrides = overrides }) catch |err| {
                log.warn("error opening window from IPC err={}", .{err});
                return false;
            };
            window.present(window.activeSurface());
        },

        .toggle_quick_terminal => self.toggleQuickTerminal() catch |err| {
            log.warn("error toggling the quick terminal from IPC err={}", .{err});
            return false;
        },

        .new_tab => {
            // The window of the given surface, or the active window.
            const window = window: {
                if (request.surface_id != 0) {
                    for (self.core_app.surfaces.items) |rt_surface| {
                        if (rt_surface.core().id == request.surface_id) break :window rt_surface.window;
                    }
                }
                break :window self.activeWindow();
            } orelse {
                _ = self.newWindow(.{ .overrides = overrides }) catch return false;
                return true;
            };
            const tab = window.addTabWith(null, null, overrides) catch |err| {
                log.warn("error opening tab from IPC err={}", .{err});
                return false;
            };
            window.present(tab.focused);
        },
    }
    return true;
}

/// Bring the given surface to the front, if it still exists.
pub fn presentSurface(self: *App, surface: *CoreSurface) void {
    for (self.core_app.surfaces.items) |rt_surface| {
        if (rt_surface.core() == surface) {
            rt_surface.window.present(rt_surface);
            return;
        }
    }
}

/// Activate the window before or after the given one, in creation order.
fn gotoWindow(self: *App, from: *Window, direction: apprt.action.GotoWindow) bool {
    const len = self.windows.items.len;
    if (len <= 1) return false;
    const idx = std.mem.indexOfScalar(*Window, self.windows.items, from) orelse return false;
    const next = switch (direction) {
        .next => (idx + 1) % len,
        .previous => (idx + len - 1) % len,
    };
    const window = self.windows.items[next];
    window.present(window.activeSurface());
    return true;
}

/// Whether windows let the desktop show through the terminal background.
pub fn translucent(self: *const App) bool {
    return self.config.@"background-opacity" < 1 and !self.background_opaque;
}

/// Like macOS, switch all windows between their translucent background
/// and an opaque one. The renderer keeps drawing with the configured
/// opacity; surfaces paint the background color beneath it instead.
fn toggleBackgroundOpacity(self: *App) void {
    if (self.config.@"background-opacity" >= 1) return;
    self.background_opaque = !self.background_opaque;
    for (self.windows.items) |window| window.configChanged();
    for (self.core_app.surfaces.items) |surface| {
        _ = c.InvalidateRect(surface.hwnd, null, c.TRUE);
    }
}

/// Show the quick terminal, creating it if needed, or hide it if it's
/// in front.
fn toggleQuickTerminal(self: *App) !void {
    const window = self.quick_terminal orelse {
        self.quick_terminal = try self.newWindow(.quick);
        return;
    };
    if (window.quickShowing() and c.GetForegroundWindow() == window.hwnd) {
        window.hideQuick();
    } else {
        window.showQuick();
    }
}

/// Like macOS: hide all windows if one of them is active, otherwise
/// show them all and activate the one that was active.
fn toggleVisibility(self: *App) void {
    const fg = c.GetForegroundWindow();
    const active = for (self.windows.items) |window| {
        if (window.hwnd == fg) break window;
    } else null;

    log.debug("toggle visibility hide={}", .{active != null});
    if (active) |window| {
        self.hidden_active = window;
        for (self.windows.items) |w| _ = c.ShowWindow(w.hwnd, c.SW_HIDE);
        return;
    }

    for (self.windows.items) |w| _ = c.ShowWindow(w.hwnd, c.SW_SHOWNA);
    const target = if (self.hidden_active) |hidden|
        if (std.mem.indexOfScalar(*Window, self.windows.items, hidden) != null) hidden else null
    else
        null;
    self.hidden_active = null;
    const window = target orelse self.activeWindow() orelse return;
    window.present(window.activeSurface());
}

/// Called by a window when it's destroyed, to remove it from our list.
pub fn windowDestroyed(self: *App, window: *Window) void {
    if (self.hidden_active == window) self.hidden_active = null;
    if (self.quick_terminal == window) self.quick_terminal = null;
    for (self.windows.items, 0..) |w, i| {
        if (w == window) {
            // Keep the creation order for goto_window.
            _ = self.windows.orderedRemove(i);
            break;
        }
    }
}

/// Start the quit timer, which quits the app (if configured to) once
/// the last surface has been closed, possibly after a delay.
///
/// Note: this is deliberately not named `startQuitTimer`, which main
/// calls before `run` if it exists. We handle having no windows at
/// startup in `run` instead.
fn armQuitTimer(self: *App) void {
    if (!self.config.@"quit-after-last-window-closed") return;

    const delay = self.config.@"quit-after-last-window-closed-delay" orelse {
        self.quit();
        return;
    };

    if (c.SetTimer(self.msg_hwnd, quit_timer_id, delay.asMilliseconds(), null) == 0) {
        log.warn("failed to start quit timer, quitting now err={}", .{c.GetLastError()});
        self.quit();
    }
}

/// Quit the application. This closes all windows and exits the
/// message loop.
fn quit(self: *App) void {
    if (self.quitting) return;
    self.quitting = true;
    c.PostQuitMessage(0);
}

/// Close all windows, asking for confirmation if any surface
/// has a running process (and the config requests it).
fn closeAllWindows(self: *App) void {
    if (self.core_app.needsConfirmQuit() and
        !Window.confirm(null, "Close all windows?", "All terminal sessions will be terminated."))
    {
        return;
    }

    SaveState.save(self);
    self.closing_all = true;
    defer self.closing_all = false;
    while (self.windows.items.len > 0) {
        self.windows.items[self.windows.items.len - 1].destroy();
    }
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            if (self.core_app.needsConfirmQuit() and
                !Window.confirm(null, "Quit Ghostty?", "All terminal sessions will be terminated."))
            {
                return true;
            }
            SaveState.save(self);
            self.quit();
        },

        .new_window => _ = try self.newWindow(.{ .parent = switch (target) {
            .app => null,
            .surface => |v| v,
        } }),

        .close_all_windows => self.closeAllWindows(),

        .close_window => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.close(),
        },

        .new_tab => switch (target) {
            .app => {
                // Open a tab in the most recently active window, or a
                // new window if we have none.
                if (self.activeWindow()) |window| {
                    _ = try window.addTab(null);
                } else {
                    _ = try self.newWindow(.{ .parent = null });
                }
            },
            .surface => |v| _ = try v.rt_surface.window.addTab(v),
        },

        .close_tab => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.closeTabs(v.rt_surface, value),
        },

        .goto_tab => switch (target) {
            .app => return false,
            .surface => |v| return v.rt_surface.window.gotoTab(value),
        },

        .move_tab => switch (target) {
            .app => return false,
            .surface => |v| return v.rt_surface.window.moveTab(value.amount),
        },

        .move_tab_to_new_window => switch (target) {
            .app => return false,
            .surface => |v| return try v.rt_surface.window.moveTabToNewWindow(v.rt_surface),
        },

        .new_split => switch (target) {
            .app => return false,
            .surface => |v| {
                const tab = v.rt_surface.window.tabOf(v.rt_surface) orelse return false;
                try tab.split(v.rt_surface, value);
            },
        },

        .goto_split => switch (target) {
            .app => return false,
            .surface => |v| {
                const tab = v.rt_surface.window.tabOf(v.rt_surface) orelse return false;
                return tab.gotoSplit(v.rt_surface, value);
            },
        },

        .resize_split => switch (target) {
            .app => return false,
            .surface => |v| {
                const window = v.rt_surface.window;
                const tab = window.tabOf(v.rt_surface) orelse return false;
                return try tab.resizeSplit(v.rt_surface, value, window.surfaceArea());
            },
        },

        .equalize_splits => switch (target) {
            .app => return false,
            .surface => |v| {
                const tab = v.rt_surface.window.tabOf(v.rt_surface) orelse return false;
                try tab.equalize();
            },
        },

        .toggle_split_zoom => switch (target) {
            .app => return false,
            .surface => |v| {
                const tab = v.rt_surface.window.tabOf(v.rt_surface) orelse return false;
                return tab.toggleZoom(v.rt_surface);
            },
        },

        .quit_timer => switch (value) {
            .start => self.armQuitTimer(),
            .stop => _ = c.KillTimer(self.msg_hwnd, quit_timer_id),
        },

        .set_title => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setTitle(value.title),
        },

        .set_tab_title => switch (target) {
            .app => return false,
            .surface => |v| {
                const tab = v.rt_surface.window.tabOf(v.rt_surface) orelse return false;
                tab.setTitleOverride(value.title);
            },
        },

        .set_window_title => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.setTitleOverride(value.title),
        },

        .prompt_title => switch (target) {
            .app => return false,
            .surface => |v| try v.rt_surface.promptTitle(value),
        },

        .copy_title_to_clipboard => switch (target) {
            .app => return false,
            .surface => |v| return try v.rt_surface.copyTitleToClipboard(),
        },

        .mouse_shape => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setMouseShape(value),
        },

        .cell_size => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.cell_size = value,
        },

        .color_change => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.colorChanged(value),
        },

        .show_on_screen_keyboard => switch (target) {
            .app => return false,
            .surface => |v| return shell.toggleTouchKeyboard(v.rt_surface.window.hwnd),
        },

        // The contents are only valid during this call, and the dialog is
        // modal, so we save them before returning.
        .export_terminal_io => switch (target) {
            .app => return false,
            .surface => |v| _ = shell.saveAs(
                self.core_app.alloc,
                if (v.rt_surface.inspector) |window| window.hwnd else v.rt_surface.window.hwnd,
                "Export Terminal IO Events",
                "ghostty-terminal-io.txt",
                value.contents,
            ),
        },

        .inspector => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.controlInspector(value),
        },

        .render_inspector => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.queueInspectorRender(),
        },

        .toggle_command_palette => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.toggleCommandPalette(),
        },

        .toggle_tab_overview => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.toggleTabOverview(),
        },

        .start_search => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.startSearch(value.needle),
        },

        .end_search => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.endSearch(),
        },

        .search_total => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setSearchTotal(value.total),
        },

        .search_selected => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setSearchSelected(value.selected),
        },

        .readonly => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setReadonly(value),
        },

        .renderer_health => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setRendererHealth(value),
        },

        .key_sequence => switch (target) {
            .app => return false,
            .surface => |v| try v.rt_surface.keySequence(value),
        },

        .key_table => switch (target) {
            .app => return false,
            .surface => |v| try v.rt_surface.keyTable(value),
        },

        .scrollbar => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.scrollbar.update(value),
        },

        .mouse_over_link => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setMouseOverLink(value.url),
        },

        .mouse_visibility => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setMouseVisibility(value == .visible),
        },

        .toggle_visibility => self.toggleVisibility(),

        .toggle_quick_terminal => try self.toggleQuickTerminal(),

        .toggle_background_opacity => self.toggleBackgroundOpacity(),

        .goto_window => switch (target) {
            .app => return false,
            .surface => |v| return self.gotoWindow(v.rt_surface.window, value),
        },

        .present_terminal => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.present(v.rt_surface),
        },

        .float_window => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.setFloating(value),
        },

        .toggle_window_decorations => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.toggleDecorations(),
        },

        .toggle_maximize => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.toggleMaximize(),
        },

        .toggle_fullscreen => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.toggleFullscreen(),
        },

        .initial_size => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.setInitialSize(value.width, value.height),
        },

        .reset_window_size => switch (target) {
            .app => return false,
            .surface => |v| return v.rt_surface.window.resetSize(),
        },

        .resize_window => switch (target) {
            .app => return false,
            .surface => |v| return v.rt_surface.window.resizeTerminal(value),
        },

        .size_limit => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.setSizeLimit(value),
        },

        .ring_bell => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.ringBell(),
        },

        .progress_report => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setProgressReport(value),
        },

        .command_finished => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.commandFinished(value),
        },

        .desktop_notification => self.notifier.send(switch (target) {
            .app => null,
            .surface => |v| v,
        }, value.title, value.body),

        .open_url => openUrl(self.core_app.alloc, value.url),

        .config_change => switch (target) {
            .surface => |v| v.rt_surface.configChanged(value.config),

            // For app updates, we update our core config. We need to
            // clone it because the caller owns the param.
            .app => if (value.config.clone(self.core_app.alloc)) |config| {
                self.config.deinit();
                self.config = config;
                self.global_keys.update(&self.config);
                for (self.windows.items) |window| window.configChanged();
            } else |err| {
                log.err("error updating app config err={}", .{err});
            },
        },

        .reload_config => try self.reloadConfig(target, value),

        .open_config => {
            const alloc = self.core_app.alloc;
            const path = configpkg.edit.openPath(alloc) catch |err| {
                log.err("error opening config path err={}", .{err});
                return true;
            };
            defer alloc.free(path);
            openUrl(alloc, path);
        },

        // Unimplemented
        else => {
            log.debug("unimplemented action={}", .{action});
            return false;
        },
    }

    return true;
}

/// Tell the core whether Windows uses the light or dark app mode, which
/// picks the theme of `theme = light:...,dark:...` and answers color
/// scheme queries. The core ignores reports that don't change the scheme.
pub fn updateColorScheme(self: *App) void {
    const scheme: apprt.ColorScheme = if (Window.systemUsesDarkTheme()) .dark else .light;
    self.core_app.colorSchemeEvent(self, scheme) catch |err| {
        log.warn("error updating app color scheme err={}", .{err});
    };
    for (self.core_app.surfaces.items) |surface| {
        surface.core().colorSchemeCallback(scheme) catch |err| {
            log.warn("unable to tell surface about color scheme change err={}", .{err});
        };
    }
}

fn reloadConfig(
    self: *App,
    target: apprt.action.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    // A soft reload just re-applies our current config.
    if (opts.soft) {
        switch (target) {
            .app => try self.core_app.updateConfig(self, &self.config),
            .surface => |core_surface| try core_surface.updateConfig(&self.config),
        }
        return;
    }

    // Load our configuration
    var config = try Config.load(self.core_app.alloc);
    defer config.deinit();

    switch (target) {
        .app => try self.core_app.updateConfig(self, &config),
        .surface => |core_surface| try core_surface.updateConfig(&config),
    }

    if (config._diagnostics.items().len > 0) {
        self.showConfigErrors(&config);
        return;
    }

    // Like GTK, tell each window.
    if (config.@"app-notifications".@"config-reload") {
        for (self.windows.items) |window| {
            if (window.tabs.items.len > 0) window.activeSurface().showToast("Reloaded the configuration");
        }
    }
}

/// Like GTK, list configuration errors and offer to reload the
/// configuration, for example after fixing them.
fn showConfigErrors(self: *App, config: *const Config) void {
    const alloc = self.core_app.alloc;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    const writer = &text.writer;
    writer.writeAll("One or more configuration errors were found:\n\n") catch return;

    // Long lists don't fit a message box.
    const max_shown = 15;
    const diagnostics = config._diagnostics.items();
    for (diagnostics[0..@min(diagnostics.len, max_shown)]) |diag| {
        writer.print("{f}\n", .{diag}) catch return;
    }
    if (diagnostics.len > max_shown) {
        writer.print("...and {d} more\n", .{diagnostics.len - max_shown}) catch return;
    }
    writer.writeAll("\nReload the configuration now? Choose No to ignore these errors.") catch return;

    const message = util.utf16Alloc(alloc, text.written()) catch return;
    defer alloc.free(message);
    const owner = if (self.activeWindow()) |window| window.hwnd else null;
    const choice = c.MessageBoxW(
        owner,
        message.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Configuration Errors"),
        c.MB_YESNO | c.MB_ICONWARNING,
    );
    if (choice == c.IDYES) {
        self.reloadConfig(.app, .{ .soft = false }) catch |err| {
            log.err("error reloading config err={}", .{err});
        };
    }
}

/// Open a URL or path with the default handler.
fn openUrl(alloc: Allocator, url: []const u8) void {
    const url16 = util.utf16Alloc(alloc, url) catch return;
    defer alloc.free(url16);
    const open = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const result = c.ShellExecuteW(null, open, url16, null, null, c.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) {
        log.warn("failed to open url={s} result={}", .{ url, @intFromPtr(result) });
    }
}

/// Send the given IPC to a running Ghostty. Returns `true` if the action was
/// able to be performed, `false` otherwise.
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    return switch (action) {
        .new_window => try Ipc.send(alloc, target, .{
            .kind = .new_window,
            .arguments = toConst(value.arguments),
        }),
        .new_tab => try Ipc.send(alloc, target, .{
            .kind = .new_tab,
            .surface_id = value.surface_id,
            .arguments = toConst(value.arguments),
        }),
        .toggle_quick_terminal => try Ipc.send(alloc, target, .{ .kind = .toggle_quick_terminal }),
    };
}

fn toConst(args: ?[][:0]const u8) ?[]const []const u8 {
    const v = args orelse return null;
    return @ptrCast(v);
}

/// Redraw the inspector for the given surface. The inspector isn't
/// supported on Windows yet.
pub fn redrawInspector(_: *App, _: *Surface) void {}
