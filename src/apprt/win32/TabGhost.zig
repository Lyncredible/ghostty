//! The picture of a tab that follows the pointer while the tab is dragged
//! out of its tab bar, to show that dropping it there takes it out of the
//! window: a small see-through popup with the tab's title. It never takes
//! the mouse or the focus (the tab bar that started the drag has the
//! capture), and the window under it is still what the pointer is over.
const TabGhost = @This();

const std = @import("std");
const i18n = @import("../../os/main.zig").i18n;
const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTabGhost");

/// How see-through it is, of 255.
const alpha = 215;

hwnd: c.HWND = null,
/// The tab bar's font, which it keeps while we're shown.
font: c.HFONT = null,
background: c.COLORREF = 0,
foreground: c.COLORREF = 0,
border: c.COLORREF = 0,
title: [128:0]u16 = @splat(0),

pub const Look = struct {
    title: []const u8,
    font: c.HFONT,
    background: c.COLORREF,
    foreground: c.COLORREF,
    border: c.COLORREF,
    width: c_int,
    height: c_int,
    /// The point is its top left corner rather than the pointer: for the
    /// mark on a window that has no tab bar showing (see TabBar).
    fixed: bool = false,
};

/// Show it by a point of the screen (the pointer), or move it there.
pub fn show(self: *TabGhost, instance: c.HINSTANCE, pt: c.POINT, look: Look) void {
    if (self.hwnd == null) {
        self.hwnd = c.CreateWindowExW(
            // Mirrored like the tab bar it comes from, so the title starts
            // on the same side.
            @as(c.DWORD, c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE | c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST) |
                if (i18n.rightToLeft()) @as(c.DWORD, c.WS_EX_LAYOUTRTL) else 0,
            class_name,
            null,
            c.WS_POPUP,
            0,
            0,
            0,
            0,
            null,
            null,
            instance,
            null,
        ) orelse {
            log.warn("unable to create the dragged tab's picture", .{});
            return;
        };
        _ = c.SetLayeredWindowAttributes(self.hwnd, 0, alpha, c.LWA_ALPHA);
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    }
    self.font = look.font;
    self.background = look.background;
    self.foreground = look.foreground;
    self.border = look.border;
    _ = util.utf16TruncateZ(&self.title, look.title);
    const place = if (look.fixed) c.RECT{
        .left = pt.x,
        .top = pt.y,
        .right = pt.x + look.width,
        .bottom = pt.y + look.height,
    } else rect(pt, look.width, look.height);
    _ = util.SetWindowPos(
        self.hwnd,
        util.HWND_TOPMOST,
        place.left,
        place.top,
        look.width,
        look.height,
        c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

pub fn hide(self: *TabGhost) void {
    if (self.hwnd != null) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    self.font = null;
}

pub fn visible(self: *const TabGhost) bool {
    return self.hwnd != null and c.IsWindowVisible(self.hwnd) != 0;
}

pub fn deinit(self: *TabGhost) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    self.* = .{};
}

/// Where it goes for a pointer position: centered on it across, and just
/// below it, so that it doesn't hide what the pointer is on.
fn rect(pt: c.POINT, width: c_int, height: c_int) c.RECT {
    const left = pt.x - @divTrunc(width, 2);
    const top = pt.y + @divTrunc(height, 4);
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
}

test rect {
    const testing = std.testing;
    const r = rect(.{ .x = 500, .y = 300 }, 200, 40);
    try testing.expectEqual(@as(c_int, 400), r.left);
    try testing.expectEqual(@as(c_int, 600), r.right);
    // Below the pointer, which stays outside it.
    try testing.expect(r.top > 300);
    try testing.expectEqual(@as(c_int, 40), r.bottom - r.top);
}

fn paint(self: *TabGhost, hdc: c.HDC) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);

    const border = c.CreateSolidBrush(self.border);
    defer _ = c.DeleteObject(border);
    _ = c.FillRect(hdc, &client, border);
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
    const line: c_int = @max(1, util.scale(1, dpi));
    var inner = client;
    _ = c.InflateRect(&inner, -line, -line);
    const background = c.CreateSolidBrush(self.background);
    defer _ = c.DeleteObject(background);
    _ = c.FillRect(hdc, &inner, background);

    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetTextColor(hdc, self.foreground);
    const old_font = if (self.font) |f| c.SelectObject(hdc, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(hdc, f);
    };
    _ = c.InflateRect(&inner, -util.scale(12, dpi), 0);
    _ = c.DrawTextW(
        hdc,
        &self.title,
        -1,
        &inner,
        c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *TabGhost = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);
            self.paint(hdc);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
