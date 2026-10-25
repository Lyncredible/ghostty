//! A top-level window. A window hosts one or more surfaces as tabs. Each
//! surface is a child window and only the active tab's surface is shown.
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

/// The tab bar control.
tab_hwnd: c.HWND,

/// The font used by the tab bar, scaled for our DPI.
tab_font: ?c.HFONT = null,

/// The surfaces in this window, in tab order.
surfaces: std.ArrayList(*Surface) = .empty,

/// The index of the active tab.
active: usize = 0,

/// The saved window state while we're fullscreen, used to restore it.
fullscreen: ?struct {
    style: c.LONG_PTR,
    placement: c.WINDOWPLACEMENT,
} = null,

/// Whether we've applied the initial size. We only apply it once.
initial_size_applied: bool = false,

/// True while we're being destroyed, so closing the last tab doesn't
/// try to destroy us again.
destroying: bool = false,

pub fn init(self: *Window, app: *App, parent: ?*CoreSurface) !void {
    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tab_hwnd = undefined,
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

    self.tab_hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("SysTabControl32"),
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS | c.TCS_FOCUSNEVER,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse {
        log.err("failed to create tab bar err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };
    self.updateTabFont();
    errdefer if (self.tab_font) |f| {
        _ = c.DeleteObject(f);
    };

    _ = try self.addTab(parent);

    // Only now that we're fully initialized do we attach ourselves to
    // the window, so our window procedure (in particular WM_DESTROY)
    // never sees a partially initialized window.
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.layout();
}

/// Free the resources of the window. This doesn't destroy the window
/// handle; this is called while the window is being destroyed.
pub fn deinit(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    for (self.surfaces.items) |surface| {
        surface.deinit();
        alloc.destroy(surface);
    }
    self.surfaces.deinit(alloc);
    if (self.tab_font) |f| _ = c.DeleteObject(f);
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

/// The surface of the active tab.
pub fn activeSurface(self: *const Window) *Surface {
    return self.surfaces.items[self.active];
}

//----------------------------------------------------------------------------
// Tabs

/// Create a new tab, inheriting from the parent surface if given, and
/// select it.
pub fn addTab(self: *Window, parent: ?*CoreSurface) !*Surface {
    const alloc = self.app.core_app.alloc;

    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self.app, self, .{
        .parent = parent,
        .context = if (self.surfaces.items.len == 0) .window else .tab,
    });
    errdefer {
        surface.deinit();
        _ = c.DestroyWindow(surface.hwnd);
    }

    const idx: usize = if (self.surfaces.items.len == 0)
        0
    else switch (self.app.config.@"window-new-tab-position") {
        .current => self.active + 1,
        .end => self.surfaces.items.len,
    };
    try self.surfaces.insert(alloc, idx, surface);
    errdefer _ = self.surfaces.orderedRemove(idx);

    var item: c.TCITEMW = std.mem.zeroes(c.TCITEMW);
    item.mask = c.TCIF_TEXT;
    item.pszText = @constCast(std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"));
    if (c.SendMessageW(
        self.tab_hwnd,
        c.TCM_INSERTITEMW,
        idx,
        @bitCast(@intFromPtr(&item)),
    ) < 0) return error.InsertTabFailed;

    self.selectTab(idx);
    self.layout();
    return surface;
}

/// Make the tab at the given index active.
pub fn selectTab(self: *Window, idx: usize) void {
    if (idx >= self.surfaces.items.len) return;

    const prev = self.active;
    self.active = idx;
    _ = c.SendMessageW(self.tab_hwnd, c.TCM_SETCURSEL, idx, 0);

    // Hide all other surfaces and show the active one.
    for (self.surfaces.items, 0..) |surface, i| {
        if (i == idx) continue;
        if (c.IsWindowVisible(surface.hwnd) != 0) {
            _ = c.ShowWindow(surface.hwnd, c.SW_HIDE);
            surface.setVisible(false);
        }
    }

    const surface = self.surfaces.items[idx];
    _ = c.ShowWindow(surface.hwnd, c.SW_SHOW);
    surface.setVisible(true);
    if (c.GetForegroundWindow() == self.hwnd or prev != idx) {
        _ = c.SetFocus(surface.hwnd);
    }

    self.updateWindowTitle();
}

/// Go to a tab, using the semantics of the goto_tab action.
pub fn gotoTab(self: *Window, goto: apprt.action.GotoTab) bool {
    const total = self.surfaces.items.len;
    if (total == 0) return false;
    const current = self.active;

    const idx: usize = switch (goto) {
        .previous => if (current > 0) current - 1 else total - 1,
        .next => if (current < total - 1) current + 1 else 0,
        .last => total - 1,
        _ => idx: {
            // 1-indexed
            const n = @backingInt(goto);
            if (n <= 0) return false;
            break :idx @min(@as(usize, @intCast(n)) - 1, total - 1);
        },
    };

    if (idx == current) return false;
    self.selectTab(idx);
    return true;
}

/// Move the active tab by the given amount, wrapping around.
pub fn moveTab(self: *Window, amount: isize) bool {
    const total = self.surfaces.items.len;
    if (total <= 1) return false;

    const total_i: isize = @intCast(total);
    const from = self.active;
    const to: usize = @intCast(@mod(@as(isize, @intCast(from)) + amount, total_i));
    if (from == to) return false;

    const surface = self.surfaces.orderedRemove(from);
    self.surfaces.insertAssumeCapacity(to, surface);

    // Rebuild the tab items in the new order.
    _ = c.SendMessageW(self.tab_hwnd, c.TCM_DELETEITEM, from, 0);
    var item: c.TCITEMW = std.mem.zeroes(c.TCITEMW);
    item.mask = c.TCIF_TEXT;
    item.pszText = @constCast(std.unicode.utf8ToUtf16LeStringLiteral(""));
    _ = c.SendMessageW(self.tab_hwnd, c.TCM_INSERTITEMW, to, @bitCast(@intFromPtr(&item)));
    self.updateTabTitle(surface);

    self.selectTab(to);
    return true;
}

/// Close the tab of the given surface without confirmation. If it's the
/// last tab, the window is closed.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    const idx = std.mem.indexOfScalar(*Surface, self.surfaces.items, surface) orelse return;

    // The last tab closes the window, which deinitializes the surface.
    if (self.surfaces.items.len == 1) {
        if (!self.destroying) self.destroy();
        return;
    }

    _ = self.surfaces.orderedRemove(idx);
    _ = c.SendMessageW(self.tab_hwnd, c.TCM_DELETEITEM, idx, 0);

    const alloc = self.app.core_app.alloc;
    surface.deinit();
    _ = c.DestroyWindow(surface.hwnd);
    alloc.destroy(surface);

    // Keep the same tab active. If the active tab was closed, the tab
    // that took its place (or the new last tab) becomes active.
    if (idx < self.active) self.active -= 1;
    self.active = @min(self.active, self.surfaces.items.len - 1);
    self.selectTab(self.active);
    self.layout();
}

/// Close tabs relative to the given surface, asking for confirmation if
/// any of them have a running process.
pub fn closeTabs(self: *Window, surface: *Surface, mode: apprt.action.CloseTabMode) void {
    const idx = std.mem.indexOfScalar(*Surface, self.surfaces.items, surface) orelse return;

    // Collect the surfaces to close.
    const alloc = self.app.core_app.alloc;
    var targets: std.ArrayList(*Surface) = .empty;
    defer targets.deinit(alloc);
    for (self.surfaces.items, 0..) |s, i| {
        const close_it = switch (mode) {
            .this => i == idx,
            .other => i != idx,
            .right => i > idx,
        };
        if (close_it) targets.append(alloc, s) catch return;
    }
    if (targets.items.len == 0) return;

    // A single tab goes through the core so it confirms as usual.
    if (targets.items.len == 1) {
        targets.items[0].core_surface.close();
        return;
    }

    for (targets.items) |s| {
        if (s.core_surface.needsConfirmQuit()) {
            if (!confirm(
                self,
                "Close tabs?",
                "A process is still running in at least one of the tabs. Closing them will kill the processes.",
            )) return;
            break;
        }
    }

    for (targets.items) |s| self.closeSurface(s);
}

/// Called by a surface when its title changes.
pub fn surfaceTitleChanged(self: *Window, surface: *Surface) void {
    self.updateTabTitle(surface);
    if (surface == self.activeSurface()) self.updateWindowTitle();
}

fn updateTabTitle(self: *Window, surface: *Surface) void {
    const idx = std.mem.indexOfScalar(*Surface, self.surfaces.items, surface) orelse return;
    const alloc = self.app.core_app.alloc;
    const title16 = util.utf16Alloc(alloc, surface.title orelse "Ghostty") catch return;
    defer alloc.free(title16);

    var item: c.TCITEMW = std.mem.zeroes(c.TCITEMW);
    item.mask = c.TCIF_TEXT;
    item.pszText = title16.ptr;
    _ = c.SendMessageW(self.tab_hwnd, c.TCM_SETITEMW, idx, @bitCast(@intFromPtr(&item)));
}

fn updateWindowTitle(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    const title = self.activeSurface().title orelse "Ghostty";
    const title16 = util.utf16Alloc(alloc, title) catch return;
    defer alloc.free(title16);
    _ = c.SetWindowTextW(self.hwnd, title16);
}

/// Whether the tab bar should be visible.
fn showTabBar(self: *const Window) bool {
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => self.surfaces.items.len > 1,
        .never => false,
    };
}

/// Position the tab bar and surfaces within our client area.
fn layout(self: *Window) void {
    var client: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &client) == 0) return;

    var top: c_int = 0;
    if (self.showTabBar()) {
        // Ask the tab control how much space its tabs need.
        var rect = client;
        _ = c.SendMessageW(self.tab_hwnd, c.TCM_ADJUSTRECT, c.FALSE, @bitCast(@intFromPtr(&rect)));
        top = @max(0, rect.top - 2);
        _ = c.MoveWindow(self.tab_hwnd, 0, 0, client.right, top, c.TRUE);
        _ = c.ShowWindow(self.tab_hwnd, c.SW_SHOWNA);
    } else {
        _ = c.ShowWindow(self.tab_hwnd, c.SW_HIDE);
    }

    // All surfaces are kept at the same size so switching tabs doesn't
    // need a resize.
    for (self.surfaces.items) |surface| {
        _ = c.MoveWindow(surface.hwnd, 0, top, client.right, @max(0, client.bottom - top), c.TRUE);
    }
}

/// Set the font of the tab bar to the system UI font for our DPI.
fn updateTabFont(self: *Window) void {
    const dpi = c.GetDpiForWindow(self.hwnd);
    var metrics: c.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (c.SystemParametersInfoForDpi(
        c.SPI_GETNONCLIENTMETRICS,
        metrics.cbSize,
        &metrics,
        0,
        dpi,
    ) == 0) return;

    const font = c.CreateFontIndirectW(&metrics.lfMessageFont) orelse return;
    _ = c.SendMessageW(self.tab_hwnd, c.WM_SETFONT, @intFromPtr(font), c.TRUE);
    if (self.tab_font) |old| _ = c.DeleteObject(old);
    self.tab_font = font;
}

//----------------------------------------------------------------------------
// Window state

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

//----------------------------------------------------------------------------
// Window procedure

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
            self.layout();
            return 0;
        },

        c.WM_SETFOCUS => {
            _ = c.SetFocus(self.activeSurface().hwnd);
            return 0;
        },

        c.WM_ACTIVATE => {
            const active = (wparam & 0xFFFF) != c.WA_INACTIVE;
            self.app.core_app.focusEvent(active);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_NOTIFY => {
            const hdr: *const c.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (hdr.hwndFrom == self.tab_hwnd and hdr.code == util.TCN_SELCHANGE) {
                const sel = c.SendMessageW(self.tab_hwnd, c.TCM_GETCURSEL, 0, 0);
                if (sel >= 0) self.selectTab(@intCast(sel));
                return 0;
            }
        },

        c.WM_DPICHANGED => {
            // Windows suggests a new size and position for our window
            // that keeps it at the same physical size on the new monitor.
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.updateTabFont();
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
            // With a single tab, go through the core so that it confirms
            // as usual and calls back into Surface.close.
            if (self.surfaces.items.len == 1) {
                self.activeSurface().core_surface.close();
                return 0;
            }

            for (self.surfaces.items) |s| {
                if (s.core_surface.needsConfirmQuit()) {
                    if (!confirm(
                        self,
                        "Close window?",
                        "A process is still running in at least one of the tabs. Closing the window will kill the processes.",
                    )) return 0;
                    break;
                }
            }

            self.destroy();
            return 0;
        },

        c.WM_DESTROY => {
            // Tear down our surfaces while our window handles are still
            // valid, since the renderers are presenting to them.
            self.destroying = true;
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
