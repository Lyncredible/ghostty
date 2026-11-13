//! The Windows clipboard's formats for MIME types, for programs that read
//! and write representations by MIME type (the Kitty clipboard protocol,
//! OSC 5522) and its paste events, which list the types available.
//!
//! Text is CF_UNICODETEXT, `text/html` is the "HTML Format" (CF_HTML)
//! browsers and Office use, and `image/png` is the "PNG" format they use
//! too. Any other type is a format registered under its own name, so that
//! programs can trade it through Ghostty (and with other programs that
//! name formats by MIME type). The functions that touch the clipboard
//! expect it to be open.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");

const util = @import("util.zig");
const c = util.c;

pub const Format = union(enum) {
    /// CF_UNICODETEXT, converted to and from UTF-8 with LF line endings.
    text,
    /// CF_HTML: a header with offsets, around the fragment.
    html: c.UINT,
    /// The bytes as they are.
    raw: c.UINT,
};

/// The format for a MIME type, or null if Windows wouldn't register one
/// (which only an odd name causes).
pub fn formatFor(mime: []const u8) ?Format {
    if (terminal.clipboard.isTextMime(mime)) return .text;
    if (std.mem.eql(u8, mime, "text/html")) return .{ .html = registered("HTML Format") orelse return null };
    return .{ .raw = registered(registeredName(mime)) orelse return null };
}

/// The name of the format registered for a MIME type that isn't text or
/// HTML.
fn registeredName(mime: []const u8) []const u8 {
    return if (std.mem.eql(u8, mime, "image/png")) "PNG" else mime;
}

/// The MIME type of a registered format's name, for the listing: those
/// we name ourselves, and names that look like MIME types. Null for the
/// others (applications' private formats, such as "Ole Private Data").
fn mimeOfName(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "HTML Format")) return "text/html";
    if (std.mem.eql(u8, name, "PNG")) return "image/png";
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    if (slash == 0 or slash == name.len - 1) return null;
    for (name) |ch| if (ch <= ' ' or ch >= 0x7f) return null;
    return name;
}

test mimeOfName {
    const testing = std.testing;
    try testing.expectEqualStrings("text/html", mimeOfName("HTML Format").?);
    try testing.expectEqualStrings("image/png", mimeOfName("PNG").?);
    try testing.expectEqualStrings("image/svg+xml", mimeOfName("image/svg+xml").?);
    try testing.expectEqualStrings("application/x-test;charset=utf-8", mimeOfName("application/x-test;charset=utf-8").?);
    try testing.expect(mimeOfName("Ole Private Data") == null);
    try testing.expect(mimeOfName("Rich Text Format") == null);
    try testing.expect(mimeOfName("/x") == null);
    try testing.expect(mimeOfName("x/") == null);
    try testing.expect(mimeOfName("not a/type") == null);
}

test "formats for MIME types" {
    const testing = std.testing;
    try testing.expectEqual(Format.text, formatFor("text/plain").?);
    try testing.expectEqual(Format.text, formatFor("UTF8_STRING").?);
    const html = formatFor("text/html").?;
    try testing.expectEqual(registered("HTML Format").?, html.html);
    try testing.expectEqual(registered("PNG").?, formatFor("image/png").?.raw);
    // Another type is a format of its own name, which the listing names
    // the same way.
    const svg = formatFor("image/svg+xml").?.raw;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("image/svg+xml", mimeOf(svg, &buf).?);
    try testing.expectEqualStrings("text/plain", mimeOf(c.CF_UNICODETEXT, &buf).?);
    try testing.expect(mimeOf(c.CF_TEXT, &buf) == null);
}

/// A registered format's id, or null if Windows wouldn't register it.
fn registered(name: []const u8) ?c.UINT {
    var buf: [256:0]u16 = undefined;
    const name16 = util.utf16TruncateZ(&buf, name);
    const format = c.RegisterClipboardFormatW(name16.ptr);
    return if (format == 0) null else format;
}

/// The MIME type of a format on the clipboard, for the listing. Text is
/// listed once, for CF_UNICODETEXT (Windows makes it from the other text
/// formats). Null for formats with no MIME type.
fn mimeOf(format: c.UINT, buf: []u8) ?[]const u8 {
    if (format == c.CF_UNICODETEXT) return "text/plain";
    // Registered formats start at 0xC000; below are the system's, with
    // no names.
    if (format < 0xC000) return null;
    var name16: [256]u16 = undefined;
    const n = c.GetClipboardFormatNameW(format, &name16, name16.len);
    if (n <= 0) return null;
    const len = std.unicode.wtf16LeToWtf8(buf, name16[0..@intCast(n)]);
    return mimeOfName(buf[0..len]);
}

/// The MIME types the open clipboard has, in its order, at most
/// `max_listing_mimes` of them. The names are allocated with `alloc`.
pub fn available(alloc: Allocator) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var format: c.UINT = 0;
    while (list.items.len < terminal.kitty.clipboard.max_listing_mimes) {
        format = c.EnumClipboardFormats(format);
        if (format == 0) break;
        var buf: [256 * 3]u8 = undefined;
        const mime = mimeOf(format, &buf) orelse continue;
        const seen = for (list.items) |item| {
            if (std.mem.eql(u8, item, mime)) break true;
        } else false;
        if (seen) continue;
        try list.append(alloc, try alloc.dupe(u8, mime));
    }
    return list.toOwnedSlice(alloc);
}

/// The bytes of a format on the open clipboard, copied with `alloc`, or
/// null if it isn't there.
pub fn readRaw(alloc: Allocator, format: c.UINT) Allocator.Error!?[]u8 {
    if (c.IsClipboardFormatAvailable(format) == 0) return null;
    const handle = c.GetClipboardData(format) orelse return null;
    const ptr: [*]const u8 = @ptrCast(c.GlobalLock(handle) orelse return null);
    defer _ = c.GlobalUnlock(handle);
    return try alloc.dupe(u8, ptr[0..c.GlobalSize(handle)]);
}

/// Put bytes on the open clipboard as a format. Returns false if Windows
/// didn't take them.
pub fn writeRaw(format: c.UINT, data: []const u8) bool {
    const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, @max(1, data.len)) orelse return false;
    const dst: [*]u8 = @ptrCast(c.GlobalLock(mem) orelse {
        _ = c.GlobalFree(mem);
        return false;
    });
    @memcpy(dst[0..data.len], data);
    _ = c.GlobalUnlock(mem);
    // On success the system owns the memory, otherwise we do.
    if (c.SetClipboardData(format, mem) == null) {
        _ = c.GlobalFree(mem);
        return false;
    }
    return true;
}

/// The fragment of CF_HTML data: what its StartFragment and EndFragment
/// offsets (counted in bytes from the start) mark. Null if they're
/// missing or out of place.
pub fn htmlFragment(data: []const u8) ?[]const u8 {
    // The header is before the HTML, so it's within the first few lines;
    // the memory may also have a NUL and padding after the HTML.
    const end = std.mem.indexOfScalar(u8, data, 0) orelse data.len;
    const html = data[0..end];
    const start = headerOffset(html, "StartFragment:") orelse return null;
    const stop = headerOffset(html, "EndFragment:") orelse return null;
    if (start > stop or stop > html.len) return null;
    return html[start..stop];
}

fn headerOffset(data: []const u8, name: []const u8) ?usize {
    const at = std.mem.indexOf(u8, data, name) orelse return null;
    var i = at + name.len;
    const digits = i;
    while (i < data.len and std.ascii.isDigit(data[i])) i += 1;
    if (i == digits) return null;
    return std.fmt.parseInt(usize, data[digits..i], 10) catch null;
}

test htmlFragment {
    const testing = std.testing;
    // As Chrome writes it: offsets of different widths, and a NUL after.
    const header = "Version:0.9\r\nStartHTML:000105\r\nEndHTML:000165\r\nStartFragment:000141\r\nEndFragment:000149\r\n";
    const data = header ++ "<html><body>\r\n<!--StartFragment--><b>hi</b><!--EndFragment-->\r\n</body></html>\x00\x00";
    const start = std.mem.indexOf(u8, data, "<b>").?;
    // Point the offsets at the fragment, whatever the header's length.
    var buf: [data.len]u8 = data.*;
    _ = std.fmt.bufPrint(buf[std.mem.indexOf(u8, data, "StartFragment:").? + 14 ..][0..6], "{d:0>6}", .{start}) catch unreachable;
    _ = std.fmt.bufPrint(buf[std.mem.indexOf(u8, data, "EndFragment:").? + 12 ..][0..6], "{d:0>6}", .{start + "<b>hi</b>".len}) catch unreachable;
    try testing.expectEqualStrings("<b>hi</b>", htmlFragment(&buf).?);

    // Missing or impossible offsets.
    try testing.expect(htmlFragment("Version:0.9\r\n<b>hi</b>") == null);
    try testing.expect(htmlFragment("StartFragment:10\r\nEndFragment:5\r\n") == null);
    try testing.expect(htmlFragment("StartFragment:1\r\nEndFragment:9999\r\n") == null);
    try testing.expect(htmlFragment("StartFragment:\r\nEndFragment:3\r\n") == null);
}
