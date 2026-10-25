//! A small label over a surface, such as the read-only indicator. Like our
//! other overlays this is a click-through layered child window, since the
//! surface's flip model swap chain covers regular child windows.
const Badge = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../../config.zig").Config;

const util = @import("util.zig");
const c = util.c;

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyBadge");

/// Where the badge is placed within the surface.
pub const Anchor = enum { top_right, bottom_center, center };

hwnd: c.HWND = null,
anchor: Anchor = .top_right,
font: c.HFONT = null,

/// The text being shown, or null if hidden.
text: ?[:0]u16 = null,

background: c.COLORREF = 0,
foreground: c.COLORREF = 0xFFFFFF,
border: c.COLORREF = 0x555555,

pub fn init(
    self: *Badge,
    parent: c.HWND,
    instance: c.HINSTANCE,
    config: *const Config,
    anchor: Anchor,
) !void {
    self.anchor = anchor;
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
    errdefer _ = c.DestroyWindow(self.hwnd);
    if (c.SetLayeredWindowAttributes(self.hwnd, 0, 230, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateConfig(config);
}

pub fn deinit(self: *Badge, alloc: Allocator) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    if (self.font != null) _ = c.DeleteObject(self.font);
    if (self.text) |v| alloc.free(v);
    self.* = .{};
}

pub fn updateConfig(self: *Badge, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;
    self.background = rgb(bg.r, bg.g, bg.b);
    self.foreground = rgb(fg.r, fg.g, fg.b);
    if (self.hwnd != null) _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// Show the given text, or hide the badge if it's null or empty.
pub fn set(self: *Badge, alloc: Allocator, text: ?[]const u8) void {
    if (self.text) |v| alloc.free(v);
    self.text = null;
    if (text) |v| if (v.len > 0) {
        self.text = util.utf16Alloc(alloc, v) catch null;
    };
    self.layout();
}

/// Called when the parent surface is resized.
pub fn parentResized(self: *Badge) void {
    if (self.text != null) self.layout();
}

fn layout(self: *Badge) void {
    const text = self.text orelse {
        _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        return;
    };

    var parent: c.RECT = undefined;
    _ = c.GetClientRect(c.GetParent(self.hwnd), &parent);
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
    self.updateFont(dpi);

    const dc = c.GetDC(self.hwnd);
    const old = c.SelectObject(dc, self.font);
    var size: c.SIZE = undefined;
    _ = c.GetTextExtentPoint32W(dc, text.ptr, @intCast(text.len), &size);
    _ = c.SelectObject(dc, old);
    _ = c.ReleaseDC(self.hwnd, dc);

    const margin = scale(8, dpi);
    const width = @min(size.cx + 2 * scale(10, dpi), parent.right);
    const height = size.cy + 2 * scale(5, dpi);
    const x: c_int, const y: c_int = switch (self.anchor) {
        .top_right => .{ parent.right - width - margin, margin },
        .bottom_center => .{ @divTrunc(parent.right - width, 2), parent.bottom - height - margin },
        .center => .{ @divTrunc(parent.right - width, 2), @divTrunc(parent.bottom - height, 2) },
    };

    _ = c.SetWindowPos(
        self.hwnd,
        null,
        @max(0, x),
        @max(0, y),
        width,
        height,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

fn updateFont(self: *Badge, dpi: c_int) void {
    if (self.font != null) _ = c.DeleteObject(self.font);
    self.font = null;
    var metrics: c.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (c.SystemParametersInfoForDpi(
        c.SPI_GETNONCLIENTMETRICS,
        metrics.cbSize,
        &metrics,
        0,
        @intCast(dpi),
    ) == 0) return;
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
    const self: *Badge = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
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
