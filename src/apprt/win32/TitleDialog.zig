//! A modal dialog that prompts for a title, for the prompt_title action.
//!
//! Win32 has no built-in text input box, so we build a small dialog
//! template in memory rather than adding a resource script.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

const id_edit = 100;

/// Our dialog's state, passed through WM_INITDIALOG.
const State = struct {
    alloc: Allocator,
    initial: [:0]const u16,
    result: ?[:0]u8 = null,
};

/// Prompt for a title. Returns null if cancelled, or the new title
/// (possibly empty, which restores the default title). The caller owns
/// the returned memory.
pub fn prompt(
    alloc: Allocator,
    owner: c.HWND,
    kind: apprt.action.PromptTitle,
    initial: []const u8,
) !?[:0]u8 {
    const initial16 = try util.utf16Alloc(alloc, initial);
    defer alloc.free(initial16);

    const caption = switch (kind) {
        .surface => "Change Terminal Title",
        .tab => "Change Tab Title",
        .window => "Change Window Title",
    };
    var template: Template = .{};
    template.build(caption);

    var state: State = .{ .alloc = alloc, .initial = initial16 };
    const result = c.DialogBoxIndirectParamW(
        null,
        @ptrCast(&template.buf),
        owner,
        dlgProc,
        @bitCast(@intFromPtr(&state)),
    );
    if (result == -1) {
        log.warn("failed to show title dialog err={}", .{c.GetLastError()});
        return error.DialogFailed;
    }
    return state.result;
}

/// An in-memory DLGTEMPLATE with its items. See the "DLGTEMPLATE" and
/// "DLGITEMTEMPLATE" docs for the layout. Dimensions are in dialog units.
const Template = struct {
    buf: [512]u16 align(4) = undefined,
    len: usize = 0,

    const width = 220;
    const height = 62;

    fn build(self: *Template, caption: []const u8) void {
        self.header(caption);
        self.item(
            c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
            7,
            7,
            width - 14,
            9,
            -1, // IDC_STATIC
            0x0082,
            "Leave blank to restore the default title.",
        );
        self.item(
            c.WS_CHILD | c.WS_VISIBLE | c.WS_BORDER | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
            7,
            19,
            width - 14,
            13,
            id_edit,
            0x0081,
            "",
        );
        self.item(
            c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON,
            width - 7 - 50 - 4 - 50,
            height - 7 - 14,
            50,
            14,
            c.IDOK,
            0x0080,
            "OK",
        );
        self.item(
            c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON,
            width - 7 - 50,
            height - 7 - 14,
            50,
            14,
            c.IDCANCEL,
            0x0080,
            "Cancel",
        );
    }

    fn header(self: *Template, caption: []const u8) void {
        const style: u32 = c.DS_SETFONT | c.DS_MODALFRAME | c.DS_CENTER |
            c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU;
        self.dword(style);
        self.dword(0); // extended style
        self.word(4); // number of items
        self.word(0); // x
        self.word(0); // y
        self.word(width);
        self.word(height);
        self.word(0); // no menu
        self.word(0); // default dialog class
        self.string(caption);
        self.word(9); // font point size
        self.string("Segoe UI");
    }

    fn item(
        self: *Template,
        style: u32,
        x: i16,
        y: i16,
        cx: i16,
        cy: i16,
        id: c_int,
        class: u16,
        text: []const u8,
    ) void {
        // Each item starts on a DWORD boundary.
        if (self.len % 2 != 0) self.word(0);
        self.dword(style);
        self.dword(0); // extended style
        self.word(@bitCast(x));
        self.word(@bitCast(y));
        self.word(@bitCast(cx));
        self.word(@bitCast(cy));
        self.word(@bitCast(@as(i16, @intCast(id))));
        self.word(0xFFFF); // predefined class follows
        self.word(class);
        self.string(text);
        self.word(0); // no creation data
    }

    fn word(self: *Template, v: u16) void {
        self.buf[self.len] = v;
        self.len += 1;
    }

    fn dword(self: *Template, v: u32) void {
        self.word(@truncate(v));
        self.word(@truncate(v >> 16));
    }

    fn string(self: *Template, s: []const u8) void {
        self.len += std.unicode.utf8ToUtf16Le(self.buf[self.len..], s) catch unreachable;
        self.word(0);
    }
};

fn dlgProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.INT_PTR {
    switch (msg) {
        c.WM_INITDIALOG => {
            _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, lparam);
            const state: *State = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const edit = c.GetDlgItem(hwnd, id_edit);
            _ = c.SetWindowTextW(edit, state.initial);
            _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
            _ = c.SetFocus(edit);

            // We set the focus ourselves.
            return c.FALSE;
        },

        c.WM_COMMAND => {
            const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
            if (ptr == 0) return c.FALSE;
            const state: *State = @ptrFromInt(@as(usize, @bitCast(ptr)));
            switch (wparam & 0xFFFF) {
                c.IDOK => {
                    state.result = readText(state.alloc, c.GetDlgItem(hwnd, id_edit)) catch |err| {
                        log.warn("error reading title err={}", .{err});
                        _ = c.EndDialog(hwnd, c.IDCANCEL);
                        return c.TRUE;
                    };
                    _ = c.EndDialog(hwnd, c.IDOK);
                    return c.TRUE;
                },
                c.IDCANCEL => {
                    _ = c.EndDialog(hwnd, c.IDCANCEL);
                    return c.TRUE;
                },
                else => {},
            }
        },

        else => {},
    }
    return c.FALSE;
}

fn readText(alloc: Allocator, edit: c.HWND) ![:0]u8 {
    const len: usize = @intCast(@max(0, c.GetWindowTextLengthW(edit)));
    const buf = try alloc.allocSentinel(u16, len, 0);
    defer alloc.free(buf);
    const n: usize = @intCast(@max(0, c.GetWindowTextW(edit, buf.ptr, @intCast(len + 1))));
    return util.utf8Alloc(alloc, buf[0..n]);
}

test "title dialog template fits" {
    var template: Template = .{};
    template.build("Change Terminal Title");
    try std.testing.expect(template.len < template.buf.len);
}
