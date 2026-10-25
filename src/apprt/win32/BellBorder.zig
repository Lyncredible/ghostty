//! A click-through layered child window that draws a border around a
//! surface while its bell is ringing, for the `border` bell feature.
//! Like GTK, this uses the system accent color at half opacity.
const BellBorder = @This();

const std = @import("std");
const util = @import("util.zig");
const c = util.c;

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyBellBorder");

/// The border width in pixels at 96 DPI.
const width = 3;

/// The color drawn inside the border, which the layered window makes
/// fully transparent. It must differ from any accent color we draw.
const transparent_key: c.COLORREF = 0x00FF00FF;

hwnd: c.HWND = null,
visible: bool = false,

pub fn init(self: *BellBorder, parent: c.HWND, instance: c.HINSTANCE) !void {
    self.hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE,
        class_name,
        null,
        c.WS_CHILD,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer self.deinit();
    if (c.SetLayeredWindowAttributes(
        self.hwnd,
        transparent_key,
        128,
        c.LWA_COLORKEY | c.LWA_ALPHA,
    ) == 0) return error.SetOpacityFailed;
}

pub fn deinit(self: *BellBorder) void {
    if (self.hwnd != null) _ = c.DestroyWindow(self.hwnd);
    self.* = .{};
}

pub fn resize(self: *BellBorder, w: c_int, h: c_int) void {
    _ = c.MoveWindow(self.hwnd, 0, 0, w, h, c.TRUE);
}

pub fn setVisible(self: *BellBorder, visible: bool) void {
    if (visible == self.visible) return;
    self.visible = visible;
    if (visible) _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    _ = c.ShowWindow(self.hwnd, if (visible) c.SW_SHOWNA else c.SW_HIDE);
}

/// The system accent color, falling back to a Windows blue.
fn accentColor() c.COLORREF {
    var argb: c.DWORD = 0;
    var opaque_blend: c.BOOL = 0;
    if (c.DwmGetColorizationColor(&argb, &opaque_blend) < 0) return rgb(0, 120, 215);
    const color = rgb(
        @truncate(argb >> 16),
        @truncate(argb >> 8),
        @truncate(argb),
    );
    // Avoid our transparent color key.
    return if (color == transparent_key) rgb(0xFE, 0, 0xFF) else color;
}

fn rgb(r: u8, g: u8, b: u8) c.COLORREF {
    return @as(c.COLORREF, r) | (@as(c.COLORREF, g) << 8) | (@as(c.COLORREF, b) << 16);
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
            const border: c_int = @max(1, @divTrunc(width * dpi, util.USER_DEFAULT_SCREEN_DPI));

            const accent = c.CreateSolidBrush(accentColor());
            defer _ = c.DeleteObject(accent);
            const key = c.CreateSolidBrush(transparent_key);
            defer _ = c.DeleteObject(key);

            _ = c.FillRect(dc, &rect, accent);
            var inner = rect;
            _ = c.InflateRect(&inner, -border, -border);
            if (inner.right > inner.left and inner.bottom > inner.top) {
                _ = c.FillRect(dc, &inner, key);
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
