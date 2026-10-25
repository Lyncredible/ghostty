//! Helpers for running shells in WSL (Windows Subsystem for Linux) from
//! Windows.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Whether an executable is the WSL launcher (wsl or wsl.exe).
pub fn isWsl(arg0: []const u8) bool {
    var exe = std.fs.path.basenameWindows(arg0);
    if (std.ascii.endsWithIgnoreCase(exe, ".exe")) exe = exe[0 .. exe.len - 4];
    return std.ascii.eqlIgnoreCase(exe, "wsl");
}

/// The distribution chosen in a wsl.exe command line with -d or
/// --distribution, if any. Returns null if the command isn't wsl.exe.
pub fn distributionFromArgs(args: []const []const u8) ?[]const u8 {
    if (args.len == 0 or !isWsl(args[0])) return null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // Everything after these is the command to run in WSL.
        if (std.mem.eql(u8, arg, "--") or
            std.mem.eql(u8, arg, "-e") or
            std.mem.eql(u8, arg, "--exec")) return null;
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--distribution")) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
    }
    return null;
}

test distributionFromArgs {
    const testing = std.testing;
    try testing.expectEqualStrings("Ubuntu", distributionFromArgs(&.{ "wsl.exe", "-d", "Ubuntu" }).?);
    try testing.expectEqualStrings("Debian", distributionFromArgs(&.{
        "C:\\Windows\\System32\\WSL.EXE",
        "--cd",
        "~",
        "--distribution",
        "Debian",
        "--exec",
        "/bin/sh",
    }).?);
    try testing.expect(distributionFromArgs(&.{"wsl.exe"}) == null);
    try testing.expect(distributionFromArgs(&.{ "wsl.exe", "-d" }) == null);
    try testing.expect(distributionFromArgs(&.{ "wsl.exe", "--", "ls", "-d", "x" }) == null);
    try testing.expect(distributionFromArgs(&.{ "cmd.exe", "-d", "x" }) == null);
}

/// The Windows path for a Linux path inside a WSL distribution, such as
/// \\wsl$\Ubuntu\home\me for /home/me. Windows 10 and 11 both support the
/// \\wsl$ prefix. The caller owns the returned memory.
pub fn windowsPath(alloc: Allocator, distribution: []const u8, path: []const u8) Allocator.Error![]u8 {
    const result = try std.fmt.allocPrint(alloc, "\\\\wsl$\\{s}{s}", .{
        distribution,
        if (path.len == 0) "/" else path,
    });
    std.mem.replaceScalar(u8, result[2..], '/', '\\');
    return result;
}

test windowsPath {
    const testing = std.testing;
    const alloc = testing.allocator;

    const home = try windowsPath(alloc, "Ubuntu", "/home/me");
    defer alloc.free(home);
    try testing.expectEqualStrings("\\\\wsl$\\Ubuntu\\home\\me", home);

    const root = try windowsPath(alloc, "Ubuntu", "/");
    defer alloc.free(root);
    try testing.expectEqualStrings("\\\\wsl$\\Ubuntu\\", root);
}

/// The name of the user's default WSL distribution, from the registry.
/// The caller owns the returned memory.
pub fn defaultDistribution(alloc: Allocator) !?[]u8 {
    if (comptime builtin.target.os.tag != .windows) return null;

    const lxss = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss",
    );
    var guid: [64]u16 = undefined;
    const guid_len = regString(lxss, std.unicode.utf8ToUtf16LeStringLiteral("DefaultDistribution"), &guid) orelse
        return null;

    // The distribution's key is Lxss\{guid}.
    var key: [lxss.len + 1 + guid.len + 1]u16 = undefined;
    @memcpy(key[0..lxss.len], lxss);
    key[lxss.len] = '\\';
    @memcpy(key[lxss.len + 1 ..][0..guid_len], guid[0..guid_len]);
    key[lxss.len + 1 + guid_len] = 0;

    var name: [256]u16 = undefined;
    const name_len = regString(
        key[0 .. lxss.len + 1 + guid_len :0],
        std.unicode.utf8ToUtf16LeStringLiteral("DistributionName"),
        &name,
    ) orelse return null;
    return try std.unicode.wtf16LeToWtf8Alloc(alloc, name[0..name_len]);
}

/// Read a string value under HKEY_CURRENT_USER, returning its length in
/// code units without the terminator.
fn regString(key: [:0]const u16, value: [:0]const u16, buf: []u16) ?usize {
    var size: u32 = @intCast(buf.len * 2);
    const result = RegGetValueW(
        HKEY_CURRENT_USER,
        key.ptr,
        value.ptr,
        RRF_RT_REG_SZ,
        null,
        buf.ptr,
        &size,
    );
    if (result != 0 or size < 2) return null;
    return size / 2 - 1;
}

const HKEY_CURRENT_USER: usize = @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))));
const RRF_RT_REG_SZ = 0x00000002;
extern "advapi32" fn RegGetValueW(
    key: usize,
    sub_key: ?[*:0]const u16,
    value: ?[*:0]const u16,
    flags: u32,
    type: ?*u32,
    data: ?*anyopaque,
    size: ?*u32,
) callconv(.winapi) i32;

test defaultDistribution {
    // This depends on the machine, so only check that it doesn't fail.
    const alloc = std.testing.allocator;
    if (try defaultDistribution(alloc)) |name| {
        defer alloc.free(name);
        try std.testing.expect(name.len > 0);
    }
}
