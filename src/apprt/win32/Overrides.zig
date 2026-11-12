//! Configuration overrides for the first surface of a window or tab opened
//! with +new-window or +new-tab, parsed from their arguments. These match
//! the GTK apprt's overrides.
const Overrides = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../../cli.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.win32);

command: ?configpkg.Command = null,
shell_integration: ?configpkg.Config.ShellIntegration = null,
working_directory: ?[:0]const u8 = null,
title: ?[:0]const u8 = null,

pub const none: Overrides = .{};

/// Parse arguments. Everything after `-e` is the command to run. The
/// result points into memory allocated with the arena.
pub fn parse(arena: Allocator, arguments: []const []const u8) Allocator.Error!Overrides {
    var result: Overrides = .{};
    var command: std.ArrayList([:0]const u8) = .empty;
    var e_seen = false;

    for (arguments) |arg| {
        if (e_seen) {
            try command.append(arena, try arena.dupeSentinel(u8, arg, 0));
            continue;
        }

        if (std.mem.eql(u8, arg, "-e")) {
            e_seen = true;
        } else if (std.mem.cutPrefix(u8, arg, "--command=")) |v| {
            var cmd: configpkg.Command = undefined;
            cmd.parseCLI(arena, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("unable to parse command: {}", .{err});
                    continue;
                },
            };
            result.command = cmd;
        } else if (std.mem.cutPrefix(u8, arg, "--shell-integration=")) |v| {
            var parsed: struct {
                @"shell-integration": ?configpkg.Config.ShellIntegration = null,
            } = .{};
            cli.args.parseIntoField(
                @TypeOf(parsed),
                arena,
                &parsed,
                "shell-integration",
                std.mem.trim(u8, v, &std.ascii.whitespace),
            ) catch |err| {
                log.warn("unable to parse shell integration {s}: {}", .{ v, err });
                continue;
            };
            result.shell_integration = parsed.@"shell-integration";
        } else if (std.mem.cutPrefix(u8, arg, "--working-directory=")) |v| {
            // As the config reads it: `home` and `inherit` are not
            // directories of those names (the CLI passes them on as they
            // are), and a `~` is the home directory.
            var wd: configpkg.Config.WorkingDirectory = .inherit;
            wd.parseCLI(arena, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("unable to parse working directory {s}: {}", .{ v, err });
                    continue;
                },
            };
            try wd.finalize(arena);
            result.working_directory = switch (wd) {
                .path => |path| try arena.dupeSentinel(u8, path, 0),
                .home => try homeDirectory(arena),
                // What a new window or tab does without the option.
                .inherit => null,
            };
        } else if (std.mem.cutPrefix(u8, arg, "--title=")) |v| {
            result.title = try arena.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0);
        } else {
            log.debug("ignoring unsupported argument={s}", .{arg});
        }
    }

    if (command.items.len > 0) result.command = .{ .direct = command.items };
    return result;
}

/// The user's home directory, if it's known.
fn homeDirectory(arena: Allocator) Allocator.Error!?[:0]const u8 {
    var env = global.environMap() catch return null;
    defer env.deinit();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = (internal_os.home(global.io(), &env, &buf) catch return null) orelse return null;
    return try arena.dupeSentinel(u8, home, 0);
}

/// Apply the overrides to a surface's config. Strings must outlive it.
pub fn apply(self: Overrides, config: *configpkg.Config) void {
    if (self.command) |command| {
        config.command = command;
        config.@"initial-command" = null;
    }
    if (self.shell_integration) |v| config.@"shell-integration" = v;
    if (self.working_directory) |v| config.@"working-directory" = .{ .path = v };
    if (self.title) |v| config.title = v;
}

test parse {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try parse(alloc, &.{
        "--working-directory= C:\\Users\\me ",
        "--title=Build",
        "--shell-integration=none",
        "--unknown=1",
        "-e",
        "pwsh",
        "-NoLogo",
        "--title=not an option",
    });
    try testing.expectEqualStrings("C:\\Users\\me", result.working_directory.?);
    try testing.expectEqualStrings("Build", result.title.?);
    try testing.expectEqual(.none, result.shell_integration.?);
    const command = result.command.?.direct;
    try testing.expectEqual(3, command.len);
    try testing.expectEqualStrings("pwsh", command[0]);
    try testing.expectEqualStrings("--title=not an option", command[2]);

    // The words the config has for a working directory, and a quoted one.
    const home = try parse(alloc, &.{"--working-directory= home "});
    const home_dir = (try homeDirectory(alloc)).?;
    try testing.expect(std.fs.path.isAbsolute(home_dir));
    try testing.expectEqualStrings(home_dir, home.working_directory.?);
    const inherit = try parse(alloc, &.{ "--working-directory=C:\\x", "--working-directory=inherit" });
    try testing.expect(inherit.working_directory == null);
    const quoted = try parse(alloc, &.{"--working-directory=\"C:\\a b\""});
    try testing.expectEqualStrings("C:\\a b", quoted.working_directory.?);
    const tilde = try parse(alloc, &.{"--working-directory=~/src"});
    try testing.expect(std.mem.startsWith(u8, tilde.working_directory.?, home_dir));
    try testing.expect(std.mem.endsWith(u8, tilde.working_directory.?, "src"));
    const empty = try parse(alloc, &.{"--working-directory="});
    try testing.expect(empty.working_directory == null);

    const none_result = try parse(alloc, &.{});
    try testing.expect(none_result.command == null);
    try testing.expect(none_result.working_directory == null);

    // --command= is a shell command line; a bare -e leaves it, and one
    // that can't be parsed is skipped.
    const shell = try parse(alloc, &.{ "--command=cmd.exe /k echo hi", "-e" });
    try testing.expectEqualStrings("cmd.exe /k echo hi", shell.command.?.shell);
    const direct = try parse(alloc, &.{ "--command=cmd.exe", "-e", "pwsh" });
    try testing.expectEqualStrings("pwsh", direct.command.?.direct[0]);
    const bad = try parse(alloc, &.{ "--command=", "--shell-integration=nope" });
    try testing.expect(bad.command == null);
    try testing.expect(bad.shell_integration == null);
}
