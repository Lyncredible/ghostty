const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Search for "cmd" in the PATH and return the absolute path. This will
/// always allocate if there is a non-null result. The caller must free the
/// resulting value.
pub fn expand(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
    cmd: []const u8,
) !?[]u8 {
    // If the command already contains a slash, then we return it as-is
    // because it is assumed to be absolute or relative.
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return try alloc.dupe(u8, cmd);
    }

    const PATH = environ_map.get("PATH") orelse return null;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, PATH, std.fs.path.delimiter);
    var seen_eacces = false;
    while (it.next()) |search_path| {
        // A directory may end with a separator already, as Windows' PATH
        // entries often do (C:\Windows\System32\WindowsPowerShell\v1.0\).
        const sep_len: usize = if (std.fs.path.isSep(search_path[search_path.len - 1])) 0 else 1;

        // We need enough space in our path buffer to store this
        const path_len = search_path.len + sep_len + cmd.len;
        if (path_buf.len <= path_len) return error.PathTooLong;

        // Copy in the full path
        @memcpy(path_buf[0..search_path.len], search_path);
        if (sep_len == 1) path_buf[search_path.len] = std.fs.path.sep;
        @memcpy(path_buf[search_path.len + sep_len ..][0..cmd.len], cmd);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0];

        if (builtin.target.os.tag == .windows) {
            switch (windowsKind(alloc, full_path)) {
                .file => return try alloc.dupe(u8, full_path),
                .access_denied => seen_eacces = true,
                .directory, .missing => {},
            }
            continue;
        }

        // Stat it
        const f = std.Io.Dir.cwd().openFile(
            io,
            full_path,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            // An entry that isn't a directory, or can't be the name of
            // one (on Windows, say one with a stray quote), has nothing
            // for us, like one that doesn't exist: a single bad entry
            // mustn't hide the rest of PATH.
            error.NotDir, error.BadPathName, error.NameTooLong => continue,
            error.AccessDenied => {
                // Accumulate this and return it later so we can try other
                // paths that we have access to.
                seen_eacces = true;
                continue;
            },
            else => return err,
        };
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.kind != .directory and isExecutable(stat.permissions)) {
            return try alloc.dupe(u8, full_path);
        }
    }

    if (seen_eacces) return error.AccessDenied;

    return null;
}

/// What a PATH candidate is, on Windows, read from its attributes rather
/// than by opening it. A Microsoft Store app's command, like the pwsh.exe
/// that PowerShell from the Store puts in WindowsApps, is an app execution
/// alias: a reparse point that only CreateProcess follows, so opening it
/// fails (ERROR_CANT_ACCESS_FILE). Windows has no executable bit to check.
fn windowsKind(
    alloc: Allocator,
    full_path: []const u8,
) enum { file, directory, missing, access_denied } {
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, full_path) catch return .missing;
    defer alloc.free(path_w);
    const attributes = GetFileAttributesW(path_w);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        return switch (std.os.windows.GetLastError()) {
            .ACCESS_DENIED => .access_denied,
            else => .missing,
        };
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY != 0) return .directory;
    return .file;
}

const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;

fn isExecutable(perms: std.Io.File.Permissions) bool {
    return switch (builtin.target.os.tag) {
        .windows => true,
        else => posix: {
            break :posix switch (std.posix.mode_t) {
                u0 => true,
                else => perms.toMode() & 0o0111 != 0,
            };
        },
    };
}

// `uname -n` is the *nix equivalent of `hostname.exe` on Windows
test "expand: hostname" {
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    const executable = if (builtin.target.os.tag == .windows) "hostname.exe" else "uname";
    const path = (try expand(testing.io, testing.allocator, &environ_map, executable)).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len > executable.len);
}

test "expand: directory ending with a separator" {
    const alloc = testing.allocator;
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    const executable = if (builtin.target.os.tag == .windows) "hostname.exe" else "uname";
    const found = (try expand(testing.io, alloc, &environ_map, executable)).?;
    defer alloc.free(found);

    // Search only its directory, with a separator at the end.
    const dir = std.fs.path.dirname(found).?;
    const search = try std.mem.concat(alloc, u8, &.{ dir, &.{std.fs.path.sep} });
    defer alloc.free(search);
    var only: std.process.Environ.Map = .init(alloc);
    defer only.deinit();
    try only.put("PATH", search);

    const path = (try expand(testing.io, alloc, &only, executable)).?;
    defer alloc.free(path);
    try testing.expectEqualStrings(found, path);
}

test "expand: skips PATH entries that aren't valid paths" {
    const alloc = testing.allocator;
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    const executable = if (builtin.target.os.tag == .windows) "hostname.exe" else "uname";
    const found = (try expand(testing.io, alloc, &environ_map, executable)).?;
    defer alloc.free(found);

    // Entries a broken PATH can have, before the directory that has the
    // program: a stray quote (seen in a machine's PATH on Windows, where
    // a quote can't be part of a file name), a file used as a directory,
    // and other characters Windows forbids.
    const delim = [_]u8{std.fs.path.delimiter};
    const search = try std.mem.concat(alloc, u8, &.{
        "C:\\Program Files\\Some Tool\"", &delim,
        found,                            &delim,
        "bad|name<>?*",                   &delim,
        std.fs.path.dirname(found).?,
    });
    defer alloc.free(search);
    var only: std.process.Environ.Map = .init(alloc);
    defer only.deinit();
    try only.put("PATH", search);

    const path = (try expand(testing.io, alloc, &only, executable)).?;
    defer alloc.free(path);
    try testing.expectEqualStrings(found, path);
}

test "expand: app execution alias" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    const local = environ_map.get("LOCALAPPDATA") orelse return error.SkipZigTest;
    const apps = try std.fs.path.join(alloc, &.{ local, "Microsoft", "WindowsApps" });
    defer alloc.free(apps);

    // The Store's aliases, which can't be opened like a file. Use one
    // this machine has.
    const alias = for ([_][]const u8{ "winget.exe", "pwsh.exe", "python.exe", "wt.exe" }) |name| {
        const full = try std.fs.path.join(alloc, &.{ apps, name });
        defer alloc.free(full);
        if (windowsKind(alloc, full) == .file) break name;
    } else return error.SkipZigTest;

    var only: std.process.Environ.Map = .init(alloc);
    defer only.deinit();
    try only.put("PATH", apps);
    const path = (try expand(testing.io, alloc, &only, alias)).?;
    defer alloc.free(path);
    try testing.expect(std.ascii.endsWithIgnoreCase(path, alias));
}

test "expand: skips a directory with the command's name" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "tool.exe", .default_dir);
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var only: std.process.Environ.Map = .init(alloc);
    defer only.deinit();
    try only.put("PATH", dir);
    try testing.expect(try expand(testing.io, alloc, &only, "tool.exe") == null);
}

test "expand: does not exist" {
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    const path = try expand(testing.io, testing.allocator, &environ_map, "thisreallyprobablydoesntexist123");
    try testing.expect(path == null);
}

test "expand: slash" {
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    const path = (try expand(testing.io, testing.allocator, &environ_map, "foo/env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len == 7);
}

test "expand: reject path without room for null terminator" {
    var environ_map: std.process.Environ.Map =
        .init(testing.allocator);
    defer environ_map.deinit();

    // The directory, separator and command exactly fill the buffer,
    // leaving no room for the null terminator.
    var search_path: [std.Io.Dir.max_path_bytes - "/x".len]u8 = undefined;
    @memset(&search_path, 'a');
    try environ_map.put("PATH", &search_path);

    try testing.expectError(
        error.PathTooLong,
        expand(testing.io, testing.allocator, &environ_map, "x"),
    );
}
