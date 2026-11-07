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
}

/// Redraw the tab bar, e.g. after tabs or titles changed.
pub fn invalidate(self: *TabBar) void {
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// The height of the tab bar for our current font and DPI.
pub fn height(self: *const TabBar) c_int {
    return self.scale(32);
}

/// Scale a size in DPI-independent pixels to physical pixels.
fn scale(self: *const TabBar, v: c_int) c_int {
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.window.hwnd));
    return @divTrunc(v * dpi, util.USER_DEFAULT_SCREEN_DPI);
}

/// Set our font to the system UI font for our DPI, or the family of
/// `window-title-font-family` at the system UI font's size.
pub fn updateFont(self: *TabBar) void {
    const dpi = c.GetDpiForWindow(self.window.hwnd);
    var metrics: c.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (c.SystemParametersInfoForDpi(
        c.SPI_GETNONCLIENTMETRICS,
        metrics.cbSize,
        &metrics,
        0,
        dpi,
    ) == 0) return;

    if (self.window.app.config.@"window-title-font-family") |family| {
        const face = &metrics.lfMessageFont.lfFaceName;
        // The face name is a fixed buffer; too long a name can't name a
        // font, so we keep the system font then.
        const len = std.unicode.calcUtf16LeLen(family) catch 0;
        if (len > 0 and len < face.len) {
            const n = std.unicode.utf8ToUtf16Le(face, family) catch 0;
            face[n] = 0;
        }
    }

    const font = c.CreateFontIndirectW(&metrics.lfMessageFont) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;
    self.invalidate();
}

//----------------------------------------------------------------------------
// Layout

const Layout = struct {
    /// The width of each tab.
    tab_width: c_int,

    /// The rectangle of the new tab button.
    new_tab: c.RECT,
    shell_menu: c.RECT,

    /// The caption buttons, with the tabs in the title bar.
    caption: ?struct { minimize: c.RECT, maximize: c.RECT, close: c.RECT },

    fn tabRect(self: Layout, idx: usize, h: c_int) c.RECT {
        const left = @as(c_int, @intCast(idx)) * self.tab_width;
        return .{ .left = left, .top = 0, .right = left + self.tab_width, .bottom = h };
    }
};

fn layout(self: *const TabBar) Layout {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const h = client.bottom;
    const n: c_int = @intCast(@max(1, self.window.tabs.items.len));

    // With the tabs in the title bar, the caption buttons (46 by 32, as
    // Windows 11 draws them) go at the right, after some empty space that
    // drags the window, even when there are many tabs.
    const caption_button = self.scale(46);
    const caption_width = if (self.window.hasTitleBarTabs()) caption_button * 3 + self.scale(48) else 0;

    // Tabs share the width (less the buttons) up to a maximum.
    const button = h;
    const available = @max(0, client.right - button * 2 - caption_width);
    const tab_width = @min(self.scale(240), @divTrunc(available, n));

    const new_left = tab_width * n;
    return .{
        .tab_width = tab_width,
        .new_tab = .{ .left = new_left, .top = 0, .right = new_left + button, .bottom = h },
        .shell_menu = .{ .left = new_left + button, .top = 0, .right = new_left + button * 2, .bottom = h },
        .caption = if (caption_width == 0) null else .{
            .minimize = .{ .left = client.right - caption_button * 3, .top = 0, .right = client.right - caption_button * 2, .bottom = h },
            .maximize = .{ .left = client.right - caption_button * 2, .top = 0, .right = client.right - caption_button, .bottom = h },
            .close = .{ .left = client.right - caption_button, .top = 0, .right = client.right, .bottom = h },
        },
    };
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

/// The rectangle of the close button of a tab.
/// The rectangle of the tab at an index, on the screen.
pub fn tabScreenRect(self: *const TabBar, idx: usize) c.RECT {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const rect = self.layout().tabRect(idx, client.bottom);
    var top_left: c.POINT = .{ .x = rect.left, .y = rect.top };
    var bottom_right: c.POINT = .{ .x = rect.right, .y = rect.bottom };
    _ = c.ClientToScreen(self.hwnd, &top_left);
    _ = c.ClientToScreen(self.hwnd, &bottom_right);
    return .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y };
}

/// The element at a point on the screen, if any.
pub fn hitAtScreen(self: *const TabBar, pt: c.POINT) ?Hit {
    var client_pt = pt;
    _ = c.ScreenToClient(self.hwnd, &client_pt);
    return self.hitTest(client_pt.x, client_pt.y);
}

/// The buttons at the end of the tab bar.
pub const Button = enum { new_tab, shell_menu };

/// The rectangle of a button, on the screen.
pub fn buttonScreenRect(self: *const TabBar, button: Button) c.RECT {
    const l = self.layout();
    const rect = switch (button) {
        .new_tab => l.new_tab,
        .shell_menu => l.shell_menu,
    };
    var top_left: c.POINT = .{ .x = rect.left, .y = rect.top };
    var bottom_right: c.POINT = .{ .x = rect.right, .y = rect.bottom };
    _ = c.ClientToScreen(self.hwnd, &top_left);
    _ = c.ClientToScreen(self.hwnd, &bottom_right);
    return .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y };
}

/// A button's name, as in its tooltip.
pub fn buttonName(self: *TabBar, button: Button) []const u8 {
    return self.tooltipText(switch (button) {
        .new_tab => .new_tab,
        .shell_menu => .shell_menu,
    });
}

/// Press a button, as if clicked, for UI Automation. It happens later,
/// from a posted message, since the menus run a modal loop and Invoke
/// should return right away.
pub fn pressButton(self: *TabBar, button: Button) void {
    _ = c.PostMessageW(self.hwnd, WM_GHOSTTY_PRESS_BUTTON, @backingInt(button), 0);
}

const WM_GHOSTTY_PRESS_BUTTON = c.WM_APP + 1;

/// Called when a tab is selected, to tell screen readers.
pub fn tabSelected(self: *TabBar, tab: *Tab) void {
    if (self.accessibility) |a| a.tabSelected(tab);
}

fn closeRect(self: *const TabBar, tab: c.RECT) c.RECT {
    const size = self.scale(16);
    const margin = self.scale(8);
    const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
    return .{
        .left = tab.right - margin - size,
        .top = top,
        .right = tab.right - margin,
        .bottom = top + size,
    };
}

fn hitTest(self: *const TabBar, x: c_int, y: c_int) ?Hit {
    const l = self.layout();
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const pt: c.POINT = .{ .x = x, .y = y };

    if (l.caption) |caption| {
        if (c.PtInRect(&caption.minimize, pt) != 0) return .minimize;
        if (c.PtInRect(&caption.maximize, pt) != 0) return .maximize;
        if (c.PtInRect(&caption.close, pt) != 0) return .close_window;
    }
    if (c.PtInRect(&l.new_tab, pt) != 0) return .new_tab;
    if (c.PtInRect(&l.shell_menu, pt) != 0) return .shell_menu;
    for (0..self.window.tabs.items.len) |i| {
        const rect = l.tabRect(i, client.bottom);
        if (c.PtInRect(&rect, pt) == 0) continue;
        const close = self.closeRect(rect);
        if (c.PtInRect(&close, pt) != 0) return .{ .close = i };
        return .{ .tab = i };
    }
    return null;
}

//----------------------------------------------------------------------------
// Painting

const Rgb = struct { r: u8, g: u8, b: u8 };

const Colors = struct {
    bar: Rgb,
    active: Rgb,
    hover: Rgb,
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
    const bar = blend(bg, black, 0.25);
    return .{
        .bar = bar,
        .active = bg,
        .hover = blend(bar, fg, 0.08),
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
    for (window.tabs.items, 0..) |tab, i| {
        const rect = l.tabRect(i, client.bottom);
        const active = i == window.active;
        const hovered = Hit.eql(self.hover, .{ .tab = i }) or Hit.eql(self.hover, .{ .close = i });

        if (active) {
            fill(hdc, &rect, col.active);
        } else if (hovered) {
            fill(hdc, &rect, col.hover);
        }

        // Separators between inactive tabs.
        if (!active and i + 1 != window.active and i + 1 < window.tabs.items.len) {
            const sep: c.RECT = .{
                .left = rect.right - 1,
                .top = rect.top + self.scale(8),
                .right = rect.right,
                .bottom = rect.bottom - self.scale(8),
            };
            fill(hdc, &sep, col.separator);
        }

        // Title
        const close = self.closeRect(rect);
        var text_rect: c.RECT = .{
            .left = rect.left + self.scale(12),
            .top = rect.top,
            .right = close.left - self.scale(4),
            .bottom = rect.bottom,
        };
        const title = tab.title();
        const title8 = if (tab.hasBell())
            std.fmt.allocPrint(alloc, "🔔 {s}", .{title}) catch continue
        else
            alloc.dupe(u8, title) catch continue;
        defer alloc.free(title8);
        const title16 = util.utf16Alloc(alloc, title8) catch continue;
        defer alloc.free(title16);
        _ = c.SetTextColor(hdc, colorref(if (active) col.text else col.text_inactive));
        _ = c.DrawTextW(
            hdc,
            title16.ptr,
            @intCast(title16.len),
            &text_rect,
            c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );

        // Close button, shown on the active and hovered tabs.
        if (active or hovered) {
            if (Hit.eql(self.hover, .{ .close = i })) {
                fill(hdc, &close, blend(if (active) col.active else col.hover, col.text, 0.15));
            }
            self.drawCross(hdc, close, if (active) col.text else col.text_inactive);
        }
    }

    // New tab button
    if (Hit.eql(self.hover, .new_tab)) fill(hdc, &l.new_tab, col.hover);
    self.drawPlus(hdc, l.new_tab, col.text_inactive);
    if (Hit.eql(self.hover, .shell_menu)) fill(hdc, &l.shell_menu, col.hover);
    self.drawChevron(hdc, l.shell_menu, col.text_inactive);

    if (l.caption) |caption| self.paintCaptionButtons(hdc, caption.minimize, caption.maximize, caption.close, col);
}

/// The minimize, maximize (or restore) and close buttons, like the system's:
/// hovering fills them, the close button in red; dimmer when the window
/// isn't active.
fn paintCaptionButtons(self: *const TabBar, hdc: c.HDC, minimize: c.RECT, maximize: c.RECT, close: c.RECT, col: Colors) void {
    const active = c.GetForegroundWindow() == self.window.hwnd;
    const glyph = if (active) col.text else col.text_inactive;
    if (Hit.eql(self.hover, .minimize)) fill(hdc, &minimize, col.hover);
    if (self.maximize_hovered) fill(hdc, &maximize, col.hover);
    const close_hovered = Hit.eql(self.hover, .close_window);
    if (close_hovered) fill(hdc, &close, .{ .r = 0xC4, .g = 0x2B, .b = 0x1C });

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
    const width = self.layout().tab_width;
    if (width <= 0) return;
    const to: usize = @min(
        @as(usize, @intCast(@divTrunc(@max(0, x), width))),
        self.window.tabs.items.len - 1,
    );
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

        WM_GHOSTTY_PRESS_BUTTON => {
            switch (std.enums.fromInt(Button, wparam) orelse return 0) {
                .new_tab => _ = self.window.newTab(),
                .shell_menu => self.showShellMenu(),
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
                const n = std.unicode.utf8ToUtf16Le(self.tooltip_text[0 .. self.tooltip_text.len - 1], text) catch 0;
                self.tooltip_text[n] = 0;
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

        // We set CS_DBLCLKS for double clicks on empty space. A quick
        // second click on anything else is just another click.
        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK => {
            const hit = self.hitTest(util.loword(lparam), util.hiword(lparam)) orelse {
                if (msg == c.WM_LBUTTONDBLCLK) _ = self.window.newTab();
                return 0;
            };
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
