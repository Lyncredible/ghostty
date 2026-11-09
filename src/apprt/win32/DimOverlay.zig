//! A click-through layered child window for unfocused split dimming.
//! Keeping this in the runtime matches the other platforms: the overlay
//! covers the entire rendered surface, including images and custom shaders.
const DimOverlay = @This();

const std = @import("std");
const Config = @import("../../config.zig").Config;
const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDimOverlay");

hwnd: c.HWND = null,
parent: c.HWND = null,
instance: c.HINSTANCE = null,
/// The overlays this goes above, in order; see `util.placeAbove`.
above: [3]*const c.HWND = undefined,
brush: c.HBRUSH = null,
alpha: u8 = 0,
dimmed: bool = false,
width: c_int = 0,
height: c_int = 0,

/// The window is made the first time the overlay shows.
pub fn init(
    self: *DimOverlay,
    parent: c.HWND,
    instance: c.HINSTANCE,
    config: *const Config,
    above: [3]*const c.HWND,
) !void {
    self.parent = parent;
    self.instance = instance;
    self.above = above;
    try self.updateConfig(config);
}

fn createWindow(self: *DimOverlay) !void {
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
    errdefer _ = c.DestroyWindow(hwnd);
    if (c.SetLayeredWindowAttributes(hwnd, 0, self.alpha, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    util.placeAbove(hwnd, &self.above);
    self.hwnd = hwnd;
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
    const brush = c.CreateSolidBrush(util.rgb(color.r, color.g, color.b)) orelse return error.CreateBrushFailed;
    errdefer _ = c.DeleteObject(brush);

    const alpha: u8 = @intFromFloat(@round((1 - config.@"unfocused-split-opacity") * 255));
    if (self.hwnd != null) {
        if (c.SetLayeredWindowAttributes(self.hwnd, 0, alpha, c.LWA_ALPHA) == 0) {
            return error.SetOpacityFailed;
        }
        _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    }
    if (self.brush != null) _ = c.DeleteObject(self.brush);
    self.brush = brush;
    self.alpha = alpha;
    self.updateVisibility();
}

/// Resizing a layered window resizes its bitmap, which costs several
/// milliseconds even while it's hidden, so a hidden overlay only takes
/// the new size when it's shown.
pub fn resize(self: *DimOverlay, width: c_int, height: c_int) void {
    self.width = width;
    self.height = height;
    if (self.shown()) _ = c.MoveWindow(self.hwnd, 0, 0, width, height, c.TRUE);
}

fn shown(self: *const DimOverlay) bool {
    // IsWindowVisible also checks the parents, which can be hidden tabs.
    return self.hwnd != null and c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE) & c.WS_VISIBLE != 0;
}

pub fn setDimmed(self: *DimOverlay, dimmed: bool) void {
    self.dimmed = dimmed;
    self.updateVisibility();
}

fn updateVisibility(self: *DimOverlay) void {
    const visible = self.dimmed and self.alpha != 0;
    if (visible == self.shown()) return;
    if (self.hwnd == null) self.createWindow() catch |err| {
        log.warn("unable to create the dim overlay err={}", .{err});
        return;
    };
    if (visible) _ = c.MoveWindow(self.hwnd, 0, 0, self.width, self.height, c.FALSE);
    _ = c.ShowWindow(self.hwnd, if (visible) c.SW_SHOWNA else c.SW_HIDE);
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
