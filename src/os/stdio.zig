//! The standard handles as `std.Io.File`s that can be written to and read
//! from whichever way their handles were opened.
//!
//! On Windows, `std.Io.File.stdout()` and friends assume handles opened for
//! synchronous I/O. The pipes of MSYS2 and Cygwin programs (Git Bash's
//! among them) are opened for asynchronous I/O instead, so a write to a
//! full pipe returns `STATUS_PENDING`, which Zig's synchronous path treats
//! as unreachable: `ghostty +show-config --default --docs | less` in Git
//! Bash stopped after 69 KB. Marking such handles nonblocking makes Zig
//! wait for the I/O to complete.

const std = @import("std");
const builtin = @import("builtin");

pub fn stdin() std.Io.File {
    return fix(.stdin());
}

pub fn stdout() std.Io.File {
    return fix(.stdout());
}

pub fn stderr() std.Io.File {
    return fix(.stderr());
}

/// Returns the file with its nonblocking flag set to how its handle was
/// opened. Elsewhere it returns the file as it is.
pub fn fix(file: std.Io.File) std.Io.File {
    if (comptime builtin.target.os.tag != .windows) return file;

    const windows = std.os.windows;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var mode: windows.FILE.MODE = undefined;
    if (windows.ntdll.NtQueryInformationFile(
        file.handle,
        &iosb,
        &mode,
        @sizeOf(windows.FILE.MODE),
        .Mode,
    ) != .SUCCESS) return file;

    var result = file;
    result.flags.nonblocking = mode.IO == .ASYNCHRONOUS;
    return result;
}

/// Uses `fix` for the stderr that `std.debug.lockStderr` (and so our
/// logging) writes to.
pub fn fixDebugStderr() void {
    if (comptime builtin.target.os.tag != .windows) return;
    const locked = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    locked.file_writer.file = fix(locked.file_writer.file);
}

test "fix keeps a synchronous file synchronous" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "file", .{});
    defer file.close(std.testing.io);
    try std.testing.expect(!fix(file).flags.nonblocking);
}

test "fix marks an asynchronous pipe nonblocking" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const windows = @import("windows.zig");
    var name_buf: [96]u16 = undefined;
    const handle = windows.exp.kernel32.CreateNamedPipeW(
        windows.testPipeName(&name_buf, "stdio"),
        windows.PIPE_ACCESS_OUTBOUND | windows.FILE_FLAG_OVERLAPPED,
        windows.PIPE_TYPE_BYTE,
        1,
        4096,
        4096,
        0,
        null,
    );
    try std.testing.expect(handle != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.exp.kernel32.CloseHandle(handle);

    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    try std.testing.expect(fix(file).flags.nonblocking);
}
