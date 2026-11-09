//! The tab bar of a window. This is a custom drawn child window so that
//! it can match the colors of the terminal, which the native tab control
//! can't.
const TabBar = @This();

const std = @import("std");

const util = @import("util.zig");
const c = util.c;
const App = @import("App.zig");
const Tab = @import("Tab.zig");
const TabBarAccessibility = @import("TabBarAccessibility.zig");
const Window = @import("Window.zig");
const Menu = @import("Menu.zig");
const shells = @import("shells.zig");

const log = std.log.scoped(.win32);

window: *Window,

/// The tab bar's window handle.
hwnd: c.HWND,

/// The font used for tab titles, scaled for our DPI.
font: ?c.HFONT = null,

/// The system's icon font for the caption buttons' glyphs, like Windows
/// Terminal's: Segoe Fluent Icons (Windows 11) or Segoe MDL2 Assets
/// (Windows 10). Null if neither is there; then we draw them with lines.
icon_font: ?c.HFONT = null,

/// The element under the mouse, if any.
hover: ?Hit = null,

/// Whether we're tracking the mouse to get WM_MOUSELEAVE.
tracking_mouse: bool = false,

/// Whether the mouse is over the maximize button, which the window tells us
/// (the button is non-client, see Window's WM_NCHITTEST).
maximize_hovered: bool = false,

/// UI Automation for the tabs, created when a client first asks.
accessibility: ?*TabBarAccessibility = null,

/// The tooltip for the element under the mouse, such as a tab's full
/// title when it's cut off, and the text we give it.
tooltip: c.HWND = null,
tooltip_text: [256:0]u16 = undefined,

/// The tab under an in-progress left-button drag, if still present.
drag_tab: ?*Tab = null,
drag_start_x: c_int = 0,
drag_start_y: c_int = 0,
dragging: bool = false,

/// The parts of the tab bar the mouse can be over.
pub const Hit = union(enum) {
    tab: usize,
    close: usize,
    new_tab,
    shell_menu,

    /// The caption buttons, with the tabs in the title bar.
    minimize,
    maximize,
    close_window,

    fn eql(a: ?Hit, b: ?Hit) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return std.meta.eql(x, y);
    }
};

pub fn init(self: *TabBar, window: *Window) !void {
    const hwnd = c.CreateWindowExW(
        0,
        App.tab_bar_class,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        window.hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        log.err("failed to create tab bar err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };

    self.* = .{ .window = window, .hwnd = hwnd };
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateFont();
    self.createTooltip();
}

/// Create our tooltip, which covers the whole tab bar and asks us for its
/// text (TTN_GETDISPINFO) based on what's under the mouse.
fn createTooltip(self: *TabBar) void {
    var icc: c.INITCOMMONCONTROLSEX = .{
        .dwSize = @sizeOf(c.INITCOMMONCONTROLSEX),
        .dwICC = c.ICC_BAR_CLASSES,
    };
    _ = c.InitCommonControlsEx(&icc);

    const tooltip = c.CreateWindowExW(
        c.WS_EX_TOPMOST,
        std.unicode.utf8ToUtf16LeStringLiteral("tooltips_class32"),
        null,
        c.WS_POPUP | c.TTS_NOPREFIX | c.TTS_ALWAYSTIP,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        self.hwnd,
        null,
        self.window.app.hinstance,
        null,
    ) orelse {
        log.warn("failed to create the tab bar tooltip err={}", .{c.GetLastError()});
        return;
    };

    var info = std.mem.zeroes(c.TTTOOLINFOW);
    info.cbSize = @sizeOf(c.TTTOOLINFOW);
    info.uFlags = c.TTF_IDISHWND | c.TTF_SUBCLASS;
    info.hwnd = self.hwnd;
    info.uId = @intFromPtr(self.hwnd);
    // LPSTR_TEXTCALLBACKW is the pointer -1, which isn't a validly aligned
    // pointer for Zig, so we set the field's bits.
    @as(*usize, @ptrCast(&info.lpszText)).* = std.math.maxInt(usize);
    _ = c.SendMessageW(tooltip, c.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&info)));
    self.tooltip = tooltip;
}

/// TTN_FIRST - 10, which translate-c can't evaluate (it's negative).
const TTN_GETDISPINFOW: c.UINT = @bitCast(@as(i32, -530));

/// The tooltip text for an element of the tab bar.
fn tooltipText(self: *TabBar, hit: Hit) []const u8 {
    return switch (hit) {
        .tab => |i| if (i < self.window.tabs.items.len) self.window.tabs.items[i].title() else "",
        .close => "Close Tab",
        .new_tab => "New Tab",
        .shell_menu => "New Tab With a Shell",
        .minimize => "Minimize",
        .maximize => if (c.IsZoomed(self.window.hwnd) != 0) "Restore Down" else "Maximize",
        .close_window => "Close",
    };
}

pub fn deinit(self: *TabBar) void {
    if (self.accessibility) |a| a.detach();
    self.accessibility = null;
    if (self.tooltip) |tooltip| _ = c.DestroyWindow(tooltip);
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
    if (self.font) |f| _ = c.DeleteObject(f);
    if (self.icon_font) |f| _ = c.DeleteObject(f);
}

/// Redraw the tab bar, e.g. after tabs or titles changed.
pub fn invalidate(self: *TabBar) void {
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// The height of the tab bar for our current font and DPI.
pub fn height(self: *const TabBar) c_int {
    return self.scale(40);
}

/// Tab geometry at 96 DPI, like Chrome's and Windows Terminal's: in a 40
/// point bar, tabs start `tab_top` from the top and run to the bottom.
/// The active tab is filled with its terminal's background, with rounded
/// top corners and, at the bottom, outward curves (`tab_radius`) that join
/// it to the terminal below. Other tabs aren't filled: thin separators
/// part them, and hovering shows a rounded highlight. The new tab and
/// shell buttons (31 by 24, as in Windows Terminal) follow the last tab.
const tab_top = 6;
const tab_left = 8;
const tab_gap = 0;
const tab_radius = 8;
const tab_padding = 12;
const tab_button_width = 31;
const tab_button_height = 24;

/// Narrower tabs are compact: with the title's padding and the close
/// button, less than about 40 points would be left for the title.
const compact_tab_width = 88;

/// Scale a size in DPI-independent pixels to physical pixels.
fn scale(self: *const TabBar, v: c_int) c_int {
    return scaleDpi(v, self.windowDpi());
}

fn windowDpi(self: *const TabBar) c_int {
    return @intCast(c.GetDpiForWindow(self.window.hwnd));
}

fn scaleDpi(v: c_int, at: c_int) c_int {
    return @divTrunc(v * at, util.USER_DEFAULT_SCREEN_DPI);
}

/// Set our font to the system UI font for our DPI, or the family of
/// `window-title-font-family` at the system UI font's size.
pub fn updateFont(self: *TabBar) void {
    const dpi = c.GetDpiForWindow(self.window.hwnd);
    var lf = util.messageLogFont(dpi) orelse return;
    if (self.window.app.config.@"window-title-font-family") |family| {
        const face = &lf.lfFaceName;
        // The face name is a fixed buffer; too long a name can't name a
        // font, so we keep the system font then.
        const len = std.unicode.calcUtf16LeLen(family) catch 0;
        if (len > 0 and len < face.len) {
            const n = std.unicode.utf8ToUtf16Le(face, family) catch 0;
            face[n] = 0;
        }
    }

    const font = c.CreateFontIndirectW(&lf) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;

    if (self.icon_font) |old| _ = c.DeleteObject(old);
    self.icon_font = iconFont(@intCast(dpi));
    self.invalidate();
}

/// The first of the system's icon fonts that's installed, at 10 points
/// (the caption glyphs are 10 by 10, as in Windows Terminal).
fn iconFont(dpi: c_int) ?c.HFONT {
    const faces = [_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe Fluent Icons"),
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets"),
    };
    const dc = c.GetDC(null) orelse return null;
    defer _ = c.ReleaseDC(null, dc);
    for (faces) |face| {
        var lf = std.mem.zeroes(c.LOGFONTW);
        lf.lfHeight = -@divTrunc(10 * dpi, util.USER_DEFAULT_SCREEN_DPI);
        lf.lfCharSet = c.DEFAULT_CHARSET;
        @memcpy(lf.lfFaceName[0..face.len], face);
        const font = c.CreateFontIndirectW(&lf) orelse continue;
        // Windows substitutes another font for one that isn't installed.
        const old = c.SelectObject(dc, font);
        var got: [c.LF_FACESIZE]u16 = undefined;
        const n = c.GetTextFaceW(dc, got.len, &got);
        _ = c.SelectObject(dc, old);
        if (n > 0 and std.mem.eql(u16, got[0..@intCast(n - 1)], face)) return font;
        _ = c.DeleteObject(font);
    }
    return null;
}

//----------------------------------------------------------------------------
// Layout

const Layout = struct {
    /// The width of each tab, and where they start.
    tab_width: c_int,
    left: c_int,
    top: c_int,
    gap: c_int,

    /// The rectangle of the new tab button.
    new_tab: c.RECT,
    shell_menu: c.RECT,

    /// The caption buttons, with the tabs in the title bar.
    caption: ?struct { minimize: c.RECT, maximize: c.RECT, close: c.RECT },

    /// Whether the tabs are too narrow for a title and a close button
    /// (with many tabs): each shows only its number, as wide as it can, and
    /// has no close button (a click there would close the tab when it was
    /// meant to select or drag it). The tooltip still has the title, and a
    /// middle click, the tab's menu or a keybinding closes it.
    compact: bool,

    /// The number of tabs, the bar's height and the DPI it was laid out
    /// for.
    tabs: usize,
    height: c_int,
    dpi: c_int,

    /// Lay out `tabs` tabs in a bar of the given size (its client area),
    /// with the caption buttons if the tabs are in the title bar.
    fn compute(width: c_int, h: c_int, tabs: usize, at: c_int, caption_buttons: bool) Layout {
        const n: c_int = @intCast(@max(1, tabs));

        // With the tabs in the title bar, the caption buttons (46 by 32, as
        // Windows 11 draws them) go at the right, after some empty space
        // that drags the window, even when there are many tabs.
        const caption_button = scaleDpi(46, at);
        const caption_width = if (caption_buttons) caption_button * 3 else 0;

        // The new tab and shell buttons follow the last tab, as in
        // browsers. Tabs share the width up to a maximum, leaving room for
        // the buttons and, with the caption buttons, some empty space to
        // drag the window.
        const button = scaleDpi(tab_button_width, at);
        const button_gap = scaleDpi(4, at);
        const left = scaleDpi(tab_left, at);
        const gap = scaleDpi(tab_gap, at);
        const drag_space = if (caption_width == 0) 0 else scaleDpi(48, at);
        const right_limit = width - caption_width - drag_space - button_gap - button * 2;
        const available = @max(0, right_limit - left - gap * (n - 1));
        const tab_width = @min(scaleDpi(240, at), @divTrunc(available, n));
        const tabs_end = left + n * tab_width + gap * (n - 1);
        const new_left = tabs_end + button_gap;

        return .{
            .tab_width = tab_width,
            .compact = tab_width < scaleDpi(compact_tab_width, at),
            .left = left,
            .top = scaleDpi(tab_top, at),
            .gap = gap,
            .tabs = tabs,
            .height = h,
            .dpi = at,
            .new_tab = .{ .left = new_left, .top = 0, .right = new_left + button, .bottom = h },
            .shell_menu = .{ .left = new_left + button, .top = 0, .right = new_left + button * 2, .bottom = h },
            .caption = if (caption_width == 0) null else .{
                .minimize = .{ .left = width - caption_button * 3, .top = 0, .right = width - caption_button * 2, .bottom = h },
                .maximize = .{ .left = width - caption_button * 2, .top = 0, .right = width - caption_button, .bottom = h },
                .close = .{ .left = width - caption_button, .top = 0, .right = width, .bottom = h },
            },
        };
    }

    fn tabRect(self: Layout, idx: usize, h: c_int) c.RECT {
        const left = self.left + @as(c_int, @intCast(idx)) * (self.tab_width + self.gap);
        return .{ .left = left, .top = self.top, .right = left + self.tab_width, .bottom = h };
    }

    /// The close button of a tab, centered on its title.
    fn closeRect(self: Layout, tab: c.RECT) c.RECT {
        const size = scaleDpi(16, self.dpi);
        const margin = scaleDpi(8, self.dpi);
        const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
        return .{
            .left = tab.right - margin - size,
            .top = top,
            .right = tab.right - margin,
            .bottom = top + size,
        };
    }

    /// The element at a point in the bar, if any.
    fn hit(self: Layout, pt: c.POINT) ?Hit {
        if (self.caption) |caption| {
            if (c.PtInRect(&caption.minimize, pt) != 0) return .minimize;
            if (c.PtInRect(&caption.maximize, pt) != 0) return .maximize;
            if (c.PtInRect(&caption.close, pt) != 0) return .close_window;
        }
        if (c.PtInRect(&self.new_tab, pt) != 0) return .new_tab;
        if (c.PtInRect(&self.shell_menu, pt) != 0) return .shell_menu;
        for (0..self.tabs) |i| {
            const rect = self.tabRect(i, self.height);
            if (c.PtInRect(&rect, pt) == 0) continue;
            const close = self.closeRect(rect);
            if (!self.compact and c.PtInRect(&close, pt) != 0) return .{ .close = i };
            return .{ .tab = i };
        }
        return null;
    }

    /// The tab index at an x position, for dragging tabs.
    fn indexAt(self: Layout, x: c_int) usize {
        const step = self.tab_width + self.gap;
        if (step <= 0) return 0;
        return @intCast(@divTrunc(@max(0, x - self.left), step));
    }
};

fn layout(self: *const TabBar) Layout {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    return .compute(
        client.right,
        client.bottom,
        self.window.tabs.items.len,
        self.windowDpi(),
        self.window.hasTitleBarTabs(),
    );
}

test "Layout: tabs share the width up to a maximum" {
    const testing = std.testing;

    // A few tabs at 96 DPI are 240 wide, from 8, and the buttons follow.
    const l: Layout = .compute(1200, 40, 2, 96, false);
    try testing.expectEqual(@as(c_int, 240), l.tab_width);
    try testing.expect(!l.compact);
    try testing.expectEqual(c.RECT{ .left = 248, .top = 6, .right = 488, .bottom = 40 }, l.tabRect(1, 40));
    try testing.expectEqual(@as(c_int, 492), l.new_tab.left);
    try testing.expectEqual(l.new_tab.right, l.shell_menu.left);
    try testing.expect(l.caption == null);

    // At 192 DPI everything doubles.
    const hi: Layout = .compute(2400, 80, 2, 192, false);
    try testing.expectEqual(@as(c_int, 480), hi.tab_width);
    try testing.expectEqual(@as(c_int, 984), hi.new_tab.left);
}

test "Layout: many tabs shrink, then go compact, and never pass the buttons" {
    const testing = std.testing;
    for ([_]usize{ 1, 3, 8, 20, 60 }) |n| {
        for ([_]bool{ false, true }) |caption| {
            const l: Layout = .compute(1000, 40, n, 96, caption);
            const last = l.tabRect(n - 1, 40);
            try testing.expect(last.right <= l.new_tab.left);
            try testing.expect(l.shell_menu.right <= if (l.caption) |cb| cb.minimize.left else 1000);
            try testing.expectEqual(l.tab_width < 88, l.compact);
        }
    }
    try testing.expect(!Layout.compute(1000, 40, 8, 96, false).compact);
    try testing.expect(Layout.compute(1000, 40, 20, 96, false).compact);

    // Too narrow a window has no room for tabs, but still lays out.
    const tiny: Layout = .compute(50, 40, 3, 96, true);
    try testing.expectEqual(@as(c_int, 0), tiny.tab_width);
    try testing.expect(tiny.compact);
}

test "Layout: the caption buttons are at the right" {
    const testing = std.testing;
    const l: Layout = .compute(1000, 40, 1, 96, true);
    const cb = l.caption.?;
    try testing.expectEqual(c.RECT{ .left = 862, .top = 0, .right = 908, .bottom = 40 }, cb.minimize);
    try testing.expectEqual(cb.minimize.right, cb.maximize.left);
    try testing.expectEqual(c.RECT{ .left = 954, .top = 0, .right = 1000, .bottom = 40 }, cb.close);
}

test "Layout: hit testing" {
    const testing = std.testing;
    const l: Layout = .compute(1000, 40, 3, 96, true);

    try testing.expectEqual(Hit{ .tab = 0 }, l.hit(.{ .x = 20, .y = 20 }).?);
    try testing.expectEqual(Hit{ .tab = 2 }, l.hit(.{ .x = 8 + 2 * l.tab_width + 1, .y = 20 }).?);
    // The close button is at the tab's right, centered on its title.
    const close = l.closeRect(l.tabRect(1, 40));
    try testing.expectEqual(Hit{ .close = 1 }, l.hit(.{ .x = close.left + 1, .y = close.top + 1 }).?);
    try testing.expectEqual(Hit.new_tab, l.hit(.{ .x = l.new_tab.left, .y = 5 }).?);
    try testing.expectEqual(Hit.shell_menu, l.hit(.{ .x = l.shell_menu.left, .y = 5 }).?);
    try testing.expectEqual(Hit.minimize, l.hit(.{ .x = 870, .y = 5 }).?);
    try testing.expectEqual(Hit.maximize, l.hit(.{ .x = 930, .y = 5 }).?);
    try testing.expectEqual(Hit.close_window, l.hit(.{ .x = 999, .y = 39 }).?);
    // Above the tabs and in the space before the caption buttons, nothing
    // (the window's caption, to drag it).
    try testing.expect(l.hit(.{ .x = 20, .y = 2 }) == null);
    try testing.expect(l.hit(.{ .x = 840, .y = 20 }) == null);

    // Compact tabs have no close button: there, it's the tab.
    const many: Layout = .compute(1000, 40, 20, 96, false);
    try testing.expect(many.compact);
    const spot = many.closeRect(many.tabRect(4, 40));
    try testing.expectEqual(Hit{ .tab = 4 }, many.hit(.{ .x = spot.left + 1, .y = spot.top + 1 }).?);
}

test "Layout: dragging finds the tab under the pointer" {
    const testing = std.testing;
    const l: Layout = .compute(1200, 40, 3, 96, false);
    try testing.expectEqual(@as(usize, 0), l.indexAt(-50));
    try testing.expectEqual(@as(usize, 0), l.indexAt(247));
    try testing.expectEqual(@as(usize, 1), l.indexAt(248));
    try testing.expectEqual(@as(usize, 2), l.indexAt(500));
}

/// Whether a point in the window's client area (which the tab bar starts
/// at the top of) is on the maximize button.
pub fn isMaximizeButton(self: *const TabBar, pt: c.POINT) bool {
    const caption = self.layout().caption orelse return false;
    return c.PtInRect(&caption.maximize, pt) != 0;
}

/// The window tells us when the mouse is over the maximize button.
pub fn setMaximizeHovered(self: *TabBar, hovered: bool) void {
    if (self.maximize_hovered == hovered) return;
    self.maximize_hovered = hovered;
    self.invalidate();
}

/// The rectangle of the tab at an index, on the screen.
pub fn tabScreenRect(self: *const TabBar, idx: usize) c.RECT {
    const l = self.layout();
    return self.toScreen(l.tabRect(idx, l.height));
}

/// The element at a point on the screen, if any.
pub fn hitAtScreen(self: *const TabBar, pt: c.POINT) ?Hit {
    var client_pt = pt;
    _ = c.ScreenToClient(self.hwnd, &client_pt);
    return self.hitTest(client_pt.x, client_pt.y);
}

/// The buttons UI Automation exposes after the tabs: the new tab and
/// shell buttons, and with the tabs in the title bar (the only time we draw
/// them) the caption buttons, which Windows no longer exposes then.
pub const Button = enum { new_tab, shell_menu, minimize, maximize, close_window };

/// How many of the buttons are there now: the caption buttons only with
/// the tabs in the title bar.
pub fn buttonCount(self: *const TabBar) usize {
    return if (self.layout().caption != null) 5 else 2;
}

/// The rectangle of a button, on the screen.
pub fn buttonScreenRect(self: *const TabBar, button: Button) c.RECT {
    const l = self.layout();
    const none: c.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const rect = switch (button) {
        .new_tab => l.new_tab,
        .shell_menu => l.shell_menu,
        .minimize => if (l.caption) |caption| caption.minimize else none,
        .maximize => if (l.caption) |caption| caption.maximize else none,
        .close_window => if (l.caption) |caption| caption.close else none,
    };
    return self.toScreen(rect);
}

/// A button's name, as in its tooltip.
pub fn buttonName(self: *TabBar, button: Button) []const u8 {
    return self.tooltipText(switch (button) {
        .new_tab => .new_tab,
        .shell_menu => .shell_menu,
        .minimize => .minimize,
        .maximize => .maximize,
        .close_window => .close_window,
    });
}

/// Press a button, as if clicked, for UI Automation. It happens later,
/// from a posted message, since the menus run a modal loop and Invoke
/// should return right away.
pub fn pressButton(self: *TabBar, button: Button) void {
    _ = c.PostMessageW(self.hwnd, WM_GHOSTTY_PRESS_BUTTON, @backingInt(button), 0);
}

const WM_GHOSTTY_PRESS_BUTTON = c.WM_APP + 1;

/// Close a tab, as its close button does, for UI Automation. Like
/// pressButton it happens later, from a posted message, since closing may
/// ask first. The tab is looked up again then, in case it closed.
pub fn closeTabLater(self: *TabBar, tab: *Tab) void {
    _ = c.PostMessageW(self.hwnd, WM_GHOSTTY_CLOSE_TAB, @intFromPtr(tab), 0);
}

const WM_GHOSTTY_CLOSE_TAB = c.WM_APP + 2;

/// Rename a tab that was double clicked, with prompt_tab_title.
const WM_GHOSTTY_RENAME_TAB = c.WM_APP + 3;

/// Whether the tabs are compact, without close buttons drawn.
pub fn compact(self: *const TabBar) bool {
    return self.layout().compact;
}

/// A tab's close button, in screen coordinates; empty when the tabs are
/// compact and don't draw one.
pub fn closeScreenRect(self: *const TabBar, idx: usize) c.RECT {
    const l = self.layout();
    if (l.compact) return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    return self.toScreen(l.closeRect(l.tabRect(idx, l.height)));
}

/// Called when a tab is selected, to tell screen readers.
pub fn tabSelected(self: *TabBar, tab: *Tab) void {
    if (self.accessibility) |a| a.tabSelected(tab);
}

fn hitTest(self: *const TabBar, x: c_int, y: c_int) ?Hit {
    return self.layout().hit(.{ .x = x, .y = y });
}

/// A rectangle in the tab bar, on the screen.
fn toScreen(self: *const TabBar, rect: c.RECT) c.RECT {
    var top_left: c.POINT = .{ .x = rect.left, .y = rect.top };
    var bottom_right: c.POINT = .{ .x = rect.right, .y = rect.bottom };
    _ = c.ClientToScreen(self.hwnd, &top_left);
    _ = c.ClientToScreen(self.hwnd, &bottom_right);
    return .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y };
}

//----------------------------------------------------------------------------
// Painting

const Rgb = struct { r: u8, g: u8, b: u8 };

const Colors = struct {
    bar: Rgb,
    active: Rgb,
    hover: Rgb,
    /// Hovered caption, new tab and shell buttons.
    caption_hover: Rgb,
    /// Inactive tabs, raised a little from the bar, with a thin border.
    tab: Rgb,
    tab_hover: Rgb,
    tab_border: Rgb,
    text: Rgb,
    text_inactive: Rgb,
    separator: Rgb,
};

fn colors(self: *const TabBar) Colors {
    if (util.highContrast()) return highContrastColors();

    // The active terminal's colors, which programs may have changed.
    const config = &self.window.app.config;
    const surface = if (self.window.tabs.items.len > 0) self.window.activeSurface() else null;
    const bg_color = if (surface) |s| s.background_color orelse config.background.toTerminalRGB() else config.background.toTerminalRGB();
    const fg_color = if (surface) |s| s.foreground_color orelse config.foreground.toTerminalRGB() else config.foreground.toTerminalRGB();
    const bg: Rgb = .{ .r = bg_color.r, .g = bg_color.g, .b = bg_color.b };
    const fg: Rgb = .{ .r = fg_color.r, .g = fg_color.g, .b = fg_color.b };
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    // Darker than the terminal, so the active tab stands out from the
    // bar: by 30% for dark backgrounds, and 12% for light ones, as in
    // browsers, where 30% would turn a white page's bar a dull gray.
    const luma = 0.2126 * @as(f32, @floatFromInt(bg.r)) + 0.7152 * @as(f32, @floatFromInt(bg.g)) + 0.0722 * @as(f32, @floatFromInt(bg.b));
    const bar = blend(bg, black, if (luma > 128) 0.12 else 0.3);
    return .{
        .bar = bar,
        .active = bg,
        .hover = blend(bar, fg, 0.08),
        .caption_hover = blend(bar, fg, 0.08),
        .tab = blend(bar, fg, 0.03),
        .tab_hover = blend(bar, fg, 0.08),
        .tab_border = blend(bar, fg, 0.12),
        .text = fg,
        .text_inactive = blend(fg, bg, 0.4),
        .separator = blend(bg, fg, 0.15),
    };
}

/// The colors of a high contrast theme: the bar is a window, the active
/// tab is highlighted (like a selected item), and hovered items are
/// buttons.
fn highContrastColors() Colors {
    const text = sysColor(c.COLOR_WINDOWTEXT);
    return .{
        .bar = sysColor(c.COLOR_WINDOW),
        .active = sysColor(c.COLOR_HIGHLIGHT),
        .hover = sysColor(c.COLOR_BTNFACE),
        .caption_hover = sysColor(c.COLOR_BTNFACE),
        .tab = sysColor(c.COLOR_WINDOW),
        .tab_hover = sysColor(c.COLOR_BTNFACE),
        .tab_border = text,
        .text = sysColor(c.COLOR_HIGHLIGHTTEXT),
        .text_inactive = text,
        .separator = text,
    };
}

fn sysColor(index: c_int) Rgb {
    const v = c.GetSysColor(index);
    return .{
        .r = @truncate(v),
        .g = @truncate(v >> 8),
        .b = @truncate(v >> 16),
    };
}

/// Blend color `a` toward `b` by `t` (0 to 1).
fn blend(a: Rgb, b: Rgb, t: f32) Rgb {
    return .{
        .r = mix(a.r, b.r, t),
        .g = mix(a.g, b.g, t),
        .b = mix(a.b, b.b, t),
    };
}

fn mix(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

fn colorref(v: Rgb) c.COLORREF {
    return @as(c.COLORREF, v.r) | (@as(c.COLORREF, v.g) << 8) | (@as(c.COLORREF, v.b) << 16);
}

fn fill(hdc: c.HDC, rect: *const c.RECT, color: Rgb) void {
    const brush = c.CreateSolidBrush(colorref(color));
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, rect, brush);
}

fn paint(self: *TabBar, hdc: c.HDC, client: c.RECT) void {
    const col = self.colors();
    const l = self.layout();
    const window = self.window;

    fill(hdc, &client, col.bar);

    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    const old_font = if (self.font) |f| c.SelectObject(hdc, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(hdc, f);
    };

    const alloc = window.app.core_app.alloc;
    const n = window.tabs.items.len;
    const r = self.scale(tab_radius);

    // Separators between tabs that aren't active or hovered.
    for (0..n -| 1) |i| {
        if (self.tabHighlighted(i) or self.tabHighlighted(i + 1)) continue;
        const rect = l.tabRect(i, client.bottom);
        const x = rect.right + @divTrunc(l.gap, 2) - @divTrunc(@max(1, self.scale(1)), 2);
        const sep: c.RECT = .{ .left = x, .top = rect.top + self.scale(8), .right = x + @max(1, self.scale(1)), .bottom = client.bottom - self.scale(8) };
        fill(hdc, &sep, col.tab_border);
    }

    for (window.tabs.items, 0..) |tab, i| {
        const rect = l.tabRect(i, client.bottom);
        const active = i == window.active;
        const hovered = Hit.eql(self.hover, .{ .tab = i }) or Hit.eql(self.hover, .{ .close = i });

        if (active) {
            // Rounded at the top, and curving out at the bottom into the
            // terminal, whose background it has.
            fillRounded(hdc, rect, r, .top, col.active);
            fillFlare(hdc, rect.left, client.bottom, r, .left, col.active);
            fillFlare(hdc, rect.right, client.bottom, r, .right, col.active);
        } else if (hovered) {
            const pill: c.RECT = .{ .left = rect.left + self.scale(2), .top = rect.top, .right = rect.right - self.scale(2), .bottom = client.bottom - self.scale(4) };
            fillRounded(hdc, pill, self.scale(6), .all, col.tab_hover);
        }

        // Title, with the tab's number and, for splits, how many terminals
        // it has, like "2: api (3)", at the left as in browsers. Compact
        // tabs have only the number, centered, and no close button.
        const close = l.closeRect(rect);
        var text_rect: c.RECT = if (l.compact) .{
            .left = rect.left + self.scale(4),
            .top = rect.top,
            .right = rect.right - self.scale(4),
            .bottom = rect.bottom,
        } else .{
            .left = rect.left + self.scale(tab_padding),
            .top = rect.top,
            .right = close.left - self.scale(4),
            .bottom = rect.bottom,
        };
        var count: usize = 0;
        var it = tab.tree.iterator();
        while (it.next()) |_| count += 1;
        const title = tab.title();
        const bell = if (tab.hasBell()) "🔔 " else "";
        const title8 = (if (l.compact)
            std.fmt.allocPrint(alloc, "{s}{d}", .{ bell, i + 1 })
        else if (count > 1)
            std.fmt.allocPrint(alloc, "{s}{d}: {s} ({d})", .{ bell, i + 1, title, count })
        else
            std.fmt.allocPrint(alloc, "{s}{d}: {s}", .{ bell, i + 1, title })) catch continue;
        defer alloc.free(title8);
        const title16 = util.utf16Alloc(alloc, title8) catch continue;
        defer alloc.free(title16);
        _ = c.SetTextColor(hdc, colorref(if (active) col.text else col.text_inactive));
        _ = c.DrawTextW(
            hdc,
            title16.ptr,
            @intCast(title16.len),
            &text_rect,
            @as(c.UINT, @intCast(c.DT_SINGLELINE | c.DT_VCENTER | (if (l.compact) c.DT_CENTER else c.DT_LEFT) | c.DT_END_ELLIPSIS | c.DT_NOPREFIX)),
        );

        // A close button on every tab that has room, as in browsers.
        if (!l.compact) {
            if (Hit.eql(self.hover, .{ .close = i })) {
                fillRounded(hdc, close, self.scale(4), .all, blend(if (active) col.active else col.tab_hover, col.text, 0.15));
            }
            const color = if (active) col.text else col.text_inactive;
            if (!self.drawGlyph(hdc, close, 0xE8BB, color)) self.drawCross(hdc, close, color);
        }
    }

    // The new tab and shell buttons, after the tabs, centered on them.
    const button_top = l.top + @divTrunc(client.bottom - l.top - self.scale(tab_button_height), 2);
    for ([_]struct { Hit, c.RECT }{ .{ .new_tab, l.new_tab }, .{ .shell_menu, l.shell_menu } }) |b| {
        const rect: c.RECT = .{ .left = b[1].left, .top = button_top, .right = b[1].right, .bottom = button_top + self.scale(tab_button_height) };
        if (Hit.eql(self.hover, b[0])) fillRounded(hdc, rect, self.scale(4), .all, col.caption_hover);
        switch (b[0]) {
            .new_tab => if (!self.drawGlyph(hdc, rect, 0xE710, col.text_inactive)) self.drawPlus(hdc, rect, col.text_inactive),
            else => if (!self.drawGlyph(hdc, rect, 0xE70D, col.text_inactive)) self.drawChevron(hdc, rect, col.text_inactive),
        }
    }

    if (l.caption) |caption| self.paintCaptionButtons(hdc, caption.minimize, caption.maximize, caption.close, col);
}

/// Whether a tab is drawn highlighted (active or hovered), which hides the
/// separators beside it.
fn tabHighlighted(self: *const TabBar, i: usize) bool {
    return i == self.window.active or
        Hit.eql(self.hover, .{ .tab = i }) or
        Hit.eql(self.hover, .{ .close = i });
}

const Corners = enum { all, top };

/// A filled rectangle with rounded corners (all, or only the top ones),
/// antialiased: GDI's RoundRect isn't, which shows on curves this large.
fn fillRounded(hdc: c.HDC, rect: c.RECT, radius: c_int, corners: Corners, color: Rgb) void {
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    const rad = @max(0, @min(radius, @divTrunc(w, 2), @divTrunc(h, 2)));
    const bottom_rad = if (corners == .all) rad else 0;
    // The middle, and the sides between the corners.
    fill(hdc, &.{ .left = rect.left + rad, .top = rect.top, .right = rect.right - rad, .bottom = rect.bottom }, color);
    fill(hdc, &.{ .left = rect.left, .top = rect.top + rad, .right = rect.left + rad, .bottom = rect.bottom - bottom_rad }, color);
    fill(hdc, &.{ .left = rect.right - rad, .top = rect.top + rad, .right = rect.right, .bottom = rect.bottom - bottom_rad }, color);
    // The corners: quarter discs centered `rad` in from each corner.
    const r: f32 = @floatFromInt(rad);
    const left: f32 = @floatFromInt(rect.left);
    const top: f32 = @floatFromInt(rect.top);
    const right: f32 = @floatFromInt(rect.right);
    const bottom: f32 = @floatFromInt(rect.bottom);
    fillCorner(hdc, rect.left, rect.top, rad, left + r, top + r, false, color);
    fillCorner(hdc, rect.right - rad, rect.top, rad, right - r, top + r, false, color);
    if (corners == .all) {
        fillCorner(hdc, rect.left, rect.bottom - rad, rad, left + r, bottom - r, false, color);
        fillCorner(hdc, rect.right - rad, rect.bottom - rad, rad, right - r, bottom - r, false, color);
    }
}

/// The outward curve at a bottom corner of the active tab, which joins it
/// to the terminal below: the square of side `radius` beside the tab's
/// edge at `x`, filled outside a disc centered `radius` above the bottom
/// and `radius` away from the tab.
fn fillFlare(hdc: c.HDC, x: c_int, bottom: c_int, radius: c_int, side: enum { left, right }, color: Rgb) void {
    if (radius <= 0) return;
    const r: f32 = @floatFromInt(radius);
    const top = bottom - radius;
    switch (side) {
        .left => fillCorner(hdc, x - radius, top, radius, @as(f32, @floatFromInt(x)) - r, @floatFromInt(top), true, color),
        .right => fillCorner(hdc, x, top, radius, @as(f32, @floatFromInt(x)) + r, @floatFromInt(top), true, color),
    }
}

/// Fill the pixels of the square at (`x`, `y`) of side `size` that are
/// inside (or, if `outside`, outside) the disc of radius `size` centered
/// at (`cx`, `cy`), blending edge pixels by coverage (4 by 4 samples)
/// over what's there. For the few pixels at a corner, GetPixel and
/// SetPixelV on the memory bitmap we paint into are fast enough.
fn fillCorner(hdc: c.HDC, x: c_int, y: c_int, size: c_int, cx: f32, cy: f32, outside: bool, color: Rgb) void {
    const r: f32 = @floatFromInt(size);
    const r2 = r * r;
    var py: c_int = y;
    while (py < y + size) : (py += 1) {
        var px: c_int = x;
        while (px < x + size) : (px += 1) {
            var inside: u8 = 0;
            for (0..4) |sy| for (0..4) |sx| {
                const fx = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4 - cx;
                const fy = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4 - cy;
                if (fx * fx + fy * fy <= r2) inside += 1;
            };
            const covered: u8 = if (outside) 16 - inside else inside;
            if (covered == 0) continue;
            if (covered == 16) {
                _ = c.SetPixelV(hdc, px, py, colorref(color));
                continue;
            }
            const under = c.GetPixel(hdc, px, py);
            const below: Rgb = .{ .r = @truncate(under), .g = @truncate(under >> 8), .b = @truncate(under >> 16) };
            _ = c.SetPixelV(hdc, px, py, colorref(blend(below, color, @as(f32, @floatFromInt(covered)) / 16)));
        }
    }
}

/// A glyph of the system's icon font, centered in a rectangle. Returns
/// false if there's no icon font, for the caller to draw it with lines.
fn drawGlyph(self: *const TabBar, hdc: c.HDC, rect: c.RECT, codepoint: u16, color: Rgb) bool {
    const font = self.icon_font orelse return false;
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);
    var r = rect;
    var text = [_]u16{codepoint};
    _ = c.SetTextColor(hdc, colorref(color));
    _ = c.DrawTextW(hdc, &text, 1, &r, c.DT_SINGLELINE | c.DT_CENTER | c.DT_VCENTER | c.DT_NOPREFIX);
    return true;
}

/// The minimize, maximize (or restore) and close buttons, like the system's:
/// hovering fills them, the close button in red; dimmer when the window
/// isn't active.
fn paintCaptionButtons(self: *const TabBar, hdc: c.HDC, minimize: c.RECT, maximize: c.RECT, close: c.RECT, col: Colors) void {
    const active = c.GetForegroundWindow() == self.window.hwnd;
    const glyph = if (active) col.text else col.text_inactive;
    if (Hit.eql(self.hover, .minimize)) fill(hdc, &minimize, col.caption_hover);
    if (self.maximize_hovered) fill(hdc, &maximize, col.caption_hover);
    const close_hovered = Hit.eql(self.hover, .close_window);
    if (close_hovered) fill(hdc, &close, .{ .r = 0xC4, .g = 0x2B, .b = 0x1C });

    // The system's glyphs: minimize, maximize or restore, and close.
    if (self.icon_font != null) {
        const maximized = c.IsZoomed(self.window.hwnd) != 0;
        _ = self.drawGlyph(hdc, minimize, 0xE921, glyph);
        _ = self.drawGlyph(hdc, maximize, if (maximized) 0xE923 else 0xE922, glyph);
        _ = self.drawGlyph(hdc, close, 0xE8BB, if (close_hovered) .{ .r = 255, .g = 255, .b = 255 } else glyph);
        return;
    }

    const size = self.scale(10);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(glyph));
    defer _ = c.DeleteObject(pen);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    const old_brush = c.SelectObject(hdc, c.GetStockObject(c.NULL_BRUSH));
    defer _ = c.SelectObject(hdc, old_brush);

    // Minimize: a line.
    {
        const cx = @divTrunc(minimize.left + minimize.right, 2);
        const cy = @divTrunc(minimize.top + minimize.bottom, 2);
        _ = c.MoveToEx(hdc, cx - @divTrunc(size, 2), cy, null);
        _ = c.LineTo(hdc, cx + @divTrunc(size, 2) + 1, cy);
    }

    // Maximize: a square; restore: two overlapping squares.
    {
        const cx = @divTrunc(maximize.left + maximize.right, 2);
        const cy = @divTrunc(maximize.top + maximize.bottom, 2);
        const half = @divTrunc(size, 2);
        if (c.IsZoomed(self.window.hwnd) != 0) {
            const off = self.scale(2);
            _ = c.Rectangle(hdc, cx - half, cy - half + off, cx + half - off + 1, cy + half + 1);
            _ = c.MoveToEx(hdc, cx - half + off, cy - half + off, null);
            _ = c.LineTo(hdc, cx - half + off, cy - half);
            _ = c.LineTo(hdc, cx + half, cy - half);
            _ = c.LineTo(hdc, cx + half, cy + half - off + 1);
            _ = c.LineTo(hdc, cx + half - off, cy + half - off + 1);
        } else {
            _ = c.Rectangle(hdc, cx - half, cy - half, cx + half + 1, cy + half + 1);
        }
    }

    // Close: a cross, white on the red hover.
    {
        const color: Rgb = if (close_hovered) .{ .r = 255, .g = 255, .b = 255 } else glyph;
        const cx = @divTrunc(close.left + close.right, 2);
        const cy = @divTrunc(close.top + close.bottom, 2);
        const half = @divTrunc(size, 2);
        self.drawCross(hdc, .{ .left = cx - half - self.scale(4), .top = cy - half - self.scale(4), .right = cx + half + self.scale(4) + 1, .bottom = cy + half + self.scale(4) + 1 }, color);
    }
}

fn drawChevron(self: *const TabBar, hdc: c.HDC, rect: c.RECT, color: Rgb) void {
    const size = self.scale(4);
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(color));
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, cx - size, cy - @divTrunc(size, 2), null);
    _ = c.LineTo(hdc, cx, cy + @divTrunc(size, 2));
    _ = c.LineTo(hdc, cx + size, cy - @divTrunc(size, 2));
}

/// This native menu pumps messages: the window may close while it is open.
fn showShellMenu(self: *TabBar) void {
    const hwnd = self.hwnd;
    const owner = self.window.hwnd;
    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    var arena: std.heap.ArenaAllocator = .init(self.window.app.core_app.alloc);
    defer arena.deinit();
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    const list = shells.list(arena.allocator()) catch |err| {
        log.warn("error listing shells err={}", .{err});
        return;
    };
    Menu.appendShells(arena.allocator(), menu, list, 1, 0) catch return;

    const rect = self.layout().shell_menu;
    var pt: c.POINT = .{ .x = rect.left, .y = rect.bottom };
    _ = c.ClientToScreen(hwnd, &pt);
    self.setHover(null);
    const selected = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_NONOTIFY, pt.x, pt.y, 0, owner, null);
    // Never dereference self after the nested loop unless it still owns HWND.
    if (selected == 0 or c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;
    _ = self.window.addTabWithShell(
        &self.window.activeSurface().core_surface,
        list[@intCast(selected - 1)].command,
    ) catch |err| {
        log.err("error creating shell tab err={}", .{err});
    };
}

fn drawCross(self: *const TabBar, hdc: c.HDC, rect: c.RECT, color: Rgb) void {
    const inset = self.scale(4);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(color));
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, rect.left + inset, rect.top + inset, null);
    _ = c.LineTo(hdc, rect.right - inset, rect.bottom - inset);
    _ = c.MoveToEx(hdc, rect.right - inset - 1, rect.top + inset, null);
    _ = c.LineTo(hdc, rect.left + inset - 1, rect.bottom - inset);
}

fn drawPlus(self: *const TabBar, hdc: c.HDC, rect: c.RECT, color: Rgb) void {
    const size = self.scale(6);
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(color));
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, cx - size, cy, null);
    _ = c.LineTo(hdc, cx + size + 1, cy);
    _ = c.MoveToEx(hdc, cx, cy - size, null);
    _ = c.LineTo(hdc, cx, cy + size + 1);
}

//----------------------------------------------------------------------------
// Window procedure

fn setHover(self: *TabBar, hit: ?Hit) void {
    if (Hit.eql(self.hover, hit)) return;
    self.hover = hit;
    self.invalidate();

    // Show the new element's text, or hide the tooltip between them.
    if (self.tooltip) |tooltip| {
        if (hit == null) {
            _ = c.SendMessageW(tooltip, c.TTM_POP, 0, 0);
        } else {
            _ = c.SendMessageW(tooltip, c.TTM_UPDATE, 0, 0);
        }
    }
}

fn dragMove(self: *TabBar, x: c_int, y: c_int) void {
    const tab = self.drag_tab orelse return;
    if (self.window.tabs.items[self.window.active] != tab) {
        self.drag_tab = null;
        return;
    }
    if (!self.dragging) {
        // Dragging down starts a drag too, to move the tab to a window.
        const threshold_x = @max(1, c.GetSystemMetrics(c.SM_CXDRAG));
        const threshold_y = @max(1, c.GetSystemMetrics(c.SM_CYDRAG));
        if (@abs(x - self.drag_start_x) < threshold_x and
            @abs(y - self.drag_start_y) < threshold_y) return;
        self.dragging = true;
    }
    const l = self.layout();
    if (l.tab_width <= 0) return;
    const to: usize = @min(l.indexAt(x), self.window.tabs.items.len - 1);
    const from = self.window.active;
    if (to != from) _ = self.window.moveTab(@as(isize, @intCast(to)) - @as(isize, @intCast(from)));
}

/// A dragged tab was dropped at a point in our client area. Dropped well
/// above or below the tab bar, like in browsers, it moves to the window
/// under the pointer, or to a new window there. Moving our window's last
/// tab to another window closes ours, and us with it.
fn dropTab(self: *TabBar, tab: *Tab, x: c_int, y: c_int) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const margin = client.bottom - client.top;
    if (y >= client.top - margin and y < client.bottom + margin) return;

    var pt: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(self.hwnd, &pt);
    const window = self.window;
    if (window.app.windowAt(pt)) |target| {
        if (target != window) {
            _ = window.moveTabToWindow(tab, target) catch |err| {
                log.warn("error moving tab to window err={}", .{err});
            };
            return;
        }
    }

    const new_window = (window.tearOffTab(tab) catch |err| {
        log.warn("error moving tab to a new window err={}", .{err});
        return;
    }) orelse return;

    // Put the new window's tab bar under the pointer.
    if (c.IsZoomed(new_window.hwnd) != 0) return;
    const dpi: c_int = @intCast(c.GetDpiForWindow(new_window.hwnd));
    const offset_x = @divTrunc(80 * dpi, 96);
    const offset_y = c.GetSystemMetricsForDpi(c.SM_CYCAPTION, @intCast(dpi)) +
        @divTrunc(margin, 2);
    _ = c.SetWindowPos(
        new_window.hwnd,
        null,
        pt.x - offset_x,
        pt.y - offset_y,
        0,
        0,
        c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

fn paintClient(self: *TabBar, hdc: c.HDC) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    self.paint(hdc, client);
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *TabBar = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        WM_GHOSTTY_RENAME_TAB => {
            // Compared by address only: the tab may be gone.
            const tab: *Tab = @ptrFromInt(wparam);
            if (self.window.tabIndex(tab) != null) tab.focused.performMenuAction(.prompt_tab_title);
            return 0;
        },

        WM_GHOSTTY_CLOSE_TAB => {
            // Compared by address only: the tab may be gone.
            const tab: *Tab = @ptrFromInt(wparam);
            if (self.window.tabIndex(tab)) |idx| self.window.closeTabAt(idx);
            return 0;
        },

        WM_GHOSTTY_PRESS_BUTTON => {
            switch (std.enums.fromInt(Button, wparam) orelse return 0) {
                .new_tab => _ = self.window.newTab(),
                .shell_menu => self.showShellMenu(),
                .minimize => _ = c.ShowWindow(self.window.hwnd, c.SW_MINIMIZE),
                .maximize => _ = c.ShowWindow(self.window.hwnd, if (c.IsZoomed(self.window.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE),
                .close_window => _ = c.PostMessageW(self.window.hwnd, c.WM_CLOSE, 0, 0),
            }
            return 0;
        },

        // With the tabs in the title bar, the window handles our empty
        // space (the caption), the top resize border and the maximize
        // button (for snap layouts); see its WM_NCHITTEST.
        c.WM_NCHITTEST => if (self.window.hasTitleBarTabs()) {
            var pt: c.POINT = .{ .x = util.loword(lparam), .y = util.hiword(lparam) };
            _ = c.ScreenToClient(hwnd, &pt);
            if (c.IsZoomed(self.window.hwnd) == 0 and pt.y < self.window.resizeBorderHeight()) return c.HTTRANSPARENT;
            const hit = self.hitTest(pt.x, pt.y) orelse return c.HTTRANSPARENT;
            if (hit == .maximize) return c.HTTRANSPARENT;
            return c.HTCLIENT;
        },

        c.WM_GETOBJECT => {
            if (self.accessibility == null) {
                self.accessibility = TabBarAccessibility.create(self.window.app.core_app.alloc, self) catch null;
            }
            if (self.accessibility) |a| {
                if (a.getObject(hwnd, wparam, lparam)) |result| return result;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);

            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            util.paintOpaque(hdc, client, self, paintClient);
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (self.drag_tab != null and (wparam & c.MK_LBUTTON) != 0) {
                self.dragMove(util.loword(lparam), util.hiword(lparam));
            }
            if (!self.tracking_mouse) {
                var tme: c.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                    .dwFlags = c.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (c.TrackMouseEvent(&tme) != 0) self.tracking_mouse = true;
            }
            self.setHover(self.hitTest(util.loword(lparam), util.hiword(lparam)));
            return 0;
        },

        c.WM_NOTIFY => {
            const header: *const c.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (self.tooltip != null and header.hwndFrom == self.tooltip and
                header.code == TTN_GETDISPINFOW)
            {
                const info: *c.NMTTDISPINFOW = @ptrFromInt(@as(usize, @bitCast(lparam)));
                const text = if (self.hover) |hit| self.tooltipText(hit) else "";
                // A tab's title can be any length.
                _ = util.utf16TruncateZ(&self.tooltip_text, text);
                info.lpszText = &self.tooltip_text;
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            self.setHover(null);
            return 0;
        },

        // We set CS_DBLCLKS for double clicks on empty space (a new tab)
        // and on tabs (renaming it, as in Windows Terminal). A quick second
        // click on anything else is just another click.
        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK => {
            const hit = self.hitTest(util.loword(lparam), util.hiword(lparam)) orelse {
                if (msg == c.WM_LBUTTONDBLCLK) _ = self.window.newTab();
                return 0;
            };
            if (msg == c.WM_LBUTTONDBLCLK and hit == .tab) {
                // The first click selected it. The dialog is modal, so it
                // opens from a posted message, after this one.
                const tab = self.window.tabs.items[hit.tab];
                _ = c.PostMessageW(hwnd, WM_GHOSTTY_RENAME_TAB, @intFromPtr(tab), 0);
                return 0;
            }
            switch (hit) {
                .tab => |i| {
                    self.window.selectTab(i);
                    self.drag_tab = self.window.tabs.items[i];
                    self.drag_start_x = util.loword(lparam);
                    self.drag_start_y = util.hiword(lparam);
                    self.dragging = false;
                    _ = c.SetCapture(hwnd);
                },
                .close => |i| self.window.closeTabAt(i),
                .new_tab => _ = self.window.newTab(),
                .shell_menu => self.showShellMenu(),
                .minimize => _ = c.ShowWindow(self.window.hwnd, c.SW_MINIMIZE),
                .maximize => _ = c.ShowWindow(self.window.hwnd, if (c.IsZoomed(self.window.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE),
                .close_window => _ = c.PostMessageW(self.window.hwnd, c.WM_CLOSE, 0, 0),
            }
            return 0;
        },

        c.WM_LBUTTONUP => {
            if (self.drag_tab) |tab| {
                const dragged = self.dragging;
                self.drag_tab = null;
                self.dragging = false;
                if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
                if (dragged) self.dropTab(tab, util.loword(lparam), util.hiword(lparam));
            }
            return 0;
        },

        c.WM_CAPTURECHANGED => {
            self.drag_tab = null;
            self.dragging = false;
            return 0;
        },

        c.WM_RBUTTONUP => {
            var pt: c.POINT = .{ .x = util.loword(lparam), .y = util.hiword(lparam) };
            const hit = self.hitTest(pt.x, pt.y);
            _ = c.ClientToScreen(hwnd, &pt);
            self.setHover(null);
            if (hit) |h| switch (h) {
                .tab, .close => |i| {
                    const tab = self.window.tabs.items[i];
                    Menu.track(&Menu.tab, tab.focused, self.window.hwnd, pt, 0);
                    return 0;
                },
                else => {},
            };
            Menu.track(&Menu.main, self.window.activeSurface(), self.window.hwnd, pt, 0);
            return 0;
        },

        c.WM_MBUTTONUP => {
            const hit = self.hitTest(util.loword(lparam), util.hiword(lparam)) orelse return 0;
            switch (hit) {
                .tab, .close => |i| self.window.closeTabAt(i),
                .new_tab, .shell_menu, .minimize, .maximize, .close_window => {},
            }
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
