//! The search box for a surface: an edit field with the match count and
//! previous, next, and close buttons, in the surface's top right corner.
//!
//! It's a layered child window like our other overlays, since the surface's
//! flip model swap chain covers regular child windows. Being a child, it
//! takes keyboard focus without deactivating the top-level window. Its
//! windows are made the first time it shows, since most surfaces are never
//! searched (it took about 3 ms of each new tab).
const SearchBar = @This();

const std = @import("std");
const Config = @import("../../config.zig").Config;

const util = @import("util.zig");
const i18n = @import("../../os/main.zig").i18n;
const c = util.c;

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchBar");

/// What the user asked for, handled by the surface.
pub const Event = union(enum) {
    changed: []const u8,
    next,
    previous,
    close,
};

const Button = enum { previous, next, close };

/// Sizes at 96 DPI.
const width = 340;
const height = 36;
const pad = 6;
const button = 24;
const count_width = 56;

/// The longest search text, in UTF-16 units.
const max_needle = 1023;

hwnd: c.HWND = null,
edit: c.HWND = null,
parent: c.HWND = null,
instance: c.HINSTANCE = null,
font: util.MessageFont = .{},
/// The buttons' glyph font, and the DPI it's for.
icon_font: c.HFONT = null,
icon_dpi: c.UINT = 0,
edit_brush: c.HBRUSH = null,
edit_proc: c.WNDPROC = null,

on_event: ?*const fn (ctx: *anyopaque, event: Event) void = null,
ctx: *anyopaque = undefined,

background: c.COLORREF = 0,
field: c.COLORREF = 0,
foreground: c.COLORREF = 0xFFFFFF,

/// The match count shown, such as "3/10".
count: [32]u16 = undefined,
count_len: usize = 0,

/// The button under the mouse, if any.
hot: ?Button = null,

/// True while we set the edit text ourselves, so we don't report it.
setting_text: bool = false,

pub fn init(
    self: *SearchBar,
    parent: c.HWND,
    instance: c.HINSTANCE,
    config: *const Config,
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, event: Event) void,
) void {
    self.parent = parent;
    self.instance = instance;
    self.ctx = ctx;
    self.on_event = on_event;
    self.setCount(null, null);
    self.updateConfig(config);
}

fn createWindows(self: *SearchBar) !void {
    if (self.hwnd != null) return;
    // Mirrored for a right-to-left language; the controls inside
    // inherit it.
    const hwnd = c.CreateWindowExW(
        @as(c.DWORD, c.WS_EX_LAYERED | c.WS_EX_CONTROLPARENT) |
            (if (i18n.rightToLeft()) @as(c.DWORD, c.WS_EX_LAYOUTRTL) else 0),
        class_name,
        null,
        c.WS_CHILD | c.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        self.parent,
        null,
        self.instance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(hwnd);
    if (c.SetLayeredWindowAttributes(hwnd, 0, 255, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }

    const edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        self.instance,
        null,
    ) orelse return error.CreateWindowFailed;
    _ = c.SendMessageW(edit, c.EM_SETLIMITTEXT, max_needle, 0);
    _ = c.SendMessageW(edit, c.EM_SETCUEBANNER, c.TRUE, @bitCast(@intFromPtr(
        std.unicode.utf8ToUtf16LeStringLiteral("Find").ptr,
    )));

    // Subclass the edit control for Enter and Escape.
    _ = c.SetWindowLongPtrW(edit, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.edit_proc = @ptrFromInt(@as(usize, @bitCast(c.SetWindowLongPtrW(
        edit,
        c.GWLP_WNDPROC,
        @bitCast(@intFromPtr(&editProc)),
    ))));

    self.hwnd = hwnd;
    self.edit = edit;
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

pub fn deinit(self: *SearchBar) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        if (self.edit != null) util.unsubclass(self.edit, self.edit_proc);
        _ = c.DestroyWindow(self.hwnd);
    }
    self.font.deinit();
    if (self.icon_font != null) _ = c.DeleteObject(self.icon_font);
    if (self.edit_brush != null) _ = c.DeleteObject(self.edit_brush);
    self.* = .{};
}

pub fn updateConfig(self: *SearchBar, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;
    self.background = util.blend(bg, fg, 0.08);
    self.field = util.blend(bg, fg, 0.16);
    self.foreground = util.rgb(fg.r, fg.g, fg.b);
    if (self.edit_brush != null) _ = c.DeleteObject(self.edit_brush);
    self.edit_brush = c.CreateSolidBrush(self.field);
    if (self.hwnd != null) _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

pub fn visible(self: *const SearchBar) bool {
    if (self.hwnd == null) return false;
    return c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE) & c.WS_VISIBLE != 0;
}

/// Show and focus the search box. A non-empty needle replaces the text,
/// cut to what the box holds.
pub fn show(self: *SearchBar, needle: []const u8) void {
    self.createWindows() catch |err| {
        log.warn("unable to create the search bar err={}", .{err});
        return;
    };
    if (needle.len > 0) {
        var buf: [max_needle + 1]u16 = undefined;
        self.setting_text = true;
        _ = c.SetWindowTextW(self.edit, util.utf16TruncateZ(&buf, needle));
        self.setting_text = false;
    }
    self.layout();
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    _ = c.SetFocus(self.edit);
    _ = c.SendMessageW(self.edit, c.EM_SETSEL, 0, -1);
}

pub fn hide(self: *SearchBar) void {
    if (self.hwnd != null) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    self.setCount(null, null);
}

/// Update the match count, like GTK: "selected/total" counting from one.
pub fn setCount(self: *SearchBar, selected: ?usize, total: ?usize) void {
    var buf: [32]u8 = undefined;
    const text = if (total) |t|
        std.fmt.bufPrint(&buf, "{d}/{d}", .{ if (selected) |s| s + 1 else 0, t }) catch ""
    else
        "";
    self.count_len = std.unicode.utf8ToUtf16Le(&self.count, text) catch 0;
    if (self.hwnd == null) return;
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);

    // The count is only drawn, so also make it the window's text, which
    // screen readers (and tests, through UI Automation) see as its name.
    var name_buf: [64]u8 = undefined;
    const name = if (total) |t| (if (t == 0)
        "No matches"
    else if (selected) |s|
        std.fmt.bufPrint(&name_buf, "Match {d} of {d}", .{ s + 1, t }) catch ""
    else
        std.fmt.bufPrint(&name_buf, "{d} matches", .{t}) catch "") else "Search";
    var name_w: [64:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&name_w, name) catch 0;
    name_w[n] = 0;
    _ = c.SetWindowTextW(self.hwnd, &name_w);
}

/// Called when the parent surface is resized.
pub fn parentResized(self: *SearchBar) void {
    if (self.visible()) self.layout();
}

fn scale(self: *const SearchBar, v: c_int) c_int {
    return util.scale(v, @intCast(c.GetDpiForWindow(self.hwnd)));
}

fn layout(self: *SearchBar) void {
    var parent: c.RECT = undefined;
    _ = c.GetClientRect(c.GetParent(self.hwnd), &parent);
    const w = @min(self.scale(width), parent.right);
    const h = self.scale(height);
    _ = c.SetWindowPos(
        self.hwnd,
        c.HWND_TOP,
        // In the top corner where a line ends: the left one for a
        // right-to-left language.
        if (i18n.rightToLeft()) self.scale(8) else parent.right - w - self.scale(8),
        self.scale(8),
        w,
        h,
        c.SWP_NOACTIVATE,
    );

    self.updateFont();
    const p = self.scale(pad);
    const edit_right = w - 3 * self.scale(button) - self.scale(count_width) - 2 * p;
    _ = c.MoveWindow(self.edit, p + self.scale(4), p + self.scale(3), edit_right - p - self.scale(4), h - 2 * p - self.scale(6), c.TRUE);
    _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

fn updateFont(self: *SearchBar) void {
    const change = self.font.update(c.GetDpiForWindow(self.hwnd), 100) orelse return;
    // The edit control lets go of the old font before it's deleted.
    _ = c.SendMessageW(self.edit, c.WM_SETFONT, @intFromPtr(self.font.font), c.TRUE);
    if (change.old != null) _ = c.DeleteObject(change.old);
}

/// The rectangle of a button.
fn buttonRect(self: *const SearchBar, b: Button) c.RECT {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &rect);
    const size = self.scale(button);
    const p = self.scale(pad);
    const index: c_int = switch (b) {
        .previous => 2,
        .next => 1,
        .close => 0,
    };
    const right = rect.right - p - index * size;
    const top = @divTrunc(rect.bottom - size, 2);
    return .{ .left = right - size, .top = top, .right = right, .bottom = top + size };
}

fn buttonAt(self: *const SearchBar, x: c_int, y: c_int) ?Button {
    inline for (.{ Button.previous, Button.next, Button.close }) |b| {
        const r = self.buttonRect(b);
        if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return b;
    }
    return null;
}

fn emit(self: *SearchBar, event: Event) void {
    const on_event = self.on_event orelse return;
    on_event(self.ctx, event);
}

fn editChanged(self: *SearchBar) void {
    if (self.setting_text) return;
    var buf: [max_needle + 1]u16 = undefined;
    const len: usize = @intCast(@max(0, c.GetWindowTextW(self.edit, &buf, buf.len)));
    var utf8: [3 * buf.len]u8 = undefined;
    const n = std.unicode.wtf16LeToWtf8(&utf8, buf[0..len]);
    self.emit(.{ .changed = utf8[0..n] });
}

/// The colors to draw with: the terminal's, or with a high contrast
/// theme on, the theme's (the field is framed, and hovered buttons are
/// highlighted).
const Colors = struct {
    background: c.COLORREF,
    field: c.COLORREF,
    field_brush: c.HBRUSH,
    foreground: c.COLORREF,
    hot: c.COLORREF,
    hot_text: c.COLORREF,
    frame: bool,
};

fn colors(self: *const SearchBar) Colors {
    if (util.highContrast()) return .{
        .background = c.GetSysColor(c.COLOR_WINDOW),
        .field = c.GetSysColor(c.COLOR_WINDOW),
        .field_brush = c.GetSysColorBrush(c.COLOR_WINDOW),
        .foreground = c.GetSysColor(c.COLOR_WINDOWTEXT),
        .hot = c.GetSysColor(c.COLOR_HIGHLIGHT),
        .hot_text = c.GetSysColor(c.COLOR_HIGHLIGHTTEXT),
        .frame = true,
    };
    return .{
        .background = self.background,
        .field = self.field,
        .field_brush = self.edit_brush,
        .foreground = self.foreground,
        .hot = self.field,
        .hot_text = self.foreground,
        .frame = false,
    };
}

fn paint(self: *SearchBar, dc: c.HDC) void {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &rect);
    const col = self.colors();

    const background = c.CreateSolidBrush(col.background);
    defer _ = c.DeleteObject(background);
    _ = c.FillRect(dc, &rect, background);

    // The field behind the edit control, slightly larger than it.
    var edit_rect: c.RECT = undefined;
    _ = c.GetWindowRect(self.edit, &edit_rect);
    _ = c.MapWindowPoints(null, self.hwnd, @ptrCast(&edit_rect), 2);
    _ = c.InflateRect(&edit_rect, self.scale(4), self.scale(3));
    _ = c.FillRect(dc, &edit_rect, col.field_brush);
    if (col.frame) _ = c.FrameRect(dc, &edit_rect, c.GetSysColorBrush(c.COLOR_WINDOWTEXT));

    const old_font = c.SelectObject(dc, self.font.font);
    defer _ = c.SelectObject(dc, old_font);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, col.foreground);

    // The match count, left of the buttons.
    var count_rect = self.buttonRect(.previous);
    count_rect.right = count_rect.left;
    count_rect.left -= self.scale(count_width);
    _ = c.DrawTextW(
        dc,
        &self.count,
        @intCast(self.count_len),
        &count_rect,
        c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX,
    );

    // Buttons, drawn with Segoe Fluent Icons (Windows 11) or Segoe MDL2
    // Assets (Windows 10) glyphs.
    // A font still selected into a DC can't be deleted (DeleteObject
    // fails and it leaks), so the previous one goes back in after.
    const icon_font = self.iconFont();
    const before_icons = if (icon_font != null) c.SelectObject(dc, icon_font) else null;
    defer if (icon_font != null) {
        _ = c.SelectObject(dc, before_icons);
    };
    inline for (.{
        .{ Button.previous, 0xE70E },
        .{ Button.next, 0xE70D },
        .{ Button.close, 0xE711 },
    }) |entry| {
        var r = self.buttonRect(entry[0]);
        if (self.hot == entry[0]) {
            const hot = c.CreateSolidBrush(col.hot);
            defer _ = c.DeleteObject(hot);
            _ = c.FillRect(dc, &r, hot);
        }
        _ = c.SetTextColor(dc, if (self.hot == entry[0]) col.hot_text else col.foreground);
        var glyph = [_]u16{entry[1]};
        _ = c.DrawTextW(dc, &glyph, 1, &r, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX);
    }
}

/// The buttons' glyph font at our DPI, made when the DPI changes.
fn iconFont(self: *SearchBar) c.HFONT {
    const dpi = c.GetDpiForWindow(self.hwnd);
    if (dpi != self.icon_dpi) {
        if (self.icon_font != null) _ = c.DeleteObject(self.icon_font);
        self.icon_font = util.iconFont(10, @intCast(dpi)) orelse null;
        self.icon_dpi = dpi;
    }
    return self.icon_font;
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SearchBar = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);
            self.paint(dc);
            return 0;
        },

        c.WM_CTLCOLOREDIT => {
            const dc = util.handle(c.HDC, wparam);
            const col = self.colors();
            _ = c.SetTextColor(dc, col.foreground);
            _ = c.SetBkColor(dc, col.field);
            return @bitCast(@intFromPtr(col.field_brush));
        },

        c.WM_COMMAND => {
            if (util.handle(c.HWND, lparam) == self.edit and
                (wparam >> 16) & 0xFFFF == c.EN_CHANGE)
            {
                self.editChanged();
                return 0;
            }
        },

        c.WM_MOUSEMOVE => {
            const hot = self.buttonAt(util.loword(lparam), util.hiword(lparam));
            if (hot != self.hot) {
                self.hot = hot;
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                var track: c.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                    .dwFlags = c.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = c.TrackMouseEvent(&track);
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.hot = null;
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            if (self.buttonAt(util.loword(lparam), util.hiword(lparam))) |b| {
                self.emit(switch (b) {
                    .previous => .previous,
                    .next => .next,
                    .close => .close,
                });
            } else {
                _ = c.SetFocus(self.edit);
            }
            return 0;
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn editProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SearchBar = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_KEYDOWN => switch (wparam) {
            c.VK_RETURN => {
                self.emit(if (c.GetKeyState(c.VK_SHIFT) < 0) .previous else .next);
                return 0;
            },
            c.VK_ESCAPE => {
                self.emit(.close);
                return 0;
            },
            else => {},
        },

        // Don't beep for the characters of the keys we handle.
        c.WM_CHAR => switch (wparam) {
            '\r', 0x1b => return 0,
            else => {},
        },

        else => {},
    }
    return c.CallWindowProcW(self.edit_proc, hwnd, msg, wparam, lparam);
}
