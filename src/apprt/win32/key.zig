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
        const ch = c.MapVirtualKeyW(vk, c.MAPVK_VK_TO_CHAR) & 0x7FFF;
        return std.math.cast(u21, std.ascii.toLower(@truncate(ch))) orelse 0;
    };
    return firstCodepoint(units);
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
    var small: [5]u8 = undefined;
    try testing.expectEqualStrings("\u{1F600}", utf16ToUtf8Buf(&.{ 0xD83D, 0xDE00, 0xD83D, 0xDE00 }, &small));
}

test "isControl" {
    const testing = std.testing;
    try testing.expect(isControl(&.{0x03}));
    try testing.expect(isControl(&.{0x7F}));
    try testing.expect(!isControl(&.{'c'}));
    try testing.expect(!isControl(&.{ 0x03, 0x03 }));
}
