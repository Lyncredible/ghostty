//! A click-through layered child window for unfocused split dimming.
//! Keeping this in the runtime matches the other platforms: the overlay
//! covers the entire rendered surface, including images and custom shaders.
const DimOverlay = @This();

const std = @import("std");
const Config = @import("../../config.zig").Config;
const util = @import("util.zig");
const c = util.c;

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDimOverlay");

hwnd: c.HWND = null,
brush: c.HBRUSH = null,
alpha: u8 = 0,
dimmed: bool = false,

pub fn init(self: *DimOverlay, parent: c.HWND, instance: c.HINSTANCE, config: *const Config) !void {
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
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    try self.updateConfig(config);
}

pub fn deinit(self: *DimOverlay) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    if (self.brush != null) _ = c.DeleteObject(self.brush);
    self.* = .{};
}

pub fn updateConfig(self: *DimOverlay, config: *const Config) !void {
    const color = config.@"unfocused-split-fill" orelse config.background;
    const rgb = @as(c.COLORREF, color.r) |
        (@as(c.COLORREF, color.g) << 8) | (@as(c.COLORREF, color.b) << 16);
    const brush = c.CreateSolidBrush(rgb) orelse return error.CreateBrushFailed;
    errdefer _ = c.DeleteObject(brush);

    const alpha: u8 = @intFromFloat(@round((1 - config.@"unfocused-split-opacity") * 255));
    if (c.SetLayeredWindowAttributes(self.hwnd, 0, alpha, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }
    if (self.brush != null) _ = c.DeleteObject(self.brush);
    self.brush = brush;
    self.alpha = alpha;
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    self.updateVisibility();
}

pub fn resize(self: *DimOverlay, width: c_int, height: c_int) void {
    _ = c.MoveWindow(self.hwnd, 0, 0, width, height, c.TRUE);
}

pub fn setDimmed(self: *DimOverlay, dimmed: bool) void {
    self.dimmed = dimmed;
    self.updateVisibility();
}

fn updateVisibility(self: *DimOverlay) void {
    const visible = self.dimmed and self.alpha != 0;
    // IsWindowVisible also checks the parents, which can be hidden tabs.
    const shown = c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE) & c.WS_VISIBLE != 0;
    if (visible != shown) _ = c.ShowWindow(self.hwnd, if (visible) c.SW_SHOWNA else c.SW_HIDE);
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *DimOverlay = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_NCHITTEST => return c.HTTRANSPARENT,
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);
            if (self.brush != null) _ = c.FillRect(dc, &ps.rcPaint, self.brush);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
