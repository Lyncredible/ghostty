//! Keyboard input translation for the Win32 apprt.
const std = @import("std");
const input = @import("../../input.zig");

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

/// Flag for ToUnicodeEx to not change the keyboard state, in particular
/// dead key state. Supported on Windows 10 1607 and later.
const TOUNICODE_NO_STATE_CHANGE = 0x4;

/// Returns the native keycode for a key message, which is the scancode
/// with a 0xE0 prefix for extended keys. This matches the Windows codes
/// in input/keycodes.zig.
pub fn nativeKeycode(wparam: c.WPARAM, lparam: c.LPARAM) u32 {
    const l: usize = @bitCast(lparam);
    var scancode: u32 = @intCast((l >> 16) & 0xFF);
    const extended = (l >> 24) & 1 != 0;

    // Some synthesized key events (e.g. from SendInput or IMEs) have
    // no scancode, so we derive it from the virtual key.
    if (scancode == 0) {
        const vk: c.UINT = @intCast(wparam & 0xFF);
        return c.MapVirtualKeyW(vk, c.MAPVK_VK_TO_VSC_EX);
    }

    if (extended) scancode |= 0xE000;
    return scancode;
}

/// Returns the physical key for a native keycode.
pub fn physicalKey(native: u32) input.Key {
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}

fn down(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

fn toggled(vk: c_int) bool {
    return c.GetKeyState(vk) & 1 != 0;
}

/// Returns the modifiers that are currently pressed, according to the
/// keyboard state of the message being processed.
pub fn currentMods() input.Mods {
    var mods: input.Mods = .{
        .shift = down(c.VK_SHIFT),
        .ctrl = down(c.VK_CONTROL),
        .alt = down(c.VK_MENU),
        .super = down(c.VK_LWIN) or down(c.VK_RWIN),
        .caps_lock = toggled(c.VK_CAPITAL),
        .num_lock = toggled(c.VK_NUMLOCK),
    };

    if (down(c.VK_RSHIFT) and !down(c.VK_LSHIFT)) mods.sides.shift = .right;
    if (down(c.VK_RCONTROL) and !down(c.VK_LCONTROL)) mods.sides.ctrl = .right;
    if (down(c.VK_RMENU) and !down(c.VK_LMENU)) mods.sides.alt = .right;
    if (down(c.VK_RWIN) and !down(c.VK_LWIN)) mods.sides.super = .right;

    return mods;
}

/// Returns true if AltGr is pressed. Windows reports AltGr as the
/// combination of left control and right alt.
pub fn altGr() bool {
    return down(c.VK_RMENU) and down(c.VK_LCONTROL);
}

/// Returns true if the key is part of an Alt code (Alt held while typing
/// a number on the numpad, such as Alt+0233 for é): Windows composes the
/// character itself and sends it when Alt is released, so, like Windows
/// Terminal, we leave the digits to it. This goes by the scancode, so it
/// works with Num Lock off too.
pub fn altCode(key: input.Key, mods: input.Mods) bool {
    if (!mods.alt or mods.ctrl or mods.shift or mods.super) return false;
    return switch (key) {
        .numpad_0,
        .numpad_1,
        .numpad_2,
        .numpad_3,
        .numpad_4,
        .numpad_5,
        .numpad_6,
        .numpad_7,
        .numpad_8,
        .numpad_9,
        => true,
        else => false,
    };
}

/// Translate a key into UTF-16 code units given a keyboard state, without
/// changing the keyboard (dead key) state. Returns null for dead keys.
fn translate(
    vk: c.UINT,
    scancode: c.UINT,
    state: *const [256]u8,
    out: []u16,
) ?[]const u16 {
    const n = c.ToUnicodeEx(
        vk,
        scancode,
        state,
        out.ptr,
        @intCast(out.len),
        TOUNICODE_NO_STATE_CHANGE,
        c.GetKeyboardLayout(0),
    );
    if (n < 0) return null;
    return out[0..@intCast(n)];
}

/// Returns the codepoint the key produces with no modifiers pressed.
pub fn unshiftedCodepoint(vk: c.UINT, scancode: c.UINT) u21 {
    const state: [256]u8 = @splat(0);
    var buf: [4]u16 = undefined;
    const units = translate(vk, scancode, &state, &buf) orelse {
        // Dead keys produce no text, but we still want to know what
        // the key is, which MapVirtualKey gives us.
        return mappedChar(c.MapVirtualKeyW(vk, c.MAPVK_VK_TO_CHAR));
    };
    return firstCodepoint(units);
}

/// The character in a MAPVK_VK_TO_CHAR result: the top bit marks a dead
/// key (older Windows used bit 15), and letters come back in upper case.
/// A dead key's character can be past U+00FF (a caron, U+02C7, on a
/// Czech keyboard), so it's kept whole rather than cut to a byte.
fn mappedChar(mapped: c.UINT) u21 {
    const ch: u21 = @intCast(mapped & 0x7FFF);
    return if (ch < 0x80) std.ascii.toLower(@intCast(ch)) else ch;
}

/// Returns the text the key produces with the current modifiers except
/// for control (and alt, unless AltGr is pressed). This is used when
/// control is held: Windows produces control characters (e.g. ctrl+c is
/// 0x03), but the core wants the text of the key so it can do its own
/// encoding of control sequences.
pub fn textWithoutCtrl(
    vk: c.UINT,
    scancode: c.UINT,
    out: []u8,
) []const u8 {
    var state: [256]u8 = undefined;
    if (c.GetKeyboardState(&state) == 0) return "";
    for ([_]c_int{ c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL, c.VK_MENU, c.VK_LMENU, c.VK_RMENU }) |v| {
        state[@intCast(v)] = 0;
    }

    var buf: [8]u16 = undefined;
    const units = translate(vk, scancode, &state, &buf) orelse return "";
    return utf16ToUtf8Buf(units, out);
}

/// Returns true if the UTF-16 text is a single C0 control character or DEL.
pub fn isControl(units: []const u16) bool {
    return units.len == 1 and (units[0] < 0x20 or units[0] == 0x7F);
}

fn firstCodepoint(units: []const u16) u21 {
    if (units.len == 0) return 0;
    var it = std.unicode.Utf16LeIterator.init(units);
    return (it.nextCodepoint() catch return 0) orelse 0;
}

/// Convert UTF-16 into the given buffer as UTF-8, truncating at the last
/// complete codepoint that fits. Invalid UTF-16 is replaced.
pub fn utf16ToUtf8Buf(units: []const u16, out: []u8) []const u8 {
    var len: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(units);
    while (true) {
        const cp = it.nextCodepoint() catch 0xFFFD orelse break;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        if (len + n > out.len) break;
        @memcpy(out[len..][0..n], buf[0..n]);
        len += n;
    }
    return out[0..len];
}

test "physicalKey" {
    const testing = std.testing;
    try testing.expectEqual(input.Key.key_a, physicalKey(0x001e));
    try testing.expectEqual(input.Key.enter, physicalKey(0x001c));
    try testing.expectEqual(input.Key.numpad_enter, physicalKey(0xe01c));
    try testing.expectEqual(input.Key.arrow_up, physicalKey(0xe048));
    try testing.expectEqual(input.Key.unidentified, physicalKey(0xffff));
}

test "utf16ToUtf8Buf" {
    const testing = std.testing;
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a", utf16ToUtf8Buf(&.{'a'}, &buf));
    // U+1F600, a surrogate pair
    try testing.expectEqualStrings("\u{1F600}", utf16ToUtf8Buf(&.{ 0xD83D, 0xDE00 }, &buf));
    // Truncates at a codepoint boundary
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("\u{1F600}", utf16ToUtf8Buf(&.{ 0xD83D, 0xDE00, 0xD83D, 0xDE00 }, &small));
}

test mappedChar {
    const testing = std.testing;
    try testing.expectEqual(@as(u21, 'a'), mappedChar('A'));
    try testing.expectEqual(@as(u21, '^'), mappedChar(0x8000_0000 | '^'));
    try testing.expectEqual(@as(u21, 0xB4), mappedChar(0x8000_0000 | 0xB4));
    try testing.expectEqual(@as(u21, 0x2C7), mappedChar(0x8000_0000 | 0x2C7));
    try testing.expectEqual(@as(u21, 0), mappedChar(0));
}

test "isControl" {
    const testing = std.testing;
    try testing.expect(isControl(&.{0x03}));
    try testing.expect(isControl(&.{0x7F}));
    try testing.expect(!isControl(&.{'c'}));
    try testing.expect(!isControl(&.{ 0x03, 0x03 }));
}

test "altCode" {
    const testing = std.testing;
    try testing.expect(altCode(.numpad_0, .{ .alt = true }));
    try testing.expect(altCode(.numpad_9, .{ .alt = true, .num_lock = true }));
    try testing.expect(!altCode(.numpad_0, .{}));
    try testing.expect(!altCode(.digit_0, .{ .alt = true }));
    try testing.expect(!altCode(.numpad_add, .{ .alt = true }));
    try testing.expect(!altCode(.numpad_1, .{ .alt = true, .ctrl = true }));
    try testing.expect(!altCode(.numpad_1, .{ .alt = true, .shift = true }));
}

test "utf16ToUtf8Buf: lone surrogates and a full buffer" {
    const testing = std.testing;
    var out: [16]u8 = undefined;
    // Halves of a pair on their own (a lost WM_CHAR) become U+FFFD, and
    // what follows them is kept.
    try testing.expectEqualStrings("a\u{FFFD}b", utf16ToUtf8Buf(&.{ 'a', 0xDC00, 'b' }, &out));
    try testing.expectEqualStrings("\u{FFFD}a", utf16ToUtf8Buf(&.{ 0xD800, 'a' }, &out));
    try testing.expectEqualStrings("\u{FFFD}", utf16ToUtf8Buf(&.{0xD800}, &out));
    try testing.expectEqualStrings("\u{1F600}", utf16ToUtf8Buf(&.{ 0xD83D, 0xDE00 }, &out));
    // Only whole characters fit.
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("a", utf16ToUtf8Buf(&.{ 'a', 0xD83D, 0xDE00 }, &small));
}
