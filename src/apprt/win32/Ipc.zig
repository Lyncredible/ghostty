//! IPC from the ghostty CLI (+new-window, +new-tab) to a running instance.
//!
//! Each instance has a hidden message window whose title is its app class.
//! The CLI finds it and sends WM_COPYDATA with an encoded request, which is
//! handled synchronously on the instance's main thread.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

/// The default app class, used to find instances without a custom class.
pub const default_class = "ghostty";

/// Identifies our WM_COPYDATA messages ("GHIP").
pub const magic: usize = 0x47484950;

pub const Kind = enum(u8) { new_window = 1, new_tab = 2, toggle_quick_terminal = 3 };

/// A decoded request. Slices point into the encoded data.
pub const Request = struct {
    kind: Kind,
    surface_id: u64 = 0,
    arguments: ?[]const []const u8 = null,
};

/// Encode a request: kind (1 byte), surface ID (8 bytes, little endian),
/// whether there are arguments (1 byte), then each argument followed by
/// a NUL byte.
pub fn encode(alloc: Allocator, request: Request) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, @backingInt(request.kind));
    var id: [8]u8 = undefined;
    std.mem.writeInt(u64, &id, request.surface_id, .little);
    try buf.appendSlice(alloc, &id);
    try buf.append(alloc, @intFromBool(request.arguments != null));
    if (request.arguments) |arguments| for (arguments) |arg| {
        try buf.appendSlice(alloc, arg);
        try buf.append(alloc, 0);
    };
    return try buf.toOwnedSlice(alloc);
}

pub fn decode(alloc: Allocator, data: []const u8) !Request {
    if (data.len < 10) return error.InvalidRequest;
    const kind = std.enums.fromInt(Kind, data[0]) orelse return error.InvalidRequest;
    const surface_id = std.mem.readInt(u64, data[1..9], .little);
    if (data[9] == 0) return .{ .kind = kind, .surface_id = surface_id };

    var arguments: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data[10..], 0);
    while (it.next()) |arg| {
        // The data ends with a NUL, so the last split is empty.
        if (it.index == null and arg.len == 0) break;
        try arguments.append(alloc, arg);
    }
    return .{
        .kind = kind,
        .surface_id = surface_id,
        .arguments = try arguments.toOwnedSlice(alloc),
    };
}

test "encode and decode" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const data = try encode(alloc, .{ .kind = .new_window });
        const request = try decode(alloc, data);
        try testing.expectEqual(Kind.new_window, request.kind);
        try testing.expect(request.arguments == null);
    }

    {
        const data = try encode(alloc, .{
            .kind = .new_tab,
            .surface_id = 0x1234_5678_9abc,
            .arguments = &.{ "--working-directory=C:\\Users", "", "-e", "pwsh" },
        });
        const request = try decode(alloc, data);
        try testing.expectEqual(Kind.new_tab, request.kind);
        try testing.expectEqual(0x1234_5678_9abc, request.surface_id);
        const args = request.arguments.?;
        try testing.expectEqual(4, args.len);
        try testing.expectEqualStrings("--working-directory=C:\\Users", args[0]);
        try testing.expectEqualStrings("", args[1]);
        try testing.expectEqualStrings("pwsh", args[3]);
    }

    try testing.expectError(error.InvalidRequest, decode(alloc, &.{ 9, 0 }));
}

/// The window title of an instance's message window.
pub fn windowTitle(buf: []u16, class: []const u8) ?[:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], class) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Send a request to a running instance. Returns false if there's no
/// running instance.
pub fn send(
    alloc: Allocator,
    target: apprt.ipc.Target,
    request: Request,
) (Allocator.Error || apprt.ipc.Errors)!bool {
    var title_buf: [256]u16 = undefined;
    const title: ?[*:0]const u16 = switch (target) {
        .class => |class| (windowTitle(&title_buf, class) orelse return error.IPCFailed).ptr,
        // Any instance.
        .detect => null,
    };
    const hwnd = c.FindWindowW(message_class, title) orelse {
        std.debug.print("No running Ghostty instance was found.\n", .{});
        return error.IPCFailed;
    };

    // Let the instance bring its new window to the foreground.
    var pid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != 0) _ = c.AllowSetForegroundWindow(pid);

    const data = try encode(alloc, request);
    defer alloc.free(data);
    var copy: c.COPYDATASTRUCT = .{
        .dwData = magic,
        .cbData = @intCast(data.len),
        .lpData = data.ptr,
    };
    const result = c.SendMessageW(hwnd, c.WM_COPYDATA, 0, @bitCast(@intFromPtr(&copy)));
    if (result == 0) {
        log.warn("the running instance failed the request", .{});
        return error.IPCFailed;
    }
    return true;
}

/// The class of our message window. This must match App.zig.
pub const message_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMessage");

/// The result of claiming the single instance lock for an app class.
pub const Claim = union(enum) {
    /// We're the running instance. Hold the mutex until we exit.
    primary: c.HANDLE,

    /// Another instance of the class is running (or starting).
    secondary,

    /// The lock couldn't be created; run as our own instance.
    failed,
};

/// Claim the single instance lock for an app class, a named mutex in
/// the session's namespace. Unlike looking for the message window, this
/// also detects an instance that is still starting.
pub fn claim(class: []const u8) Claim {
    const prefix = "Local\\ghostty-instance-";
    var buf: [prefix.len + 256 + 1]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, prefix) catch unreachable;
    const len = n + (std.unicode.utf8ToUtf16Le(buf[n .. buf.len - 1], class) catch return .failed);
    // Backslashes are reserved in object names, except for the namespace.
    for (buf[n..len]) |*ch| {
        if (ch.* == '\\') ch.* = '_';
    }
    buf[len] = 0;

    const mutex = c.CreateMutexW(null, c.FALSE, buf[0..len :0]) orelse return .failed;
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
        _ = c.CloseHandle(mutex);
        return .secondary;
    }
    return .{ .primary = mutex };
}

/// The arguments for a +new-window request that opens this launch's window
/// in the running instance, or null if the launch has options that the
/// running instance can't apply to a new window (such as --font-size), in
/// which case it should run as its own instance.
///
/// The working directory, if any, comes first so that an explicit
/// --working-directory argument takes precedence.
pub fn launchArguments(
    alloc: Allocator,
    args: []const []const u8,
    working_directory: ?[]const u8,
) Allocator.Error!?[]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    if (working_directory) |wd| {
        try result.append(alloc, try std.fmt.allocPrint(alloc, "--working-directory={s}", .{wd}));
    }

    // The options that Overrides applies to the new window.
    const supported = [_][]const u8{
        "--command=",
        "--working-directory=",
        "--title=",
        "--shell-integration=",
    };
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-e")) {
            try result.appendSlice(alloc, args[i..]);
            break;
        }

        // The class selects the instance.
        if (std.mem.startsWith(u8, arg, "--class=")) continue;

        for (supported) |prefix| {
            if (std.mem.startsWith(u8, arg, prefix)) break;
        } else return null;
        try result.append(alloc, arg);
    }
    return try result.toOwnedSlice(alloc);
}

test launchArguments {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const args = (try launchArguments(alloc, &.{}, "C:\\src")).?;
        try testing.expectEqual(1, args.len);
        try testing.expectEqualStrings("--working-directory=C:\\src", args[0]);
    }

    {
        const args = (try launchArguments(alloc, &.{
            "--class=dev",
            "--title=hi",
            "-e",
            "pwsh",
            "--font-size=20",
        }, null)).?;
        try testing.expectEqual(4, args.len);
        try testing.expectEqualStrings("--title=hi", args[0]);
        try testing.expectEqualStrings("-e", args[1]);
        try testing.expectEqualStrings("--font-size=20", args[3]);
    }

    try testing.expect(try launchArguments(alloc, &.{"--font-size=20"}, null) == null);
    try testing.expect(try launchArguments(alloc, &.{"--title"}, null) == null);
}

/// Open this launch's window in the running instance of the class, waiting
/// briefly for it to finish starting. Returns false if there's no running
/// instance to take it.
pub fn forwardLaunch(
    alloc: Allocator,
    class: []const u8,
    arguments: []const []const u8,
) bool {
    var title_buf: [256]u16 = undefined;
    const title = windowTitle(&title_buf, class) orelse return false;

    // The instance holds the lock before it creates its message window.
    const hwnd = for (0..100) |_| {
        if (c.FindWindowW(message_class, title.ptr)) |hwnd| break hwnd;
        c.Sleep(50);
    } else {
        log.warn("another instance holds the lock but has no message window", .{});
        return false;
    };

    var pid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != 0) _ = c.AllowSetForegroundWindow(pid);

    const data = encode(alloc, .{ .kind = .new_window, .arguments = arguments }) catch return false;
    defer alloc.free(data);
    var copy: c.COPYDATASTRUCT = .{
        .dwData = magic,
        .cbData = @intCast(data.len),
        .lpData = data.ptr,
    };
    return c.SendMessageW(hwnd, c.WM_COPYDATA, 0, @bitCast(@intFromPtr(&copy))) != 0;
}
