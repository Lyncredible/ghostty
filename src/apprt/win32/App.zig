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

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

/// Posted to our message window to wake up the event loop.
const WM_GHOSTTY_WAKEUP = c.WM_APP + 1;

/// The window class names we register.
pub const window_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
pub const surface_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");
const message_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMessage");

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

/// All of our open top-level windows.
windows: std.ArrayList(*Window) = .empty,

/// True once we've started quitting, so we don't quit twice.
quitting: bool = false,

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

    // Note: we render at the native resolution of each monitor. The
    // per-monitor DPI awareness for that is set by our application
    // manifest (dist/windows/ghostty.manifest).

    // Our tab bar is a common control.
    const icc: c.INITCOMMONCONTROLSEX = .{
        .dwSize = @sizeOf(c.INITCOMMONCONTROLSEX),
        .dwICC = c.ICC_TAB_CLASSES,
    };
    if (c.InitCommonControlsEx(&icc) == 0) {
        log.warn("failed to initialize common controls", .{});
    }

    const hinstance: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    try registerClasses(hinstance);
    errdefer unregisterClasses(hinstance);

    const msg_hwnd = c.CreateWindowExW(
        0,
        message_class,
        null,
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

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .msg_hwnd = msg_hwnd,
    };

    _ = c.SetWindowLongPtrW(msg_hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
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
            // We need double click messages to detect multi-clicks
            // ourselves, but the core does its own click counting so
            // we don't set CS_DBLCLKS.
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
    _ = c.UnregisterClassW(message_class, hinstance);
}

pub fn run(self: *App) !void {
    // Create our initial window, if requested.
    if (self.config.@"initial-window") {
        _ = try self.newWindow(null);
    }

    // If we have no windows at this point there's nothing to do.
    if (self.windows.items.len == 0 and self.config.@"quit-after-last-window-closed") {
        return;
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

pub fn terminate(self: *App) void {
    // Close any windows that are still open. This deinitializes their
    // surfaces, which must happen before the core app is destroyed.
    while (self.windows.items.len > 0) {
        self.windows.items[self.windows.items.len - 1].destroy();
    }
    self.windows.deinit(self.core_app.alloc);

    _ = c.DestroyWindow(self.msg_hwnd);
    unregisterClasses(self.hinstance);
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
    if (ptr != 0 and msg == WM_GHOSTTY_WAKEUP) {
        const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
        self.core_app.tick(self) catch |err| {
            log.err("error ticking app err={}", .{err});
        };
        return 0;
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Create a new window. If a parent surface is given, the new
/// window inherits relevant properties from it (font size, cwd).
fn newWindow(self: *App, parent: ?*CoreSurface) !*Window {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    window.init(self, parent) catch |err| {
        alloc.destroy(window);
        return err;
    };

    // From here on the window owns itself: destroying it frees it.
    self.windows.append(alloc, window) catch |err| {
        window.destroy();
        return err;
    };
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

/// Called by a window when it's destroyed, to remove it from our list.
pub fn windowDestroyed(self: *App, window: *Window) void {
    for (self.windows.items, 0..) |w, i| {
        if (w == window) {
            _ = self.windows.swapRemove(i);
            break;
        }
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
            self.quit();
        },

        .new_window => _ = try self.newWindow(switch (target) {
            .app => null,
            .surface => |v| v,
        }),

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
                    _ = try self.newWindow(null);
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

        .quit_timer => switch (value) {
            // Quit timer delays aren't supported yet, so we quit
            // immediately once the last surface is gone.
            .start => if (self.config.@"quit-after-last-window-closed") self.quit(),
            .stop => {},
        },

        .set_title => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setTitle(value.title),
        },

        .mouse_shape => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setMouseShape(value),
        },

        .mouse_visibility => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setMouseVisibility(value == .visible),
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

        .ring_bell => _ = c.MessageBeep(c.MB_OK),

        .open_url => openUrl(self.core_app.alloc, value.url),

        .config_change => switch (target) {
            .surface => {},

            // For app updates, we update our core config. We need to
            // clone it because the caller owns the param.
            .app => if (value.config.clone(self.core_app.alloc)) |config| {
                self.config.deinit();
                self.config = config;
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
///
/// IPC is not supported on Windows yet.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    return false;
}

/// Redraw the inspector for the given surface. The inspector isn't
/// supported on Windows yet.
pub fn redrawInspector(_: *App, _: *Surface) void {}
