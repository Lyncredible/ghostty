//! Raw, best-effort stderr writing that bypasses `std.Io` entirely.
//!
//! `std.debug.lockStderr` (and everything layered on top of it) routes
//! through `std.Options.debug_io`, whose default implementation is
//! `std.Io.Threaded`. This keeps ~70KB of unreachable code in binaries.

const std = @import("std");
const builtin = @import("builtin");

/// Write bytes to stderr using the most primitive mechanism available
/// for the target. This is best-effort: errors are ignored, since this
/// is only used for diagnostics (logging and panic messages).
///
/// Freestanding targets (e.g. wasm) have no stderr, so this is a no-op
/// there.
pub fn write(bytes: []const u8) void {
    switch (builtin.target.os.tag) {
        .freestanding, .other => {},

        .windows => writeWindows(std.os.windows.peb().ProcessParameters.hStdError, bytes),

        else => {
            const posix = std.posix;
            var i: usize = 0;
            while (i < bytes.len) {
                const rc = posix.system.write(
                    posix.STDERR_FILENO,
                    bytes[i..].ptr,
                    bytes.len - i,
                );
                switch (posix.errno(rc)) {
                    .SUCCESS => i += @as(usize, @intCast(rc)),
                    .INTR => continue,
                    else => return,
                }
            }
        },
    }
}

fn writeWindows(handle: std.os.windows.HANDLE, bytes: []const u8) void {
    const windows = std.os.windows;
    var i: usize = 0;
    while (i < bytes.len) {
        var iosb: windows.IO_STATUS_BLOCK = .{
            .u = .{ .Status = .PENDING },
            .Information = 0,
        };
        var status = windows.ntdll.NtWriteFile(
            handle,
            null, // event
            null, // APC routine
            null, // APC context
            &iosb,
            bytes[i..].ptr,
            std.math.lossyCast(u32, bytes.len - i),
            null, // byte offset
            null, // key
        );

        // Handles opened for asynchronous I/O (the pipes of MSYS2 and
        // Cygwin programs, such as Git Bash's) can return before the write
        // is done, and the kernel fills in iosb when it is, so we must wait
        // for that before returning. The handle is signaled when any of its
        // I/O completes, so we wait until iosb itself says ours did.
        if (status == .PENDING) {
            while (@atomicLoad(windows.NTSTATUS, &iosb.u.Status, .acquire) == .PENDING) {
                _ = windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null);
            }
            status = iosb.u.Status;
        }

        if (status != .SUCCESS or iosb.Information == 0) return;
        i += iosb.Information;
    }
}

test write {
    // Smoke test: must not crash. We can't assert on the output without
    // capturing stderr, which isn't worth the complexity here.
    write("");
}

test "write waits for an asynchronous pipe" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const windows = @import("windows.zig");
    const name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\ghostty-stderr-test");
    const server = windows.exp.kernel32.CreateNamedPipeW(
        name,
        PIPE_ACCESS_INBOUND,
        windows.PIPE_TYPE_BYTE,
        1,
        64,
        64,
        0,
        null,
    );
    try std.testing.expect(server != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.exp.kernel32.CloseHandle(server);

    // The client end is opened for asynchronous I/O, as MSYS2 opens the
    // pipes it gives us.
    const client = windows.exp.kernel32.CreateFileW(
        name,
        GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_OVERLAPPED,
        null,
    );
    try std.testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.exp.kernel32.CloseHandle(client);

    // Read the pipe only after a while, so writes find it full and the
    // write can't be done sooner.
    const Reader = struct {
        fn run(handle: windows.HANDLE, out: []u8) void {
            Sleep(200);
            var total: usize = 0;
            while (total < out.len) {
                var n: u32 = 0;
                if (ReadFile(handle, out[total..].ptr, @intCast(out.len - total), &n, null) == windows.FALSE) return;
                total += n;
            }
        }
    };
    var expected: [16 * 1024]u8 = undefined;
    for (&expected, 0..) |*b, i| b.* = @truncate(i *% 7);
    var received: [expected.len]u8 = @splat(0);
    const thread = try std.Thread.spawn(.{}, Reader.run, .{ server, &received });
    const start = GetTickCount64();
    writeWindows(client, &expected);
    try std.testing.expect(GetTickCount64() - start >= 150);
    thread.join();
    try std.testing.expectEqualSlices(u8, &expected, &received);
}

const PIPE_ACCESS_INBOUND = 0x00000001;
const GENERIC_WRITE = 0x40000000;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn ReadFile(
    handle: std.os.windows.HANDLE,
    buffer: [*]u8,
    len: u32,
    read: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) std.os.windows.BOOL;
