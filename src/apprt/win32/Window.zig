//! A top-level window. A window hosts one or more tabs, and each tab is
//! a tree of surfaces (splits). Each surface is a child window and only
//! the surfaces of the active tab are shown.
const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");

const util = @import("util.zig");
const i18n = @import("../../os/main.zig").i18n;
const c = util.c;
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabBar = @import("TabBar.zig");
const Taskbar = @import("Taskbar.zig");
const Overrides = @import("Overrides.zig");
const Menu = @import("Menu.zig");
const Dialog = @import("Dialog.zig");
const shells = @import("shells.zig");
const SaveState = @import("SaveState.zig");
const SplitDrag = @import("SplitDrag.zig");

const log = std.log.scoped(.win32);

const progress_timer_id = 1;
const quick_slide_timer_id = 2;
const undo_timer_id = 3;
const closed_window_timer_id = 4;

/// Posted to update the title bar and tab bar after title changes.
const WM_GHOSTTY_TITLE_CHANGED = c.WM_APP + 20;

/// Posted to lay out the window again, after a terminal's cell size
/// changed (which sets the minimum size of its side of a split).
const WM_GHOSTTY_LAYOUT = c.WM_APP + 21;

/// A closed tab or split that `undo` can reopen until it expires.
const Closed = struct {
    what: What,

    /// When to destroy it, from GetTickCount64.
    expires: u64,

    const What = union(enum) {
        /// A tab that was at the given index.
        tab: struct { tab: *Tab, index: usize },

        /// A surface that was split in the tab. We hold a reference to it.
        split: struct { tab: *Tab, surface: *Surface, placement: Tab.Placement },
    };
};

/// A tab or split reopened by `undo`.
const Reopened = union(enum) {
    tab: *Tab,
    split: *Surface,
};

app: *App,

/// The top-level window handle.
hwnd: c.HWND,

/// The tab bar.
tab_bar: TabBar,

/// The tabs in this window, in order.
tabs: std.ArrayList(*Tab) = .empty,

/// Closed tabs and splits, most recent last. Their surfaces stay alive
/// (and hidden) so that `undo` can reopen them, until the undo timeout.
closed: std.ArrayList(Closed) = .empty,

/// Tabs and splits reopened by `undo`, most recent last, which `redo`
/// closes again. Entries are removed when they close otherwise.
reopened: std.ArrayList(Reopened) = .empty,

/// The index of the active tab.
active: usize = 0,

/// The split divider being dragged, if any.
dragging: ?Tab.Divider = null,

/// The terminal showing where a dragged split would drop, if any.
drop_target: ?*Surface = null,

/// Whether a restored window was maximized when its state was saved.
restore_maximized: bool = false,

/// Set when the user asks to close the window, as opposed to it closing
/// because its last terminal exited.
closing_by_user: bool = false,

/// While the window is closed but `undo` can still reopen it, when it's
/// destroyed (from GetTickCount64). Zero while it's open.
closed_expires: u64 = 0,

/// The number of items in the default system menu. Our main menu items
/// follow them and are rebuilt each time the menu opens.
system_menu_base: c_int = 0,

/// The shells our system menu items were last built with, which its
/// commands refer to by index, and the arena that holds them.
system_menu_arena: ?std.heap.ArenaAllocator = null,
system_menu_shells: []const shells.Shell = &.{},

/// The saved window state while we're fullscreen, used to restore it.
fullscreen: ?struct {
    style: c.LONG_PTR,
    placement: c.WINDOWPLACEMENT,
} = null,

/// Whether we've applied the initial size. We only apply it once.
initial_size_applied: bool = false,

/// The DPI our layout and our terminals' fonts were last made for. See
/// syncDpi.
dpi: c.UINT = util.USER_DEFAULT_SCREEN_DPI,

/// The monitor a new window was placed on, next to the window it was
/// opened from, until it's shown. See cascadeOrigin.
placed_on: ?c.HMONITOR = null,

/// Whether the saved session set our size and position, which the DPI
/// then mustn't change.
restored: bool = false,

/// The default terminal size in points, from the initial_size action,
/// used by reset_window_size.
default_size: ?struct { width: u32, height: u32 } = null,

/// Overrides `window-decoration` after toggle_window_decorations.
decorated_override: ?bool = null,

/// Whether the tabs are in the title bar: the client area covers the
/// caption, and the tab bar draws the caption buttons. See tabsInTitleBar.
titlebar_tabs: bool = false,

/// The minimum terminal size in pixels, from the size_limit action.
min_size: ?struct { width: u32, height: u32 } = null,

/// True while we're being destroyed, so closing the last tab doesn't
/// try to destroy us again.
destroying: bool = false,

/// Explorer sends TaskbarButtonCreated after the window's button exists.
taskbar_ready: bool = false,

/// True while a WM_GHOSTTY_TITLE_CHANGED is posted and not yet handled.
title_change_posted: bool = false,

/// True while a WM_GHOSTTY_LAYOUT is posted and not yet handled.
layout_posted: bool = false,

/// Whether the window is minimized, while which its surfaces don't draw.
minimized: bool = false,

/// A title set by the user, which takes precedence over the active tab's.
title_override: ?[:0]const u8 = null,

/// Whether this is the quick terminal: a borderless, topmost window
/// without a taskbar button that's toggled into view.
quick: bool = false,

/// Whether toggle_visibility hid this window, so showing them again
/// brings back only the ones that were shown.
hidden_by_toggle: bool = false,

/// The quick terminal's rectangle when fully shown, and how much of it is
/// shown, from 0 (hidden) to 1. It slides in from its edge of the screen.
quick_target: c.RECT = std.mem.zeroes(c.RECT),
quick_shown: f32 = 0,

/// The quick terminal's slide animation, while one is running.
quick_slide: ?QuickSlide = null,

const QuickSlide = struct {
    from: f32,
    to: f32,
    start_ms: u64,
    duration_ms: u64,
};

/// What a new window starts with.
pub const Initial = union(enum) {
    /// A new tab, inheriting from the parent surface if given.
    parent: ?*CoreSurface,

    /// An existing tab moved from another window. The caller removes
    /// it from its old window once this succeeds.
    tab: *Tab,

    /// A new tab with overrides from +new-window.
    overrides: Overrides,

    /// A new tab with a shell chosen from a shell menu, or the configured
    /// command when null.
    shell: struct { parent: ?*CoreSurface, shell: ?configpkg.Command },

    /// The quick terminal, with a new tab.
    quick,

    /// Saved tabs and placement, for window-save-state.
    restored: *const SaveState.WindowState,
};

pub fn init(self: *Window, app: *App, initial: Initial) !void {
    const quick = initial == .quick;
    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tab_bar = undefined,
        .quick = quick,
    };

    // A new window opens by the one it was opened from, on its monitor.
    // Left to Windows, it can open on another monitor (the primary one),
    // and with two monitors at different scales it then kept the scale
    // of the one it didn't open on.
    const origin: ?Origin = if (quick or initial == .restored) null else cascadeOrigin(app);
    const hwnd = c.CreateWindowExW(
        if (quick) c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST else 0,
        App.window_class,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        if (quick)
            c.WS_POPUP | c.WS_CLIPCHILDREN
        else
            c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        if (origin) |v| v.at.x else util.CW_USEDEFAULT,
        if (origin) |v| v.at.y else util.CW_USEDEFAULT,
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
    self.dpi = c.GetDpiForWindow(hwnd);

    // Explorer runs without elevation, and an elevated Ghostty ("Run as
    // administrator") would never get its TaskbarButtonCreated: Windows
    // drops messages from a less trusted process unless the window lets
    // them in. Without it the taskbar button never shows progress.
    if (ChangeWindowMessageFilterEx(hwnd, app.taskbar_button_created, MSGFLT_ALLOW, null) == 0) {
        log.warn("unable to let TaskbarButtonCreated through err={}", .{c.GetLastError()});
    }
    if (origin) |v| self.placed_on = v.monitor;

    if (c.GetSystemMenu(hwnd, c.FALSE)) |menu| {
        self.system_menu_base = @max(0, c.GetMenuItemCount(menu));
    }

    self.updateTheme();
    self.updateDecorations();
    self.updateBackdrop();
    if (!quick and app.windows.items.len == 0) self.placeAtConfiguredPosition();

    try self.tab_bar.init(self);
    errdefer self.tab_bar.deinit();

    switch (initial) {
        .parent => |parent| _ = try self.addTab(parent),
        .tab => |tab| try self.adoptTab(tab, null),
        .overrides => |overrides| _ = try self.addTabWith(null, null, overrides),
        .shell => |shell| _ = try self.addTabWithShell(shell.parent, shell.shell),
        .quick => {
            // Size the window first, since popup windows start out empty
            // and the first surface's size sets the initial pty size.
            self.placeQuick(false);
            _ = try self.addTab(null);
        },
        .restored => |state| try self.restore(state),
    }

    // Only now that we're fully initialized do we attach ourselves to
    // the window, so our window procedure (in particular WM_DESTROY)
    // never sees a partially initialized window.
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Sized now, it may reach past the monitor's edge.
    if (self.placed_on) |monitor| self.fitOnMonitor(monitor);
    // Until now our window procedure ignored its messages, a DPI change
    // among them.
    self.syncDpi();
    self.layout();
}

/// Where a new window goes, and on which monitor.
const Origin = struct { at: c.POINT, monitor: c.HMONITOR };

/// The place for a new window: down and right of the window it's opened
/// from (the active one), by about a title bar. Null if there's no such
/// window to go by, and Windows chooses.
fn cascadeOrigin(app: *App) ?Origin {
    // The active window if it will do, or else the newest that will: the
    // active one can be the quick terminal, or minimized, or (going by
    // the focused terminal) a closed window that's kept for undo.
    const usable = struct {
        fn usable(window: *const Window) bool {
            return !window.quick and
                c.IsWindowVisible(window.hwnd) != 0 and
                c.IsIconic(window.hwnd) == 0;
        }
    }.usable;
    const source = source: {
        if (app.activeWindow()) |window| {
            if (usable(window)) break :source window;
        }
        var i = app.windows.items.len;
        while (i > 0) {
            i -= 1;
            if (usable(app.windows.items[i])) break :source app.windows.items[i];
        }
        return null;
    };

    var rect: c.RECT = undefined;
    if (c.GetWindowRect(source.hwnd, &rect) == 0) return null;
    const monitor = c.MonitorFromWindow(source.hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return null;
    var info: c.MONITORINFO = undefined;
    info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &info) == 0) return null;

    const step = util.scale(32, @intCast(c.GetDpiForWindow(source.hwnd)));
    return .{ .at = cascade(rect, info.rcWork, step), .monitor = monitor };
}

/// A window's place a step down and right of another's, inside the
/// monitor's work area: from a maximized or fullscreen window, or one
/// near the far edges, it starts over near the work area's corner.
fn cascade(from: c.RECT, work: c.RECT, step: c_int) c.POINT {
    var at: c.POINT = .{ .x = from.left + step, .y = from.top + step };
    // Leave room for a useful part of a window.
    const room = step * 8;
    if (at.x < work.left or at.x > work.right - room) at.x = work.left + step;
    if (at.y < work.top or at.y > work.bottom - room) at.y = work.top + step;
    return at;
}

test cascade {
    const testing = std.testing;
    const work: c.RECT = .{ .left = 1920, .top = 0, .right = 3840, .bottom = 1040 };
    // By the window it came from, on the second monitor.
    try testing.expectEqual(c.POINT{ .x = 2132, .y = 232 }, cascade(.{ .left = 2100, .top = 200, .right = 2900, .bottom = 800 }, work, 32));
    // From a maximized window (which reaches past the edges): just
    // inside it. From one at the far corner: near the work area's corner.
    try testing.expectEqual(c.POINT{ .x = 1944, .y = 24 }, cascade(.{ .left = 1912, .top = -8, .right = 3848, .bottom = 1048 }, work, 32));
    try testing.expectEqual(c.POINT{ .x = 1952, .y = 32 }, cascade(.{ .left = 3700, .top = 900, .right = 4500, .bottom = 1500 }, work, 32));
    // Only one of the two.
    try testing.expectEqual(c.POINT{ .x = 2132, .y = 32 }, cascade(.{ .left = 2100, .top = 900, .right = 2900, .bottom = 1500 }, work, 32));
}

/// Move the window, without resizing it, so that it doesn't reach past
/// the right or bottom of the monitor's work area, if it fits.
fn fitOnMonitor(self: *Window, monitor: c.HMONITOR) void {
    var info: c.MONITORINFO = undefined;
    info.cbSize = @sizeOf(c.MONITORINFO);
    var rect: c.RECT = undefined;
    if (c.GetMonitorInfoW(monitor, &info) == 0 or c.GetWindowRect(self.hwnd, &rect) == 0) return;
    const at = fit(rect, info.rcWork);
    if (at.x == rect.left and at.y == rect.top) return;
    _ = c.SetWindowPos(self.hwnd, null, at.x, at.y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// Where a window's top left goes for it to be inside a work area: moved
/// left and up as far as needed, but never past the area's top left.
fn fit(rect: c.RECT, work: c.RECT) c.POINT {
    return .{
        .x = @max(work.left, rect.left - @max(0, rect.right - work.right)),
        .y = @max(work.top, rect.top - @max(0, rect.bottom - work.bottom)),
    };
}

test fit {
    const testing = std.testing;
    const work: c.RECT = .{ .left = 1920, .top = 0, .right = 3840, .bottom = 1040 };
    // Inside already.
    try testing.expectEqual(c.POINT{ .x = 2000, .y = 100 }, fit(.{ .left = 2000, .top = 100, .right = 2800, .bottom = 700 }, work));
    // Past the right and the bottom: moved back by as much.
    try testing.expectEqual(c.POINT{ .x = 3040, .y = 440 }, fit(.{ .left = 3500, .top = 800, .right = 4300, .bottom = 1400 }, work));
    // Larger than the area: its top left stays in it.
    try testing.expectEqual(c.POINT{ .x = 1920, .y = 0 }, fit(.{ .left = 2000, .top = 100, .right = 5000, .bottom = 3000 }, work));
}

/// Catch up with the window's DPI if it isn't the one we laid out and
/// made our terminals' fonts for. Windows says when it changes
/// (WM_DPICHANGED), but a window that's still being made doesn't hear it,
/// and Windows can move a new window to another monitor before it shows:
/// one then opened on a monitor with the scale of another (seen with two
/// monitors at different scales). Called once it's made and once it's
/// shown.
fn syncDpi(self: *Window) void {
    const dpi = c.GetDpiForWindow(self.hwnd);
    if (dpi == self.dpi or dpi == 0) return;
    log.info("window dpi changed while it was made from={} to={}", .{ self.dpi, dpi });
    self.dpi = dpi;
    self.tab_bar.updateFont();
    for (self.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.refreshContentScale();
    }

    // Its size was worked out in pixels for a DPI, perhaps the old one:
    // work it out again from the size in points.
    if (!self.quick and !self.restored and self.fullscreen == null and c.IsZoomed(self.hwnd) == 0) {
        if (self.default_size) |size| {
            self.setTerminalSize(self.pointsToPixels(size.width), self.pointsToPixels(size.height));
        }
    }
    self.layout();
}

/// Free the resources of the window. This doesn't destroy the window
/// handle; this is called while the window is being destroyed.
pub fn deinit(self: *Window) void {
    _ = c.KillTimer(self.hwnd, progress_timer_id);
    _ = c.KillTimer(self.hwnd, quick_slide_timer_id);
    _ = c.KillTimer(self.hwnd, undo_timer_id);
    _ = c.KillTimer(self.hwnd, closed_window_timer_id);
    const alloc = self.app.core_app.alloc;
    if (self.title_override) |v| alloc.free(v);
    for (self.tabs.items) |tab| tab.destroy();
    self.tabs.deinit(alloc);
    while (self.closed.pop()) |closed| self.release(closed.what);
    self.closed.deinit(alloc);
    self.reopened.deinit(alloc);
    self.tab_bar.deinit();
    if (self.system_menu_arena) |*arena| arena.deinit();
}

/// Show the window for the first time.
pub fn show(self: *Window) void {
    if (self.quick) {
        self.showQuick();
        return;
    }
    // Start maximized or in fullscreen per the config. The initial size
    // has already been set, so it's the size the window restores to.
    const config = &self.app.config;
    const maximize = config.maximize or self.restore_maximized;
    // A handed off console session's window starts as its program asked.
    const command = self.app.next_show orelse
        if (maximize) c.SW_SHOWMAXIMIZED else c.SW_SHOWDEFAULT;
    _ = c.ShowWindow(self.hwnd, command);
    self.placed_on = null;
    self.syncDpi();
    _ = c.UpdateWindow(self.hwnd);
    if (command == c.SW_SHOWMINNOACTIVE) return;
    if (config.fullscreen != .false and self.fullscreen == null) self.toggleFullscreen();
}

/// Place the quick terminal according to its config, then show and
/// focus it. The screen is chosen each time, so it follows the mouse with
/// `quick-terminal-screen = mouse`.
pub fn showQuick(self: *Window) void {
    self.showQuickWith(self.activeSurface());
}

/// `showQuick`, focusing `surface`.
fn showQuickWith(self: *Window, surface: *Surface) void {
    // If it's still sliding out, it slides back in from where it is.
    if (c.IsWindowVisible(self.hwnd) == 0) self.quick_shown = 0;
    const target = self.quickTarget() orelse self.quick_target;
    self.quick_target = target;

    // Windows doesn't put tool windows on a virtual desktop, so the quick
    // terminal shows on whichever one the user is on, as with
    // `quick-terminal-space-behavior = move`.

    _ = util.SetWindowPos(
        self.hwnd,
        util.HWND_TOPMOST,
        target.left,
        target.top,
        target.right - target.left,
        target.bottom - target.top,
        c.SWP_NOACTIVATE,
    );
    self.slideQuick(1);
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    // present calls back here while it's hidden.
    if (!self.quickShowing()) return;
    self.present(surface);
}

/// Whether the quick terminal is shown or sliding in.
pub fn quickShowing(self: *const Window) bool {
    if (c.IsWindowVisible(self.hwnd) == 0) return false;
    const slide = self.quick_slide orelse return true;
    return slide.to > 0;
}

/// Move and size the quick terminal according to its config.
fn placeQuick(self: *Window, visible: bool) void {
    const rect = self.quickTarget() orelse return;
    self.quick_target = rect;
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

/// The quick terminal's rectangle according to its config, on the screen
/// it's configured to use.
fn quickTarget(self: *const Window) ?c.RECT {
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
    if (c.GetMonitorInfoW(monitor, &info) == 0) return null;
    var dpi_x: c.UINT = util.USER_DEFAULT_SCREEN_DPI;
    var dpi_y: c.UINT = util.USER_DEFAULT_SCREEN_DPI;
    _ = c.GetDpiForMonitor(monitor, c.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
    return quickRect(
        config.@"quick-terminal-position",
        config.@"quick-terminal-size",
        info.rcWork,
        dpi_x,
    );
}

/// Slide the quick terminal toward being shown (1) or hidden (0), from
/// wherever it is now, over `quick-terminal-animation-duration`. It's
/// hidden at the end of sliding out. With Windows' animation effects
/// turned off, it appears and disappears in place.
fn slideQuick(self: *Window, to: f32) void {
    const config = &self.app.config;
    const seconds = config.@"quick-terminal-animation-duration";
    const animate = seconds > 0 and
        config.@"quick-terminal-position" != .center and
        util.animations();
    const distance: f64 = @abs(to - self.quick_shown);
    self.quick_slide = .{
        .from = self.quick_shown,
        .to = to,
        .start_ms = c.GetTickCount64(),
        .duration_ms = if (animate) slideMs(seconds, distance) else 0,
    };
    self.stepQuickSlide();
    if (self.quick_slide != null) {
        // About 100 frames per second; timers aren't more precise anyway.
        _ = c.SetTimer(self.hwnd, quick_slide_timer_id, 10, null);
    }
}

/// How long a slide over `distance` (0 to 1 of the window) takes, in
/// milliseconds, for an animation of `seconds`. A duration that isn't a
/// number or is absurdly long (infinite, say) is capped at a minute.
fn slideMs(seconds: f64, distance: f64) u64 {
    // Not `@min` alone, which takes the other number over NaN.
    if (!(seconds > 0) or !(distance > 0)) return 0;
    return @intFromFloat(@min(seconds, 60) * 1000 * @min(distance, 1));
}

test slideMs {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 200), slideMs(0.2, 1));
    try testing.expectEqual(@as(u64, 100), slideMs(0.2, 0.5));
    try testing.expectEqual(@as(u64, 60000), slideMs(std.math.inf(f64), 1));
    try testing.expectEqual(@as(u64, 60000), slideMs(1e30, 1));
    try testing.expectEqual(@as(u64, 0), slideMs(std.math.nan(f64), 1));
    try testing.expectEqual(@as(u64, 0), slideMs(-1, 1));
}

/// Advance the quick terminal's slide animation.
fn stepQuickSlide(self: *Window) void {
    const slide = self.quick_slide orelse return;
    const elapsed: f32 = @floatFromInt(c.GetTickCount64() - slide.start_ms);
    const t: f32 = if (slide.duration_ms == 0)
        1
    else
        @min(1, elapsed / @as(f32, @floatFromInt(slide.duration_ms)));

    // Ease out: fast at first, then settling into place.
    const eased = 1 - std.math.pow(f32, 1 - t, 3);
    self.quick_shown = slide.from + (slide.to - slide.from) * eased;
    self.applyQuickSlide();

    if (t < 1) return;
    _ = c.KillTimer(self.hwnd, quick_slide_timer_id);
    self.quick_slide = null;
    if (slide.to == 0) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
}

/// Move and clip the quick terminal for how much of it is shown.
fn applyQuickSlide(self: *Window) void {
    const frame = quickSlideFrame(
        self.app.config.@"quick-terminal-position",
        self.quick_target,
        self.quick_shown,
    );
    _ = util.SetWindowPos(
        self.hwnd,
        util.HWND_TOPMOST,
        frame.x,
        frame.y,
        0,
        0,
        c.SWP_NOSIZE | c.SWP_NOACTIVATE,
    );

    // Clip the window at the screen edge it slides from, so that it never
    // shows on a neighboring monitor. The system owns the region.
    const region = if (self.quick_shown >= 1)
        null
    else
        c.CreateRectRgnIndirect(&frame.visible);
    _ = c.SetWindowRgn(self.hwnd, region, c.TRUE);
}

const QuickSlideFrame = struct {
    /// The window position.
    x: c_int,
    y: c_int,

    /// The part of the window that is shown, in window coordinates.
    visible: c.RECT,
};

/// Where the quick terminal is when `shown` (0 to 1) of it is shown,
/// sliding in from the edge of its position.
fn quickSlideFrame(
    position: configpkg.Config.QuickTerminalPosition,
    target: c.RECT,
    shown: f32,
) QuickSlideFrame {
    const w = target.right - target.left;
    const h = target.bottom - target.top;
    const hidden_w: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(w)) * (1 - shown)));
    const hidden_h: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(h)) * (1 - shown)));
    return switch (position) {
        .top => .{
            .x = target.left,
            .y = target.top - hidden_h,
            .visible = .{ .left = 0, .top = hidden_h, .right = w, .bottom = h },
        },
        .bottom => .{
            .x = target.left,
            .y = target.top + hidden_h,
            .visible = .{ .left = 0, .top = 0, .right = w, .bottom = h - hidden_h },
        },
        .left => .{
            .x = target.left - hidden_w,
            .y = target.top,
            .visible = .{ .left = hidden_w, .top = 0, .right = w, .bottom = h },
        },
        .right => .{
            .x = target.left + hidden_w,
            .y = target.top,
            .visible = .{ .left = 0, .top = 0, .right = w - hidden_w, .bottom = h },
        },
        // There's no edge to slide from, so it appears in place.
        .center => .{
            .x = target.left,
            .y = target.top,
            .visible = .{ .left = 0, .top = 0, .right = w, .bottom = h },
        },
    };
}

test quickSlideFrame {
    const testing = std.testing;
    const target: c.RECT = .{ .left = 100, .top = 40, .right = 1100, .bottom = 440 };

    // Hidden at the top: entirely above its place, and clipped away.
    try testing.expectEqual(
        QuickSlideFrame{ .x = 100, .y = -360, .visible = .{ .left = 0, .top = 400, .right = 1000, .bottom = 400 } },
        quickSlideFrame(.top, target, 0),
    );

    // Half shown at the top: the bottom half of the window is visible.
    try testing.expectEqual(
        QuickSlideFrame{ .x = 100, .y = -160, .visible = .{ .left = 0, .top = 200, .right = 1000, .bottom = 400 } },
        quickSlideFrame(.top, target, 0.5),
    );

    // A quarter shown from the right: its left quarter is visible.
    try testing.expectEqual(
        QuickSlideFrame{ .x = 850, .y = 40, .visible = .{ .left = 0, .top = 0, .right = 250, .bottom = 400 } },
        quickSlideFrame(.right, target, 0.25),
    );

    // Fully shown: in place and unclipped.
    try testing.expectEqual(
        QuickSlideFrame{ .x = 100, .y = 40, .visible = .{ .left = 0, .top = 0, .right = 1000, .bottom = 400 } },
        quickSlideFrame(.bottom, target, 1),
    );
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
    if (c.IsWindowVisible(self.hwnd) == 0) return;
    self.slideQuick(0);
}

/// Request to close the window. This goes through the same path as the
/// user closing the window, so it may ask for confirmation.
pub fn close(self: *Window) void {
    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
}

/// Destroy the window immediately, without confirmation.
pub fn destroy(self: *Window) void {
    // When the last window closes, save the session if the user closed it,
    // and otherwise (its shell exited) forget it. Quitting saves before
    // closing the windows.
    if (!self.quick and !self.app.quitting and !self.app.closing_all and self.app.lastWindow() == self) {
        if (self.closing_by_user) SaveState.save(self.app) else SaveState.clear(self.app);
    }
    _ = c.DestroyWindow(self.hwnd);
}

/// A split's drag handle moved to a point on the screen: highlight where
/// it would drop.
pub fn splitDragMove(self: *Window, source: *Surface, pt: c.POINT) void {
    const tab = self.tabOf(source) orelse return;
    const target = tab.surfaceAt(pt);
    if (self.drop_target != target) {
        if (self.drop_target) |old| old.drop_zone.set(null);
        self.drop_target = target;
    }
    const t = target orelse return;
    if (t == source) return t.drop_zone.set(null);
    var rect: c.RECT = undefined;
    _ = c.GetWindowRect(t.hwnd, &rect);
    t.drop_zone.set(SplitDrag.dropDirection(rect, pt));
}

/// A split's drag handle was released at a point: move it there.
pub fn splitDragEnd(self: *Window, source: *Surface, pt: c.POINT) void {
    self.splitDragCancel();
    const tab = self.tabOf(source) orelse return;
    const target = tab.surfaceAt(pt) orelse return;
    if (target == source) return;
    var rect: c.RECT = undefined;
    _ = c.GetWindowRect(target.hwnd, &rect);
    tab.moveSplit(source, target, SplitDrag.dropDirection(rect, pt)) catch |err| {
        log.warn("error moving split err={}", .{err});
    };
}

/// Stop showing where a dragged split would drop.
pub fn splitDragCancel(self: *Window) void {
    if (self.drop_target) |t| t.drop_zone.set(null);
    self.drop_target = null;
}

/// Close the window because the user asked to.
pub fn closeByUser(self: *Window) void {
    self.closing_by_user = true;
    self.closeOrKeep();
}

/// Close the window, or, like macOS, hide it so that `undo` can reopen
/// it for a while.
fn closeOrKeep(self: *Window) void {
    if (!self.keepForUndo()) self.destroy();
}

/// Hide the window instead of destroying it, if it's worth reopening:
/// a terminal is still running in it, and another window stays open.
/// The app quits when its last window closes, so that one isn't kept.
fn keepForUndo(self: *Window) bool {
    if (self.quick or self.app.quitting or self.app.closing_all) return false;
    const timeout = self.undoTimeout();
    if (timeout == 0) return false;
    const other_open = for (self.app.windows.items) |window| {
        if (window != self and !window.quick) break true;
    } else false;
    if (!other_open) return false;
    const running = for (self.tabs.items) |tab| {
        if (tab.hasRunningProcess()) break true;
    } else false;
    if (!running) return false;

    // This fails for a window that's already closed.
    self.app.keepClosedWindow(self) catch return false;
    self.closed_expires = c.GetTickCount64() +| timeout;
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    const delay: c.UINT = @intCast(@min(timeout, std.math.maxInt(c.UINT)));
    _ = c.SetTimer(self.hwnd, closed_window_timer_id, delay, null);
    return true;
}

/// Show a window that `undo` reopened.
pub fn reopen(self: *Window) void {
    self.closed_expires = 0;
    self.closing_by_user = false;
    _ = c.KillTimer(self.hwnd, closed_window_timer_id);
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    self.present(self.activeSurface());
}

/// When the most recently closed tab or split expires, if any. Later
/// expiry means it was closed later.
pub fn lastClosedExpiry(self: *const Window) ?u64 {
    const closed = self.closed.getLastOrNull() orelse return null;
    return closed.expires;
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

pub fn tabIndex(self: *const Window, tab: *const Tab) ?usize {
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

/// Take ownership of a tab from another window and select it, at a place
/// among our tabs or (null, or past them) after the last. This reparents
/// its surfaces to this window.
fn adoptTab(self: *Window, tab: *Tab, at: ?usize) !void {
    const idx = @min(at orelse self.tabs.items.len, self.tabs.items.len);
    try self.tabs.insert(self.app.core_app.alloc, idx, tab);
    tab.window = self;
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        entry.view.window = self;
        _ = c.SetParent(entry.view.hwnd, self.hwnd);
        if (entry.view.core_initialized) entry.view.core_surface.setParentWindow(@intFromPtr(self.hwnd));
    }
    self.selectTab(idx);
}

/// Move the tab containing the given surface to a new window. Like GTK,
/// this does nothing if it's the only tab.
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) !bool {
    const tab = self.tabOf(surface) orelse return false;
    return try self.tearOffTab(tab) != null;
}

/// Move a tab to a new window, returning it. Does nothing (and returns
/// null) if it's the only tab.
pub fn tearOffTab(self: *Window, tab: *Tab) !?*Window {
    if (self.tabs.items.len <= 1) return null;
    const idx = self.tabIndex(tab) orelse return null;

    const window = try self.app.newWindow(.{ .tab = tab });
    self.detachTab(idx);

    // Selecting our remaining tab focuses it, which activates this window
    // again. The moved tab should end up in front.
    window.present(tab.focused);
    return window;
}

/// Move a tab to another window and select it there, at a place among
/// its tabs or (null) after the last. If it was our only tab, we close:
/// the caller must not use this window afterwards.
pub fn moveTabToWindow(self: *Window, tab: *Tab, target: *Window, at: ?usize) !bool {
    if (target == self) return false;
    const idx = self.tabIndex(tab) orelse return false;
    try target.tabs.ensureUnusedCapacity(self.app.core_app.alloc, 1);

    if (self.tabs.items.len > 1) {
        self.detachTab(idx);
        // We reserved room for the tab, so this can't fail.
        target.adoptTab(tab, at) catch unreachable;
        target.present(tab.focused);
        return true;
    }

    // Our last tab: hide first, while we still have a tab to answer
    // focus messages with, then close without any tabs.
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    _ = self.tabs.orderedRemove(idx);
    self.forgetReopened(tab);
    target.adoptTab(tab, at) catch unreachable;
    target.present(tab.focused);
    self.destroy();
    return true;
}

/// Remove a tab that moved to another window from our list.
fn detachTab(self: *Window, idx: usize) void {
    const tab = self.tabs.orderedRemove(idx);
    self.forgetReopened(tab);
    if (idx < self.active) self.active -= 1;
    self.active = @min(self.active, self.tabs.items.len - 1);
    self.dragging = null;
    self.selectTab(self.active);
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
    self.tab_bar.tabSelected(tab);
}

/// Go to a tab, using the semantics of the goto_tab action.
pub fn gotoTab(self: *Window, goto: apprt.action.GotoTab) bool {
    const idx = gotoIndex(goto, self.active, self.tabs.items.len) orelse return false;
    if (idx == self.active) return false;
    self.selectTab(idx);
    return true;
}

/// The tab that goto_tab goes to from `current` of `total`: previous and
/// next wrap around, and a 1-based index past the end is the last tab.
/// Null if there's no such tab.
fn gotoIndex(goto: apprt.action.GotoTab, current: usize, total: usize) ?usize {
    if (total == 0) return null;
    return switch (goto) {
        .previous => if (current > 0) current - 1 else total - 1,
        .next => if (current < total - 1) current + 1 else 0,
        .last => total - 1,
        _ => idx: {
            const n = @backingInt(goto);
            if (n <= 0) return null;
            break :idx @min(@as(usize, @intCast(n)) - 1, total - 1);
        },
    };
}

/// Move the active tab by the given amount, wrapping around.
pub fn moveTab(self: *Window, amount: isize) bool {
    const total = self.tabs.items.len;
    if (total <= 1) return false;

    const from = self.active;
    const to = moveIndex(from, amount, total);
    if (from == to) return false;

    const tab = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(to, tab);
    self.selectTab(to);
    return true;
}

/// Where move_tab puts the tab at `from` of `total` (at least one),
/// wrapping around at either end.
fn moveIndex(from: usize, amount: isize, total: usize) usize {
    const total_i: isize = @intCast(total);
    return @intCast(@mod(@as(isize, @intCast(from)) + amount, total_i));
}

test gotoIndex {
    const testing = std.testing;
    const GotoTab = apprt.action.GotoTab;
    try testing.expectEqual(@as(?usize, 1), gotoIndex(.previous, 2, 4));
    try testing.expectEqual(@as(?usize, 3), gotoIndex(.previous, 0, 4));
    try testing.expectEqual(@as(?usize, 3), gotoIndex(.next, 2, 4));
    try testing.expectEqual(@as(?usize, 0), gotoIndex(.next, 3, 4));
    try testing.expectEqual(@as(?usize, 3), gotoIndex(.last, 0, 4));
    // 1-based, and past the end is the last tab (Ctrl+9 with four tabs).
    try testing.expectEqual(@as(?usize, 0), gotoIndex(@fromBackingInt(@intCast(1)), 2, 4));
    try testing.expectEqual(@as(?usize, 3), gotoIndex(@fromBackingInt(@intCast(9)), 0, 4));
    try testing.expectEqual(@as(?usize, null), gotoIndex(@as(GotoTab, @fromBackingInt(@intCast(0))), 0, 4));
    try testing.expectEqual(@as(?usize, null), gotoIndex(@as(GotoTab, @fromBackingInt(@intCast(-7))), 0, 4));
    // One tab: next and previous stay on it; no tabs, nowhere to go.
    try testing.expectEqual(@as(?usize, 0), gotoIndex(.next, 0, 1));
    try testing.expectEqual(@as(?usize, 0), gotoIndex(.previous, 0, 1));
    try testing.expectEqual(@as(?usize, null), gotoIndex(.next, 0, 0));
}

test moveIndex {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 2), moveIndex(1, 1, 4));
    try testing.expectEqual(@as(usize, 0), moveIndex(1, -1, 4));
    // Wrapping at either end, and by more than the number of tabs.
    try testing.expectEqual(@as(usize, 0), moveIndex(3, 1, 4));
    try testing.expectEqual(@as(usize, 3), moveIndex(0, -1, 4));
    try testing.expectEqual(@as(usize, 2), moveIndex(1, 9, 4));
    try testing.expectEqual(@as(usize, 2), moveIndex(1, -7, 4));
}

/// Close the given tab without confirmation. If it's the last tab, the
/// window is closed.
fn closeTab(self: *Window, tab: *Tab) void {
    const idx = self.tabIndex(tab) orelse return;

    // The last tab closes the window, which destroys the tab.
    if (self.tabs.items.len == 1) {
        if (!self.destroying) self.closeOrKeep();
        return;
    }

    _ = self.tabs.orderedRemove(idx);
    self.forgetReopened(tab);

    // Keep the same tab active. If the active tab was closed, the tab
    // that took its place (or the new last tab) becomes active.
    // Do this before destroying the old tab: DestroyWindow can send
    // WM_SETFOCUS to us synchronously, which reads activeSurface().
    if (idx < self.active) self.active -= 1;
    self.active = @min(self.active, self.tabs.items.len - 1);
    tab.setVisible(false);
    self.selectTab(self.active);

    // Like macOS, a closed tab can be reopened with `undo` for a while.
    // A tab whose processes have all exited isn't worth reopening.
    if (tab.hasRunningProcess() and
        self.keepClosed(.{ .tab = .{ .tab = tab, .index = idx } })) return;
    self.destroyTab(tab);
}

/// Close the given surface without confirmation. This removes it from
/// its split tree, closing the tab if it's the last surface in it.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    const tab = self.tabOf(surface) orelse return;
    if (tab.isSingle()) {
        self.closeTab(tab);
        return;
    }

    for (self.reopened.items, 0..) |reopened, i| {
        if (std.meta.eql(reopened, Reopened{ .split = surface })) {
            _ = self.reopened.orderedRemove(i);
            break;
        }
    }

    // Like a tab, a closed split can be reopened with `undo` for a while.
    // We keep a reference to the surface so that removing it doesn't
    // destroy it.
    const alloc = self.app.core_app.alloc;
    var placement: ?Tab.Placement = if (self.undoTimeout() > 0 and
        !surface.core_surface.child_exited)
        tab.placement(alloc, surface) catch null
    else
        null;
    if (placement != null) _ = surface.ref();

    tab.remove(surface) catch |err| {
        log.err("error removing split err={}", .{err});
        if (placement) |*p| {
            p.deinit(alloc);
            surface.unref();
        }
        return;
    };

    const p = placement orelse return;
    _ = c.ShowWindow(surface.hwnd, c.SW_HIDE);
    surface.setVisible(false);
    if (!self.keepClosed(.{ .split = .{ .tab = tab, .surface = surface, .placement = p } })) {
        var owned = p;
        owned.deinit(alloc);
        surface.unref();
    }
}

/// How long closed tabs and splits can be reopened, in milliseconds.
fn undoTimeout(self: *const Window) u64 {
    return self.app.config.@"undo-timeout".duration / std.time.ns_per_ms;
}

/// Keep a closed tab or split for `undo`. Returns false if it can't be
/// kept, in which case the caller still owns it.
fn keepClosed(self: *Window, what: Closed.What) bool {
    const timeout = self.undoTimeout();
    if (timeout == 0) return false;
    self.closed.append(self.app.core_app.alloc, .{
        .what = what,
        .expires = c.GetTickCount64() +| timeout,
    }) catch |err| {
        log.warn("error keeping closed terminal for undo err={}", .{err});
        return false;
    };
    self.scheduleUndoExpiry();
    return true;
}

/// Whether `undo` has anything to reopen.
pub fn canUndo(self: *const Window) bool {
    return self.closed.items.len > 0;
}

/// Reopen the most recently closed tab or split. Returns false if
/// there's none.
pub fn undoClose(self: *Window) bool {
    const closed = self.closed.pop() orelse return false;
    self.scheduleUndoExpiry();
    const alloc = self.app.core_app.alloc;
    switch (closed.what) {
        .tab => |v| {
            const idx = @min(v.index, self.tabs.items.len);
            self.tabs.insert(alloc, idx, v.tab) catch |err| {
                log.warn("error reopening tab err={}", .{err});
                self.release(closed.what);
                return false;
            };
            self.reopened.append(alloc, .{ .tab = v.tab }) catch {};
            self.selectTab(idx);
        },
        .split => |v| {
            // The tab may have closed since.
            const idx = self.tabIndex(v.tab) orelse {
                self.release(closed.what);
                return false;
            };
            if (idx != self.active) self.selectTab(idx);
            v.tab.restore(v.surface, v.placement) catch |err| {
                log.warn("error reopening split err={}", .{err});
                self.release(closed.what);
                return false;
            };
            // The tab's tree now holds the surface.
            self.release(closed.what);
            self.reopened.append(alloc, .{ .split = v.surface }) catch {};
        },
    }
    return true;
}

/// Whether `redo` has anything to close again.
pub fn canRedo(self: *const Window) bool {
    return self.reopened.items.len > 0;
}

/// Close the tab or split most recently reopened by `undo` again.
/// Returns false if there's none.
pub fn redoClose(self: *Window) bool {
    const reopened = self.reopened.pop() orelse return false;
    switch (reopened) {
        .tab => |tab| {
            if (self.tabIndex(tab) == null) return false;
            self.closeTab(tab);
        },
        .split => |surface| {
            if (self.tabOf(surface) == null) return false;
            self.closeSurface(surface);
        },
    }
    return true;
}

/// Forget the tab, and its surfaces, for `redo`.
fn forgetReopened(self: *Window, tab: *const Tab) void {
    var i: usize = 0;
    while (i < self.reopened.items.len) {
        const forget = switch (self.reopened.items[i]) {
            .tab => |v| v == tab,
            .split => |v| tab.contains(v),
        };
        if (forget) {
            _ = self.reopened.orderedRemove(i);
        } else i += 1;
    }
}

/// Destroy a tab that isn't in our list, dropping closed splits that
/// would go back into it.
fn destroyTab(self: *Window, tab: *Tab) void {
    var i: usize = 0;
    while (i < self.closed.items.len) {
        const closed = self.closed.items[i];
        switch (closed.what) {
            .split => |v| if (v.tab == tab) {
                _ = self.closed.orderedRemove(i);
                self.release(closed.what);
                continue;
            },
            .tab => {},
        }
        i += 1;
    }
    tab.destroy();
}

/// Drop a closed tab or split. A tab is destroyed; for a split, we
/// release our reference to its surface, which destroys it unless it
/// was reopened.
fn release(self: *Window, what: Closed.What) void {
    switch (what) {
        .tab => |v| self.destroyTab(v.tab),
        .split => |v| {
            var placement = v.placement;
            placement.deinit(self.app.core_app.alloc);
            v.surface.unref();
        },
    }
}

/// Destroy closed tabs and splits that can no longer be reopened, and
/// wake up when the next one expires.
fn scheduleUndoExpiry(self: *Window) void {
    const now = c.GetTickCount64();
    var i: usize = 0;
    while (i < self.closed.items.len) {
        const closed = self.closed.items[i];
        if (closed.expires <= now) {
            _ = self.closed.orderedRemove(i);
            // Releasing a tab removes entries, so we start over.
            self.release(closed.what);
            i = 0;
            continue;
        }
        i += 1;
    }

    var next: ?u64 = null;
    for (self.closed.items) |closed| next = @min(next orelse closed.expires, closed.expires);
    if (next) |expires| {
        const delay: c.UINT = @intCast(@min(expires - now, std.math.maxInt(c.UINT)));
        _ = c.SetTimer(self.hwnd, undo_timer_id, delay, null);
    } else {
        _ = c.KillTimer(self.hwnd, undo_timer_id);
    }
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
            if (!confirmClosing(self, .tabs)) return;
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
    const report = (if (surface.progress_style) surface.progressReport(now) else null) orelse {
        taskbar.clear(self.hwnd);
        return;
    };
    const progress = Taskbar.Progress.of(report, surface.progress_value);
    taskbar.setState(self.hwnd, progress.state);
    if (progress.value) |value| taskbar.setValue(self.hwnd, value);

    const remaining: c.UINT = @intCast(@min(surface.progress_expires_at - now, 15_000));
    _ = c.SetTimer(self.hwnd, progress_timer_id, @max(remaining, 1), null);
}

/// Called by a surface when its title changes.
pub fn surfaceTitleChanged(self: *Window, surface: *Surface) void {
    const tab = self.tabOf(surface) orelse return;
    if (tab.focused != surface) return;

    // Programs can change the title with every command (cmd puts the
    // command in it), and the core handles all queued messages before
    // returning to our message loop. Updating the title bar each time
    // was slower than the titles arrived, so the window stopped
    // responding while output flooded in. We update once, later.
    if (self.title_change_posted) return;
    if (c.PostMessageW(self.hwnd, WM_GHOSTTY_TITLE_CHANGED, 0, 0) != 0) {
        self.title_change_posted = true;
    } else self.titleChanged();
}

/// A terminal's cell size changed (its font size, say). A split keeps
/// each side at least a cell wide, so a terminal in one is laid out
/// again, later: the core is still changing its font.
pub fn cellSizeChanged(self: *Window, surface: *const Surface) void {
    const tab = self.tabOf(surface) orelse return;
    if (tab.isSingle() or self.layout_posted) return;
    if (c.PostMessageW(self.hwnd, WM_GHOSTTY_LAYOUT, 0, 0) != 0) self.layout_posted = true;
}

fn titleChanged(self: *Window) void {
    self.title_change_posted = false;
    self.tab_bar.invalidate();
    self.updateWindowTitle();
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
    //
    // Debug builds are much slower, so like GTK's banner, we say so.
    const debug = if (comptime builtin.mode == .debug) " (debug build)" else "";

    // The title bar has a single line, so a subtitle follows the title,
    // unless the title already shows it (cmd's titles are often the
    // working directory).
    const pwd: ?[]const u8 = switch (self.app.config.@"window-subtitle") {
        .false => null,
        .@"working-directory" => self.activeSurface().core_surface.pwd(alloc) catch null,
    };
    defer if (pwd) |v| alloc.free(v);
    const subtitle = if (pwd) |v|
        if (v.len > 0 and std.mem.indexOf(u8, title, v) == null) v else null
    else
        null;

    const display_title = std.fmt.allocPrint(alloc, "{s}{s}{s}{s}{s}", .{
        if (pending) "🔔 " else "",
        title,
        if (subtitle != null) " — " else "",
        subtitle orelse "",
        debug,
    }) catch return;
    defer alloc.free(display_title);
    const title16 = util.utf16Alloc(alloc, display_title) catch return;
    defer alloc.free(title16);
    _ = c.SetWindowTextW(self.hwnd, title16);
}

/// Whether the tab bar should be visible.
fn showTabBar(self: *const Window) bool {
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        // With the tabs in the title bar, the bar is the title bar, so it
        // shows with one tab too.
        .auto => self.tabs.items.len > 1 or self.titleBarTabsAllowed(),
        .never => false,
    };
}

/// Whether the window can have its tabs in the title bar: it has a title
/// bar (fullscreen and the quick terminal don't), the tab bar isn't turned
/// off, and no high contrast theme is on (which keeps the system's title
/// bar, in the theme's colors).
fn titleBarTabsAllowed(self: *const Window) bool {
    if (self.quick or self.fullscreen != null or util.highContrast()) return false;
    if (self.app.config.@"window-show-tab-bar" == .never) return false;
    return self.decorated_override orelse
        (self.app.config.@"window-decoration" != .none);
}

/// Whether the tabs should be in the title bar, like Windows Terminal:
/// whenever the tab bar shows in a window with a title bar. Fullscreen and
/// the quick terminal have no title bar; high contrast themes keep the
/// system's, which follows the theme's colors.
fn tabsInTitleBar(self: *const Window) bool {
    return self.titleBarTabsAllowed();
}

/// Switch between the system's title bar and the tabs in it when that
/// changes (more tabs, decorations, fullscreen), recalculating the frame.
fn updateTitleBarTabs(self: *Window) void {
    // Not until our window procedure can see us (the end of init): the
    // frame change's WM_NCCALCSIZE would go to DefWindowProc, and we'd
    // think it had happened.
    if (c.GetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA) == 0) return;
    const want = self.tabsInTitleBar();
    if (want == self.titlebar_tabs) return;
    self.titlebar_tabs = want;
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// The height of the resize border at the top of the window, which the tabs
/// cover when they're in the title bar.
pub fn resizeBorderHeight(self: *const Window) c_int {
    const dpi = c.GetDpiForWindow(self.hwnd);
    return c.GetSystemMetricsForDpi(c.SM_CYFRAME, dpi) + c.GetSystemMetricsForDpi(c.SM_CXPADDEDBORDER, dpi);
}

/// Show the window menu at a point on the screen, as a title bar's right
/// click or icon does. We build our part of it on WM_INITMENUPOPUP and run
/// the command from WM_SYSCOMMAND, as for the system's.
pub fn showSystemMenu(self: *Window, pt: c.POINT) void {
    const menu = c.GetSystemMenu(self.hwnd, c.FALSE) orelse return;
    const cmd = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON, pt.x, pt.y, 0, self.hwnd, null);
    if (cmd != 0) _ = c.PostMessageW(self.hwnd, c.WM_SYSCOMMAND, @intCast(cmd), 0);
}

/// Whether the tabs are in the title bar right now.
pub fn hasTitleBarTabs(self: *const Window) bool {
    return self.titlebar_tabs;
}

/// The area of our client area that the active tab's surfaces fill.
pub fn surfaceArea(self: *const Window) c.RECT {
    var client: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &client) == 0) return std.mem.zeroes(c.RECT);
    // Never upside down, which callers would turn into a huge size: a
    // minimized window's client area is empty, smaller than the tab bar.
    if (self.showTabBar()) client.top = @min(self.tab_bar.height(), client.bottom);
    return client;
}

/// Position the tab bar and the active tab's surfaces within our
/// client area.
pub fn layout(self: *Window) void {
    self.updateTitleBarTabs();
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
    if (config.@"split-divider-color") |v| return util.rgb(v.r, v.g, v.b);

    // A high contrast theme gets the terminal's foreground itself, which
    // stands out from the terminals on either side.
    const fg = config.foreground;
    if (util.highContrast()) return util.rgb(fg.r, fg.g, fg.b);

    // By default, blend the background toward the foreground a little so
    // the divider is visible but subtle in both light and dark themes.
    const bg = config.background;
    return util.rgb(
        mix(bg.r, fg.r),
        mix(bg.g, fg.g),
        mix(bg.b, fg.b),
    );
}

fn mix(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) * 3 + @as(u16, b)) / 4);
}

//----------------------------------------------------------------------------
// Window state

/// Apply app-level config changes, such as the tab bar colors and
/// visibility and the window theme.
pub fn configChanged(self: *Window) void {
    self.tab_bar.updateFont();
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

    // The system backdrop (acrylic) needs Windows 11 22H2. Earlier
    // versions, including Windows 10, get the older blur behind accent.
    const system_backdrop = util.windowsBuild() >= 22621;
    const DWMWA_SYSTEMBACKDROP_TYPE = 38;
    const DWMSBT_AUTO = 0;
    const DWMSBT_TRANSIENTWINDOW = 3;
    const backdrop: c.DWORD = if (blur and system_backdrop) DWMSBT_TRANSIENTWINDOW else DWMSBT_AUTO;
    _ = c.DwmSetWindowAttribute(
        self.hwnd,
        DWMWA_SYSTEMBACKDROP_TYPE,
        &backdrop,
        @sizeOf(c.DWORD),
    );
    if (system_backdrop) {
        log.debug("background blur={} with the system backdrop build={}", .{ blur, util.windowsBuild() });
    } else {
        const ok = util.setBlurBehindAccent(self.hwnd, blur);
        log.debug("background blur={} with the blur behind accent build={} ok={}", .{ blur, util.windowsBuild(), ok });
    }

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

/// Use a light or dark title bar according to `window-theme` (or the
/// theme chosen with `set_window_theme`). This matches the GTK apprt:
/// `auto` and `ghostty` follow the luminance of the terminal background.
fn updateTheme(self: *Window) void {
    const config = &self.app.config;
    const theme = self.app.windowTheme();
    const dark = switch (theme) {
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
    util.setMenuTheme(dark);

    // With the ghostty theme, the title bar takes the terminal's colors
    // (or the configured title bar colors), like GTK. Caption colors need
    // Windows 11. DWMWA_COLOR_DEFAULT restores the system's colors.
    const DWMWA_CAPTION_COLOR = 35;
    const DWMWA_TEXT_COLOR = 36;
    const DWMWA_COLOR_DEFAULT: c.COLORREF = 0xFFFFFFFF;
    // High contrast themes color title bars themselves.
    const ghostty = theme == .ghostty and !util.highContrast();
    const background = config.@"window-titlebar-background" orelse config.background;
    const foreground = config.@"window-titlebar-foreground" orelse config.foreground;
    const caption: c.COLORREF = if (ghostty) util.rgb(background.r, background.g, background.b) else DWMWA_COLOR_DEFAULT;
    const text: c.COLORREF = if (ghostty) util.rgb(foreground.r, foreground.g, foreground.b) else DWMWA_COLOR_DEFAULT;
    _ = c.DwmSetWindowAttribute(self.hwnd, DWMWA_CAPTION_COLOR, &caption, @sizeOf(c.COLORREF));
    _ = c.DwmSetWindowAttribute(self.hwnd, DWMWA_TEXT_COLOR, &text, @sizeOf(c.COLORREF));
}

/// Whether the user chose the dark app mode in the Windows settings.
pub fn systemUsesDarkTheme() bool {
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
    // A hidden quick terminal slides in (showQuick presents it again once
    // it's showing), and a window toggle_visibility hid comes back. Other
    // hidden windows, such as closed ones kept for undo, stay hidden.
    if (self.quick) {
        if (!self.quickShowing()) return self.showQuickWith(surface);
    } else if (self.hidden_by_toggle) {
        self.hidden_by_toggle = false;
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    }
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
        // The resizes above laid us out while still fullscreen, with the
        // tabs out of the title bar (and the tab bar hidden); put them back.
        self.layout();
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
    return scalePoints(points, c.GetDpiForWindow(self.hwnd));
}

/// The largest terminal size we ask for, in pixels: far past any screen
/// (Windows limits a window to its screens anyway), and small enough that
/// adding the frame and the tab bar can't overflow.
const max_terminal_pixels = 1 << 20;

/// Points to pixels at a DPI, at most `max_terminal_pixels`. A huge
/// `window-height` (100000000) or a program's resize request no longer
/// overflows what Windows takes.
fn scalePoints(points: u32, dpi: c.UINT) u32 {
    return @intCast(@min(max_terminal_pixels, @as(u64, points) * dpi / util.USER_DEFAULT_SCREEN_DPI));
}

test scalePoints {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 800), scalePoints(400, 192));
    try testing.expectEqual(@as(u32, 150), scalePoints(100, 144));
    try testing.expectEqual(@as(u32, max_terminal_pixels), scalePoints(2_000_000_000, 192));
    try testing.expectEqual(@as(u32, max_terminal_pixels), scalePoints(std.math.maxInt(u32), 480));
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
    // With the tabs in the title bar, the client area starts at the top of
    // the window: only the sides and bottom of the frame remain, so the
    // height is the client's plus the bottom (rect.bottom, from a top of 0).
    // Whether they will be, not whether they are yet: the initial size
    // comes during init, before the tabs move into the title bar (which
    // keeps the window's size, so the terminal would grow by the title
    // bar's height).
    if (self.tabsInTitleBar()) return .{ rect.right - rect.left, rect.bottom };
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

/// Adjust a window rectangle being resized by the user (WM_SIZING) so that
/// the terminal grows and shrinks by whole cells, for window-step-resize.
fn stepResize(self: *const Window, rect: *c.RECT, edge: c_uint, cell: apprt.action.CellSize) void {
    var window: c.RECT = undefined;
    var client: c.RECT = undefined;
    if (c.GetWindowRect(self.hwnd, &window) == 0 or c.GetClientRect(self.hwnd, &client) == 0) return;

    // The non-client area doesn't change while resizing.
    const frame_w = (window.right - window.left) - client.right;
    const frame_h = (window.bottom - window.top) - client.bottom;
    const width = snapToCells(client.right, (rect.right - rect.left) - frame_w, @intCast(cell.width));
    const height = snapToCells(client.bottom, (rect.bottom - rect.top) - frame_h, @intCast(cell.height));

    switch (edge) {
        c.WMSZ_LEFT, c.WMSZ_TOPLEFT, c.WMSZ_BOTTOMLEFT => rect.left = rect.right - width - frame_w,
        else => rect.right = rect.left + width + frame_w,
    }
    switch (edge) {
        c.WMSZ_TOP, c.WMSZ_TOPLEFT, c.WMSZ_TOPRIGHT => rect.top = rect.bottom - height - frame_h,
        else => rect.bottom = rect.top + height + frame_h,
    }
}

/// The client size nearest to `proposed` that differs from `current` by
/// whole cells, so that the leftover space (padding, the tab bar) stays
/// the same. It's never less than one cell plus that leftover space.
fn snapToCells(current: c_int, proposed: c_int, cell: c_int) c_int {
    if (cell <= 0) return proposed;
    const extra = @mod(current, cell);
    const cells = @max(1, @divFloor(proposed - extra + @divTrunc(cell, 2), cell));
    return extra + cells * cell;
}

test snapToCells {
    const testing = std.testing;
    // 10px cells and 3px of padding: sizes are 3 + 10n.
    try testing.expectEqual(@as(c_int, 803), snapToCells(803, 801, 10));
    try testing.expectEqual(@as(c_int, 813), snapToCells(803, 809, 10));
    try testing.expectEqual(@as(c_int, 793), snapToCells(803, 797, 10));
    try testing.expectEqual(@as(c_int, 13), snapToCells(803, 2, 10));
    try testing.expectEqual(@as(c_int, 500), snapToCells(803, 500, 0));
}

/// Restore saved placement and tabs into a new window.
fn restore(self: *Window, state: *const SaveState.WindowState) !void {
    // Place the window first, like the quick terminal, so that the
    // terminals start out at their size. The saved size wins over the
    // configured initial size.
    self.initial_size_applied = true;
    self.restored = true;
    var placement: c.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(c.WINDOWPLACEMENT);
    if (c.GetWindowPlacement(self.hwnd, &placement) != 0) {
        placement.rcNormalPosition = .{ .left = state.left, .top = state.top, .right = state.right, .bottom = state.bottom };
        placement.showCmd = c.SW_HIDE;
        _ = c.SetWindowPlacement(self.hwnd, &placement);
    }
    self.restore_maximized = state.maximized;

    const alloc = self.app.core_app.alloc;
    for (state.tabs) |tab_state| {
        const tab = Tab.createRestored(self, tab_state, self.tabs.items.len == 0) catch |err| {
            log.warn("error restoring a tab err={}", .{err});
            continue;
        };
        self.tabs.append(alloc, tab) catch {
            tab.destroy();
            continue;
        };
    }
    if (self.tabs.items.len == 0) _ = try self.addTab(null);
    self.selectTab(@min(state.active_tab, self.tabs.items.len - 1));
}

/// Move the first window to `window-position-x` and `window-position-y`,
/// if both are set.
fn placeAtConfiguredPosition(self: *Window) void {
    const config = &self.app.config;
    const x = config.@"window-position-x" orelse return;
    const y = config.@"window-position-y" orelse return;

    const primary = c.MonitorFromPoint(.{ .x = 0, .y = 0 }, c.MONITOR_DEFAULTTOPRIMARY);
    var info: c.MONITORINFO = undefined;
    info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(primary, &info) == 0) return;
    var dpi_x: c.UINT = util.USER_DEFAULT_SCREEN_DPI;
    var dpi_y: c.UINT = util.USER_DEFAULT_SCREEN_DPI;
    _ = c.GetDpiForMonitor(primary, c.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);

    var pt = configuredPosition(info.rcWork, dpi_x, x, y);

    // Keep the window's corner on a monitor, so that it can't be lost.
    if (c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTONULL) == null) {
        pt = .{ .x = info.rcWork.left, .y = info.rcWork.top };
    }
    // The window's rectangle includes its invisible resize borders, but
    // the position is for what's visible.
    var rect: c.RECT = undefined;
    var visible: c.RECT = undefined;
    const DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    if (c.GetWindowRect(self.hwnd, &rect) != 0 and
        c.DwmGetWindowAttribute(self.hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &visible, @sizeOf(c.RECT)) >= 0)
    {
        pt.x -= visible.left - rect.left;
        pt.y -= visible.top - rect.top;
    }
    _ = c.SetWindowPos(self.hwnd, null, pt.x, pt.y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// The window position for `window-position-x` and `window-position-y`,
/// which are in points from the top left of the primary monitor's work
/// area (the screen without the taskbar), like macOS.
fn configuredPosition(work: c.RECT, dpi: c.UINT, x: i16, y: i16) c.POINT {
    const scale = struct {
        fn f(v: i16, d: c.UINT) c_int {
            return @divTrunc(@as(c_int, v) * @as(c_int, @intCast(d)), util.USER_DEFAULT_SCREEN_DPI);
        }
    }.f;
    return .{ .x = work.left + scale(x, dpi), .y = work.top + scale(y, dpi) };
}

test configuredPosition {
    const testing = std.testing;
    const work: c.RECT = .{ .left = 0, .top = 48, .right = 2000, .bottom = 1200 };
    try testing.expectEqual(c.POINT{ .x = 200, .y = 248 }, configuredPosition(work, 192, 100, 100));
    try testing.expectEqual(c.POINT{ .x = -50, .y = 48 }, configuredPosition(work, 96, -50, 0));
}

/// Ask a question with a button for each answer (see Dialog.zig). Returns
/// true if the user chose the accept button.
pub fn confirm(window: ?*Window, text: Dialog.Text) bool {
    var message_buf: [1024]u16 = undefined;
    return Dialog.ask(
        if (window) |w| w.hwnd else null,
        text.title,
        util.utf16TruncateZ(&message_buf, text.message).ptr,
        text.accept,
        text.reject,
        .accept,
    );
}

/// What a close confirmation asks about, for its text in the user's
/// language.
pub const Closing = enum {
    terminal,
    tabs,
    window,
    all_windows,
    app,

    const Text = Dialog.Text;

    /// Our wording, which says what closing does to the processes.
    fn english(self: Closing) Text {
        return switch (self) {
            .terminal => .{
                .title = "Close terminal?",
                .message = "A process is still running in this terminal. Closing it will kill the process.",
                .accept = "Close",
            },
            .tabs => .{
                .title = "Close tabs?",
                .message = "A process is still running in at least one of the terminals. Closing them will kill the processes.",
                .accept = "Close",
            },
            .window => .{
                .title = "Close window?",
                .message = "A process is still running in at least one of the terminals. Closing the window will kill the processes.",
                .accept = "Close",
            },
            .all_windows => .{
                .title = "Close all windows?",
                .message = "All terminal sessions will be terminated.",
                .accept = "Close",
            },
            .app => .{
                .title = "Quit Ghostty?",
                .message = "All terminal sessions will be terminated.",
                .accept = "Quit",
            },
        };
    }

    /// The messages of GTK's close confirmation for the same question,
    /// which have translations.
    fn translatable(self: Closing) Text {
        return switch (self) {
            .terminal => .{
                .title = "Close Split?",
                .message = "The currently running process in this split will be terminated.",
                .accept = "Close",
            },
            .tabs => .{
                .title = "Close Tab?",
                .message = "All terminal sessions in this tab will be terminated.",
                .accept = "Close",
            },
            .window => .{
                .title = "Close Window?",
                .message = "All terminal sessions in this window will be terminated.",
                .accept = "Close",
            },
            .all_windows => .{
                .title = "Close All Windows",
                .message = "All terminal sessions will be terminated.",
                .accept = "Close",
            },
            .app => .{
                .title = "Quit Ghostty?",
                .message = "All terminal sessions will be terminated.",
                .accept = "Quit",
            },
        };
    }

    /// What to show: translated if all of it is, so that a dialog is in
    /// one language.
    fn text(self: Closing) Text {
        return self.translatable().translated() orelse self.english();
    }
};

/// Ask whether to close something with processes still running. Returns
/// true if the user confirmed.
pub fn confirmClosing(window: ?*Window, what: Closing) bool {
    return confirm(window, what.text());
}

test "Closing: text" {
    const testing = std.testing;
    try testing.expectEqualStrings("Close terminal?", Closing.terminal.text().title);
    try testing.expectEqualStrings("Quit Ghostty?", Closing.app.text().title);
    try testing.expectEqualStrings("Quit", Closing.app.text().accept);
    try testing.expectEqualStrings("Close", Closing.tabs.text().accept);
    try testing.expectEqualStrings("Cancel", Closing.tabs.text().reject);

    if (comptime !i18n.embedded) return;
    defer _ = i18n.useEmbeddedLocale(null);
    try testing.expect(i18n.useEmbeddedLocale("de"));
    try testing.expectEqualStrings("Ghostty schließen?", Closing.app.text().title);
    try testing.expectEqualStrings("Alle Terminalsitzungen werden beendet.", Closing.app.text().message);
    try testing.expectEqualStrings("Beenden", Closing.app.text().accept);
    try testing.expectEqualStrings("Schließen", Closing.window.text().accept);
    try testing.expectEqualStrings("Abbrechen", Closing.window.text().reject);

    // Every question's messages have translations somewhere, and each
    // language shows a dialog in one language.
    var translated: [std.enums.values(Closing).len]bool = @splat(false);
    for (@import("../../os/i18n_locales.zig").locales) |locale| {
        try testing.expect(i18n.useEmbeddedLocale(locale));
        for (std.enums.values(Closing)) |what| {
            const text = what.text();
            const english = what.english();
            const is_english = text.title.ptr == english.title.ptr;
            try testing.expectEqual(is_english, text.message.ptr == english.message.ptr);
            if (!is_english) translated[@backingInt(what)] = true;
        }
    }
    for (translated) |v| try testing.expect(v);
}

/// Like `confirm`, with a preview of some text below the message, such as
/// what's about to be pasted. Like GTK, the user sees what they allow.
pub fn confirmText(
    window: ?*Window,
    alloc: Allocator,
    question: Dialog.Text,
    text: []const u8,
    check: ?Dialog.Check,
) bool {
    if (check) |v| v.checked.* = false;
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    writePreview(&body.writer, question.message, text) catch
        return confirm(window, question);
    const body16 = util.utf16Alloc(alloc, body.written()) catch
        return confirm(window, question);
    defer alloc.free(body16);
    return Dialog.askWithCheck(
        if (window) |w| w.hwnd else null,
        question.title,
        body16.ptr,
        question.accept,
        question.reject,
        .accept,
        check,
    );
}

/// The message, then the start of the text: a dialog only has room for a
/// few lines. Control characters (such as escape sequences) are shown as
/// a dot rather than interpreted.
fn writePreview(writer: *std.Io.Writer, message: []const u8, text: []const u8) !void {
    const max_lines = 12;
    const max_bytes = 800;
    try writer.print("{s}\n\n", .{message});
    var lines: usize = 1;
    for (text, 0..) |ch, i| {
        if (i >= max_bytes or lines > max_lines) {
            try writer.writeAll("\u{2026}");
            return;
        }
        switch (ch) {
            '\r' => if (i + 1 < text.len and text[i + 1] == '\n') continue else {
                try writer.writeByte('\n');
                lines += 1;
            },
            '\n' => {
                try writer.writeByte('\n');
                lines += 1;
            },
            '\t' => try writer.writeByte('\t'),
            0...8, 11, 12, 14...0x1F, 0x7F => try writer.writeAll("\u{00B7}"),
            else => try writer.writeByte(ch),
        }
    }
}

test writePreview {
    const testing = std.testing;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writePreview(&out.writer, "Paste?", "echo a\r\necho \x1b[31mb");
    try testing.expectEqualStrings("Paste?\n\necho a\necho \u{00B7}[31mb", out.written());

    out.clearRetainingCapacity();
    try writePreview(&out.writer, "M", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14");
    try testing.expectEqualStrings("M\n\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n\u{2026}", out.written());
}

//----------------------------------------------------------------------------
// Window procedure

/// Replace our items in the system menu, so that their shortcuts and
/// whether they're enabled are current.
fn updateSystemMenu(self: *Window, menu: c.HMENU) void {
    while (c.GetMenuItemCount(menu) > self.system_menu_base) {
        if (c.DeleteMenu(menu, @intCast(self.system_menu_base), c.MF_BYPOSITION) == 0) break;
    }

    // The shells stay until the menu is next built, for WM_SYSCOMMAND.
    if (self.system_menu_arena) |*shells_arena| {
        _ = shells_arena.reset(.retain_capacity);
    } else {
        self.system_menu_arena = .init(self.app.core_app.alloc);
    }
    self.system_menu_shells = Menu.shellsFor(self.system_menu_arena.?.allocator(), &Menu.main);

    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    Menu.appendToSystemMenu(
        arena.allocator(),
        menu,
        &Menu.main,
        self.activeSurface(),
        self.system_menu_shells,
    ) catch |err| {
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
        c.WM_TIMER => if (wparam == quick_slide_timer_id) {
            self.stepQuickSlide();
            return 0;
        } else if (wparam == progress_timer_id) {
            self.updateTaskbarProgress();
            return 0;
        } else if (wparam == undo_timer_id) {
            self.scheduleUndoExpiry();
            return 0;
        } else if (wparam == closed_window_timer_id) {
            _ = c.KillTimer(hwnd, closed_window_timer_id);
            self.app.releaseClosedWindow(self);
            return 0;
        },
        c.WM_SIZE => {
            // A minimized window has no client area. Laying out would
            // size its surfaces to nothing, and so their terminals.
            const minimized = wparam == c.SIZE_MINIMIZED;
            if (minimized != self.minimized) {
                self.minimized = minimized;
                if (self.tabs.items.len > 0) self.activeTab().setMinimized(minimized);
            }
            if (!minimized) self.layout();
            return 0;
        },

        WM_GHOSTTY_TITLE_CHANGED => {
            self.titleChanged();
            return 0;
        },

        WM_GHOSTTY_LAYOUT => {
            self.layout_posted = false;
            self.layout();
            return 0;
        },

        c.WM_SIZING => if (self.app.config.@"window-step-resize" and
            self.fullscreen == null and self.tabs.items.len > 0)
        {
            if (self.activeSurface().cell_size) |cell| {
                const rect: *c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                self.stepResize(rect, @intCast(wparam), cell);
                return c.TRUE;
            }
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
            self.app.updateColorScheme();
            self.updateTheme();
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // Sent when a high contrast theme is turned on or off, or its
        // colors change. What we draw ourselves (the tab bar, search
        // bar, command palette and badges) checks for high contrast as
        // it paints, so repaint it all.
        c.WM_SYSCOLORCHANGE => {
            self.updateTheme();
            _ = c.RedrawWindow(hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
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
            // We have no tabs after moving our last one to another window.
            if (self.tabs.items.len == 0) return 0;
            _ = c.SetFocus(self.activeSurface().hwnd);
            return 0;
        },

        // With the tabs in the title bar, the client area covers the
        // caption: keep the frame's sides and bottom only. A maximized
        // window hangs over the screen's edges by its frame, so move the
        // top back in by as much.
        c.WM_NCCALCSIZE => if (wparam != 0 and self.titlebar_tabs) {
            const params: *c.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const top = params.rgrc[0].top;
            const result = c.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (result != 0) return result;
            params.rgrc[0].top = top;
            if (c.IsZoomed(hwnd) != 0) params.rgrc[0].top += self.resizeBorderHeight();
            return 0;
        },

        // What's under the mouse in the title bar: the tab bar passes us
        // its empty space and its maximize button (HTTRANSPARENT).
        c.WM_NCHITTEST => if (self.titlebar_tabs) {
            const hit = c.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (hit != c.HTCLIENT) return hit;
            var pt: c.POINT = .{ .x = util.loword(lparam), .y = util.hiword(lparam) };
            _ = c.ScreenToClient(hwnd, &pt);
            if (pt.y >= self.tab_bar.height()) return c.HTCLIENT;
            if (c.IsZoomed(hwnd) == 0 and pt.y < self.resizeBorderHeight()) return c.HTTOP;
            if (self.tab_bar.isMaximizeButton(pt)) return c.HTMAXBUTTON;
            return c.HTCAPTION;
        },

        // The maximize button is ours to draw and press, but it's
        // HTMAXBUTTON so that Windows 11 shows its snap layouts over it.
        c.WM_NCMOUSEMOVE => if (self.titlebar_tabs) {
            self.tab_bar.setMaximizeHovered(wparam == c.HTMAXBUTTON);
            if (wparam == c.HTMAXBUTTON) {
                var track: c.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                    .dwFlags = c.TME_LEAVE | c.TME_NONCLIENT,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = c.TrackMouseEvent(&track);
            }
        },
        c.WM_NCMOUSELEAVE => if (self.titlebar_tabs) {
            self.tab_bar.setMaximizeHovered(false);
        },
        c.WM_NCLBUTTONDOWN, c.WM_NCLBUTTONDBLCLK => if (self.titlebar_tabs and wparam == c.HTMAXBUTTON) {
            return 0;
        },
        c.WM_NCRBUTTONDOWN => if (self.titlebar_tabs and wparam == c.HTCAPTION) {
            return 0;
        },
        c.WM_NCRBUTTONUP => if (self.titlebar_tabs and wparam == c.HTCAPTION) {
            self.showSystemMenu(.{ .x = util.loword(lparam), .y = util.hiword(lparam) });
            return 0;
        },
        c.WM_NCLBUTTONUP => if (self.titlebar_tabs and wparam == c.HTMAXBUTTON) {
            _ = c.ShowWindow(hwnd, if (c.IsZoomed(hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
            return 0;
        },

        c.WM_ACTIVATE => {
            const active = (wparam & 0xFFFF) != c.WA_INACTIVE;
            self.tab_bar.invalidate();
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
            self.dpi = @as(u16, @bitCast(util.loword(wparam)));
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
            var after: c.RECT = undefined;
            _ = c.GetWindowRect(hwnd, &after);
            log.debug("dpi changed dpi={} suggested={}x{} now={}x{}", .{
                util.loword(wparam),
                rect.right - rect.left,
                rect.bottom - rect.top,
                after.right - after.left,
                after.bottom - after.top,
            });
            return 0;
        },

        c.WM_CLOSE => {
            // With a single surface, go through the core so that it
            // confirms as usual and calls back into Surface.close.
            if (self.tabs.items.len == 1 and self.activeTab().isSingle()) {
                // Closing may destroy the window, and us with it.
                const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
                self.closing_by_user = true;
                self.activeSurface().core_surface.close();
                if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) == identity) {
                    self.closing_by_user = false;
                }
                return 0;
            }

            for (self.tabs.items) |tab| {
                if (tab.needsConfirmQuit()) {
                    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
                    if (!confirmClosing(self, .window)) return 0;
                    if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return 0;
                    break;
                }
            }

            self.closeByUser();
            return 0;
        },

        c.WM_INITMENUPOPUP => if (c.GetSystemMenu(hwnd, c.FALSE)) |menu| {
            if (@intFromPtr(menu) == wparam) self.updateSystemMenu(menu);
        },

        c.WM_SYSCOMMAND => if (Menu.systemCommand(&Menu.main, wparam)) |choice| {
            Menu.perform(self.activeSurface(), choice, self.system_menu_shells);
            return 0;
        },

        // The process ends after this, without quitting normally.
        c.WM_ENDSESSION => {
            if (wparam != 0) self.app.endSession();
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

const MSGFLT_ALLOW: c.DWORD = 1;
extern "user32" fn ChangeWindowMessageFilterEx(hwnd: c.HWND, msg: c.UINT, action: c.DWORD, info: ?*anyopaque) callconv(.winapi) c.BOOL;
