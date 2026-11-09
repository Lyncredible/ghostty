//! The shells a new tab or window can start with: the configured command,
//! the Windows shells that are installed, and each registered WSL
//! distribution. The tab bar's shell menu and the main menu list them.
const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../../global.zig");
const configpkg = @import("../../config.zig");
const path = @import("../../os/path.zig");

const util = @import("util.zig");
const c = util.c;

pub const Shell = struct {
    label: []const u8,

    /// The command to run, or null for the configured one.
    command: ?configpkg.Command,
};

/// List the shells, the configured command first. Everything is allocated
/// with `alloc`, which should be an arena.
pub fn list(alloc: Allocator) ![]const Shell {
    var shells: std.ArrayList(Shell) = .empty;
    try shells.append(alloc, .{ .label = "Configured default", .command = null });

    const candidates = .{
        .{ "Command Prompt", "cmd.exe" },
        .{ "Windows PowerShell", "powershell.exe" },
        .{ "PowerShell", "pwsh.exe" },
        .{ "WSL (default distribution)", "wsl.exe" },
    };
    var wsl_exe: ?[:0]const u8 = null;
    var env = try global.environMap();
    defer env.deinit();
    inline for (candidates) |candidate| {
        const wsl = comptime std.mem.eql(u8, candidate[1], "wsl.exe");
        if (!wsl or hasWslDistribution()) {
            if (path.expand(global.io(), alloc, &env, candidate[1]) catch null) |exe| {
                const argv = try alloc.alloc([:0]const u8, 1);
                argv[0] = try alloc.dupeSentinel(u8, exe, 0);
                try shells.append(alloc, .{ .label = candidate[0], .command = .{ .direct = argv } });
                if (wsl) wsl_exe = argv[0];
            }
        }
    }
    if (wsl_exe) |exe| try appendWslDistributions(alloc, exe, &shells);
    return shells.items;
}

fn openWslRegistry() ?c.HKEY {
    var current_user: c.HKEY = null;
    if (c.RegOpenCurrentUser(c.KEY_READ, &current_user) != c.ERROR_SUCCESS) return null;
    defer _ = c.RegCloseKey(current_user);

    var key: c.HKEY = null;
    if (c.RegOpenKeyExW(
        current_user,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"),
        0,
        c.KEY_READ,
        &key,
    ) != c.ERROR_SUCCESS) return null;
    return key;
}

/// WSL may be installed without a registered distribution. In that case
/// launching bare wsl.exe only displays an error instead of a shell.
fn hasWslDistribution() bool {
    const key = openWslRegistry() orelse return false;
    defer _ = c.RegCloseKey(key);

    var name: [256]u16 = undefined;
    var name_len: c.DWORD = name.len;
    return c.RegEnumKeyExW(key, 0, &name, &name_len, null, null, null, null) == c.ERROR_SUCCESS;
}

/// Add each registered WSL distribution as its own shell.
fn appendWslDistributions(
    alloc: Allocator,
    wsl_exe: [:0]const u8,
    shells: *std.ArrayList(Shell),
) !void {
    const root = openWslRegistry() orelse return;
    defer _ = c.RegCloseKey(root);

    var index: c.DWORD = 0;
    while (true) : (index += 1) {
        var key_name: [256]u16 = undefined;
        var key_len: c.DWORD = key_name.len;
        const result = c.RegEnumKeyExW(root, index, &key_name, &key_len, null, null, null, null);
        if (result == c.ERROR_NO_MORE_ITEMS) break;
        if (result != c.ERROR_SUCCESS) continue;
        key_name[key_len] = 0;

        var distro_key: c.HKEY = null;
        if (c.RegOpenKeyExW(root, &key_name, 0, c.KEY_READ, &distro_key) != c.ERROR_SUCCESS) continue;
        defer _ = c.RegCloseKey(distro_key);

        var value_type: c.DWORD = 0;
        var value: [2048]u16 = undefined;
        var value_len: c.DWORD = @sizeOf(@TypeOf(value));
        if (c.RegQueryValueExW(
            distro_key,
            std.unicode.utf8ToUtf16LeStringLiteral("DistributionName"),
            null,
            &value_type,
            @ptrCast(&value),
            &value_len,
        ) != c.ERROR_SUCCESS or value_type != c.REG_SZ) continue;
        const units = @min(@as(usize, @intCast(value_len / 2)), value.len - 1);
        value[units] = 0;
        const name = try util.utf8Alloc(alloc, std.mem.sliceTo(value[0 .. units + 1], 0));
        if (name.len == 0) continue;

        const argv = try alloc.alloc([:0]const u8, 3);
        argv[0] = wsl_exe;
        argv[1] = "-d";
        argv[2] = name;
        try shells.append(alloc, .{
            .label = try std.fmt.allocPrint(alloc, "WSL: {s}", .{name}),
            .command = .{ .direct = argv },
        });
    }
}

test list {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const shells = try list(arena.allocator());

    // The configured command comes first, then what's installed: every
    // Windows has cmd, found on the PATH as a full path.
    try testing.expectEqualStrings("Configured default", shells[0].label);
    try testing.expect(shells[0].command == null);
    var cmd: ?[:0]const u8 = null;
    for (shells[1..]) |shell| {
        const argv = shell.command.?.direct;
        try testing.expect(argv.len > 0);
        try testing.expect(std.fs.path.isAbsolute(argv[0]));
        if (std.mem.eql(u8, shell.label, "Command Prompt")) cmd = argv[0];
        // A distribution runs the WSL found above with its name.
        if (std.mem.startsWith(u8, shell.label, "WSL: ")) {
            try testing.expectEqual(@as(usize, 3), argv.len);
            try testing.expectEqualStrings("-d", argv[1]);
            try testing.expectEqualStrings(shell.label["WSL: ".len..], argv[2]);
        }
    }
    try testing.expect(std.ascii.endsWithIgnoreCase(cmd.?, "\\cmd.exe"));
}
