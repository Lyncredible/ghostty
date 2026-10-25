//! Desktop notifications through a notification area icon.
//!
//! Balloon notifications from Shell_NotifyIconW are shown as toasts on
//! Windows 10 and 11. Unlike WinRT toasts they don't need an AppUserModelID
//! registered with a Start menu shortcut, which unpackaged builds don't have.
//!
//! The icon is only added while a notification is showing, and removed
//! once the user clicks or dismisses it or it times out.
const Notifier = @This();

const std = @import("std");
const CoreSurface = @import("../../Surface.zig");

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

/// The message the notification icon sends to our window.
pub const WM_NOTIFY_ICON = c.WM_APP + 2;

/// Our single icon's ID, unique for our message window.
const icon_id = 1;

// Notification icon messages and flags (shellapi.h). translate-c can't
// convert these since they're defined relative to WM_USER.
const NIN_BALLOONHIDE = c.WM_USER + 3;
const NIN_BALLOONTIMEOUT = c.WM_USER + 4;
const NIN_BALLOONUSERCLICK = c.WM_USER + 5;

/// The window that receives the icon's callback messages.
hwnd: c.HWND,

/// The icon shown in the notification area and the notification.
icon: c.HICON,

/// Whether our icon is currently in the notification area.
added: bool = false,

/// The surface that sent the last notification, focused if the user
/// clicks it. This may be freed by now, so it must only be compared
/// against live surfaces, never dereferenced directly.
surface: ?*CoreSurface = null,

pub fn init(hwnd: c.HWND, icon: c.HICON) Notifier {
    return .{ .hwnd = hwnd, .icon = icon };
}

pub fn deinit(self: *Notifier) void {
    self.remove();
}

/// Show a notification. An empty title uses the app name.
pub fn send(
    self: *Notifier,
    surface: ?*CoreSurface,
    title: []const u8,
    body: []const u8,
) void {
    var data = self.iconData();
    if (!self.added) {
        data.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP;
        if (c.Shell_NotifyIconW(c.NIM_ADD, &data) == 0) {
            log.warn("failed to add notification icon", .{});
            return;
        }
        self.added = true;

        // Version 4 gives us NIN_BALLOONUSERCLICK in the low word of
        // the callback's LPARAM.
        data.unnamed_0.uVersion = c.NOTIFYICON_VERSION_4;
        _ = c.Shell_NotifyIconW(c.NIM_SETVERSION, &data);
    }

    data.uFlags = c.NIF_INFO;
    data.dwInfoFlags = c.NIIF_USER | c.NIIF_LARGE_ICON;
    data.hBalloonIcon = self.icon;
    copyTruncated(&data.szInfoTitle, if (title.len == 0) "Ghostty" else title);
    // An empty body hides the balloon, so always show something.
    copyTruncated(&data.szInfo, if (body.len == 0) " " else body);
    if (c.Shell_NotifyIconW(c.NIM_MODIFY, &data) == 0) {
        log.warn("failed to show notification", .{});
        return;
    }
    log.debug("showing notification title={s}", .{title});
    self.surface = surface;
}

/// Handle a callback message from our icon. Returns the surface to
/// present if the user clicked the notification.
pub fn handleMessage(self: *Notifier, lparam: c.LPARAM) ?*CoreSurface {
    const event: c_uint = @as(u16, @bitCast(util.loword(lparam)));
    log.debug("notification icon event=0x{x}", .{event});
    switch (event) {
        NIN_BALLOONUSERCLICK => {
            const surface = self.surface;
            self.remove();
            return surface;
        },
        NIN_BALLOONTIMEOUT, NIN_BALLOONHIDE => self.remove(),
        else => {},
    }
    return null;
}

/// Forget a surface that is being destroyed.
pub fn surfaceDestroyed(self: *Notifier, surface: *CoreSurface) void {
    if (self.surface == surface) self.surface = null;
}

fn remove(self: *Notifier) void {
    self.surface = null;
    if (!self.added) return;
    var data = self.iconData();
    _ = c.Shell_NotifyIconW(c.NIM_DELETE, &data);
    self.added = false;
}

fn iconData(self: *const Notifier) c.NOTIFYICONDATAW {
    var data = std.mem.zeroes(c.NOTIFYICONDATAW);
    data.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    data.hWnd = self.hwnd;
    data.uID = icon_id;
    data.uCallbackMessage = WM_NOTIFY_ICON;
    data.hIcon = self.icon;
    copyTruncated(&data.szTip, "Ghostty");
    return data;
}

/// Copy UTF-8 into a fixed size UTF-16 buffer, truncating to fit
/// without splitting a surrogate pair. Invalid UTF-8 is replaced.
fn copyTruncated(buf: []u16, s: []const u8) void {
    @memset(buf, 0);
    const max = buf.len - 1;
    var i: usize = 0;
    var pos: usize = 0;
    while (pos < s.len) {
        const cp: u21, const len: usize = decode: {
            const len = std.unicode.utf8ByteSequenceLength(s[pos]) catch
                break :decode .{ 0xFFFD, 1 };
            if (pos + len > s.len) break :decode .{ 0xFFFD, 1 };
            const cp = std.unicode.utf8Decode(s[pos..][0..len]) catch
                break :decode .{ 0xFFFD, 1 };
            break :decode .{ cp, len };
        };
        pos += len;

        if (cp < 0x10000) {
            if (i + 1 > max) break;
            buf[i] = @intCast(cp);
            i += 1;
        } else {
            if (i + 2 > max) break;
            const v = cp - 0x10000;
            buf[i] = @intCast(0xD800 + (v >> 10));
            buf[i + 1] = @intCast(0xDC00 + (v & 0x3FF));
            i += 2;
        }
    }
}

test copyTruncated {
    const testing = std.testing;

    var buf: [4]u16 = undefined;
    copyTruncated(&buf, "ab");
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 0, 0 }, &buf);

    copyTruncated(&buf, "abcdef");
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 0 }, &buf);

    // A surrogate pair that doesn't fit is dropped entirely.
    copyTruncated(&buf, "ab😀");
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 0, 0 }, &buf);

    copyTruncated(&buf, "a😀");
    try testing.expectEqualSlices(u16, &.{ 'a', 0xD83D, 0xDE00, 0 }, &buf);

    copyTruncated(&buf, "a\xffb");
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0 }, &buf);
}
