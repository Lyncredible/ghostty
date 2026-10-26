//! Rearranging splits with the mouse, like GTK: each terminal in a split
//! has a drag handle at its top. Dragging it over another terminal in the
//! tab highlights the half it would move to, and dropping it moves it
//! there.
//!
//! The handle and highlight are layered child windows of the surface, like
//! our other overlays, since the surface's swap chain covers regular child
//! windows.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");

pub const Direction = Tab.Tree.Split.Direction;

/// Sizes at 96 DPI.
const handle_width = 48;
const handle_height = 6;
const handle_margin = 4;

/// The drag handle of a surface.
pub const Handle = struct {
    pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDragHandle");

    hwnd: c.HWND = null,
    surface: *Surface = undefined,
    brush: c.HBRUSH = null,
    shown: bool = false,
    dragging: bool = false,

    pub fn init(self: *Handle, surface: *Surface, instance: c.HINSTANCE, config: *const Config) !void {
        self.surface = surface;
        self.hwnd = c.CreateWindowExW(
            c.WS_EX_LAYERED | c.WS_EX_NOACTIVATE,
            class_name,
            null,
            c.WS_CHILD,
            0,
            0,
            0,
            0,
            surface.hwnd,
            null,
            instance,
            null,
        ) orelse return error.CreateWindowFailed;
        errdefer self.deinit();
        if (c.SetLayeredWindowAttributes(self.hwnd, 0, 140, c.LWA_ALPHA) == 0) return error.SetOpacityFailed;
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.updateConfig(config);
    }

    pub fn deinit(self: *Handle) void {
        if (self.hwnd != null) {
            _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
            _ = c.DestroyWindow(self.hwnd);
        }
        if (self.brush != null) _ = c.DeleteObject(self.brush);
        self.* = .{};
    }

    pub fn updateConfig(self: *Handle, config: *const Config) void {
        const fg = config.foreground;
        if (self.brush != null) _ = c.DeleteObject(self.brush);
        self.brush = c.CreateSolidBrush(rgb(fg.r, fg.g, fg.b));
        _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
    }

    /// Show or hide the handle, and place it at the top center.
    pub fn setShown(self: *Handle, shown: bool) void {
        self.shown = shown;
        if (!shown) {
            _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
            return;
        }
        var parent: c.RECT = undefined;
        _ = c.GetClientRect(self.surface.hwnd, &parent);
        const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
        const w = scale(handle_width, dpi);
        const h = scale(handle_height, dpi);
        _ = c.SetWindowPos(
            self.hwnd,
            c.HWND_TOP,
            @divTrunc(parent.right - w, 2),
            scale(handle_margin, dpi),
            w,
            h,
            c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
        );
    }

    pub fn parentResized(self: *Handle) void {
        if (self.shown) self.setShown(true);
    }

    fn screenPoint(self: *const Handle, lparam: c.LPARAM) c.POINT {
        var pt: c.POINT = .{ .x = util.loword(lparam), .y = util.hiword(lparam) };
        _ = c.ClientToScreen(self.hwnd, &pt);
        return pt;
    }

    pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
        const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
        if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        const self: *Handle = @ptrFromInt(@as(usize, @bitCast(ptr)));
        switch (msg) {
            c.WM_ERASEBKGND => return 1,
            c.WM_PAINT => {
                var ps: c.PAINTSTRUCT = undefined;
                const dc = c.BeginPaint(hwnd, &ps);
                defer _ = c.EndPaint(hwnd, &ps);
                if (self.brush != null) _ = c.FillRect(dc, &ps.rcPaint, self.brush);
                return 0;
            },
            c.WM_SETCURSOR => {
                _ = c.SetCursor(util.loadSystemCursor(util.IDC_SIZEALL));
                return 1;
            },
            c.WM_LBUTTONDOWN => {
                self.dragging = true;
                _ = c.SetCapture(hwnd);
                return 0;
            },
            c.WM_MOUSEMOVE => {
                if (self.dragging) self.surface.window.splitDragMove(self.surface, self.screenPoint(lparam));
                return 0;
            },
            c.WM_LBUTTONUP => {
                if (self.dragging) {
                    self.dragging = false;
                    const pt = self.screenPoint(lparam);
                    _ = c.ReleaseCapture();
                    self.surface.window.splitDragEnd(self.surface, pt);
                }
                return 0;
            },
            c.WM_CAPTURECHANGED => {
                if (self.dragging) {
                    self.dragging = false;
                    self.surface.window.splitDragCancel();
                }
                return 0;
            },
            else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};

/// The highlight over the half of a surface a dragged split would move to.
pub const DropZone = struct {
    pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDropZone");

    hwnd: c.HWND = null,
    brush: c.HBRUSH = null,

    pub fn init(self: *DropZone, parent: c.HWND, instance: c.HINSTANCE, config: *const Config) !void {
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
        if (c.SetLayeredWindowAttributes(self.hwnd, 0, 70, c.LWA_ALPHA) == 0) return error.SetOpacityFailed;
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.updateConfig(config);
    }

    pub fn deinit(self: *DropZone) void {
        if (self.hwnd != null) {
            _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
            _ = c.DestroyWindow(self.hwnd);
        }
        if (self.brush != null) _ = c.DeleteObject(self.brush);
        self.* = .{};
    }

    pub fn updateConfig(self: *DropZone, config: *const Config) void {
        const fg = config.foreground;
        if (self.brush != null) _ = c.DeleteObject(self.brush);
        self.brush = c.CreateSolidBrush(rgb(fg.r, fg.g, fg.b));
    }

    /// Highlight the half of the parent in a direction, or hide.
    pub fn set(self: *DropZone, direction: ?Direction) void {
        const dir = direction orelse {
            _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
            return;
        };
        var parent: c.RECT = undefined;
        _ = c.GetClientRect(c.GetParent(self.hwnd), &parent);
        const half_w = @divTrunc(parent.right, 2);
        const half_h = @divTrunc(parent.bottom, 2);
        const rect: c.RECT = switch (dir) {
            .left => .{ .left = 0, .top = 0, .right = half_w, .bottom = parent.bottom },
            .right => .{ .left = half_w, .top = 0, .right = parent.right, .bottom = parent.bottom },
            .up => .{ .left = 0, .top = 0, .right = parent.right, .bottom = half_h },
            .down => .{ .left = 0, .top = half_h, .right = parent.right, .bottom = parent.bottom },
        };
        _ = c.SetWindowPos(
            self.hwnd,
            c.HWND_TOP,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
        );
    }

    pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
        const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
        if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        const self: *DropZone = @ptrFromInt(@as(usize, @bitCast(ptr)));
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
};

/// The side of a rectangle nearest to a point, which is where a split
/// dropped there goes, like GTK.
pub fn dropDirection(rect: c.RECT, pt: c.POINT) Direction {
    const width: f64 = @floatFromInt(@max(1, rect.right - rect.left));
    const height: f64 = @floatFromInt(@max(1, rect.bottom - rect.top));
    const l: f64 = @as(f64, @floatFromInt(pt.x - rect.left)) / width;
    const t: f64 = @as(f64, @floatFromInt(pt.y - rect.top)) / height;
    const min = @min(l, t, 1 - l, 1 - t);
    if (min == l) return .left;
    if (min == 1 - l) return .right;
    if (min == t) return .up;
    return .down;
}

test dropDirection {
    const testing = std.testing;
    const rect: c.RECT = .{ .left = 100, .top = 100, .right = 500, .bottom = 300 };
    try testing.expectEqual(Direction.left, dropDirection(rect, .{ .x = 110, .y = 200 }));
    try testing.expectEqual(Direction.right, dropDirection(rect, .{ .x = 490, .y = 200 }));
    try testing.expectEqual(Direction.up, dropDirection(rect, .{ .x = 300, .y = 105 }));
    try testing.expectEqual(Direction.down, dropDirection(rect, .{ .x = 300, .y = 295 }));
}

fn scale(v: c_int, dpi: c_int) c_int {
    return @divTrunc(v * dpi, util.USER_DEFAULT_SCREEN_DPI);
}

fn rgb(r: u8, g: u8, b: u8) c.COLORREF {
    return @as(c.COLORREF, r) | (@as(c.COLORREF, g) << 8) | (@as(c.COLORREF, b) << 16);
}
