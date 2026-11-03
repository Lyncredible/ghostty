//! Checks for links that come from terminal output (OSC 8 hyperlinks, and
//! text that a `link` config entry matched) before we give them to the
//! Windows shell. Any program can print these, and ShellExecute runs
//! programs and scripts, so this follows the macOS app's policy (see
//! macos/Sources/Helpers/UntrustedURL.swift): web and mail links open,
//! other schemes ask first, and local files open only if they're on this
//! machine and their type can't run code.
const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const c = util.c;

pub const Reason = enum {
    malformed,
    unsafe_characters,
    invalid_web_url,
    remote_file,
    inaccessible_file,
    unsafe_file,

    pub fn message(self: Reason) []const u8 {
        return switch (self) {
            .malformed => "The target is not an absolute URL or path.",
            .unsafe_characters => "The target contains invisible or line-breaking characters.",
            .invalid_web_url => "The web target does not contain a valid host.",
            .remote_file => "The target is a file on another computer.",
            .inaccessible_file => "The local target does not exist or is not a regular file or folder.",
            .unsafe_file => "Opening this local target could run code.",
        };
    }
};

pub const Decision = union(enum) {
    /// Open this target (a URL, or the checked file's full path).
    allow: [:0]u16,

    /// Ask before opening this target, which goes to whatever app is
    /// registered for its scheme.
    confirm: [:0]u16,

    /// Don't open it.
    deny: Reason,

    pub fn deinit(self: Decision, alloc: Allocator) void {
        switch (self) {
            .allow, .confirm => |target| alloc.free(target),
            .deny => {},
        }
    }
};

/// Decide what to do with an untrusted link. `plain_paths` allows targets
/// without a scheme to be checked as local paths (text matched by a `link`
/// entry can be a path); OSC 8 targets must be URLs.
pub fn check(alloc: Allocator, value: []const u8, plain_paths: bool) Allocator.Error!Decision {
    if (value.len == 0) return .{ .deny = .malformed };
    if (hasUnsafeCharacters(value)) return .{ .deny = .unsafe_characters };

    const scheme = schemeOf(value) orelse {
        if (!plain_paths) return .{ .deny = .malformed };
        const path = try util.utf16Alloc(alloc, value);
        defer alloc.free(path);
        return try checkPath(alloc, path);
    };
    const rest = value[scheme.len + 1 ..];

    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        // Values such as "https:relative" have a scheme but no host.
        if (!std.mem.startsWith(u8, rest, "//")) return .{ .deny = .invalid_web_url };
        const after = rest[2..];
        const authority = after[0 .. std.mem.indexOfAny(u8, after, "/?#\\") orelse after.len];
        const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
        if (host.len == 0 or host[0] == ':') return .{ .deny = .invalid_web_url };
        return .{ .allow = try util.utf16Alloc(alloc, value) };
    }

    if (std.ascii.eqlIgnoreCase(scheme, "mailto")) {
        if (rest.len == 0) return .{ .deny = .malformed };
        return .{ .allow = try util.utf16Alloc(alloc, value) };
    }

    if (std.ascii.eqlIgnoreCase(scheme, "file")) return try checkFileUrl(alloc, value);

    // Another scheme goes to whatever app registered it, which the user
    // should see before it opens.
    return .{ .confirm = try util.utf16Alloc(alloc, value) };
}

/// The scheme of a URL, without its colon, or null if there's none. A
/// single letter is a drive (`C:\...`), not a scheme.
fn schemeOf(value: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    if (colon < 2 or !std.ascii.isAlphabetic(value[0])) return null;
    for (value[1..colon]) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
        else => return null,
    };
    return value[0..colon];
}

fn checkFileUrl(alloc: Allocator, value: []const u8) Allocator.Error!Decision {
    // Only this machine: an empty host or localhost. Anything else would
    // make Windows connect to that host (and sign in to it) to check it.
    const rest = value["file:".len..];
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const host = after[0 .. std.mem.indexOfAny(u8, after, "/\\") orelse after.len];
        if (host.len > 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) {
            return .{ .deny = .remote_file };
        }
    }
    if (std.mem.indexOfAny(u8, value, "?#") != null) return .{ .deny = .malformed };

    const url = try util.utf16Alloc(alloc, value);
    defer alloc.free(url);
    var buf: [32 * 1024]u16 = undefined;
    var len: u32 = buf.len;
    if (PathCreateFromUrlW(url.ptr, &buf, &len, 0) < 0) return .{ .deny = .malformed };
    const path = buf[0..len];

    // Percent-encoding can hide characters that the first check missed.
    for (path) |unit| if (isUnsafeCharacter(unit)) return .{ .deny = .unsafe_characters };
    return try checkPath(alloc, path);
}

fn checkPath(alloc: Allocator, path: []const u16) Allocator.Error!Decision {
    // Network paths (and \\?\ and \\.\ device paths) would make Windows
    // connect to another machine or open a device just to check them.
    if (path.len >= 2 and isSep(path[0]) and isSep(path[1])) return .{ .deny = .remote_file };

    // Only absolute drive paths. A colon anywhere else names an alternate
    // data stream.
    if (path.len < 3 or path[1] != ':' or !isSep(path[2]) or
        path[0] > 0x7f or !std.ascii.isAlphabetic(@intCast(path[0])))
    {
        return .{ .deny = .malformed };
    }
    if (std.mem.indexOfScalar(u16, path[2..], ':') != null) return .{ .deny = .malformed };

    // Look at the file itself, so that the name Windows uses decides,
    // rather than how the link spelled it: trailing dots and spaces, short
    // (8.3) names, and symbolic links all resolve here.
    // Windows follows symbolic links to network shares, so opening the
    // path below could connect to one.
    if (try checkLinks(alloc, path, max_links)) |reason| return .{ .deny = reason };

    const path_z = try alloc.dupeSentinel(u16, path, 0);
    defer alloc.free(path_z);
    const handle = c.CreateFileW(
        path_z.ptr,
        FILE_READ_ATTRIBUTES,
        c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE,
        null,
        c.OPEN_EXISTING,
        c.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return .{ .deny = .inaccessible_file };
    defer _ = c.CloseHandle(handle);
    if (c.GetFileType(handle) != c.FILE_TYPE_DISK) return .{ .deny = .inaccessible_file };

    var info: c.BY_HANDLE_FILE_INFORMATION = undefined;
    if (c.GetFileInformationByHandle(handle, &info) == 0) return .{ .deny = .inaccessible_file };
    const directory = info.dwFileAttributes & c.FILE_ATTRIBUTE_DIRECTORY != 0;

    var final_buf: [32 * 1024]u16 = undefined;
    const final_len = c.GetFinalPathNameByHandleW(handle, &final_buf, final_buf.len, 0);
    if (final_len == 0 or final_len >= final_buf.len) return .{ .deny = .inaccessible_file };
    var final: []const u16 = final_buf[0..final_len];

    // The final path starts with \\?\, or \\?\UNC\ on a mapped network
    // drive. ShellExecute wants the plain form.
    const unc_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\");
    const long_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    if (std.mem.startsWith(u16, final, unc_prefix)) {
        final = final[unc_prefix.len - 2 ..];
        final_buf[unc_prefix.len - 2] = '\\';
        final_buf[unc_prefix.len - 1] = '\\';
    } else if (std.mem.startsWith(u16, final, long_prefix)) {
        final = final[long_prefix.len..];
    }

    const name = final[if (std.mem.lastIndexOfScalar(u16, final, '\\')) |i| i + 1 else 0..];
    if (directory) {
        // A folder named like `name.{CLSID}` opens as that shell object
        // instead of as a folder.
        if (std.mem.indexOfScalar(u16, name, '{') != null) return .{ .deny = .unsafe_file };
    } else if (std.mem.lastIndexOfScalar(u16, name, '.')) |dot| {
        if (isDangerousExtension(name[dot..])) return .{ .deny = .unsafe_file };
    }

    return .{ .allow = try alloc.dupeSentinel(u16, final, 0) };
}

/// Windows follows at most 63 symbolic links in a path.
const max_links = 63;

/// Reads each symbolic link on the way to `path` (an absolute drive path)
/// without following it, and returns why the path can't be opened if one
/// points to another computer (or can't be read). Junctions and other
/// reparse points only lead to local volumes.
fn checkLinks(alloc: Allocator, path: []const u16, links_left: usize) Allocator.Error!?Reason {
    if (path.len < 3 or path[1] != ':' or !isSep(path[2])) return .malformed;

    var end: usize = 3;
    while (end <= path.len) : (end += 1) {
        if (end < path.len and !isSep(path[end])) continue;
        if (isSep(path[end - 1])) continue;

        const prefix = try alloc.dupeSentinel(u16, path[0..end], 0);
        defer alloc.free(prefix);
        const attributes = c.GetFileAttributesW(prefix.ptr);
        // Opening the path fails too.
        if (attributes == c.INVALID_FILE_ATTRIBUTES) return null;
        if (attributes & c.FILE_ATTRIBUTE_REPARSE_POINT == 0) continue;

        const target = switch (try readLink(alloc, prefix)) {
            .none => continue,
            .remote => return .remote_file,
            .unreadable => return .inaccessible_file,
            .target => |target| target,
        };
        defer alloc.free(target);
        if (links_left == 0) return .inaccessible_file;

        // The rest of the path continues from the link's target.
        const next = try std.mem.concat(alloc, u16, &.{ target, path[end..] });
        defer alloc.free(next);
        return try checkLinks(alloc, next, links_left - 1);
    }
    return null;
}

const Link = union(enum) {
    /// Not a symbolic link.
    none,
    remote,
    unreadable,
    /// The absolute path it points to.
    target: []u16,
};

fn readLink(alloc: Allocator, link: [:0]const u16) Allocator.Error!Link {
    const handle = c.CreateFileW(
        link.ptr,
        FILE_READ_ATTRIBUTES,
        c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE,
        null,
        c.OPEN_EXISTING,
        c.FILE_FLAG_BACKUP_SEMANTICS | c.FILE_FLAG_OPEN_REPARSE_POINT,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return .unreadable;
    defer _ = c.CloseHandle(handle);

    // REPARSE_DATA_BUFFER (the symbolic link form).
    var data: [16 * 1024]u8 = undefined;
    var len: c.DWORD = 0;
    if (c.DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT, null, 0, &data, data.len, &len, null) == 0) {
        return .unreadable;
    }
    if (len < 8) return .unreadable;
    if (std.mem.readInt(u32, data[0..4], .little) != IO_REPARSE_TAG_SYMLINK) return .none;
    if (len < 20) return .unreadable;
    const name_offset = std.mem.readInt(u16, data[8..10], .little);
    const name_len = std.mem.readInt(u16, data[10..12], .little);
    const flags = std.mem.readInt(u32, data[16..20], .little);
    if (name_offset % 2 != 0 or name_len % 2 != 0 or 20 + @as(usize, name_offset) + name_len > len) {
        return .unreadable;
    }
    const bytes = data[20 + name_offset ..][0..name_len];
    const name = try alloc.alloc(u16, name_len / 2);
    defer alloc.free(name);
    for (name, 0..) |*unit, i| unit.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);

    if (flags & SYMLINK_FLAG_RELATIVE != 0) {
        // From the link's folder, or its drive for `\name`.
        const base = if (name.len > 0 and isSep(name[0]))
            link[0..2]
        else
            link[0 .. (std.mem.lastIndexOfAny(u16, link, &.{ '\\', '/' }) orelse return .unreadable) + 1];
        return .{ .target = try std.mem.concat(alloc, u16, &.{ base, name }) };
    }

    // Absolute targets are NT paths: \??\C:\... or \??\UNC\host\...
    const unc_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\UNC\\");
    const nt_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\");
    if (std.ascii.startsWithIgnoreCase(std.mem.sliceAsBytes(name), std.mem.sliceAsBytes(unc_prefix))) return .remote;
    if (!std.mem.startsWith(u16, name, nt_prefix)) return .unreadable;
    const target = name[nt_prefix.len..];
    if (target.len < 3 or target[1] != ':' or !isSep(target[2])) return .unreadable;
    return .{ .target = try alloc.dupe(u16, target) };
}

fn isSep(unit: u16) bool {
    return unit == '\\' or unit == '/';
}

/// Whether opening a file with this extension (including its dot) could run
/// code. Windows' own list (`AssocIsDangerous`) and `PATHEXT` cover most of
/// them; ours adds types that run code or change settings through the app
/// that opens them.
fn isDangerousExtension(ext: []const u16) bool {
    if (ext.len < 2 or ext.len > 32) return ext.len > 32;

    var lower_buf: [32]u8 = undefined;
    for (ext, 0..) |unit, i| {
        // Non-ASCII extensions aren't on any list; Windows' check below
        // still sees them.
        lower_buf[i] = if (unit < 0x80) std.ascii.toLower(@intCast(unit)) else 0;
    }
    const lower = lower_buf[0..ext.len];
    for (dangerous_extensions) |dangerous| {
        if (std.mem.eql(u8, lower, dangerous)) return true;
    }

    var ext_z: [33]u16 = undefined;
    @memcpy(ext_z[0..ext.len], ext);
    ext_z[ext.len] = 0;
    if (AssocIsDangerous(@ptrCast(&ext_z)) != 0) return true;

    var pathext_buf: [1024]u16 = undefined;
    const n = c.GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("PATHEXT"),
        &pathext_buf,
        pathext_buf.len,
    );
    if (n == 0 or n >= pathext_buf.len) return false;
    var it = std.mem.tokenizeScalar(u16, pathext_buf[0..n], ';');
    while (it.next()) |entry| {
        if (entry.len != ext.len) continue;
        for (entry, ext) |a, b| {
            if (lowerUnit(a) != lowerUnit(b)) break;
        } else return true;
    }
    return false;
}

fn lowerUnit(unit: u16) u16 {
    return if (unit >= 'A' and unit <= 'Z') unit + ('a' - 'A') else unit;
}

const dangerous_extensions = [_][]const u8{
    ".ade",                ".adp",               ".app",        ".appinstaller",
    ".application",        ".appref-ms",         ".appx",       ".appxbundle",
    ".bas",                ".bat",               ".cer",        ".chm",
    ".cmd",                ".com",               ".cpl",        ".crt",
    ".der",                ".diagcab",           ".diagcfg",    ".diagpkg",
    ".exe",                ".gadget",            ".hlp",        ".hta",
    ".inf",                ".ins",               ".isp",        ".jar",
    ".js",                 ".jse",               ".library-ms", ".lnk",
    ".mde",                ".msc",               ".msh",        ".msi",
    ".msix",               ".msixbundle",        ".msp",        ".mst",
    ".pif",                ".ps1",               ".ps1xml",     ".ps2",
    ".psc1",               ".psd1",              ".psm1",       ".reg",
    ".scf",                ".scr",               ".sct",        ".search-ms",
    ".searchconnector-ms", ".settingcontent-ms", ".shb",        ".shs",
    ".url",                ".vb",                ".vbe",        ".vbs",
    ".website",            ".ws",                ".wsc",        ".wsf",
    ".wsh",                ".xbap",              ".xll",
};

/// Whether the value has control, invisible or text-reversing characters,
/// which could make the target look different from what opens. Invalid
/// UTF-8 counts too.
fn hasUnsafeCharacters(value: []const u8) bool {
    const view = std.unicode.Utf8View.init(value) catch return true;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (isUnsafeCharacter(cp)) return true;
    return false;
}

fn isUnsafeCharacter(cp: u21) bool {
    return switch (cp) {
        // C0 and C1 controls, including CR and LF.
        0x00...0x1F, 0x7F...0x9F => true,
        // Directional marks and zero-width characters.
        0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069 => true,
        // Line and paragraph separators.
        0x2028...0x2029 => true,
        // Word joiner and BOM.
        0x2060, 0xFEFF => true,
        else => false,
    };
}

/// The value as one line, for showing in a dialog: unsafe characters are
/// written as `\u{...}` so they can't hide or reorder anything.
pub fn display(alloc: Allocator, value: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var i: usize = 0;
    while (i < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[i]) catch 0;
        const cp: ?u21 = if (len > 0 and i + len <= value.len)
            std.unicode.utf8Decode(value[i .. i + len]) catch null
        else
            null;
        if (cp) |v| {
            if (isUnsafeCharacter(v)) {
                w.print("\\u{{{X}}}", .{v}) catch return error.OutOfMemory;
            } else {
                w.writeAll(value[i .. i + len]) catch return error.OutOfMemory;
            }
            i += len;
        } else {
            w.print("\\x{X:0>2}", .{value[i]}) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return try out.toOwnedSlice();
}

const FILE_READ_ATTRIBUTES = 0x0080;
const FSCTL_GET_REPARSE_POINT = 0x000900A8;
const IO_REPARSE_TAG_SYMLINK = 0xA000000C;
const SYMLINK_FLAG_RELATIVE = 0x1;
const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;

extern "shlwapi" fn AssocIsDangerous(ext: [*:0]const u16) callconv(.winapi) c.BOOL;
extern "shlwapi" fn PathCreateFromUrlW(
    url: [*:0]const u16,
    path: [*]u16,
    len: *u32,
    flags: u32,
) callconv(.winapi) c.HRESULT;

const testing = std.testing;

fn expectDeny(reason: Reason, value: []const u8, plain_paths: bool) !void {
    const decision = try check(testing.allocator, value, plain_paths);
    defer decision.deinit(testing.allocator);
    if (decision != .deny or decision.deny != reason) {
        std.debug.print("expected {s} to be denied ({s}), got {any}\n", .{ value, @tagName(reason), decision });
        return error.TestUnexpectedResult;
    }
}

fn expectTarget(tag: std.meta.Tag(Decision), expected: []const u8, value: []const u8, plain_paths: bool) !void {
    const decision = try check(testing.allocator, value, plain_paths);
    defer decision.deinit(testing.allocator);
    if (decision != tag) {
        std.debug.print("expected {s} to be {s}, got {any}\n", .{ value, @tagName(tag), decision });
        return error.TestUnexpectedResult;
    }
    const target = switch (decision) {
        .allow, .confirm => |t| t,
        .deny => unreachable,
    };
    const target8 = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, target);
    defer testing.allocator.free(target8);
    try testing.expectEqualStrings(expected, target8);
}

test "web, mail and other schemes" {
    try expectTarget(.allow, "https://example.com/a?b#c", "https://example.com/a?b#c", false);
    try expectTarget(.allow, "HTTP://user@example.com", "HTTP://user@example.com", false);
    try expectTarget(.allow, "mailto:someone@example.com", "mailto:someone@example.com", false);
    try expectTarget(.confirm, "ms-settings:display", "ms-settings:display", false);
    try expectTarget(.confirm, "ms-msdt:/id PCWDiagnostic", "ms-msdt:/id PCWDiagnostic", false);

    try expectDeny(.invalid_web_url, "https:relative", false);
    try expectDeny(.invalid_web_url, "https://", false);
    try expectDeny(.invalid_web_url, "https://user@/path", false);
    try expectDeny(.malformed, "mailto:", false);
    try expectDeny(.malformed, "", false);
}

test "unsafe characters" {
    try expectDeny(.unsafe_characters, "https://example.com/\x1b[2J", false);
    try expectDeny(.unsafe_characters, "https://example.com/\u{202E}txt.exe", false);
    try expectDeny(.unsafe_characters, "https://example.com/\u{200B}", false);
    try expectDeny(.unsafe_characters, "https://example.com/\xff", false);
    try expectDeny(.unsafe_characters, "file:///C:/a%0Ab.txt", false);

    const shown = try display(testing.allocator, "a\u{202E}b\nc\xff");
    defer testing.allocator.free(shown);
    try testing.expectEqualStrings("a\\u{202E}b\\u{A}c\\xFF", shown);
}

test "paths need an absolute local path" {
    // OSC 8 targets must be URLs.
    try expectDeny(.malformed, "C:\\Windows\\win.ini", false);
    try expectDeny(.malformed, "notes.txt", true);
    try expectDeny(.malformed, "\\Windows\\win.ini", true);
    try expectDeny(.remote_file, "\\\\server\\share\\notes.txt", true);
    try expectDeny(.remote_file, "//server/share/notes.txt", true);
    try expectDeny(.remote_file, "\\\\?\\C:\\Windows\\win.ini", true);
    try expectDeny(.remote_file, "file://server/share/notes.txt", false);
    try expectDeny(.remote_file, "file:////server/share/notes.txt", false);
    try expectDeny(.malformed, "file:///C:/Windows/win.ini?x", false);
    try expectDeny(.inaccessible_file, "C:\\does\\not\\exist.txt", true);
    try expectDeny(.inaccessible_file, "file:///C:/does/not/exist.txt", false);
}

test "local files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    for ([_][]const u8{ "notes.txt", "run.bat", "run.vbs", "README", "data.PS1" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    try tmp.dir.createDir(io, "folder", .default_dir);
    try tmp.dir.createDir(io, "tool.{20D04FE0-3AEA-1069-A2D8-08002B30309D}", .default_dir);

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const Case = struct { name: []const u8, allowed: ?[]const u8 };
    const cases = [_]Case{
        .{ .name = "notes.txt", .allowed = "notes.txt" },
        .{ .name = "README", .allowed = "README" },
        .{ .name = "folder", .allowed = "folder" },
        .{ .name = "run.bat", .allowed = null },
        .{ .name = "run.vbs", .allowed = null },
        .{ .name = "data.PS1", .allowed = null },
        // Windows drops trailing dots and spaces, so this opens run.bat.
        .{ .name = "run.bat.", .allowed = null },
        .{ .name = "run.bat .. ", .allowed = null },
        .{ .name = "tool.{20D04FE0-3AEA-1069-A2D8-08002B30309D}", .allowed = null },
        // An alternate data stream.
        .{ .name = "notes.txt:hidden", .allowed = null },
    };
    for (cases) |case| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ dir, case.name });
        defer testing.allocator.free(path);
        if (case.allowed) |allowed| {
            const expected = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ dir, allowed });
            defer testing.allocator.free(expected);
            try expectTarget(.allow, expected, path, true);
        } else {
            const decision = try check(testing.allocator, path, true);
            defer decision.deinit(testing.allocator);
            if (decision != .deny) {
                std.debug.print("expected {s} to be denied\n", .{path});
                return error.TestUnexpectedResult;
            }
        }
    }

    // The same through a file URL, with percent-encoding.
    const url = try std.fmt.allocPrint(testing.allocator, "file:///{s}/notes%2Etxt", .{dir});
    defer testing.allocator.free(url);
    std.mem.replaceScalar(u8, url, '\\', '/');
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\\notes.txt", .{dir});
    defer testing.allocator.free(expected);
    try expectTarget(.allow, expected, url, false);

    const bat_url = try std.fmt.allocPrint(testing.allocator, "file:///{s}/run%2Ebat", .{dir});
    defer testing.allocator.free(bat_url);
    std.mem.replaceScalar(u8, bat_url, '\\', '/');
    try expectDeny(.unsafe_file, bat_url, false);

    // Windows' own executables.
    try expectDeny(.unsafe_file, "C:\\Windows\\System32\\calc.exe", true);
    try expectDeny(.unsafe_file, "file:///C:/Windows/System32/calc.exe", false);
}

test "symbolic links to other computers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "x" });

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];

    const LinkCase = struct { name: []const u8, target: []const u8, folder: bool = false };
    const notes = try std.fmt.allocPrint(testing.allocator, "{s}\\notes.txt", .{dir});
    defer testing.allocator.free(notes);
    const links = [_]LinkCase{
        .{ .name = "remote.txt", .target = "\\\\127.0.0.1\\c$\\Windows\\win.ini" },
        .{ .name = "share", .target = "\\\\127.0.0.1\\c$", .folder = true },
        .{ .name = "hop.txt", .target = "remote.txt" },
        .{ .name = "here", .target = ".", .folder = true },
        .{ .name = "local.txt", .target = "notes.txt" },
        .{ .name = "absolute.txt", .target = notes },
    };
    for (links) |l| {
        const name = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ dir, l.name });
        defer testing.allocator.free(name);
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, name);
        defer testing.allocator.free(name_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, l.target);
        defer testing.allocator.free(target_w);
        const flags: c.DWORD = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE |
            @as(c.DWORD, if (l.folder) c.SYMBOLIC_LINK_FLAG_DIRECTORY else 0);
        // Needs developer mode or the symbolic link privilege, which CI
        // lacks.
        if (c.CreateSymbolicLinkW(name_w.ptr, target_w.ptr, flags) == 0) return error.SkipZigTest;
    }

    // Checking these must not connect to 127.0.0.1.
    for ([_][]const u8{ "remote.txt", "share\\Windows\\win.ini", "hop.txt", "here\\hop.txt", "here\\share\\Windows" }) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ dir, name });
        defer testing.allocator.free(path);
        try expectDeny(.remote_file, path, true);
    }

    // Local links still open, by their target's path.
    for ([_][]const u8{ "local.txt", "absolute.txt", "here\\local.txt" }) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ dir, name });
        defer testing.allocator.free(path);
        try expectTarget(.allow, notes, path, true);
    }
}
