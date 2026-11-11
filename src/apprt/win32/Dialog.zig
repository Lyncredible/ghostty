//! A question with two buttons that say what they do ("Paste", "Cancel"),
//! as a task dialog. A message box only has Windows' own buttons (OK,
//! Cancel, Yes, No), so its text has to spell out what they mean; GTK's
//! dialogs name the action on the button, and those names have
//! translations.
const std = @import("std");
const util = @import("util.zig");
const i18n = @import("../../os/main.zig").i18n;
const c = util.c;

const log = std.log.scoped(.win32);

/// What a dialog says: its window's title, the message, and its two
/// buttons.
pub const Text = struct {
    title: [:0]const u8,
    message: [:0]const u8,
    accept: [:0]const u8,
    reject: [:0]const u8 = "Cancel",

    /// These messages in the user's language, if we have all of them, so
    /// that a dialog is in one language.
    pub fn translated(msgids: Text) ?Text {
        return .{
            .title = i18n.translation(msgids.title) orelse return null,
            .message = i18n.translation(msgids.message) orelse return null,
            .accept = i18n.translation(msgids.accept) orelse return null,
            .reject = i18n.translation(msgids.reject) orelse return null,
        };
    }
};

pub const Default = enum { accept, reject };

/// The buttons' IDs, which are also what Enter and Escape press in a
/// dialog. The tests press them with `TDM_CLICK_BUTTON`.
pub const id_accept = c.IDOK;
pub const id_reject = c.IDCANCEL;

/// Ask, and return whether the user chose the accept button. Closing the
/// dialog, Escape, and the dialog going away with its owner are all the
/// reject button. This runs a message loop, so anything can have happened
/// to the caller's windows by the time it returns.
pub fn ask(
    owner: c.HWND,
    title: []const u8,
    message: [*:0]const u16,
    accept: []const u8,
    reject: []const u8,
    default: Default,
) bool {
    var title_buf: [256]u16 = undefined;
    const title16 = util.utf16TruncateZ(&title_buf, title);

    if (taskDialog()) |show| {
        var accept_buf: [128]u16 = undefined;
        var reject_buf: [128]u16 = undefined;
        const buttons = [_]Button{
            .{ .id = id_accept, .text = label(&accept_buf, accept).ptr },
            .{ .id = id_reject, .text = label(&reject_buf, reject).ptr },
        };
        const config: Config = .{
            .hwndParent = owner,
            .dwFlags = TDF_ALLOW_DIALOG_CANCELLATION |
                @as(c_int, if (i18n.rightToLeft()) TDF_RTL_LAYOUT else 0) |
                @as(c_int, if (owner != null) TDF_POSITION_RELATIVE_TO_WINDOW else 0),
            .pszWindowTitle = title16.ptr,
            .pszMainIcon = TD_WARNING_ICON,
            .pszContent = message,
            .cButtons = buttons.len,
            .pButtons = &buttons,
            .nDefaultButton = switch (default) {
                .accept => id_accept,
                .reject => id_reject,
            },
        };
        var pressed: c_int = 0;
        const hr = show(&config, &pressed, null, null);
        if (hr >= 0) return pressed == id_accept;
        log.warn("task dialog failed, using a message box hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }

    // Without version 6 of the common controls (our manifest asks for
    // it, so this is a build without the manifest) there's no task
    // dialog: OK and Cancel stand for the two buttons.
    const direction: c.UINT = if (i18n.rightToLeft()) c.MB_RTLREADING | c.MB_RIGHT else 0;
    const flags: c.UINT = direction | switch (default) {
        .accept => @as(c.UINT, c.MB_OKCANCEL | c.MB_ICONWARNING),
        .reject => @as(c.UINT, c.MB_OKCANCEL | c.MB_ICONWARNING | c.MB_DEFBUTTON2),
    };
    return c.MessageBoxW(owner, message, title16.ptr, flags) == c.IDOK;
}

/// A button's label. A task dialog reads "&" as marking the next letter
/// as the button's access key, so one in the text is doubled.
fn label(buf: []u16, text: []const u8) [:0]u16 {
    var doubled: [256]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        const len: usize = if (ch == '&') 2 else 1;
        if (n + len > doubled.len) break;
        @memset(doubled[n..][0..len], ch);
        n += len;
    }
    return util.utf16TruncateZ(buf, doubled[0..n]);
}

test label {
    const testing = std.testing;
    var buf: [32]u16 = undefined;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Paste"), label(&buf, "Paste"));
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("A && B"), label(&buf, "A & B"));
    // Too long for the buffer: cut, and still terminated.
    var small: [4]u16 = undefined;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Ein"), label(&small, "Einfügen"));
}

test "Text: translated" {
    const testing = std.testing;
    const paste: Text = .{ .title = "Warning: Potentially Unsafe Paste", .message = "Paste", .accept = "Paste" };
    try testing.expectEqual(null, paste.translated());

    if (comptime !i18n.embedded) return;
    defer _ = i18n.useEmbeddedLocale(null);
    try testing.expect(i18n.useEmbeddedLocale("de"));
    const german = paste.translated().?;
    try testing.expectEqualStrings("Einfügen", german.accept);
    try testing.expectEqualStrings("Abbrechen", german.reject);
    // One message without a translation, and the dialog stays English.
    var mixed = paste;
    mixed.accept = "No such message";
    try testing.expectEqual(null, mixed.translated());
}

const TDF_ALLOW_DIALOG_CANCELLATION = 0x0008;
const TDF_POSITION_RELATIVE_TO_WINDOW = 0x1000;
const TDF_RTL_LAYOUT = 0x2000;

/// `TD_WARNING_ICON`: `MAKEINTRESOURCEW(-1)`.
const TD_WARNING_ICON: ?[*:0]align(1) const u16 = @ptrFromInt(0xFFFF);

/// `TASKDIALOG_BUTTON`, which like `TASKDIALOGCONFIG` is packed to one
/// byte in commctrl.h.
const Button = extern struct {
    id: c_int align(1),
    text: [*:0]const u16 align(1),
};

/// `TASKDIALOGCONFIG`.
const Config = extern struct {
    cbSize: c.UINT align(1) = @sizeOf(Config),
    hwndParent: c.HWND align(1) = null,
    hInstance: c.HINSTANCE align(1) = null,
    dwFlags: c_int align(1) = 0,
    dwCommonButtons: c_int align(1) = 0,
    pszWindowTitle: ?[*:0]const u16 align(1) = null,
    pszMainIcon: ?[*:0]align(1) const u16 align(1) = null,
    pszMainInstruction: ?[*:0]const u16 align(1) = null,
    pszContent: ?[*:0]const u16 align(1) = null,
    cButtons: c.UINT align(1) = 0,
    pButtons: ?[*]const Button align(1) = null,
    nDefaultButton: c_int align(1) = 0,
    cRadioButtons: c.UINT align(1) = 0,
    pRadioButtons: ?[*]const Button align(1) = null,
    nDefaultRadioButton: c_int align(1) = 0,
    pszVerificationText: ?[*:0]const u16 align(1) = null,
    pszExpandedInformation: ?[*:0]const u16 align(1) = null,
    pszExpandedControlText: ?[*:0]const u16 align(1) = null,
    pszCollapsedControlText: ?[*:0]const u16 align(1) = null,
    pszFooterIcon: ?[*:0]align(1) const u16 align(1) = null,
    pszFooter: ?[*:0]const u16 align(1) = null,
    pfCallback: ?*const anyopaque align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: c.UINT align(1) = 0,
};

comptime {
    // As commctrl.h lays them out.
    const pointer = @sizeOf(usize);
    std.debug.assert(@sizeOf(Button) == 4 + pointer);
    std.debug.assert(@sizeOf(Config) == 8 * 4 + 16 * pointer);
    std.debug.assert(@offsetOf(Config, "pButtons") == 4 * 4 + 6 * pointer);
}

const TaskDialogIndirect = *const fn (
    config: *const Config,
    button: ?*c_int,
    radio_button: ?*c_int,
    verification: ?*c.BOOL,
) callconv(.winapi) c.HRESULT;

/// `TaskDialogIndirect`, looked up rather than imported: only version 6
/// of comctl32 has it, and a program that imports it without the
/// manifest that asks for version 6 (the unit tests) doesn't start.
fn taskDialog() ?TaskDialogIndirect {
    const module = c.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("comctl32.dll")) orelse return null;
    const proc = c.GetProcAddress(module, "TaskDialogIndirect") orelse return null;
    return @ptrCast(proc);
}
