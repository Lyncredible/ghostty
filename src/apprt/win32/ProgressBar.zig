//! A thin bar along the top of a surface for its progress report (ConEmu's
//! OSC 9;4), as GTK and macOS have: the part done in the accent color (red
//! for an error), or, when how much is unknown, a short piece sliding
//! across. The window is only the bar itself, so nothing else covers the
//! terminal. The taskbar button shows the focused surface's progress too.
const ProgressBar = @This();

const std = @import("std");
const terminal = @import("../../terminal/main.zig");
const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyProgressBar");

/// The bar's height in pixels at 96 DPI.
const height = 3;

/// How long the sliding piece takes to cross, and its share of the width.
pub const slide_ms = 1500;
const slide_fraction = 5;

/// GNOME's error red, as GTK's progress bar uses.
const error_color = util.rgb(0xE0, 0x1B, 0x24);

hwnd: c.HWND = null,
parent: c.HWND = null,
instance: c.HINSTANCE = null,
/// The overlay our window goes just below when it's made, to keep the
/// order the overlays were made in.
after: c.HWND = null,

/// What the bar shows.
pub const Look = union(enum) {
    /// Nothing: no report, or `progress-style = false`.
    none,
    /// A percentage done.
    done: struct { percent: u8, failed: bool },
    /// An unknown amount: the sliding piece.
    sliding: struct { failed: bool },

    /// What a report shows, with the last percentage a pause without one
    /// keeps (as GTK does, which leaves the bar as it was).
    pub fn of(report: ?terminal.osc.Command.ProgressReport, last: ?u8) Look {
        const r = report orelse return .none;
        return switch (r.state) {
            .remove => .none,
            .set, .@"error" => if (r.progress) |p|
                .{ .done = .{ .percent = p, .failed = r.state == .@"error" } }
            else
                .{ .sliding = .{ .failed = r.state == .@"error" } },
            .indeterminate => .{ .sliding = .{ .failed = false } },
            .pause => if (r.progress orelse last) |p|
                .{ .done = .{ .percent = p, .failed = false } }
            else
                .none,
        };
    }
};

/// The bar's place in a surface `width` pixels wide at `dpi`, `ms` into
/// the slide, or null when nothing shows.
pub fn place(look: Look, width: c_int, dpi: c_int, ms: u64) ?c.RECT {
    if (width <= 0) return null;
    const bottom: c_int = @max(1, util.scale(height, dpi));
    switch (look) {
        .none => return null,
        .done => |v| {
            const right: c_int = @intCast(@divFloor(@as(i64, width) * @min(v.percent, 100), 100));
            if (right <= 0) return null;
            return .{ .left = 0, .top = 0, .right = right, .bottom = bottom };
        },
        .sliding => {
            // From just off the left edge to just off the right one.
            const piece: c_int = @max(1, @divFloor(width, slide_fraction));
            const travel: i64 = width + piece;
            const at: i64 = @divFloor(@as(i64, @intCast(ms % slide_ms)) * travel, slide_ms);
            const left: c_int = @as(c_int, @intCast(at)) - piece;
            const rect: c.RECT = .{
                .left = @max(0, left),
                .top = 0,
                .right = @min(width, left + piece),
                .bottom = bottom,
            };
            return if (rect.right > rect.left) rect else null;
        },
    }
}

pub fn color(look: Look) c.COLORREF {
    const failed = switch (look) {
        .none => false,
        .done => |v| v.failed,
        .sliding => |v| v.failed,
    };
    return if (failed) error_color else util.accentColor();
}

pub fn init(self: *ProgressBar, parent: c.HWND, instance: c.HINSTANCE, after: c.HWND) void {
    self.parent = parent;
    self.instance = instance;
    self.after = after;
}

pub fn deinit(self: *ProgressBar) void {
    if (self.hwnd != null) _ = c.DestroyWindow(self.hwnd);
    self.* = .{};
}

fn createWindow(self: *ProgressBar) !void {
    const hwnd = c.CreateWindowExW(
        c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE,
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
    if (self.after != null) {
        _ = c.SetWindowPos(hwnd, self.after, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    }
    self.hwnd = hwnd;
}

/// Show the bar at `rect` in `fill`, or hide it.
pub fn set(self: *ProgressBar, rect: ?c.RECT, fill: c.COLORREF) void {
    const r = rect orelse {
        if (self.hwnd != null) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        return;
    };
    if (self.hwnd == null) self.createWindow() catch |err| {
        log.warn("unable to create the progress bar err={}", .{err});
        return;
    };
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, @intCast(fill));
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
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
            const fill: c.COLORREF = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA))));
            const brush = c.CreateSolidBrush(fill);
            defer _ = c.DeleteObject(brush);
            _ = c.FillRect(dc, &rect, brush);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test Look {
    const testing = std.testing;
    try testing.expectEqual(Look.none, Look.of(null, 40));
    try testing.expectEqual(Look.none, Look.of(.{ .state = .remove, .progress = 10 }, 40));
    try testing.expectEqual(Look{ .done = .{ .percent = 10, .failed = false } }, Look.of(.{ .state = .set, .progress = 10 }, 40));
    try testing.expectEqual(Look{ .sliding = .{ .failed = false } }, Look.of(.{ .state = .set, .progress = null }, 40));
    try testing.expectEqual(Look{ .done = .{ .percent = 70, .failed = true } }, Look.of(.{ .state = .@"error", .progress = 70 }, 40));
    try testing.expectEqual(Look{ .sliding = .{ .failed = true } }, Look.of(.{ .state = .@"error", .progress = null }, 40));
    try testing.expectEqual(Look{ .sliding = .{ .failed = false } }, Look.of(.{ .state = .indeterminate, .progress = null }, 40));
    // A pause keeps the last percentage, or shows nothing without one.
    try testing.expectEqual(Look{ .done = .{ .percent = 40, .failed = false } }, Look.of(.{ .state = .pause, .progress = null }, 40));
    try testing.expectEqual(Look{ .done = .{ .percent = 80, .failed = false } }, Look.of(.{ .state = .pause, .progress = 80 }, 40));
    try testing.expectEqual(Look.none, Look.of(.{ .state = .pause, .progress = null }, null));
}

test place {
    const testing = std.testing;
    const half: Look = .{ .done = .{ .percent = 50, .failed = false } };
    try testing.expectEqual(c.RECT{ .left = 0, .top = 0, .right = 400, .bottom = 3 }, place(half, 800, 96, 0).?);
    // Taller at a higher DPI; never past the width; nothing at 0 or with
    // no width.
    try testing.expectEqual(c.RECT{ .left = 0, .top = 0, .right = 400, .bottom = 6 }, place(half, 800, 192, 0).?);
    try testing.expectEqual(@as(c_int, 800), place(.{ .done = .{ .percent = 255, .failed = false } }, 800, 96, 0).?.right);
    try testing.expectEqual(null, place(.{ .done = .{ .percent = 0, .failed = false } }, 800, 96, 0));
    try testing.expectEqual(null, place(half, 0, 96, 0));
    try testing.expectEqual(null, place(.none, 800, 96, 0));
    // The piece is a fifth of the width, entering from the left, halfway
    // across halfway through, and wrapping around.
    const sliding: Look = .{ .sliding = .{ .failed = false } };
    try testing.expectEqual(null, place(sliding, 800, 96, 0));
    try testing.expectEqual(c.RECT{ .left = 0, .top = 0, .right = 16, .bottom = 3 }, place(sliding, 800, 96, 25).?);
    try testing.expectEqual(c.RECT{ .left = 320, .top = 0, .right = 480, .bottom = 3 }, place(sliding, 800, 96, slide_ms / 2).?);
    try testing.expectEqual(place(sliding, 800, 96, 100), place(sliding, 800, 96, slide_ms + 100));
}
