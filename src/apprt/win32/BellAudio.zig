//! Plays `bell-audio-path` for the `audio` bell feature using MCI.
//!
//! The MCI `mpegvideo` device plays through DirectShow/Media Foundation,
//! so it handles the common formats (WAV, MP3, AAC, ...) and supports a
//! per-device volume, unlike PlaySound. The file stays open between bells
//! and is only reopened when the path changes.
const BellAudio = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

const alias = "ghostty_bell";

/// The path that is currently open, if any.
path: ?[:0]const u8 = null,

pub fn deinit(self: *BellAudio, alloc: Allocator) void {
    self.close(alloc);
}

/// Play the configured file at the given volume (0 to 1).
pub fn play(
    self: *BellAudio,
    alloc: Allocator,
    config_path: configpkg.Path,
    volume: f64,
) void {
    const path, const required = switch (config_path) {
        .optional => |path| .{ path, false },
        .required => |path| .{ path, true },
    };

    if (self.path == null or !std.mem.eql(u8, self.path.?, path)) {
        self.close(alloc);
        if (!fileExists(alloc, path)) {
            if (required) log.warn("bell audio file not found path={s}", .{path});
            return;
        }
        command(alloc, "open \"{s}\" type mpegvideo alias " ++ alias, .{path}) catch return;
        self.path = alloc.dupeSentinel(u8, path, 0) catch {
            command(alloc, "close " ++ alias, .{}) catch {};
            return;
        };
    }

    const level: u32 = @intFromFloat(@round(std.math.clamp(volume, 0, 1) * 1000));
    command(alloc, "setaudio " ++ alias ++ " volume to {d}", .{level}) catch {};
    command(alloc, "play " ++ alias ++ " from 0", .{}) catch return;
    log.debug("playing bell audio path={s} volume={d}", .{ path, level });
}

fn close(self: *BellAudio, alloc: Allocator) void {
    const path = self.path orelse return;
    command(alloc, "close " ++ alias, .{}) catch {};
    alloc.free(path);
    self.path = null;
}

fn fileExists(alloc: Allocator, path: []const u8) bool {
    const path16 = util.utf16Alloc(alloc, path) catch return false;
    defer alloc.free(path16);
    const attrs = c.GetFileAttributesW(path16);
    return attrs != c.INVALID_FILE_ATTRIBUTES and
        attrs & c.FILE_ATTRIBUTE_DIRECTORY == 0;
}

fn command(alloc: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const cmd = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(cmd);
    const cmd16 = try util.utf16Alloc(alloc, cmd);
    defer alloc.free(cmd16);

    const err = c.mciSendStringW(cmd16, null, 0, null);
    if (err != 0) {
        var buf: [256]u16 = undefined;
        const msg: []const u16 = if (c.mciGetErrorStringW(err, &buf, buf.len) != 0)
            std.mem.sliceTo(&buf, 0)
        else
            &.{};
        log.warn("bell audio command failed cmd={s} err={} msg={f}", .{
            cmd,
            err,
            std.unicode.fmtUtf16Le(msg),
        });
        return error.MciFailed;
    }
}
