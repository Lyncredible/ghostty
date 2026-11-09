//! Shows the URL under the mouse in a corner of the surface, for the
//! mouse_over_link action. Like GTK, it's in the bottom left corner and
//! moves to the bottom right corner when the mouse is over it.
const LinkPreview = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../../config.zig").Config;

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyLinkPreview");

hwnd: c.HWND = null,
parent: c.HWND = null,
instance: c.HINSTANCE = null,
/// The overlay this goes above; see `util.placeAbove`.
above: *const c.HWND = undefined,
font: util.MessageFont = .{},

/// The URL being shown, if any.
text: ?[:0]u16 = null,

/// Colors, from the terminal's colors.
background: c.COLORREF = 0,
foreground: c.COLORREF = 0xFFFFFF,
border: c.COLORREF = 0x555555,

/// Whether we're in the right corner, because the mouse is in the left.
right: bool = false,

/// The window is made the first time a URL shows.
pub fn init(
    self: *LinkPreview,
    parent: c.HWND,
    instance: c.HINSTANCE,
    config: *const Config,
    above: *const c.HWND,
) void {
    self.parent = parent;
    self.instance = instance;
    self.above = above;
    self.updateConfig(config);
}

fn createWindow(self: *LinkPreview) !void {
    // Like our other overlays this is layered: the flip model swap chain
    // of the surface would cover a regular child window.
    const hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE,
        class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
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
    if (c.SetLayeredWindowAttributes(hwnd, 0, 255, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    util.placeAbove(hwnd, &.{self.above});
    self.hwnd = hwnd;
}

pub fn deinit(self: *LinkPreview, alloc: Allocator) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    self.font.deinit();
    if (self.text) |v| alloc.free(v);
    self.* = .{};
}

pub fn updateConfig(self: *LinkPreview, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;
    self.background = util.rgb(bg.r, bg.g, bg.b);
    self.foreground = util.rgb(fg.r, fg.g, fg.b);
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
    _ = c.ScreenToClient(self.parent, &pt);
    self.layout(pt);
}

fn layout(self: *LinkPreview, cursor: c.POINT) void {
    const text = self.text orelse {
        if (self.hwnd != null) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        return;
    };
    if (self.hwnd == null) self.createWindow() catch |err| {
        log.warn("unable to create the link preview err={}", .{err});
        return;
    };

    var parent_rect: c.RECT = undefined;
    _ = c.GetClientRect(self.parent, &parent_rect);
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
    self.font.refresh(@intCast(dpi), 100);

    // Measure the text.
    const dc = c.GetDC(self.hwnd);
    const old = c.SelectObject(dc, self.font.font);
    var size: c.SIZE = undefined;
    _ = c.GetTextExtentPoint32W(dc, text.ptr, @intCast(text.len), &size);
    _ = c.SelectObject(dc, old);
    _ = c.ReleaseDC(self.hwnd, dc);

    const p = place(parent_rect, size, cursor, dpi);
    self.right = p.right;
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        p.rect.left,
        p.rect.top,
        p.rect.right - p.rect.left,
        p.rect.bottom - p.rect.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// Where the preview goes in a parent of `parent` (a client rectangle) for
/// text of `size`: the bottom left corner, or the bottom right one when
/// `cursor` is over the bottom left one. It's never wider than the parent.
fn place(parent: c.RECT, size: c.SIZE, cursor: c.POINT, dpi: c_int) struct { rect: c.RECT, right: bool } {
    const width = @min(size.cx + 2 * util.scale(8, dpi), parent.right);
    const height = size.cy + 2 * util.scale(4, dpi);
    const top = parent.bottom - height;
    const over_left = cursor.x >= 0 and cursor.x < width and
        cursor.y >= top and cursor.y < parent.bottom;
    const left = if (over_left) parent.right - width else 0;
    return .{
        .rect = .{ .left = left, .top = top, .right = left + width, .bottom = parent.bottom },
        .right = over_left,
    };
}

test place {
    const testing = std.testing;
    const parent: c.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    const text: c.SIZE = .{ .cx = 200, .cy = 16 };

    // At 96 DPI: 8 pixels each side, 4 above and below, in the bottom left.
    const away = place(parent, text, .{ .x = 400, .y = 100 }, 96);
    try testing.expect(!away.right);
    try testing.expectEqual(c.RECT{ .left = 0, .top = 576, .right = 216, .bottom = 600 }, away.rect);

    // The mouse over it moves it to the bottom right; just outside doesn't.
    const over = place(parent, text, .{ .x = 10, .y = 590 }, 96);
    try testing.expect(over.right);
    try testing.expectEqual(c.RECT{ .left = 584, .top = 576, .right = 800, .bottom = 600 }, over.rect);
    try testing.expect(!place(parent, text, .{ .x = 216, .y = 590 }, 96).right);
    try testing.expect(!place(parent, text, .{ .x = 10, .y = 575 }, 96).right);
    try testing.expect(!place(parent, text, .{ .x = -1, .y = 590 }, 96).right);

    // Padding scales with the DPI.
    const big = place(parent, text, .{ .x = 400, .y = 100 }, 192);
    try testing.expectEqual(c.RECT{ .left = 0, .top = 568, .right = 232, .bottom = 600 }, big.rect);

    // A URL wider than the surface is cut to its width (and ellipsized
    // when drawn), even in the right corner.
    const long: c.SIZE = .{ .cx = 5000, .cy = 16 };
    try testing.expectEqual(c.RECT{ .left = 0, .top = 576, .right = 800, .bottom = 600 }, place(parent, long, .{ .x = 400, .y = 100 }, 96).rect);
    try testing.expectEqual(c.RECT{ .left = 0, .top = 576, .right = 800, .bottom = 600 }, place(parent, long, .{ .x = 400, .y = 590 }, 96).rect);
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
            const col = (util.TipColors{
                .border = self.border,
                .background = self.background,
                .foreground = self.foreground,
            }).effective();
            const border = c.CreateSolidBrush(col.border);
            defer _ = c.DeleteObject(border);
            const background = c.CreateSolidBrush(col.background);
            defer _ = c.DeleteObject(background);
            _ = c.FillRect(dc, &rect, border);
            var inner = rect;
            _ = c.InflateRect(&inner, -1, -1);
            _ = c.FillRect(dc, &inner, background);

            const text = self.text orelse return 0;
            const old = c.SelectObject(dc, self.font.font);
            defer _ = c.SelectObject(dc, old);
            _ = c.SetBkMode(dc, c.TRANSPARENT);
            _ = c.SetTextColor(dc, col.foreground);
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
