//! A click-through layered child window that draws a border around a
//! surface while its bell is ringing, for the `border` bell feature.
//! Like GTK, this uses the system accent color at half opacity. A high
//! contrast theme gets its highlight color, solid.
const BellBorder = @This();

const std = @import("std");
const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyBellBorder");

/// The border width in pixels at 96 DPI.
const width = 3;

/// The color drawn inside the border, which the layered window makes
/// fully transparent. It must differ from any accent color we draw.
const transparent_key: c.COLORREF = 0x00FF00FF;

hwnd: c.HWND = null,
parent: c.HWND = null,
instance: c.HINSTANCE = null,
/// The overlays this goes above, in order; see `util.placeAbove`.
above: [2]*const c.HWND = undefined,
visible: bool = false,
surface_width: c_int = 0,
surface_height: c_int = 0,

/// The window is made the first time the border shows.
pub fn init(self: *BellBorder, parent: c.HWND, instance: c.HINSTANCE, above: [2]*const c.HWND) void {
    self.parent = parent;
    self.instance = instance;
    self.above = above;
}

fn createWindow(self: *BellBorder) !void {
    const hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE,
        class_name,
        null,
        c.WS_CHILD,
        0,
        0,
        0,
        0,
        self.parent,
        null,
        self.instance,
        null,
    ) orelse return error.CreateWindowFailed;
    util.placeAbove(hwnd, &self.above);
    self.hwnd = hwnd;
}

pub fn deinit(self: *BellBorder) void {
    if (self.hwnd != null) _ = c.DestroyWindow(self.hwnd);
    self.* = .{};
}

/// Like the dim overlay, a hidden border only takes the new size when
/// it's shown, since resizing a layered window's bitmap is slow.
pub fn resize(self: *BellBorder, w: c_int, h: c_int) void {
    self.surface_width = w;
    self.surface_height = h;
    if (self.visible) _ = c.MoveWindow(self.hwnd, 0, 0, w, h, c.TRUE);
}

pub fn setVisible(self: *BellBorder, visible: bool) void {
    if (visible == self.visible) return;
    if (self.hwnd == null) self.createWindow() catch |err| {
        log.warn("unable to create the bell border err={}", .{err});
        return;
    };
    self.visible = visible;
    if (visible) {
        _ = c.SetLayeredWindowAttributes(
            self.hwnd,
            transparent_key,
            if (util.highContrast()) 255 else 128,
            c.LWA_COLORKEY | c.LWA_ALPHA,
        );
        _ = c.MoveWindow(self.hwnd, 0, 0, self.surface_width, self.surface_height, c.FALSE);
        _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    }
    _ = c.ShowWindow(self.hwnd, if (visible) c.SW_SHOWNA else c.SW_HIDE);
}

/// A color to draw, changed slightly if it's our transparent color key
/// so it doesn't vanish.
fn avoidKey(color: c.COLORREF) c.COLORREF {
    return if (color == transparent_key) util.rgb(0xFE, 0, 0xFF) else color;
}

/// The part of a client rectangle inside the border, which is drawn in
/// the transparent color key, or null if the border fills it.
fn hole(rect: c.RECT, dpi: c_int) ?c.RECT {
    const border: c_int = @max(1, util.scale(width, dpi));
    const inner: c.RECT = .{
        .left = rect.left + border,
        .top = rect.top + border,
        .right = rect.right - border,
        .bottom = rect.bottom - border,
    };
    if (inner.right <= inner.left or inner.bottom <= inner.top) return null;
    return inner;
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_NCHITTEST => return c.HTTRANSPARENT,
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);

            var rect: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &rect);
            const dpi: c_int = @intCast(c.GetDpiForWindow(hwnd));

            const accent = c.CreateSolidBrush(avoidKey(util.accentColor()));
            defer _ = c.DeleteObject(accent);
            const key = c.CreateSolidBrush(transparent_key);
            defer _ = c.DeleteObject(key);

            _ = c.FillRect(dc, &rect, accent);
            if (hole(rect, dpi)) |inner| _ = c.FillRect(dc, &inner, key);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test avoidKey {
    const testing = std.testing;
    try testing.expectEqual(util.rgb(0, 120, 215), avoidKey(util.rgb(0, 120, 215)));
    try testing.expect(avoidKey(transparent_key) != transparent_key);
}

test hole {
    const testing = std.testing;
    const rect: c.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    // 3 pixels at 96 DPI, 6 at 192, and at least 1 however small the DPI.
    try testing.expectEqual(c.RECT{ .left = 3, .top = 3, .right = 797, .bottom = 597 }, hole(rect, 96).?);
    try testing.expectEqual(c.RECT{ .left = 6, .top = 6, .right = 794, .bottom = 594 }, hole(rect, 192).?);
    try testing.expectEqual(c.RECT{ .left = 1, .top = 1, .right = 799, .bottom = 599 }, hole(rect, 1).?);
    // A surface too small for a hole is all border.
    try testing.expectEqual(null, hole(.{ .left = 0, .top = 0, .right = 6, .bottom = 600 }, 96));
    try testing.expectEqual(null, hole(.{ .left = 0, .top = 0, .right = 800, .bottom = 5 }, 96));
    try testing.expectEqual(null, hole(.{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, 96));
}
