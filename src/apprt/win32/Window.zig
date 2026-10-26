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
const Overrides = @import("Overrides.zig");
const Menu = @import("Menu.zig");

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

/// The number of items in the default system menu. Our main menu items
/// follow them and are rebuilt each time the menu opens.
system_menu_base: c_int = 0,

/// The saved window state while we're fullscreen, used to restore it.
fullscreen: ?struct {
    style: c.LONG_PTR,
    placement: c.WINDOWPLACEMENT,
} = null,

/// Whether we've applied the initial size. We only apply it once.
initial_size_applied: bool = false,

/// The default terminal size in points, from the initial_size action,
/// used by reset_window_size.
default_size: ?struct { width: u32, height: u32 } = null,

/// Overrides `window-decoration` after toggle_window_decorations.
decorated_override: ?bool = null,

/// The minimum terminal size in pixels, from the size_limit action.
min_size: ?struct { width: u32, height: u32 } = null,

/// True while we're being destroyed, so closing the last tab doesn't
/// try to destroy us again.
destroying: bool = false,

/// Explorer sends TaskbarButtonCreated after the window's button exists.
taskbar_ready: bool = false,

/// A title set by the user, which takes precedence over the active tab's.
title_override: ?[:0]const u8 = null,

/// Whether this is the quick terminal: a borderless, topmost window
/// without a taskbar button that's toggled into view.
quick: bool = false,

/// What a new window starts with.
pub const Initial = union(enum) {
    /// A new tab, inheriting from the parent surface if given.
    parent: ?*CoreSurface,

    /// An existing tab moved from another window. The caller removes
    /// it from its old window once this succeeds.
    tab: *Tab,

    /// A new tab with overrides from +new-window.
    overrides: Overrides,

    /// The quick terminal, with a new tab.
    quick,
};

pub fn init(self: *Window, app: *App, initial: Initial) !void {
    const quick = initial == .quick;
    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tab_bar = undefined,
        .quick = quick,
    };

    const hwnd = c.CreateWindowExW(
        if (quick) c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST else 0,
        App.window_class,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        if (quick)
            c.WS_POPUP | c.WS_CLIPCHILDREN
        else
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

    if (c.GetSystemMenu(hwnd, c.FALSE)) |menu| {
        self.system_menu_base = @max(0, c.GetMenuItemCount(menu));
    }

    self.updateTheme();
    self.updateDecorations();
    self.updateBackdrop();

    try self.tab_bar.init(self);
    errdefer self.tab_bar.deinit();

    switch (initial) {
        .parent => |parent| _ = try self.addTab(parent),
        .tab => |tab| try self.adoptTab(tab),
        .overrides => |overrides| _ = try self.addTabWith(null, null, overrides),
        .quick => {
            // Size the window first, since popup windows start out empty
            // and the first surface's size sets the initial pty size.
            self.placeQuick(false);
            _ = try self.addTab(null);
        },
    }

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
    if (self.title_override) |v| alloc.free(v);
    for (self.tabs.items) |tab| tab.destroy();
    self.tabs.deinit(alloc);
    self.tab_bar.deinit();
}

/// Show the window for the first time.
pub fn show(self: *Window) void {
    if (self.quick) {
        self.showQuick();
        return;
    }
    _ = c.ShowWindow(self.hwnd, c.SW_SHOWDEFAULT);
    _ = c.UpdateWindow(self.hwnd);
}

/// Place the quick terminal according to its config, then show and
/// focus it. The screen is chosen each time, so it follows the mouse with
/// `quick-terminal-screen = mouse`.
pub fn showQuick(self: *Window) void {
    self.placeQuick(true);
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    self.present(self.activeSurface());
}

/// Move and size the quick terminal according to its config.
fn placeQuick(self: *Window, visible: bool) void {
    const config = &self.app.config;
    const monitor = switch (config.@"quick-terminal-screen") {
        .mouse => monitor: {
            var pt: c.POINT = undefined;
            _ = c.GetCursorPos(&pt);
            break :monitor c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTOPRIMARY);
        },
        .main, .@"macos-menu-bar" => c.MonitorFromPoint(.{ .x = 0, .y = 0 }, c.MONITOR_DEFAULTTOPRIMARY),
    };
    var info: c.MONITORINFO = undefined;
    info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &info) != 0) {
        const work = info.rcWork;
        var dpi_x: c.UINT = util.USER_DEFAULT_SCREEN_DPI;
        var dpi_y: c.UINT = util.USER_DEFAULT_SCREEN_DPI;
        _ = c.GetDpiForMonitor(monitor, c.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
        const rect = quickRect(
            config.@"quick-terminal-position",
            config.@"quick-terminal-size",
            work,
            dpi_x,
        );
        _ = util.SetWindowPos(
            self.hwnd,
            util.HWND_TOPMOST,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            if (visible) c.SWP_SHOWWINDOW else c.SWP_NOACTIVATE,
        );
    }
}

/// The quick terminal's rectangle within a monitor's work area. Pixel
/// sizes are in points, scaled by the monitor's DPI.
fn quickRect(
    position: configpkg.Config.QuickTerminalPosition,
    size: configpkg.Config.QuickTerminalSize,
    work: c.RECT,
    dpi: c.UINT,
) c.RECT {
    const work_w: u32 = @intCast(work.right - work.left);
    const work_h: u32 = @intCast(work.bottom - work.top);
    var scaled = size;
    inline for (.{ &scaled.primary, &scaled.secondary }) |s| {
        if (s.*) |v| switch (v) {
            .pixels => |px| s.* = .{ .pixels = @intCast(@as(u64, px) * dpi / util.USER_DEFAULT_SCREEN_DPI) },
            .percentage => {},
        };
    }
    var dims = scaled.calculate(position, .{ .width = work_w, .height = work_h });
    if (size.primary == null) {
        // The defaults are in points too.
        switch (position) {
            .left, .right => dims.width = @intCast(@as(u64, dims.width) * dpi / util.USER_DEFAULT_SCREEN_DPI),
            .top, .bottom => dims.height = @intCast(@as(u64, dims.height) * dpi / util.USER_DEFAULT_SCREEN_DPI),
            .center => {
                dims.width = @intCast(@as(u64, dims.width) * dpi / util.USER_DEFAULT_SCREEN_DPI);
                dims.height = @intCast(@as(u64, dims.height) * dpi / util.USER_DEFAULT_SCREEN_DPI);
            },
        }
    }
    const w: c_int = @intCast(@min(dims.width, work_w));
    const h: c_int = @intCast(@min(dims.height, work_h));
    const center_x = work.left + @divTrunc(@as(c_int, @intCast(work_w)) - w, 2);
    const center_y = work.top + @divTrunc(@as(c_int, @intCast(work_h)) - h, 2);
    const x: c_int, const y: c_int = switch (position) {
        .top => .{ center_x, work.top },
        .bottom => .{ center_x, work.bottom - h },
        .left => .{ work.left, center_y },
        .right => .{ work.right - w, center_y },
        .center => .{ center_x, center_y },
    };
    return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
}

test quickRect {
    const testing = std.testing;
    const work: c.RECT = .{ .left = 0, .top = 40, .right = 2000, .bottom = 1040 };

    // Top, default size at 200% scale: full width, 400pt tall.
    try testing.expectEqual(
        c.RECT{ .left = 0, .top = 40, .right = 2000, .bottom = 840 },
        quickRect(.top, .{}, work, 192),
    );

    // Bottom, half the height and 1000px (500pt) wide, centered.
    try testing.expectEqual(
        c.RECT{ .left = 500, .top = 540, .right = 1500, .bottom = 1040 },
        quickRect(.bottom, .{ .primary = .{ .percentage = 50 }, .secondary = .{ .pixels = 500 } }, work, 192),
    );

    // Right, 25% wide, full height.
    try testing.expectEqual(
        c.RECT{ .left = 1500, .top = 40, .right = 2000, .bottom = 1040 },
        quickRect(.right, .{ .primary = .{ .percentage = 25 } }, work, 96),
    );
}

/// Hide the quick terminal.
pub fn hideQuick(self: *Window) void {
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
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
    return self.addTabWith(parent, shell, .none);
}

/// Open a tab with an explicit shell and overrides for its surface.
pub fn addTabWith(
    self: *Window,
    parent: ?*CoreSurface,
    shell: ?configpkg.Command,
    overrides: Overrides,
) !*Tab {
    const alloc = self.app.core_app.alloc;

    const tab = try Tab.create(self, parent, self.tabs.items.len == 0, shell, overrides);
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

/// Take ownership of a tab from another window and select it. This
/// reparents its surfaces to this window.
fn adoptTab(self: *Window, tab: *Tab) !void {
    try self.tabs.append(self.app.core_app.alloc, tab);
    tab.window = self;
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        entry.view.window = self;
        _ = c.SetParent(entry.view.hwnd, self.hwnd);
    }
    self.selectTab(self.tabs.items.len - 1);
}

/// Move the tab containing the given surface to a new window. Like GTK,
/// this does nothing if it's the only tab.
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) !bool {
    if (self.tabs.items.len <= 1) return false;
    const tab = self.tabOf(surface) orelse return false;
    const idx = self.tabIndex(tab) orelse return false;

    const window = try self.app.newWindow(.{ .tab = tab });

    _ = self.tabs.orderedRemove(idx);
    if (idx < self.active) self.active -= 1;
    self.active = @min(self.active, self.tabs.items.len - 1);
    self.dragging = null;
    self.selectTab(self.active);

    // Selecting our remaining tab focuses it, which activates this window
    // again. The moved tab should end up in front.
    window.present(tab.focused);
    return true;
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
    surface.bell_pending = false;
    surface.updateBellBorder();
    tab.updateDimming();
    self.tab_bar.invalidate();
    if (tab == self.activeTab()) {
        self.updateWindowTitle();
        self.updateTaskbarProgress();
    }
}

/// Mark a bell from a surface until it's focused or receives key input.
pub fn surfaceBell(self: *Window, surface: *Surface) void {
    if (self.tabOf(surface) == null) return;
    surface.setBellPending(true);
}

/// Refresh the tab markers and title after a pending bell changes.
pub fn updateBellIndicators(self: *Window) void {
    self.tab_bar.invalidate();
    if (self.tabs.items.len > 0) self.updateWindowTitle();
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
    if (!surface.progress_style or surface.progress_report == null) {
        taskbar.clear(self.hwnd);
        return;
    }
    if (surface.progress_expires_at <= now) {
        log.debug("progress report expired", .{});
        surface.progress_report = null;
        surface.progress_value = null;
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
        // A pause without a percentage retains the previous fraction.
        // Error without one similarly keeps the last known value.
        taskbar.setValue(self.hwnd, report.progress orelse surface.progress_value orelse 100);
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

/// Set or clear (with null or an empty title) the user's title override.
pub fn setTitleOverride(self: *Window, value: ?[]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title_override) |v| alloc.free(v);
    self.title_override = null;
    if (value) |v| if (v.len > 0) {
        self.title_override = alloc.dupeSentinel(u8, v, 0) catch null;
    };
    self.updateWindowTitle();
}

fn updateWindowTitle(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    const title = self.title_override orelse self.activeTab().title();
    const pending = for (self.tabs.items) |tab| {
        if (tab.hasBell()) break true;
    } else false;
    // Like other platforms, mark the title with a bell emoji. We do so
    // for any tab so that it remains visible when the tab bar is hidden.
    const display_title = if (pending)
        std.fmt.allocPrint(alloc, "🔔 {s}", .{title}) catch return
    else
        alloc.dupe(u8, title) catch return;
    defer alloc.free(display_title);
    const title16 = util.utf16Alloc(alloc, display_title) catch return;
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

/// Apply app-level config changes, such as the tab bar colors and
/// visibility and the window theme.
pub fn configChanged(self: *Window) void {
    self.updateTheme();
    self.updateDecorations();
    self.updateBackdrop();
    self.layout();
}

/// Toggle the title bar, like GTK: back to the config's setting if we
/// had toggled it, otherwise to the opposite of the config's setting.
pub fn toggleDecorations(self: *Window) void {
    self.decorated_override = if (self.decorated_override) |_|
        null
    else
        self.app.config.@"window-decoration" == .none;
    self.updateDecorations();
}

/// Show or hide the title bar. The resize border stays either way.
fn updateDecorations(self: *Window) void {
    // Fullscreen has no frame; we're called again when it's restored.
    // The quick terminal never has one.
    if (self.fullscreen != null or self.quick) return;
    const decorated = self.decorated_override orelse
        (self.app.config.@"window-decoration" != .none);

    const style = c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE);
    const caption: c.LONG_PTR = c.WS_CAPTION;
    const new_style = if (decorated) style | caption else style & ~caption;
    if (new_style == style) return;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, new_style);
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER |
            c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    );
}

/// Keep this window above other windows, or stop doing so.
pub fn setFloating(self: *Window, mode: apprt.action.FloatWindow) void {
    const ex_style = c.GetWindowLongPtrW(self.hwnd, c.GWL_EXSTYLE);
    const floating = ex_style & c.WS_EX_TOPMOST != 0;
    const float = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !floating,
    };
    _ = util.SetWindowPos(
        self.hwnd,
        if (float) util.HWND_TOPMOST else util.HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE,
    );
}

/// Use a light or dark title bar according to `window-theme`. This
/// matches the GTK apprt: `auto` and `ghostty` follow the luminance of
/// the terminal background.
fn paintDividers(self: *Window, hdc: c.HDC) void {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &rect);
    const brush = c.CreateSolidBrush(self.dividerColor());
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &rect, brush);
}

/// For `background-opacity`, let the desktop show through wherever the
/// terminal is translucent. With `background-blur`, this extends the window
/// frame over the client area with the Windows 11 acrylic backdrop.
/// Without blur, a blur-behind region that's empty gives us per-pixel
/// alpha without the blur: extended frames without a backdrop are drawn
/// as a solid color since Windows 8.
fn updateBackdrop(self: *Window) void {
    const config = &self.app.config;
    const translucent = self.app.translucent();
    const blur = translucent and switch (config.@"background-blur") {
        .false => false,
        .radius => |r| r > 0,
        else => true,
    };

    const extend: c_int = if (blur) -1 else 0;
    const margins: c.MARGINS = .{
        .cxLeftWidth = extend,
        .cxRightWidth = extend,
        .cyTopHeight = extend,
        .cyBottomHeight = extend,
    };
    _ = c.DwmExtendFrameIntoClientArea(self.hwnd, &margins);

    const DWMWA_SYSTEMBACKDROP_TYPE = 38;
    const DWMSBT_AUTO = 0;
    const DWMSBT_TRANSIENTWINDOW = 3;
    const backdrop: c.DWORD = if (blur) DWMSBT_TRANSIENTWINDOW else DWMSBT_AUTO;
    _ = c.DwmSetWindowAttribute(
        self.hwnd,
        DWMWA_SYSTEMBACKDROP_TYPE,
        &backdrop,
        @sizeOf(c.DWORD),
    );

    const region = if (translucent and !blur) c.CreateRectRgn(0, 0, -1, -1) else null;
    defer if (region != null) {
        _ = c.DeleteObject(region);
    };
    var blur_behind: c.DWM_BLURBEHIND = .{
        .dwFlags = c.DWM_BB_ENABLE | c.DWM_BB_BLURREGION,
        .fEnable = @intFromBool(translucent and !blur),
        .hRgnBlur = region,
        .fTransitionOnMaximized = c.FALSE,
    };
    _ = c.DwmEnableBlurBehindWindow(self.hwnd, &blur_behind);
    _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

fn updateTheme(self: *Window) void {
    const config = &self.app.config;
    const dark = switch (config.@"window-theme") {
        .auto, .ghostty => config.background.toTerminalRGB().perceivedLuminance() <= 0.5,
        .system => systemUsesDarkTheme(),
        .dark => true,
        .light => false,
    };

    const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    const value: c.BOOL = @intFromBool(dark);
    _ = c.DwmSetWindowAttribute(
        self.hwnd,
        DWMWA_USE_IMMERSIVE_DARK_MODE,
        &value,
        @sizeOf(c.BOOL),
    );
}

/// Whether the user chose the dark app mode in the Windows settings.
fn systemUsesDarkTheme() bool {
    // HKEY_CURRENT_USER isn't a validly aligned pointer for Zig, so we
    // open the current user's key instead.
    var current_user: c.HKEY = null;
    if (c.RegOpenCurrentUser(c.KEY_READ, &current_user) != c.ERROR_SUCCESS) return false;
    defer _ = c.RegCloseKey(current_user);

    var value: c.DWORD = 1;
    var size: c.DWORD = @sizeOf(c.DWORD);
    if (c.RegGetValueW(
        current_user,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme"),
        c.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    ) != c.ERROR_SUCCESS) return false;
    return value == 0;
}

/// Bring this window to the front and focus the given surface.
pub fn present(self: *Window, surface: *Surface) void {
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
    const tab = self.tabOf(surface) orelse return;
    const idx = self.tabIndex(tab) orelse return;
    if (idx != self.active) self.selectTab(idx);
    tab.focus(surface);
}

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
        self.updateDecorations();
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

/// Set the initial size of the window, given the size of the terminal
/// in points. This is applied once, and remembered for
/// reset_window_size.
pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    self.default_size = .{ .width = width, .height = height };
    if (self.initial_size_applied) return;
    self.initial_size_applied = true;
    self.setTerminalSize(self.pointsToPixels(width), self.pointsToPixels(height));
}

/// Restore the default size from initial_size, if we have one.
pub fn resetSize(self: *Window) bool {
    const size = self.default_size orelse return false;
    if (self.fullscreen != null) return false;
    if (c.IsZoomed(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    self.setTerminalSize(self.pointsToPixels(size.width), self.pointsToPixels(size.height));
    return true;
}

/// Resize the window so its terminal is the requested size in points. A zero dimension keeps the current size. Like GTK, this only
/// applies to a window with a single unsplit tab that isn't maximized
/// or fullscreen.
pub fn resizeTerminal(self: *Window, size: apprt.action.ResizeWindow) bool {
    if (self.fullscreen != null or c.IsZoomed(self.hwnd) != 0) return false;
    if (self.tabs.items.len != 1 or !self.tabs.items[0].isSingle()) return false;

    const area = self.surfaceArea();
    self.setTerminalSize(
        if (size.width == 0) @intCast(area.right - area.left) else self.pointsToPixels(size.width),
        if (size.height == 0) @intCast(area.bottom - area.top) else self.pointsToPixels(size.height),
    );
    return true;
}

pub fn setSizeLimit(self: *Window, limit: apprt.action.SizeLimit) void {
    // We have no use for a maximum size, which the core doesn't send.
    self.min_size = .{ .width = limit.min_width, .height = limit.min_height };
}

fn pointsToPixels(self: *const Window, points: u32) u32 {
    return @intCast(@divTrunc(@as(u64, points) * c.GetDpiForWindow(self.hwnd), util.USER_DEFAULT_SCREEN_DPI));
}

/// The window size for the given terminal area size in pixels,
/// including the tab bar and the window frame.
fn windowSizeFor(self: *const Window, width: u32, height: u32) struct { c_int, c_int } {
    const style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE))));
    const ex_style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_EXSTYLE))));
    var rect: c.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(width),
        .bottom = @as(c_int, @intCast(height)) + if (self.showTabBar()) self.tab_bar.height() else 0,
    };
    _ = c.AdjustWindowRectExForDpi(&rect, style, c.FALSE, ex_style, c.GetDpiForWindow(self.hwnd));
    return .{ rect.right - rect.left, rect.bottom - rect.top };
}

/// Resize the window so the terminal area is the given size in pixels.
fn setTerminalSize(self: *Window, width: u32, height: u32) void {
    const w, const h = self.windowSizeFor(width, height);
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        w,
        h,
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

/// Replace our items in the system menu, so that their shortcuts and
/// whether they're enabled are current.
fn updateSystemMenu(self: *Window, menu: c.HMENU) void {
    while (c.GetMenuItemCount(menu) > self.system_menu_base) {
        if (c.DeleteMenu(menu, @intCast(self.system_menu_base), c.MF_BYPOSITION) == 0) break;
    }

    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    Menu.appendToSystemMenu(arena.allocator(), menu, &Menu.main, self.activeSurface()) catch |err| {
        log.warn("error building system menu err={}", .{err});
    };
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

        c.WM_GETMINMAXINFO => if (self.min_size) |min| {
            const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const w, const h = self.windowSizeFor(min.width, min.height);
            info.ptMinTrackSize.x = @max(info.ptMinTrackSize.x, w);
            info.ptMinTrackSize.y = @max(info.ptMinTrackSize.y, h);
            return 0;
        },

        // Sent when the system light/dark mode changes, among others.
        c.WM_SETTINGCHANGE => {
            self.updateTheme();
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
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
            util.paintOpaque(hdc, ps.rcPaint, self, paintDividers);
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
            if (!active and self.quick and self.app.config.@"quick-terminal-autohide") {
                self.hideQuick();
            }
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

        c.WM_INITMENUPOPUP => if (c.GetSystemMenu(hwnd, c.FALSE)) |menu| {
            if (@intFromPtr(menu) == wparam) self.updateSystemMenu(menu);
        },

        c.WM_SYSCOMMAND => if (Menu.systemCommand(&Menu.main, wparam)) |action| {
            self.activeSurface().performMenuAction(action);
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
