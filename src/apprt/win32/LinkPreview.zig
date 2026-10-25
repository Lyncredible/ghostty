//! Shows the URL under the mouse in a corner of the surface, for the
//! mouse_over_link action. Like GTK, it's in the bottom left corner and
//! moves to the bottom right corner when the mouse is over it.
const LinkPreview = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../../config.zig").Config;

const util = @import("util.zig");
const c = util.c;

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyLinkPreview");

hwnd: c.HWND = null,
font: c.HFONT = null,

/// The URL being shown, if any.
text: ?[:0]u16 = null,

/// Colors, from the terminal's colors.
background: c.COLORREF = 0,
foreground: c.COLORREF = 0xFFFFFF,
border: c.COLORREF = 0x555555,

/// Whether we're in the right corner, because the mouse is in the left.
right: bool = false,

pub fn init(self: *LinkPreview, parent: c.HWND, instance: c.HINSTANCE, config: *const Config) !void {
    // Like our other overlays this is layered: the flip model swap chain
    // of the surface would cover a regular child window.
    self.hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE,
        class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
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
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateConfig(config);
}

pub fn deinit(self: *LinkPreview, alloc: Allocator) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    if (self.font != null) _ = c.DeleteObject(self.font);
    if (self.text) |v| alloc.free(v);
    self.* = .{};
}

pub fn updateConfig(self: *LinkPreview, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;
    self.background = rgb(bg.r, bg.g, bg.b);
    self.foreground = rgb(fg.r, fg.g, fg.b);
    if (self.hwnd != null) _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// Show the given URL, or hide the preview if it's empty.
pub fn setUrl(self: *LinkPreview, alloc: Allocator, url: []const u8, cursor: c.POINT) void {
    if (self.text) |v| alloc.free(v);
    self.text = null;
    if (url.len > 0) self.text = util.utf16Alloc(alloc, url) catch null;
    self.layout(cursor);
}

/// Called when the mouse moves, to get out of its way.
pub fn cursorMoved(self: *LinkPreview, cursor: c.POINT) void {
    if (self.text == null) return;
    self.layout(cursor);
}

/// Called when the parent surface is resized.
pub fn parentResized(self: *LinkPreview) void {
    if (self.text == null) return;
    var pt: c.POINT = undefined;
    _ = c.GetCursorPos(&pt);
    _ = c.ScreenToClient(c.GetParent(self.hwnd), &pt);
    self.layout(pt);
}

fn layout(self: *LinkPreview, cursor: c.POINT) void {
    const text = self.text orelse {
        _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        return;
    };

    var parent_rect: c.RECT = undefined;
    _ = c.GetClientRect(c.GetParent(self.hwnd), &parent_rect);
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
    self.updateFont(dpi);

    // Measure the text.
    const dc = c.GetDC(self.hwnd);
    const old = c.SelectObject(dc, self.font);
    var size: c.SIZE = undefined;
    _ = c.GetTextExtentPoint32W(dc, text.ptr, @intCast(text.len), &size);
    _ = c.SelectObject(dc, old);
    _ = c.ReleaseDC(self.hwnd, dc);

    const pad_x = scale(8, dpi);
    const pad_y = scale(4, dpi);
    const width = @min(size.cx + 2 * pad_x, parent_rect.right);
    const height = size.cy + 2 * pad_y;
    const top = parent_rect.bottom - height;

    // Move to the right if the mouse is over our left position.
    const over_left = cursor.x >= 0 and cursor.x < width and
        cursor.y >= top and cursor.y < parent_rect.bottom;
    self.right = over_left;
    const left = if (over_left) parent_rect.right - width else 0;

    _ = c.SetWindowPos(
        self.hwnd,
        null,
        left,
        top,
        width,
        height,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

fn updateFont(self: *LinkPreview, dpi: c_int) void {
    if (self.font != null) _ = c.DeleteObject(self.font);
    var metrics: c.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (c.SystemParametersInfoForDpi(
        c.SPI_GETNONCLIENTMETRICS,
        metrics.cbSize,
        &metrics,
        0,
        @intCast(dpi),
    ) == 0) {
        self.font = null;
        return;
    }
    self.font = c.CreateFontIndirectW(&metrics.lfMessageFont);
}

fn scale(v: c_int, dpi: c_int) c_int {
    return @divTrunc(v * dpi, util.USER_DEFAULT_SCREEN_DPI);
}

fn rgb(r: u8, g: u8, b: u8) c.COLORREF {
    return @as(c.COLORREF, r) | (@as(c.COLORREF, g) << 8) | (@as(c.COLORREF, b) << 16);
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *LinkPreview = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        // Let the mouse through to the surface below.
        c.WM_NCHITTEST => return c.HTTRANSPARENT,
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);

            var rect: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &rect);
            const border = c.CreateSolidBrush(self.border);
            defer _ = c.DeleteObject(border);
            const background = c.CreateSolidBrush(self.background);
            defer _ = c.DeleteObject(background);
            _ = c.FillRect(dc, &rect, border);
            var inner = rect;
            _ = c.InflateRect(&inner, -1, -1);
            _ = c.FillRect(dc, &inner, background);

            const text = self.text orelse return 0;
            const old = c.SelectObject(dc, self.font);
            defer _ = c.SelectObject(dc, old);
            _ = c.SetBkMode(dc, c.TRANSPARENT);
            _ = c.SetTextColor(dc, self.foreground);
            _ = c.DrawTextW(
                dc,
                text.ptr,
                @intCast(text.len),
                &rect,
                c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
            );
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
