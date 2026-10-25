//! A top-level window. A window currently hosts exactly one surface as a
//! child window that fills its client area. Tabs and splits will build on
//! this by hosting multiple surfaces.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");

const util = @import("util.zig");
const c = util.c;
const App = @import("App.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

app: *App,

/// The top-level window handle.
hwnd: c.HWND,

/// The surface hosted in this window.
surface: *Surface,

/// The saved window state while we're fullscreen, used to restore it.
fullscreen: ?struct {
    style: c.LONG_PTR,
    placement: c.WINDOWPLACEMENT,
} = null,

/// Whether we've applied the initial size. We only apply it once.
initial_size_applied: bool = false,

pub fn init(self: *Window, app: *App, parent: ?*CoreSurface) !void {
    const alloc = app.core_app.alloc;

    self.* = .{
        .app = app,
        .hwnd = undefined,
        .surface = undefined,
    };

    const hwnd = c.CreateWindowExW(
        0,
        App.window_class,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        util.CW_USEDEFAULT,
        util.CW_USEDEFAULT,
        util.CW_USEDEFAULT,
        util.CW_USEDEFAULT,
        null,
        null,
        app.hinstance,
        null,
    ) orelse {
        log.err("failed to create window err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = c.DestroyWindow(hwnd);
    self.hwnd = hwnd;

    // Use a dark title bar if the system is in dark mode, to match
    // the typically dark terminal background.
    {
        const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        const dark: c.BOOL = c.TRUE;
        _ = c.DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark,
            @sizeOf(c.BOOL),
        );
    }

    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(app, self, .{
        .parent = parent,
        .context = .window,
    });
    self.surface = surface;

    // Only now that we're fully initialized do we attach ourselves to
    // the window, so our window procedure (in particular WM_DESTROY)
    // never sees a partially initialized window.
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

/// Free the resources of the window. This doesn't destroy the window
/// handle; this is called while the window is being destroyed.
pub fn deinit(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    self.surface.deinit();
    alloc.destroy(self.surface);
}

/// Show the window for the first time.
pub fn show(self: *Window) void {
    _ = c.ShowWindow(self.hwnd, c.SW_SHOWDEFAULT);
    _ = c.UpdateWindow(self.hwnd);
}

/// Request to close the window. This goes through the same path as the
/// user closing the window, so it may ask for confirmation.
pub fn close(self: *Window) void {
    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
}

/// Destroy the window immediately, without confirmation.
pub fn destroy(self: *Window) void {
    _ = c.DestroyWindow(self.hwnd);
}

pub fn setTitle(self: *Window, title: [:0]const u16) void {
    _ = c.SetWindowTextW(self.hwnd, title);
}

pub fn toggleMaximize(self: *Window) void {
    _ = c.ShowWindow(
        self.hwnd,
        if (c.IsZoomed(self.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE,
    );
}

/// Toggle borderless fullscreen on the monitor the window is on.
pub fn toggleFullscreen(self: *Window) void {
    if (self.fullscreen) |saved| {
        // Restore
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, saved.style);
        _ = c.SetWindowPlacement(self.hwnd, &saved.placement);
        _ = c.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER |
                c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
        );
        self.fullscreen = null;
        return;
    }

    var placement: c.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(c.WINDOWPLACEMENT);
    if (c.GetWindowPlacement(self.hwnd, &placement) == 0) return;

    const monitor = c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST);
    var info: c.MONITORINFO = undefined;
    info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &info) == 0) return;

    const style = c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE);
    self.fullscreen = .{ .style = style, .placement = placement };

    _ = c.SetWindowLongPtrW(
        self.hwnd,
        c.GWL_STYLE,
        style & ~@as(c.LONG_PTR, c.WS_OVERLAPPEDWINDOW),
    );
    _ = c.SetWindowPos(
        self.hwnd,
        c.HWND_TOP,
        info.rcMonitor.left,
        info.rcMonitor.top,
        info.rcMonitor.right - info.rcMonitor.left,
        info.rcMonitor.bottom - info.rcMonitor.top,
        c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
    );
}

/// Set the initial size of the window, given the size of the client
/// area (the terminal surface) in pixels.
pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    if (self.initial_size_applied) return;
    self.initial_size_applied = true;

    const style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE))));
    const ex_style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_EXSTYLE))));
    var rect: c.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(width),
        .bottom = @intCast(height),
    };
    _ = c.AdjustWindowRectExForDpi(&rect, style, c.FALSE, ex_style, c.GetDpiForWindow(self.hwnd));
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// Show a yes/no confirmation dialog. Returns true if the user confirmed.
pub fn confirm(window: ?*Window, title: []const u8, message: []const u8) bool {
    var title_buf: [256]u16 = undefined;
    var message_buf: [1024]u16 = undefined;
    const title16 = utf16Buf(&title_buf, title);
    const message16 = utf16Buf(&message_buf, message);
    const result = c.MessageBoxW(
        if (window) |w| w.hwnd else null,
        message16,
        title16,
        c.MB_OKCANCEL | c.MB_ICONWARNING,
    );
    return result == c.IDOK;
}

/// Convert a short ASCII/UTF-8 string into a stack buffer as UTF-16,
/// truncating if needed.
fn utf16Buf(buf: []u16, s: []const u8) [*:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s) catch 0;
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        c.WM_SIZE => {
            // Our surface fills our entire client area.
            const width: c_int = @as(u16, @bitCast(util.loword(lparam)));
            const height: c_int = @as(u16, @bitCast(util.hiword(lparam)));
            _ = c.MoveWindow(self.surface.hwnd, 0, 0, width, height, c.TRUE);
            return 0;
        },

        c.WM_SETFOCUS => {
            _ = c.SetFocus(self.surface.hwnd);
            return 0;
        },

        c.WM_ACTIVATE => {
            const active = (wparam & 0xFFFF) != c.WA_INACTIVE;
            self.app.core_app.focusEvent(active);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_DPICHANGED => {
            // Windows suggests a new size and position for our window
            // that keeps it at the same physical size on the new monitor.
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
            return 0;
        },

        c.WM_CLOSE => {
            // Ask the core surface to close, which checks whether we
            // need to confirm and then calls back into Surface.close.
            self.surface.core_surface.close();
            return 0;
        },

        c.WM_DESTROY => {
            // Tear down our surface while our window handles are still
            // valid, since the renderer is presenting to them.
            _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, 0);
            const app = self.app;
            self.deinit();
            app.windowDestroyed(self);
            app.core_app.alloc.destroy(self);
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
