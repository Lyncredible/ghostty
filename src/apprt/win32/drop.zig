//! The text to paste for files dropped on a terminal: their paths, quoted
//! for the shell and separated by spaces, like Windows Terminal.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The kind of shell the paths are for.
pub const Shell = enum {
    /// A Windows shell such as cmd or PowerShell: paths are quoted with
    /// double quotes when needed.
    windows,

    /// A shell in WSL: paths are translated to Linux paths and quoted
    /// with single quotes when needed.
    wsl,
};

/// The text for the dropped paths. The caller owns the result.
pub fn text(alloc: Allocator, paths: []const []const u8, shell: Shell) Allocator.Error![:0]u8 {
    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    const writer = &result.writer;
    for (paths, 0..) |path, i| {
        if (i > 0) writer.writeByte(' ') catch return error.OutOfMemory;
        switch (shell) {
            .windows => writeWindows(writer, path) catch return error.OutOfMemory,
            .wsl => writeWsl(alloc, writer, path) catch return error.OutOfMemory,
        }
    }
    return result.toOwnedSliceSentinel(0);
}

fn writeWindows(writer: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    // Characters that cmd or PowerShell would treat specially. Paths can't
    // contain double quotes, so quoting the whole path is enough.
    const special = " &()[]{}^=;!'+,`~$@#%";
    if (std.mem.indexOfAny(u8, path, special) == null) return writer.writeAll(path);
    try writer.print("\"{s}\"", .{path});
}

fn writeWsl(alloc: Allocator, writer: *std.Io.Writer, path: []const u8) !void {
    const linux = try linuxPath(alloc, path);
    defer alloc.free(linux);

    const safe = for (linux) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/._-+,:@%", ch) != null)) break false;
    } else true;
    if (safe) return writer.writeAll(linux);

    // Single quotes, with any single quote written as '\''.
    try writer.writeByte('\'');
    var rest = linux;
    while (std.mem.indexOfScalar(u8, rest, '\'')) |i| {
        try writer.writeAll(rest[0..i]);
        try writer.writeAll("'\\''");
        rest = rest[i + 1 ..];
    }
    try writer.writeAll(rest);
    try writer.writeByte('\'');
}

/// The Linux path in WSL for a Windows path: drives are mounted at
/// /mnt/<drive>, and paths in a distribution's \\wsl$ or \\wsl.localhost
/// share are that distribution's own paths. Other paths (such as network
/// shares) only have their separators changed.
fn linuxPath(alloc: Allocator, path: []const u8) Allocator.Error![]u8 {
    var linux: std.ArrayList(u8) = .empty;
    errdefer linux.deinit(alloc);

    var rest = path;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        try linux.print(alloc, "/mnt/{c}", .{std.ascii.toLower(path[0])});
        rest = path[2..];
    } else for ([_][]const u8{ "\\\\wsl$\\", "\\\\wsl.localhost\\" }) |prefix| {
        if (!std.ascii.startsWithIgnoreCase(path, prefix)) continue;
        // Skip the distribution name.
        const after = path[prefix.len..];
        rest = if (std.mem.indexOfScalar(u8, after, '\\')) |i| after[i..] else "/";
        break;
    }

    for (rest) |ch| try linux.append(alloc, if (ch == '\\') '/' else ch);
    if (linux.items.len == 0) try linux.append(alloc, '/');
    return linux.toOwnedSlice(alloc);
}

test text {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        const result = try text(alloc, &.{ "C:\\Users\\me\\a.txt", "C:\\Program Files\\x" }, .windows);
        defer alloc.free(result);
        try testing.expectEqualStrings("C:\\Users\\me\\a.txt \"C:\\Program Files\\x\"", result);
    }

    {
        const result = try text(alloc, &.{
            "C:\\Users\\me\\a.txt",
            "D:\\it's here",
            "\\\\wsl$\\Ubuntu\\home\\me\\notes.md",
            "\\\\wsl.localhost\\Debian",
        }, .wsl);
        defer alloc.free(result);
        try testing.expectEqualStrings(
            "/mnt/c/Users/me/a.txt '/mnt/d/it'\\''s here' /home/me/notes.md /",
            result,
        );
    }
}
