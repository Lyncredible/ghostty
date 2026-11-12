//! Crash handling for Windows. Ghostty is a GUI subsystem program there,
//! so a panic's message and stack trace go to a standard error that
//! nobody sees, and the window just disappears. Before the default panic
//! handler runs, we write a report to
//! `%LOCALAPPDATA%\ghostty\crash\crash-<date>-<time>-<pid>.txt` (UTC) and,
//! when there's no console to see the message in, tell the user where it
//! is.
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
    writeAddresses(&writer) catch {};

    var path_buf: [512]u16 = undefined;
    const path = writeReport(&path_buf, writer.buffered()) orelse return;

    // With a console (a CLI action, or launched from a terminal with one
    // attached), the default handler's output is visible there. A standard
    // error that's a file or a pipe (Git Bash's terminal, or a script that
    // captures it) gets that output too, and a dialog would only keep us
    // from exiting until someone clicks it: under Git Bash, a CLI action
    // that panicked used to hang there.
    if (GetConsoleWindow() != null or hasStderr()) return;

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

/// Whether our standard error goes somewhere: a GUI program started from
/// Explorer or the Start menu has none.
fn hasStderr() bool {
    const handle = GetStdHandle(STD_ERROR_HANDLE) orelse return false;
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return false;
    return GetFileType(handle) != FILE_TYPE_UNKNOWN;
}

/// Release builds have no debug info to print a stack trace with, so we
/// also write the raw return addresses as offsets into ghostty.exe, which
/// the build's PDB can resolve.
fn writeAddresses(writer: *std.Io.Writer) !void {
    var frames: [48]?*anyopaque = undefined;
    const count = RtlCaptureStackBackTrace(0, frames.len, &frames, null);
    const base = @intFromPtr(GetModuleHandleW(null));
    try writer.print("\r\nReturn addresses (ghostty.exe base 0x{x}):\r\n", .{base});
    for (frames[0..count]) |frame| {
        const addr = @intFromPtr(frame);
        if (addr >= base) {
            try writer.print("  0x{x} (ghostty.exe+0x{x})\r\n", .{ addr, addr - base });
        } else {
            try writer.print("  0x{x}\r\n", .{addr});
        }
    }
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
    var now: SYSTEMTIME = undefined;
    GetSystemTime(&now);
    path.append("\\");
    path.append(reportName(&name_buf, now, GetCurrentProcessId()) orelse return null);
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

/// A report's file name: when it was written (UTC) and by which process.
/// It was the time since Windows started, which comes around again after
/// a restart, and a later crash then wrote over an earlier report. The
/// names sort by time.
fn reportName(buf: []u8, now: SYSTEMTIME, pid: DWORD) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "crash-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}.txt",
        .{ now.year, now.month, now.day, now.hour, now.minute, now.second, pid },
    ) catch null;
}

test reportName {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const time: SYSTEMTIME = .{
        .year = 2026,
        .month = 3,
        .day_of_week = 0,
        .day = 9,
        .hour = 7,
        .minute = 5,
        .second = 1,
        .milliseconds = 999,
    };
    try testing.expectEqualStrings("crash-20260309-070501-4321.txt", reportName(&buf, time, 4321).?);
    // The longest it gets fits, and a buffer too small is no name.
    const last: SYSTEMTIME = .{
        .year = 30827,
        .month = 12,
        .day_of_week = 0,
        .day = 31,
        .hour = 23,
        .minute = 59,
        .second = 59,
        .milliseconds = 0,
    };
    try testing.expectEqualStrings(
        "crash-308271231-235959-4294967295.txt",
        reportName(&buf, last, std.math.maxInt(DWORD)).?,
    );
    var small: [16]u8 = undefined;
    try testing.expect(reportName(&small, time, 1) == null);
}

const SYSTEMTIME = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};

/// A NUL-terminated UTF-16 string in a fixed buffer, truncated if it
/// doesn't fit.
const Utf16Buf = struct {
    buf: []u16,
    len: usize = 0,
    overflowed: bool = false,

    /// Invalid UTF-8, or a character cut off at the end (the message is
    /// cut to fit), becomes the replacement character: a panic message
    /// can hold anything, and failing here would lose the dialog.
    fn append(self: *Utf16Buf, utf8: []const u8) void {
        var i: usize = 0;
        while (i < utf8.len) {
            const cp: u21, const len: usize = decode: {
                const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch break :decode .{ 0xFFFD, 1 };
                if (i + len > utf8.len) break :decode .{ 0xFFFD, 1 };
                const cp = std.unicode.utf8Decode(utf8[i..][0..len]) catch break :decode .{ 0xFFFD, 1 };
                break :decode .{ cp, len };
            };
            i += len;
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

    // Invalid bytes and a character cut off at the end (as the message is
    // cut to 300 bytes) are replaced, not trusted.
    var buf2: [16]u16 = undefined;
    var t: Utf16Buf = .{ .buf = &buf2 };
    t.append("a\xffb");
    t.append("\xe3\x81");
    t.append("\xe3\x81\x82");
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0xFFFD, 0xFFFD, 0x3042 }, t.slice());
}

const MB_OK: u32 = 0x0;
const MB_ICONERROR: u32 = 0x10;
const MB_SETFOREGROUND: u32 = 0x10000;

extern "kernel32" fn RtlCaptureStackBackTrace(skip: DWORD, count: DWORD, frames: [*]?*anyopaque, hash: ?*DWORD) callconv(.winapi) u16;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetFileType(file: HANDLE) callconv(.winapi) DWORD;
const FILE_TYPE_UNKNOWN = 0;
extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemTime(time: *SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
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
