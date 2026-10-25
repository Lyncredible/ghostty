//! A top-level window. A window hosts one or more tabs, and each tab is
//! a tree of surfaces (splits). Each surface is a child window and only
//! the surfaces of the active tab are shown.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");

const util = @import("util.zig");
const c = util.c;
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabBar = @import("TabBar.zig");

const log = std.log.scoped(.win32);

const progress_timer_id = 1;

app: *App,

/// The top-level window handle.
hwnd: c.HWND,

/// The tab bar.
tab_bar: TabBar,

/// The tabs in this window, in order.
tabs: std.ArrayList(*Tab) = .empty,

/// The index of the active tab.
active: usize = 0,

/// The split divider being dragged, if any.
dragging: ?Tab.Divider = null,

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

/// Explorer sends TaskbarButtonCreated after the window's button exists.
taskbar_ready: bool = false,

pub fn init(self: *Window, app: *App, parent: ?*CoreSurface) !void {
    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tab_bar = undefined,
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

    try self.tab_bar.init(self);
    errdefer self.tab_bar.deinit();

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
    _ = c.KillTimer(self.hwnd, progress_timer_id);
    const alloc = self.app.core_app.alloc;
    for (self.tabs.items) |tab| tab.destroy();
    self.tabs.deinit(alloc);
    self.tab_bar.deinit();
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

/// The active tab.
pub fn activeTab(self: *const Window) *Tab {
    return self.tabs.items[self.active];
}

/// The focused surface of the active tab.
pub fn activeSurface(self: *const Window) *Surface {
    return self.activeTab().focused;
}

/// The tab that contains the given surface.
pub fn tabOf(self: *const Window, surface: *const Surface) ?*Tab {
    for (self.tabs.items) |tab| {
        if (tab.contains(surface)) return tab;
    }
    return null;
}

fn tabIndex(self: *const Window, tab: *const Tab) ?usize {
    return std.mem.indexOfScalar(*Tab, self.tabs.items, @constCast(tab));
}

//----------------------------------------------------------------------------
// Tabs

/// Create a new tab, inheriting from the parent surface if given, and
/// select it.
pub fn addTab(self: *Window, parent: ?*CoreSurface) !*Tab {
    return self.addTabWithShell(parent, null);
}

/// Open a tab with an explicit shell, or the configured command when null.
pub fn addTabWithShell(self: *Window, parent: ?*CoreSurface, shell: ?configpkg.Command) !*Tab {
    const alloc = self.app.core_app.alloc;

    const tab = try Tab.create(self, parent, self.tabs.items.len == 0, shell);
    errdefer tab.destroy();

    const idx: usize = if (self.tabs.items.len == 0)
        0
    else switch (self.app.config.@"window-new-tab-position") {
        .current => self.active + 1,
        .end => self.tabs.items.len,
    };
    try self.tabs.insert(alloc, idx, tab);
    self.selectTab(idx);
    return tab;
}

/// Open a new tab from the tab bar, inheriting from the active surface.
pub fn newTab(self: *Window) ?*Tab {
    return self.addTab(&self.activeSurface().core_surface) catch |err| {
        log.err("error creating tab err={}", .{err});
        return null;
    };
}

/// Make the tab at the given index active.
pub fn selectTab(self: *Window, idx: usize) void {
    if (idx >= self.tabs.items.len) return;

    self.active = idx;
    self.tab_bar.invalidate();

    // Hide all other tabs, and show and lay out the active one.
    for (self.tabs.items, 0..) |tab, i| {
        if (i != idx) tab.setVisible(false);
    }
    self.layout();

    const tab = self.tabs.items[idx];
    tab.focus(tab.focused);
    self.updateWindowTitle();
    self.updateTaskbarProgress();
}

/// Go to a tab, using the semantics of the goto_tab action.
pub fn gotoTab(self: *Window, goto: apprt.action.GotoTab) bool {
    const total = self.tabs.items.len;
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
    const total = self.tabs.items.len;
    if (total <= 1) return false;

    const total_i: isize = @intCast(total);
    const from = self.active;
    const to: usize = @intCast(@mod(@as(isize, @intCast(from)) + amount, total_i));
    if (from == to) return false;

    const tab = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(to, tab);
    self.selectTab(to);
    return true;
}

/// Close the given tab without confirmation. If it's the last tab, the
/// window is closed.
fn closeTab(self: *Window, tab: *Tab) void {
    const idx = self.tabIndex(tab) orelse return;

    // The last tab closes the window, which destroys the tab.
    if (self.tabs.items.len == 1) {
        if (!self.destroying) self.destroy();
        return;
    }

    _ = self.tabs.orderedRemove(idx);

    // Keep the same tab active. If the active tab was closed, the tab
    // that took its place (or the new last tab) becomes active.
    // Do this before destroying the old tab: DestroyWindow can send
    // WM_SETFOCUS to us synchronously, which reads activeSurface().
    if (idx < self.active) self.active -= 1;
    self.active = @min(self.active, self.tabs.items.len - 1);
    self.selectTab(self.active);
    tab.destroy();
}

/// Close the given surface without confirmation. This removes it from
/// its split tree, closing the tab if it's the last surface in it.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    const tab = self.tabOf(surface) orelse return;
    if (tab.isSingle()) {
        self.closeTab(tab);
        return;
    }

    tab.remove(surface) catch |err| {
        log.err("error removing split err={}", .{err});
    };
}

/// Close the tab at the given index, asking for confirmation if needed.
pub fn closeTabAt(self: *Window, idx: usize) void {
    if (idx >= self.tabs.items.len) return;
    self.closeTabs(self.tabs.items[idx].focused, .this);
}

/// Close tabs relative to the tab of the given surface, asking for
/// confirmation if any of them have a running process.
pub fn closeTabs(self: *Window, surface: *Surface, mode: apprt.action.CloseTabMode) void {
    const current = self.tabOf(surface) orelse return;
    const idx = self.tabIndex(current) orelse return;

    // Collect the tabs to close.
    const alloc = self.app.core_app.alloc;
    var targets: std.ArrayList(*Tab) = .empty;
    defer targets.deinit(alloc);
    for (self.tabs.items, 0..) |tab, i| {
        const close_it = switch (mode) {
            .this => i == idx,
            .other => i != idx,
            .right => i > idx,
        };
        if (close_it) targets.append(alloc, tab) catch return;
    }
    if (targets.items.len == 0) return;

    // A single surface goes through the core so it confirms as usual.
    if (targets.items.len == 1 and targets.items[0].isSingle()) {
        targets.items[0].focused.core_surface.close();
        return;
    }

    const hwnd = self.hwnd;
    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    for (targets.items) |tab| {
        if (tab.needsConfirmQuit()) {
            if (!confirm(
                self,
                "Close tabs?",
                "A process is still running in at least one of the terminals. Closing them will kill the processes.",
            )) return;
            // MessageBox pumps messages. A child can exit and close the
            // window while the confirmation is open.
            if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;
            break;
        }
    }

    for (targets.items) |tab| {
        if (self.tabIndex(tab) != null) self.closeTab(tab);
    }
}

/// Called by a surface when it gains focus.
pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    const tab = self.tabOf(surface) orelse return;
    tab.focused = surface;
    tab.updateDimming();
    self.tab_bar.invalidate();
    if (tab == self.activeTab()) {
        self.updateWindowTitle();
        self.updateTaskbarProgress();
    }
}

/// Show the focused surface's live progress on this window's taskbar button.
pub fn updateTaskbarProgress(self: *Window) void {
    _ = c.KillTimer(self.hwnd, progress_timer_id);
    if (!self.taskbar_ready) return;
    const taskbar = &self.app.taskbar;
    if (self.tabs.items.len == 0) {
        taskbar.clear(self.hwnd);
        return;
    }

    const surface = self.activeSurface();
    const now = c.GetTickCount64();
    if (!surface.progress_style or surface.progress_report == null or
        surface.progress_expires_at <= now)
    {
        taskbar.clear(self.hwnd);
        return;
    }

    const report = surface.progress_report.?;
    const state: c.TBPFLAG = switch (report.state) {
        .remove => c.TBPF_NOPROGRESS,
        .set => if (report.progress == null) c.TBPF_INDETERMINATE else c.TBPF_NORMAL,
        .@"error" => c.TBPF_ERROR,
        .indeterminate => c.TBPF_INDETERMINATE,
        .pause => c.TBPF_PAUSED,
    };
    taskbar.setState(self.hwnd, state);
    if (state != c.TBPF_INDETERMINATE and state != c.TBPF_NOPROGRESS) {
        taskbar.setValue(self.hwnd, report.progress orelse 100);
    }

    const remaining: c.UINT = @intCast(@min(surface.progress_expires_at - now, 15_000));
    _ = c.SetTimer(self.hwnd, progress_timer_id, @max(remaining, 1), null);
}

/// Called by a surface when its title changes.
pub fn surfaceTitleChanged(self: *Window, surface: *Surface) void {
    const tab = self.tabOf(surface) orelse return;
    if (tab.focused != surface) return;
    self.tab_bar.invalidate();
    if (tab == self.activeTab()) self.updateWindowTitle();
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
        .auto => self.tabs.items.len > 1,
        .never => false,
    };
}

/// The area of our client area that the active tab's surfaces fill.
pub fn surfaceArea(self: *const Window) c.RECT {
    var client: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &client) == 0) return std.mem.zeroes(c.RECT);
    if (self.showTabBar()) client.top = self.tab_bar.height();
    return client;
}

/// Position the tab bar and the active tab's surfaces within our
/// client area.
pub fn layout(self: *Window) void {
    const area = self.surfaceArea();
    if (self.showTabBar()) {
        _ = c.MoveWindow(self.tab_bar.hwnd, 0, 0, area.right, area.top, c.TRUE);
        _ = c.ShowWindow(self.tab_bar.hwnd, c.SW_SHOWNA);
        self.tab_bar.invalidate();
    } else {
        _ = c.ShowWindow(self.tab_bar.hwnd, c.SW_HIDE);
    }

    if (self.tabs.items.len > 0) self.activeTab().layout(area);

    // Repaint the split dividers.
    _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

/// The color of the dividers between splits.
fn dividerColor(self: *const Window) c.COLORREF {
    const config = &self.app.config;
    if (config.@"split-divider-color") |v| return rgb(v.r, v.g, v.b);

    // By default, blend the background toward the foreground a little so
    // the divider is visible but subtle in both light and dark themes.
    const bg = config.background;
    const fg = config.foreground;
    return rgb(
        mix(bg.r, fg.r),
        mix(bg.g, fg.g),
        mix(bg.b, fg.b),
    );
}

fn mix(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) * 3 + @as(u16, b)) / 4);
}

fn rgb(r: u8, g: u8, b: u8) c.COLORREF {
    return @as(c.COLORREF, r) | (@as(c.COLORREF, g) << 8) | (@as(c.COLORREF, b) << 16);
}

//----------------------------------------------------------------------------
// Window state

/// Request attention without moving keyboard focus. Windows stops the
/// taskbar flash automatically when this window comes to the foreground.
pub fn requestAttention(self: *Window) void {
    if (c.GetForegroundWindow() == self.hwnd) return;
    var info: c.FLASHWINFO = .{
        .cbSize = @sizeOf(c.FLASHWINFO),
        .hwnd = self.hwnd,
        .dwFlags = c.FLASHW_TRAY | c.FLASHW_TIMERNOFG,
        .uCount = 0,
        .dwTimeout = 0,
    };
    _ = c.FlashWindowEx(&info);
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

    if (msg == self.app.taskbar_button_created) {
        log.debug("taskbar button created", .{});
        self.taskbar_ready = true;
        self.updateTaskbarProgress();
        return 0;
    }

    switch (msg) {
        c.WM_TIMER => if (wparam == progress_timer_id) {
            self.updateTaskbarProgress();
            return 0;
        },
        c.WM_SIZE => {
            self.layout();
            return 0;
        },

        // We paint everything in WM_PAINT. Note that we can't use the
        // HDC passed in WPARAM here anyway: GDI handles aren't aligned
        // pointers, which Zig checks when converting from an integer.
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            // The only part of our client area not covered by child
            // windows is the space between splits, which we fill with
            // the divider color.
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);
            const brush = c.CreateSolidBrush(self.dividerColor());
            defer _ = c.DeleteObject(brush);
            _ = c.FillRect(hdc, &ps.rcPaint, brush);
            return 0;
        },

        c.WM_SETCURSOR => {
            if (util.loword(lparam) == c.HTCLIENT) {
                var pt: c.POINT = undefined;
                _ = c.GetCursorPos(&pt);
                _ = c.ScreenToClient(hwnd, &pt);
                if (self.activeTab().dividerAt(pt.x, pt.y)) |d| {
                    _ = c.SetCursor(util.loadSystemCursor(switch (d.layout) {
                        .horizontal => util.IDC_SIZEWE,
                        .vertical => util.IDC_SIZENS,
                    }));
                    return 1;
                }
            }
        },

        c.WM_LBUTTONDOWN => {
            const x: c_int = util.loword(lparam);
            const y: c_int = util.hiword(lparam);
            if (self.activeTab().dividerAt(x, y)) |d| {
                self.dragging = d;
                _ = c.SetCapture(hwnd);
            }
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (self.dragging) |d| {
                self.activeTab().dragDivider(d, util.loword(lparam), util.hiword(lparam));
            }
            return 0;
        },

        c.WM_LBUTTONUP, c.WM_CAPTURECHANGED => {
            if (self.dragging != null) {
                self.dragging = null;
                if (msg == c.WM_LBUTTONUP) _ = c.ReleaseCapture();
            }
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

        c.WM_DPICHANGED => {
            // Windows suggests a new size and position for our window
            // that keeps it at the same physical size on the new monitor.
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.tab_bar.updateFont();
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
            // With a single surface, go through the core so that it
            // confirms as usual and calls back into Surface.close.
            if (self.tabs.items.len == 1 and self.activeTab().isSingle()) {
                self.activeSurface().core_surface.close();
                return 0;
            }

            for (self.tabs.items) |tab| {
                if (tab.needsConfirmQuit()) {
                    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
                    if (!confirm(
                        self,
                        "Close window?",
                        "A process is still running in at least one of the terminals. Closing the window will kill the processes.",
                    )) return 0;
                    if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return 0;
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
