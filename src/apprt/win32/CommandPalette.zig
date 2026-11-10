//! The command palette: a search field over a list of the configured
//! `command-palette-entry` commands and of the open terminals, like GTK's.
//!
//! It's a layered child window of the surface, like the search bar, since
//! the surface's flip model swap chain covers regular child windows. Its
//! windows are made the first time it opens (they took about 3 ms of each
//! new tab).
const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const util = @import("util.zig");
const i18n = @import("../../os/main.zig").i18n;
const c = util.c;
const Menu = @import("Menu.zig");

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyCommandPalette");

/// What the user chose, handled by the surface.
pub const Choice = union(enum) {
    /// Run an action on the surface.
    action: input.Binding.Action,

    /// Focus a terminal. It may have closed since the palette opened.
    surface: *CoreSurface,
};

/// What the palette lists.
pub const Contents = enum {
    /// The configured commands, then every terminal.
    commands,

    /// Only the given terminals, for the tab overview. Their titles are
    /// shown as they are.
    terminals,
};

/// A terminal that can be focused from the palette.
pub const Target = struct {
    surface: *CoreSurface,
    title: []const u8,
    pwd: ?[]const u8 = null,
};

const Entry = struct {
    title: [:0]const u16,
    description: [:0]const u16,
    shortcut: [:0]const u16,

    /// Lowercase text that the search matches.
    search: []const u8,
    choice: Choice,
};

/// Sizes at 96 DPI.
const width = 560;
const field_height = 40;
const row_height = 44;
const max_rows = 8;
const pad = 8;

/// The longest query, in UTF-16 units.
const max_query = 255;

hwnd: c.HWND = null,
edit: c.HWND = null,
list: c.HWND = null,
parent: c.HWND = null,
instance: c.HINSTANCE = null,
font: util.MessageFont = .{},
small_font: util.MessageFont = .{},
edit_proc: c.WNDPROC = null,

on_choose: ?*const fn (ctx: *anyopaque, choice: Choice) void = null,
ctx: *anyopaque = undefined,

background: c.COLORREF = 0,
field: c.COLORREF = 0,
foreground: c.COLORREF = 0xFFFFFF,
dim: c.COLORREF = 0xAAAAAA,

/// Whether the background is dark, for a dark list scrollbar.
dark: bool = false,
background_brush: c.HBRUSH = null,
field_brush: c.HBRUSH = null,

/// What the palette lists while it's open.
contents: Contents = .commands,

/// The entries while the palette is open, allocated in the arena.
arena: ?std.heap.ArenaAllocator = null,
entries: []Entry = &.{},

pub fn init(
    self: *CommandPalette,
    parent: c.HWND,
    instance: c.HINSTANCE,
    config: *const Config,
    ctx: *anyopaque,
    on_choose: *const fn (ctx: *anyopaque, choice: Choice) void,
) void {
    self.parent = parent;
    self.instance = instance;
    self.ctx = ctx;
    self.on_choose = on_choose;
    self.updateConfig(config);
}

fn createWindows(self: *CommandPalette) !void {
    if (self.hwnd != null) return;
    const hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_CONTROLPARENT,
        class_name,
        null,
        c.WS_CHILD | c.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        self.parent,
        null,
        self.instance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(hwnd);
    if (c.SetLayeredWindowAttributes(hwnd, 0, 255, c.LWA_ALPHA) == 0) {
        return error.SetOpacityFailed;
    }

    const edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        self.instance,
        null,
    ) orelse return error.CreateWindowFailed;
    const list = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX"),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_VSCROLL | c.LBS_NOTIFY |
            c.LBS_OWNERDRAWFIXED | c.LBS_HASSTRINGS | c.LBS_NOINTEGRALHEIGHT,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        self.instance,
        null,
    ) orelse return error.CreateWindowFailed;

    // Subclass the edit control to move through the list from the field.
    _ = c.SetWindowLongPtrW(edit, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.edit_proc = @ptrFromInt(@as(usize, @bitCast(c.SetWindowLongPtrW(
        edit,
        c.GWLP_WNDPROC,
        @bitCast(@intFromPtr(&editProc)),
    ))));

    self.hwnd = hwnd;
    self.edit = edit;
    self.list = list;
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateListTheme();
}

/// A dark scrollbar for a dark background.
fn updateListTheme(self: *const CommandPalette) void {
    if (self.list == null) return;
    _ = c.SetWindowTheme(
        self.list,
        if (self.dark) std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer") else null,
        null,
    );
}

pub fn deinit(self: *CommandPalette) void {
    if (self.hwnd != null) {
        _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
        if (self.edit != null) util.unsubclass(self.edit, self.edit_proc);
        _ = c.DestroyWindow(self.hwnd);
    }
    self.font.deinit();
    self.small_font.deinit();
    if (self.background_brush != null) _ = c.DeleteObject(self.background_brush);
    if (self.field_brush != null) _ = c.DeleteObject(self.field_brush);
    if (self.arena) |*arena| arena.deinit();
    self.* = .{};
}

pub fn updateConfig(self: *CommandPalette, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;
    self.background = util.blend(bg, fg, 0.08);
    self.field = util.blend(bg, fg, 0.16);
    self.foreground = util.rgb(fg.r, fg.g, fg.b);
    self.dim = util.blend(fg, bg, 0.4);
    if (self.background_brush != null) _ = c.DeleteObject(self.background_brush);
    if (self.field_brush != null) _ = c.DeleteObject(self.field_brush);
    self.background_brush = c.CreateSolidBrush(self.background);

    self.dark = bg.toTerminalRGB().perceivedLuminance() <= 0.5;
    self.updateListTheme();
    self.field_brush = c.CreateSolidBrush(self.field);
    if (self.hwnd != null) _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

pub fn visible(self: *const CommandPalette) bool {
    return self.hwnd != null and
        c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE) & c.WS_VISIBLE != 0;
}

/// Open the palette with the given contents.
pub fn show(
    self: *CommandPalette,
    alloc: Allocator,
    config: *const Config,
    contents: Contents,
    targets: []const Target,
) void {
    self.createWindows() catch |err| {
        log.warn("unable to create the command palette err={}", .{err});
        return;
    };
    if (self.arena) |*arena| arena.deinit();
    self.arena = .init(alloc);
    self.contents = contents;
    self.entries = buildEntries(self.arena.?.allocator(), config, contents, targets) catch |err| entries: {
        log.warn("error building command palette err={}", .{err});
        break :entries &.{};
    };

    var cue_buf: [128]u16 = undefined;
    const cue = util.utf16TruncateZ(&cue_buf, switch (contents) {
        .commands => i18n.text("Execute a command…"),
        .terminals => "Switch to a tab…",
    });
    _ = c.SendMessageW(self.edit, c.EM_SETCUEBANNER, c.TRUE, @bitCast(@intFromPtr(cue.ptr)));
    _ = c.SendMessageW(self.edit, c.EM_SETLIMITTEXT, max_query, 0);
    _ = c.SetWindowTextW(self.edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
    self.filter();
    self.layout();
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    _ = c.SetFocus(self.edit);
}

/// Close the palette, returning focus to the surface if we had it.
pub fn hide(self: *CommandPalette) void {
    if (!self.visible()) return;
    const focus = c.GetFocus();
    const had_focus = focus == self.edit or focus == self.list;
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    _ = c.SendMessageW(self.list, c.LB_RESETCONTENT, 0, 0);
    if (self.arena) |*arena| arena.deinit();
    self.arena = null;
    self.entries = &.{};
    if (had_focus) _ = c.SetFocus(c.GetParent(self.hwnd));
}

/// Called when the parent surface is resized.
pub fn parentResized(self: *CommandPalette) void {
    if (self.visible()) self.layout();
}

fn buildEntries(
    alloc: Allocator,
    config: *const Config,
    contents: Contents,
    targets: []const Target,
) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    if (contents == .commands) for (config.@"command-palette-entry".value.items) |command| {
        if (!supported(command.action)) continue;

        var shortcut_buf: [64]u8 = undefined;
        const shortcut = if (Menu.shortcut(&config.keybind.set, command.action)) |trigger|
            Menu.triggerText(&shortcut_buf, trigger) catch ""
        else
            "";
        const action_key = try std.fmt.allocPrint(alloc, "{f}", .{command.action});
        try entries.append(alloc, .{
            .title = try util.utf16Alloc(alloc, command.title),
            .description = try util.utf16Alloc(alloc, command.description),
            .shortcut = try util.utf16Alloc(alloc, shortcut),
            .search = try searchText(alloc, &.{ command.title, action_key }),
            .choice = .{ .action = try command.action.clone(alloc) },
        });
    };

    // The commands come sorted by their English titles. Translated, they
    // go by the titles shown, in code unit order: near enough to find
    // one, and the same wherever it runs.
    if (i18n.translating()) {
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u16, a.title, b.title) == .lt;
            }
        }.lessThan);
    }

    for (targets) |target| {
        const title = switch (contents) {
            .commands => try std.fmt.allocPrint(alloc, "{s}: {s}", .{ i18n.text("Focus"), target.title }),
            .terminals => target.title,
        };

        // The working directory, unless the title already shows it.
        const description = if (target.pwd) |pwd|
            if (std.mem.indexOf(u8, target.title, pwd) == null) pwd else ""
        else
            "";
        try entries.append(alloc, .{
            .title = try util.utf16Alloc(alloc, title),
            .description = try util.utf16Alloc(alloc, description),
            .shortcut = try util.utf16Alloc(alloc, ""),
            .search = try searchText(alloc, &.{ title, description }),
            .choice = .{ .surface = target.surface },
        });
    }
    return try entries.toOwnedSlice(alloc);
}

/// Whether we implement an action, so that it's worth listing.
fn supported(action: input.Binding.Action) bool {
    return switch (action) {
        .toggle_secure_input,
        .check_for_updates,
        .redo,
        .undo,
        .toggle_command_palette,
        => false,

        else => true,
    };
}

/// The lowercase text the search matches, from the parts joined by spaces.
fn searchText(alloc: Allocator, parts: []const []const u8) ![]const u8 {
    const text = try std.mem.join(alloc, " ", parts);
    for (text) |*ch| ch.* = std.ascii.toLower(ch.*);
    return text;
}

/// Whether every word of the query is in the (lowercase) search text,
/// ignoring case.
fn matches(search: []const u8, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, &std.ascii.whitespace);
    while (words.next()) |word| {
        if (!containsIgnoreCase(search, word)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

test matches {
    const testing = std.testing;
    try testing.expect(matches("new tab new_tab", ""));
    try testing.expect(matches("new tab new_tab", "TAB"));
    try testing.expect(matches("split right new_split:right", "split rig"));
    try testing.expect(matches("split right new_split:right", "new_split"));
    try testing.expect(!matches("split right new_split:right", "split left"));
}

/// Show the entries that match the field, selecting the first.
fn filter(self: *CommandPalette) void {
    var buf: [max_query + 1]u16 = undefined;
    const len: usize = @intCast(@max(0, c.GetWindowTextW(self.edit, &buf, buf.len)));
    var query: [3 * buf.len]u8 = undefined;
    const n = std.unicode.wtf16LeToWtf8(&query, buf[0..len]);

    _ = c.SendMessageW(self.list, c.WM_SETREDRAW, c.FALSE, 0);
    defer {
        _ = c.SendMessageW(self.list, c.WM_SETREDRAW, c.TRUE, 0);
        _ = c.InvalidateRect(self.list, null, c.TRUE);
    }
    _ = c.SendMessageW(self.list, c.LB_RESETCONTENT, 0, 0);
    for (self.entries, 0..) |entry, i| {
        if (!matches(entry.search, query[0..n])) continue;
        // We draw the items ourselves, but give them their titles as text
        // so that screen readers (through the list box's UI Automation
        // proxy) can read them. The data is the entry's index.
        const item = c.SendMessageW(self.list, c.LB_ADDSTRING, 0, @bitCast(@intFromPtr(entry.title.ptr)));
        if (item < 0) continue;
        _ = c.SendMessageW(self.list, c.LB_SETITEMDATA, @intCast(item), @intCast(i));
    }
    _ = c.SendMessageW(self.list, c.LB_SETCURSEL, 0, 0);
    if (self.visible()) self.layout();
}

/// Move the selection by `delta` rows, staying within the list.
fn moveSelection(self: *CommandPalette, delta: isize) void {
    const count: isize = c.SendMessageW(self.list, c.LB_GETCOUNT, 0, 0);
    if (count <= 0) return;
    const current: isize = c.SendMessageW(self.list, c.LB_GETCURSEL, 0, 0);
    const next = std.math.clamp(@max(current, 0) + delta, 0, count - 1);
    _ = c.SendMessageW(self.list, c.LB_SETCURSEL, @intCast(next), 0);
}

/// Run the selected entry.
fn chooseSelected(self: *CommandPalette) void {
    const selected = c.SendMessageW(self.list, c.LB_GETCURSEL, 0, 0);
    if (selected < 0) return;
    const index: usize = @intCast(c.SendMessageW(self.list, c.LB_GETITEMDATA, @intCast(selected), 0));
    if (index >= self.entries.len) return;
    const choice = self.entries[index].choice;

    // Close first, so that the action runs with the surface focused.
    self.hide();
    _ = c.SetFocus(c.GetParent(self.hwnd));
    const on_choose = self.on_choose orelse return;
    on_choose(self.ctx, choice);
}

fn scale(self: *const CommandPalette, v: c_int) c_int {
    return util.scale(v, @intCast(c.GetDpiForWindow(self.hwnd)));
}

fn layout(self: *CommandPalette) void {
    var parent: c.RECT = undefined;
    _ = c.GetClientRect(c.GetParent(self.hwnd), &parent);
    self.updateFonts();

    const p = self.scale(pad);
    const w = @max(0, @min(self.scale(width), parent.right - 2 * p));
    const count: c_int = @intCast(@max(0, c.SendMessageW(self.list, c.LB_GETCOUNT, 0, 0)));
    const row = self.scale(row_height);
    const list_h = row * @min(count, max_rows);
    const field_h = self.scale(field_height);
    const h = @min(field_h + list_h + (if (count > 0) p else 0), parent.bottom - 2 * p);

    _ = c.SetWindowPos(
        self.hwnd,
        c.HWND_TOP,
        @divTrunc(parent.right - w, 2),
        p,
        w,
        h,
        c.SWP_NOACTIVATE,
    );
    _ = c.MoveWindow(
        self.edit,
        2 * p,
        p + self.scale(4),
        w - 4 * p,
        field_h - 2 * p - self.scale(8),
        c.TRUE,
    );
    _ = c.SendMessageW(self.list, c.LB_SETITEMHEIGHT, 0, row);
    _ = c.MoveWindow(self.list, 0, field_h, w, @max(0, h - field_h - (if (count > 0) p else 0)), c.TRUE);
    _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

fn updateFonts(self: *CommandPalette) void {
    const dpi = c.GetDpiForWindow(self.hwnd);
    self.small_font.refresh(dpi, 90);
    const change = self.font.update(dpi, 100) orelse return;
    // The edit control lets go of the old font before it's deleted.
    _ = c.SendMessageW(self.edit, c.WM_SETFONT, @intFromPtr(self.font.font), c.TRUE);
    if (change.old != null) _ = c.DeleteObject(change.old);
}

/// The colors to draw with: the terminal's, or with a high contrast
/// theme on, the theme's (the field is framed, and the selected entry is
/// highlighted).
const Colors = struct {
    background_brush: c.HBRUSH,
    field: c.COLORREF,
    field_brush: c.HBRUSH,
    foreground: c.COLORREF,
    dim: c.COLORREF,
    selected_brush: c.HBRUSH,
    selected_text: c.COLORREF,
    selected_dim: c.COLORREF,
    frame: bool,
};

fn colors(self: *const CommandPalette) Colors {
    if (util.highContrast()) return .{
        .background_brush = c.GetSysColorBrush(c.COLOR_WINDOW),
        .field = c.GetSysColor(c.COLOR_WINDOW),
        .field_brush = c.GetSysColorBrush(c.COLOR_WINDOW),
        .foreground = c.GetSysColor(c.COLOR_WINDOWTEXT),
        .dim = c.GetSysColor(c.COLOR_WINDOWTEXT),
        .selected_brush = c.GetSysColorBrush(c.COLOR_HIGHLIGHT),
        .selected_text = c.GetSysColor(c.COLOR_HIGHLIGHTTEXT),
        .selected_dim = c.GetSysColor(c.COLOR_HIGHLIGHTTEXT),
        .frame = true,
    };
    return .{
        .background_brush = self.background_brush,
        .field = self.field,
        .field_brush = self.field_brush,
        .foreground = self.foreground,
        .dim = self.dim,
        .selected_brush = self.field_brush,
        .selected_text = self.foreground,
        .selected_dim = self.dim,
        .frame = false,
    };
}

fn paint(self: *CommandPalette, dc: c.HDC) void {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &rect);
    const col = self.colors();
    _ = c.FillRect(dc, &rect, col.background_brush);

    // The field behind the edit control, slightly larger than it.
    var edit_rect: c.RECT = undefined;
    _ = c.GetWindowRect(self.edit, &edit_rect);
    _ = c.MapWindowPoints(null, self.hwnd, @ptrCast(&edit_rect), 2);
    _ = c.InflateRect(&edit_rect, self.scale(6), self.scale(4));
    _ = c.FillRect(dc, &edit_rect, col.field_brush);
    if (col.frame) _ = c.FrameRect(dc, &edit_rect, c.GetSysColorBrush(c.COLOR_WINDOWTEXT));
}

fn drawItem(self: *CommandPalette, item: *const c.DRAWITEMSTRUCT) void {
    if (item.itemID == std.math.maxInt(c.UINT)) return;
    const index: usize = item.itemData;
    if (index >= self.entries.len) return;
    const entry = &self.entries[index];
    const dc = item.hDC;

    const col = self.colors();
    const selected = item.itemState & c.ODS_SELECTED != 0;
    _ = c.FillRect(dc, &item.rcItem, if (selected) col.selected_brush else col.background_brush);
    _ = c.SetBkMode(dc, c.TRANSPARENT);

    const p = self.scale(pad);
    var rect = item.rcItem;
    rect.left += 2 * p;
    rect.right -= 2 * p;
    const has_description = entry.description.len > 0;
    const middle = @divTrunc(rect.top + rect.bottom, 2);

    // The shortcut, on the right, and the description are dimmed.
    const old_font = c.SelectObject(dc, self.small_font.font);
    defer _ = c.SelectObject(dc, old_font);
    _ = c.SetTextColor(dc, if (selected) col.selected_dim else col.dim);
    var shortcut_rect = rect;
    if (entry.shortcut.len > 0) {
        var size: c.SIZE = undefined;
        _ = c.GetTextExtentPoint32W(dc, entry.shortcut.ptr, @intCast(entry.shortcut.len), &size);
        shortcut_rect.left = rect.right - size.cx;
        _ = c.DrawTextW(dc, entry.shortcut.ptr, @intCast(entry.shortcut.len), &shortcut_rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_RIGHT | c.DT_NOPREFIX);
        rect.right = shortcut_rect.left - p;
    }

    // The description, below the title.
    if (has_description) {
        var description_rect = rect;
        description_rect.top = middle;
        _ = c.DrawTextW(dc, entry.description.ptr, @intCast(entry.description.len), &description_rect, c.DT_SINGLELINE | c.DT_TOP | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);
    }

    _ = c.SelectObject(dc, self.font.font);
    _ = c.SetTextColor(dc, if (selected) col.selected_text else col.foreground);
    var title_rect = rect;
    if (has_description) title_rect.bottom = middle;
    _ = c.DrawTextW(
        dc,
        entry.title.ptr,
        @intCast(entry.title.len),
        &title_rect,
        @as(c_uint, c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX) |
            @as(c_uint, if (has_description) c.DT_BOTTOM else c.DT_VCENTER),
    );
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *CommandPalette = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);
            self.paint(dc);
            return 0;
        },

        c.WM_CTLCOLOREDIT => {
            const dc = util.handle(c.HDC, wparam);
            const col = self.colors();
            _ = c.SetTextColor(dc, col.foreground);
            _ = c.SetBkColor(dc, col.field);
            return @bitCast(@intFromPtr(col.field_brush));
        },

        c.WM_CTLCOLORLISTBOX => return @bitCast(@intFromPtr(self.colors().background_brush)),

        c.WM_DRAWITEM => {
            const item: *const c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (item.hwndItem == self.list) {
                self.drawItem(item);
                return c.TRUE;
            }
        },

        c.WM_COMMAND => {
            const control = util.handle(c.HWND, lparam);
            const code = (wparam >> 16) & 0xFFFF;
            if (control == self.edit and code == c.EN_CHANGE) {
                self.filter();
                return 0;
            }
            if (control == self.list) switch (code) {
                // A click in the list runs the entry.
                c.LBN_SELCHANGE => if (c.GetKeyState(c.VK_LBUTTON) < 0) {
                    self.chooseSelected();
                    return 0;
                },
                c.LBN_KILLFOCUS => if (c.GetFocus() != self.edit) {
                    self.hide();
                    return 0;
                },
                else => {},
            };
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn editProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *CommandPalette = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_KEYDOWN => switch (wparam) {
            c.VK_RETURN => {
                self.chooseSelected();
                return 0;
            },
            c.VK_ESCAPE => {
                self.hide();
                return 0;
            },
            c.VK_UP => {
                self.moveSelection(-1);
                return 0;
            },
            c.VK_DOWN => {
                self.moveSelection(1);
                return 0;
            },
            c.VK_PRIOR => {
                self.moveSelection(-max_rows);
                return 0;
            },
            c.VK_NEXT => {
                self.moveSelection(max_rows);
                return 0;
            },
            else => {},
        },

        // Don't beep for the characters of the keys we handle.
        c.WM_CHAR => switch (wparam) {
            '\r', 0x1b => return 0,
            else => {},
        },

        // Close when focus leaves the palette, but not for its list.
        c.WM_KILLFOCUS => {
            const next = util.handle(c.HWND, wparam);
            const result = c.CallWindowProcW(self.edit_proc, hwnd, msg, wparam, lparam);
            if (next != self.list) self.hide();
            return result;
        },

        else => {},
    }
    return c.CallWindowProcW(self.edit_proc, hwnd, msg, wparam, lparam);
}
