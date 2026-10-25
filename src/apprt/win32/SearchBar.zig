//! The search box for a surface: an edit field with the match count and
//! previous, next, and close buttons, in the surface's top right corner.
//!
//! It's a layered child window like our other overlays, since the surface's
//! flip model swap chain covers regular child windows. Being a child, it
//! takes keyboard focus without deactivating the top-level window.
const SearchBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../../config.zig").Config;

const util = @import("util.zig");
const c = util.c;

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

hwnd: c.HWND = null,
edit: c.HWND = null,
font: c.HFONT = null,
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
) !void {
    self.hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_CONTROLPARENT,
        class_name,
        null,
        c.WS_CHILD | c.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(self.hwnd);
    if (c.SetLayeredWindowAttributes(self.hwnd, 0, 255, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }

    self.edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        self.hwnd,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    _ = c.SendMessageW(self.edit, c.EM_SETCUEBANNER, c.TRUE, @bitCast(@intFromPtr(
        std.unicode.utf8ToUtf16LeStringLiteral("Find").ptr,
    )));

    // Subclass the edit control for Enter and Escape.
    _ = c.SetWindowLongPtrW(self.edit, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.edit_proc = @ptrFromInt(@as(usize, @bitCast(c.SetWindowLongPtrW(
        self.edit,
        c.GWLP_WNDPROC,
        @bitCast(@intFromPtr(&editProc)),
    ))));

    self.ctx = ctx;
    self.on_event = on_event;
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.setCount(null, null);
    self.updateConfig(config);
}

pub fn deinit(self: *SearchBar) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        if (self.edit != null) _ = c.SetWindowLongPtrW(self.edit, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    if (self.font != null) _ = c.DeleteObject(self.font);
    if (self.edit_brush != null) _ = c.DeleteObject(self.edit_brush);
    self.* = .{};
}

pub fn updateConfig(self: *SearchBar, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;
    self.background = rgb(mix(bg.r, fg.r, 0.08), mix(bg.g, fg.g, 0.08), mix(bg.b, fg.b, 0.08));
    self.field = rgb(mix(bg.r, fg.r, 0.16), mix(bg.g, fg.g, 0.16), mix(bg.b, fg.b, 0.16));
    self.foreground = rgb(fg.r, fg.g, fg.b);
    if (self.edit_brush != null) _ = c.DeleteObject(self.edit_brush);
    self.edit_brush = c.CreateSolidBrush(self.field);
    _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

pub fn visible(self: *const SearchBar) bool {
    return c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE) & c.WS_VISIBLE != 0;
}

/// Show and focus the search box. A non-empty needle replaces the text.
pub fn show(self: *SearchBar, alloc: Allocator, needle: []const u8) void {
    if (needle.len > 0) {
        if (util.utf16Alloc(alloc, needle)) |text| {
            defer alloc.free(text);
            self.setting_text = true;
            _ = c.SetWindowTextW(self.edit, text);
            self.setting_text = false;
        } else |_| {}
    }
    self.layout();
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    _ = c.SetFocus(self.edit);
    _ = c.SendMessageW(self.edit, c.EM_SETSEL, 0, -1);
}

pub fn hide(self: *SearchBar) void {
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
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
    if (self.hwnd != null) _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// Called when the parent surface is resized.
pub fn parentResized(self: *SearchBar) void {
    if (self.visible()) self.layout();
}

fn scale(self: *const SearchBar, v: c_int) c_int {
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
    return @divTrunc(v * dpi, util.USER_DEFAULT_SCREEN_DPI);
}

fn layout(self: *SearchBar) void {
    var parent: c.RECT = undefined;
    _ = c.GetClientRect(c.GetParent(self.hwnd), &parent);
    const w = @min(self.scale(width), parent.right);
    const h = self.scale(height);
    _ = c.SetWindowPos(
        self.hwnd,
        c.HWND_TOP,
        parent.right - w - self.scale(8),
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
    if (self.font != null) _ = c.DeleteObject(self.font);
    self.font = null;
    var metrics: c.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (c.SystemParametersInfoForDpi(
        c.SPI_GETNONCLIENTMETRICS,
        metrics.cbSize,
        &metrics,
        0,
        c.GetDpiForWindow(self.hwnd),
    ) == 0) return;
    self.font = c.CreateFontIndirectW(&metrics.lfMessageFont);
    _ = c.SendMessageW(self.edit, c.WM_SETFONT, @intFromPtr(self.font), c.TRUE);
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
    var buf: [1024]u16 = undefined;
    const len: usize = @intCast(@max(0, c.GetWindowTextW(self.edit, &buf, buf.len)));
    var utf8: [3 * buf.len]u8 = undefined;
    const n = std.unicode.wtf16LeToWtf8(&utf8, buf[0..len]);
    self.emit(.{ .changed = utf8[0..n] });
}

fn paint(self: *SearchBar, dc: c.HDC) void {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &rect);

    const background = c.CreateSolidBrush(self.background);
    defer _ = c.DeleteObject(background);
    _ = c.FillRect(dc, &rect, background);

    // The field behind the edit control, slightly larger than it.
    var edit_rect: c.RECT = undefined;
    _ = c.GetWindowRect(self.edit, &edit_rect);
    _ = c.MapWindowPoints(null, self.hwnd, @ptrCast(&edit_rect), 2);
    _ = c.InflateRect(&edit_rect, self.scale(4), self.scale(3));
    _ = c.FillRect(dc, &edit_rect, self.edit_brush);

    const old_font = c.SelectObject(dc, self.font);
    defer _ = c.SelectObject(dc, old_font);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, self.foreground);

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
    const icon_font = self.iconFont();
    defer if (icon_font != null) {
        _ = c.DeleteObject(icon_font);
    };
    if (icon_font != null) _ = c.SelectObject(dc, icon_font);
    inline for (.{
        .{ Button.previous, 0xE70E },
        .{ Button.next, 0xE70D },
        .{ Button.close, 0xE711 },
    }) |entry| {
        var r = self.buttonRect(entry[0]);
        if (self.hot == entry[0]) {
            const hot = c.CreateSolidBrush(self.field);
            defer _ = c.DeleteObject(hot);
            _ = c.FillRect(dc, &r, hot);
        }
        var glyph = [_]u16{entry[1]};
        _ = c.DrawTextW(dc, &glyph, 1, &r, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX);
    }
}

fn iconFont(self: *const SearchBar) c.HFONT {
    var lf = std.mem.zeroes(c.LOGFONTW);
    lf.lfHeight = -self.scale(10);
    lf.lfCharSet = c.DEFAULT_CHARSET;
    const names = [_][]const u8{ "Segoe Fluent Icons", "Segoe MDL2 Assets" };
    for (names) |name| {
        const n = std.unicode.utf8ToUtf16Le(lf.lfFaceName[0 .. lf.lfFaceName.len - 1], name) catch continue;
        lf.lfFaceName[n] = 0;
        if (fontExists(&lf)) return c.CreateFontIndirectW(&lf);
    }
    return null;
}

fn fontExists(lf: *const c.LOGFONTW) bool {
    const dc = c.GetDC(null);
    defer _ = c.ReleaseDC(null, dc);
    var found = false;
    _ = c.EnumFontFamiliesExW(dc, @constCast(lf), fontFound, @bitCast(@intFromPtr(&found)), 0);
    return found;
}

fn fontFound(
    _: [*c]const c.LOGFONTW,
    _: [*c]const c.TEXTMETRICW,
    _: c.DWORD,
    lparam: c.LPARAM,
) callconv(.c) c_int {
    const found: *bool = @ptrFromInt(@as(usize, @bitCast(lparam)));
    found.* = true;
    return 0;
}

fn rgb(r: u8, g: u8, b: u8) c.COLORREF {
    return @as(c.COLORREF, r) | (@as(c.COLORREF, g) << 8) | (@as(c.COLORREF, b) << 16);
}

fn mix(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
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
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, self.foreground);
            _ = c.SetBkColor(dc, self.field);
            return @bitCast(@intFromPtr(self.edit_brush));
        },

        c.WM_COMMAND => {
            if (@as(c.HWND, @ptrFromInt(@as(usize, @bitCast(lparam)))) == self.edit and
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
