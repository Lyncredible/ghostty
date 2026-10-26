//! Crash handling for Windows. Ghostty is a GUI subsystem program there,
//! so a panic's message and stack trace go to a standard error that
//! nobody sees, and the window just disappears. Before the default panic
//! handler runs, we write a report to
//! `%LOCALAPPDATA%\ghostty\crash\crash-<time>.txt` and, when there's no
//! console to see the message in, tell the user where it is.
//!
//! This runs while panicking, so it doesn't allocate: it only uses fixed
//! buffers and the Win32 API.
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");

const BOOL = std.os.windows.BOOL;
const DWORD = std.os.windows.DWORD;
const HANDLE = std.os.windows.HANDLE;

/// Set once we start handling a panic, so that a panic while writing the
/// report goes straight to the default handler.
var panicking = std.atomic.Value(bool).init(false);

/// The report: the message and stack trace. Static, since the stack may
/// be in a bad state.
var report_buf: [64 * 1024]u8 = undefined;

pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (!panicking.swap(true, .acq_rel)) report(msg, first_trace_addr orelse @returnAddress());
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn report(msg: []const u8, first_trace_addr: usize) void {
    var writer: std.Io.Writer = .fixed(&report_buf);
    writer.print("Ghostty {s} crashed.\r\n\r\npanic: {s}\r\n\r\n", .{
        build_config.version_string,
        msg,
    }) catch {};
    std.debug.writeCurrentStackTrace(
        .{ .first_address = first_trace_addr },
        .{ .writer = &writer, .mode = .no_color },
    ) catch {};

    var path_buf: [512]u16 = undefined;
    const path = writeReport(&path_buf, writer.buffered()) orelse return;

    // With a console (a CLI action, or launched from a terminal with one
    // attached), the default handler's output is visible there.
    if (GetConsoleWindow() != null) return;

    var text_buf: [1024]u16 = undefined;
    var text: Utf16Buf = .{ .buf = &text_buf };
    text.append("Ghostty crashed: ");
    text.append(msg[0..@min(msg.len, 300)]);
    text.append("\n\nA report with the details was saved to:\n");
    text.appendUtf16(path);
    _ = MessageBoxW(
        null,
        text.slice(),
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
    );
}

/// Write the report to the crash directory, returning its path.
fn writeReport(path_buf: []u16, contents: []const u8) ?[:0]const u16 {
    var path: Utf16Buf = .{ .buf = path_buf };
    const n = GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"),
        path_buf.ptr,
        @intCast(path_buf.len),
    );
    if (n == 0 or n >= path_buf.len) return null;
    path.len = n;

    path.append("\\ghostty");
    _ = CreateDirectoryW(path.slice(), null);
    path.append("\\crash");
    _ = CreateDirectoryW(path.slice(), null);

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "\\crash-{d}.txt", .{GetTickCount64()}) catch return null;
    path.append(name);
    if (path.overflowed) return null;

    const GENERIC_WRITE: DWORD = 0x40000000;
    const CREATE_ALWAYS: DWORD = 2;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
    const file = CreateFileW(path.slice(), GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (file == std.os.windows.INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(file);
    var written: DWORD = 0;
    if (WriteFile(file, contents.ptr, @intCast(contents.len), &written, null) == .FALSE) return null;
    return path.slice();
}

/// A NUL-terminated UTF-16 string in a fixed buffer, truncated if it
/// doesn't fit.
const Utf16Buf = struct {
    buf: []u16,
    len: usize = 0,
    overflowed: bool = false,

    fn append(self: *Utf16Buf, utf8: []const u8) void {
        var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
        while (it.nextCodepoint()) |cp| {
            var units: [2]u16 = undefined;
            const count: usize = if (cp < 0x10000) one: {
                units[0] = @intCast(cp);
                break :one 1;
            } else two: {
                const v = cp - 0x10000;
                units[0] = @intCast(0xD800 + (v >> 10));
                units[1] = @intCast(0xDC00 + (v & 0x3FF));
                break :two 2;
            };
            self.appendUtf16(units[0..count]);
        }
    }

    fn appendUtf16(self: *Utf16Buf, units: []const u16) void {
        for (units) |unit| {
            if (self.len + 1 >= self.buf.len) {
                self.overflowed = true;
                return;
            }
            self.buf[self.len] = unit;
            self.len += 1;
        }
    }

    fn slice(self: *Utf16Buf) [:0]const u16 {
        self.buf[self.len] = 0;
        return self.buf[0..self.len :0];
    }
};

test Utf16Buf {
    const testing = std.testing;
    var buf: [8]u16 = undefined;
    var s: Utf16Buf = .{ .buf = &buf };
    s.append("ab");
    s.append("\u{1F600}");
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 0xD83D, 0xDE00 }, s.slice());
    s.append("cdefg");
    try testing.expect(s.overflowed);
    try testing.expectEqual(@as(usize, 7), s.slice().len);
}

const MB_OK: u32 = 0x0;
const MB_ICONERROR: u32 = 0x10;
const MB_SETFOREGROUND: u32 = 0x10000;

extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: DWORD,
    share: DWORD,
    security: ?*anyopaque,
    disposition: DWORD,
    flags: DWORD,
    template: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, len: DWORD, written: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "user32" fn MessageBoxW(hwnd: ?HANDLE, text: [*:0]const u16, caption: [*:0]const u16, flags: u32) callconv(.winapi) i32;
