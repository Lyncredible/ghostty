//! A small label over a surface, such as the read-only indicator. Like our
//! other overlays this is a click-through layered child window, since the
//! surface's flip model swap chain covers regular child windows. Its
//! window is made the first time it shows, since most badges never do:
//! a surface's five took about 6 ms of each new tab.
const Badge = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../../config.zig").Config;

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyBadge");

/// Where the badge is placed within the surface.
pub const Anchor = enum { top_left, top_center, top_right, bottom_left, bottom_center, bottom_right, center };

hwnd: c.HWND = null,
parent: c.HWND = null,
instance: c.HINSTANCE = null,

/// The overlay our window goes just below when it's made, to keep the
/// order the overlays were made in.
after: c.HWND = null,

anchor: Anchor = .top_right,
font: util.MessageFont = .{},

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
    after: c.HWND,
) void {
    self.parent = parent;
    self.instance = instance;
    self.after = after;
    self.anchor = anchor;
    self.updateConfig(config);
}

fn createWindow(self: *Badge) !void {
    if (self.hwnd != null) return;
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
    if (c.SetLayeredWindowAttributes(hwnd, 0, 230, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // New child windows go below the ones before them, so a badge made
    // late would go below overlays made after it, such as the search bar.
    if (self.after != null) {
        _ = c.SetWindowPos(hwnd, self.after, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    }
    self.hwnd = hwnd;
}

pub fn deinit(self: *Badge, alloc: Allocator) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }
    self.font.deinit();
    if (self.text) |v| alloc.free(v);
    self.* = .{};
}

pub fn updateConfig(self: *Badge, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;
    self.background = util.rgb(bg.r, bg.g, bg.b);
    self.foreground = util.rgb(fg.r, fg.g, fg.b);
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
        if (self.hwnd != null) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        return;
    };
    self.createWindow() catch |err| {
        log.warn("unable to create a badge err={}", .{err});
        return;
    };

    var parent: c.RECT = undefined;
    _ = c.GetClientRect(self.parent, &parent);
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.hwnd));
    self.font.refresh(@intCast(dpi), 100);

    const dc = c.GetDC(self.hwnd);
    const old = c.SelectObject(dc, self.font.font);
    var size: c.SIZE = undefined;
    _ = c.GetTextExtentPoint32W(dc, text.ptr, @intCast(text.len), &size);
    _ = c.SelectObject(dc, old);
    _ = c.ReleaseDC(self.hwnd, dc);

    const rect = place(self.anchor, parent, size, dpi);
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// Where a badge with text of `size` goes in a parent of `parent` (a
/// client rectangle): at `anchor`, 8 pixels in from the edges (at 96 DPI),
/// never wider than the parent nor above or left of it.
fn place(anchor: Anchor, parent: c.RECT, size: c.SIZE, dpi: c_int) c.RECT {
    const margin = util.scale(8, dpi);
    const width = @min(size.cx + 2 * util.scale(10, dpi), parent.right);
    const height = size.cy + 2 * util.scale(5, dpi);
    const center_x = @divTrunc(parent.right - width, 2);
    const right = parent.right - width - margin;
    const bottom = parent.bottom - height - margin;
    const x: c_int, const y: c_int = switch (anchor) {
        .top_left => .{ margin, margin },
        .top_center => .{ center_x, margin },
        .top_right => .{ right, margin },
        .bottom_left => .{ margin, bottom },
        .bottom_center => .{ center_x, bottom },
        .bottom_right => .{ right, bottom },
        .center => .{ center_x, @divTrunc(parent.bottom - height, 2) },
    };
    return .{ .left = @max(0, x), .top = @max(0, y), .right = @max(0, x) + width, .bottom = @max(0, y) + height };
}

test place {
    const testing = std.testing;
    const parent: c.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    const text: c.SIZE = .{ .cx = 80, .cy = 16 };

    // 100 by 26 at 96 DPI: 10 pixels each side and 5 above and below.
    try testing.expectEqual(c.RECT{ .left = 692, .top = 8, .right = 792, .bottom = 34 }, place(.top_right, parent, text, 96));
    try testing.expectEqual(c.RECT{ .left = 8, .top = 8, .right = 108, .bottom = 34 }, place(.top_left, parent, text, 96));
    try testing.expectEqual(c.RECT{ .left = 350, .top = 8, .right = 450, .bottom = 34 }, place(.top_center, parent, text, 96));
    try testing.expectEqual(c.RECT{ .left = 8, .top = 566, .right = 108, .bottom = 592 }, place(.bottom_left, parent, text, 96));
    try testing.expectEqual(c.RECT{ .left = 350, .top = 566, .right = 450, .bottom = 592 }, place(.bottom_center, parent, text, 96));
    try testing.expectEqual(c.RECT{ .left = 692, .top = 566, .right = 792, .bottom = 592 }, place(.bottom_right, parent, text, 96));
    try testing.expectEqual(c.RECT{ .left = 350, .top = 287, .right = 450, .bottom = 313 }, place(.center, parent, text, 96));

    // Twice the DPI, twice the padding and margins.
    try testing.expectEqual(c.RECT{ .left = 664, .top = 16, .right = 784, .bottom = 52 }, place(.top_right, parent, text, 192));

    // Text wider than the surface: as wide as it, and never off its left
    // or top edge, even in a surface shorter than the badge.
    const tiny: c.RECT = .{ .left = 0, .top = 0, .right = 50, .bottom = 20 };
    for (std.enums.values(Anchor)) |anchor| {
        const rect = place(anchor, tiny, text, 96);
        try testing.expect(rect.left >= 0 and rect.top >= 0);
        try testing.expect(rect.right - rect.left <= 50);
    }
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
