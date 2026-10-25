//! Configuration overrides for the first surface of a window or tab opened
//! with +new-window or +new-tab, parsed from their arguments. These match
//! the GTK apprt's overrides.
const Overrides = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../../cli.zig");
const configpkg = @import("../../config.zig");

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
            result.working_directory = try arena.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0);
        } else if (std.mem.cutPrefix(u8, arg, "--title=")) |v| {
            result.title = try arena.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0);
        } else {
            log.debug("ignoring unsupported argument={s}", .{arg});
        }
    }

    if (command.items.len > 0) result.command = .{ .direct = command.items };
    return result;
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

    const none_result = try parse(alloc, &.{});
    try testing.expect(none_result.command == null);
    try testing.expect(none_result.working_directory == null);
}
