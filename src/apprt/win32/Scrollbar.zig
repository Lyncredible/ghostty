//! An overlay scrollbar for a surface, in the style of Windows 11: a thin
//! thumb at the right edge that appears while scrolling or when the mouse
//! is near the edge, widens when hovered, and can be dragged.
//!
//! It hides itself after a moment unless the user turned off "Automatically
//! hide scroll bars" in the Windows accessibility settings.
const Scrollbar = @This();

const std = @import("std");
const terminal = @import("../../terminal/main.zig");
const Config = @import("../../config.zig").Config;

const util = @import("util.zig");
const c = util.c;

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyScrollbar");

/// Sizes at 96 DPI.
const hit_width = 12;
const thin_width = 3;
const wide_width = 8;
const margin = 2;
const min_thumb = 24;

/// Hide this long after the last scroll or hover.
const hide_ms = 1200;
const hide_timer_id = 1;

/// The color drawn around the thumb, which the layered window makes
/// transparent (and lets mouse input through).
const transparent_key: c.COLORREF = 0x00FF00FF;

hwnd: c.HWND = null,

/// Called with the row to scroll to while dragging the thumb.
on_scroll: ?*const fn (ctx: *anyopaque, row: usize) void = null,
ctx: *anyopaque = undefined,

enabled: bool = true,
color: c.COLORREF = 0xFFFFFF,

/// The latest scrollbar state from the core.
state: terminal.Scrollbar = .zero,

/// Whether the mouse is near the edge (wide thumb), and the thumb
/// offset of the mouse while dragging.
hovered: bool = false,
drag_offset: ?c_int = null,

pub fn init(
    self: *Scrollbar,
    parent: c.HWND,
    instance: c.HINSTANCE,
    config: *const Config,
    ctx: *anyopaque,
    on_scroll: *const fn (ctx: *anyopaque, row: usize) void,
) !void {
    self.hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_NOACTIVATE,
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
    if (c.SetLayeredWindowAttributes(
        self.hwnd,
        transparent_key,
        160,
        c.LWA_COLORKEY | c.LWA_ALPHA,
    ) == 0) return error.SetOpacityFailed;
    self.ctx = ctx;
    self.on_scroll = on_scroll;
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateConfig(config);
}

pub fn deinit(self: *Scrollbar) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    self.* = .{};
}

pub fn updateConfig(self: *Scrollbar, config: *const Config) void {
    self.enabled = config.scrollbar != .never;
    const fg = config.foreground;
    self.color = @as(c.COLORREF, fg.r) | (@as(c.COLORREF, fg.g) << 8) | (@as(c.COLORREF, fg.b) << 16);
    if (self.color == transparent_key) self.color ^= 1;
    if (!self.enabled) self.hide();
    self.layout();
}

/// New scrollbar state from the core. This shows the scrollbar briefly
/// if the position changed.
pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
    const moved = state.offset != self.state.offset or state.total != self.state.total;
    self.state = state;
    if (!self.scrollable()) {
        self.hide();
        return;
    }
    if (moved and self.state.total != 0) self.show();
    self.layout();
}

/// Called when the mouse moves over or leaves the surface, so we can
/// appear when it's near the right edge.
pub fn updateHover(self: *Scrollbar) void {
    if (!self.enabled or !self.scrollable()) return;
    const parent = c.GetParent(self.hwnd);
    var pt: c.POINT = undefined;
    _ = c.GetCursorPos(&pt);
    _ = c.ScreenToClient(parent, &pt);
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(parent, &rect);
    const near = pt.x >= rect.right - self.scale(hit_width) and pt.x < rect.right and
        pt.y >= 0 and pt.y < rect.bottom;
    if (near != self.hovered) {
        self.hovered = near;
        _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    }
    if (near) self.show();
}

/// Called when the parent surface is resized.
pub fn parentResized(self: *Scrollbar) void {
    self.layout();
}

fn scrollable(self: *const Scrollbar) bool {
    return self.state.total > self.state.len;
}

fn show(self: *Scrollbar) void {
    if (!self.enabled) return;
    _ = c.ShowWindow(self.hwnd, c.SW_SHOWNA);
    if (autoHide()) {
        _ = c.SetTimer(self.hwnd, hide_timer_id, hide_ms, null);
    }
}

fn hide(self: *Scrollbar) void {
    _ = c.KillTimer(self.hwnd, hide_timer_id);
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    self.hovered = false;
}

/// Whether scrollbars hide automatically, from the Windows setting
/// Accessibility > Visual effects > Always show scrollbars.
fn autoHide() bool {
    var value: c.DWORD = 1;
    var size: c.DWORD = @sizeOf(c.DWORD);
    const result = util.RegGetValueW(
        util.HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral("Control Panel\\Accessibility"),
        std.unicode.utf8ToUtf16LeStringLiteral("DynamicScrollbars"),
        c.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    );
    return result != 0 or value != 0;
}

fn scale(self: *const Scrollbar, v: c_int) c_int {
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
    return @divTrunc(v * dpi, util.USER_DEFAULT_SCREEN_DPI);
}

/// Position our window along the right edge of the surface.
fn layout(self: *Scrollbar) void {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(c.GetParent(self.hwnd), &rect);
    const w = self.scale(hit_width);
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        rect.right - w,
        0,
        w,
        rect.bottom,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// The thumb's top and bottom within a track of the given height.
fn thumb(self: *const Scrollbar, track: c_int) struct { c_int, c_int } {
    const total: f64 = @floatFromInt(@max(self.state.total, 1));
    const h: f64 = @floatFromInt(track);
    const len = @max(
        @as(c_int, @intFromFloat(h * @as(f64, @floatFromInt(self.state.len)) / total)),
        @min(self.scale(min_thumb), track),
    );
    const top: c_int = @intFromFloat(h * @as(f64, @floatFromInt(self.state.offset)) / total);
    const clamped = std.math.clamp(top, 0, track - len);
    return .{ clamped, clamped + len };
}

/// The row to scroll to so the thumb's top is at y.
fn rowAt(self: *const Scrollbar, y: c_int, track: c_int) usize {
    if (track <= 0) return 0;
    const top, const bottom = self.thumb(track);
    const free = track - (bottom - top);
    if (free <= 0) return 0;
    const clamped: f64 = @floatFromInt(std.math.clamp(y, 0, free));
    const max_row: f64 = @floatFromInt(self.state.total - self.state.len);
    return @intFromFloat(@round(clamped / @as(f64, @floatFromInt(free)) * max_row));
}

fn trackHeight(self: *const Scrollbar) c_int {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &rect);
    return rect.bottom - 2 * self.scale(margin);
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Scrollbar = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);

            var rect: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &rect);
            const key = c.CreateSolidBrush(transparent_key);
            defer _ = c.DeleteObject(key);
            _ = c.FillRect(dc, &rect, key);

            if (!self.scrollable()) return 0;
            const m = self.scale(margin);
            const top, const bottom = self.thumb(rect.bottom - 2 * m);
            const wide = self.hovered or self.drag_offset != null;
            const w = self.scale(if (wide) wide_width else thin_width);
            const brush = c.CreateSolidBrush(self.color);
            defer _ = c.DeleteObject(brush);
            const old_brush = c.SelectObject(dc, brush);
            defer _ = c.SelectObject(dc, old_brush);
            const pen = c.GetStockObject(c.NULL_PEN);
            const old_pen = c.SelectObject(dc, pen);
            defer _ = c.SelectObject(dc, old_pen);
            _ = c.RoundRect(
                dc,
                rect.right - m - w,
                m + top,
                rect.right - m + 1,
                m + bottom + 1,
                w,
                w,
            );
            return 0;
        },

        c.WM_TIMER => if (wparam == hide_timer_id) {
            // Stay while the mouse is on us or dragging.
            if (self.hovered or self.drag_offset != null) return 0;
            self.hide();
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            const y: c_int = util.hiword(lparam);
            const m = self.scale(margin);
            const track = self.trackHeight();
            const top, const bottom = self.thumb(track);
            const thumb_y = y - m;
            // Clicking the track jumps so the thumb is centered there.
            self.drag_offset = if (thumb_y >= top and thumb_y < bottom)
                thumb_y - top
            else
                @divTrunc(bottom - top, 2);
            _ = c.SetCapture(hwnd);
            self.scrollTo(self.rowAt(thumb_y - self.drag_offset.?, track));
            return 0;
        },

        c.WM_MOUSEMOVE => {
            var track: c.TRACKMOUSEEVENT = .{
                .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                .dwFlags = c.TME_LEAVE,
                .hwndTrack = hwnd,
                .dwHoverTime = 0,
            };
            _ = c.TrackMouseEvent(&track);
            self.updateHover();
            if (self.drag_offset) |offset| {
                const y: c_int = util.hiword(lparam);
                self.scrollTo(self.rowAt(y - self.scale(margin) - offset, self.trackHeight()));
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.updateHover();
            return 0;
        },

        c.WM_LBUTTONUP, c.WM_CAPTURECHANGED => {
            if (self.drag_offset != null) {
                self.drag_offset = null;
                if (msg == c.WM_LBUTTONUP) _ = c.ReleaseCapture();
                self.show();
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
            }
            return 0;
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn scrollTo(self: *Scrollbar, row: usize) void {
    const on_scroll = self.on_scroll orelse return;
    on_scroll(self.ctx, row);
}
