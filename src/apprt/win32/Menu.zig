//! Native popup menus: the terminal context menu, and the main menu,
//! which is shown from the tab bar's menu button and added to each
//! window's system menu (the title bar menu, also opened with Alt+Space).
//!
//! Items run keybind actions on a surface, so they do the same thing as
//! the equivalent keybind and show its shortcut, like GTK's menus. Shell
//! submenus open a new tab or window with one of the shells.
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const i18n = @import("../../os/main.zig").i18n;
const Binding = input.Binding;

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");
const shells = @import("shells.zig");

const log = std.log.scoped(.win32);

pub const Item = union(enum) {
    action: Action,
    submenu: Submenu,
    separator,

    /// A submenu of the shells, which opens the chosen one.
    shells: Shells,

    pub const Action = struct {
        label: []const u8,
        action: Binding.Action,
    };

    pub const Submenu = struct {
        label: []const u8,
        items: []const Item,
    };

    pub const Shells = struct {
        label: []const u8,
        target: Target,
    };

    fn act(label: []const u8, action: Binding.Action) Item {
        return .{ .action = .{ .label = label, .action = action } };
    }

    fn sub(label: []const u8, items: []const Item) Item {
        return .{ .submenu = .{ .label = label, .items = items } };
    }

    fn shellsIn(label: []const u8, target: Target) Item {
        return .{ .shells = .{ .label = label, .target = target } };
    }
};

/// Where a shell from a shell submenu opens.
pub const Target = enum { tab, window };

/// What a menu item does: run an action, or open a shell, by its index in
/// the list of shells the menu was built with.
pub const Choice = union(enum) {
    action: Binding.Action,
    shell: struct { target: Target, index: usize },
};

/// Shell items have IDs from here, a block of `max_shells` for each target,
/// after the actions'. Shifted for the system menu, they stay below 0xF000.
const shell_id_base = 0x100;
const max_shells = 0x100;

const split_items = [_]Item{
    .act("Change &Title…", .prompt_surface_title),
    .separator,
    .act("Split &Up", .{ .new_split = .up }),
    .act("Split &Down", .{ .new_split = .down }),
    .act("Split &Left", .{ .new_split = .left }),
    .act("Split &Right", .{ .new_split = .right }),
    .separator,
    .act("&Close Split", .close_surface),
};

const config_items = [_]Item{
    .act("&Open Configuration", .{ .open_config = .os_open }),
    .act("&Reload Configuration", .reload_config),
};

/// The menu for right clicks in a terminal: what applies to the terminal.
/// Tabs have their own menu (right click a tab), and windows and the
/// config are in the title bar's menu, so they aren't repeated here.
pub const context = [_]Item{
    .act("&Copy", .{ .copy_to_clipboard = .mixed }),
    .act("&Paste", .paste_from_clipboard),
    .act("Select &All", .select_all),
    .separator,
    .act("&Find…", .start_search),
    .separator,
    .sub("&Split", &split_items),
    .separator,
    .act("Cl&ear", .clear_screen),
    .act("&Reset", .reset),
};

/// The menu for right clicks on a tab, like GTK's. It runs on the tab's
/// focused terminal.
pub const tab = [_]Item{
    .act("Change Tab &Title…", .prompt_tab_title),
    .act("&New Tab", .new_tab),
    .shellsIn("New Tab With S&hell", .tab),
    .act("Reo&pen Closed Tab", .undo),
    .separator,
    .act("&Move Tab to New Window", .move_tab_to_new_window),
    .separator,
    .act("&Close Tab", .{ .close_tab = .this }),
    .act("Close &Other Tabs", .{ .close_tab = .other }),
    .act("Close Tabs to the &Right", .{ .close_tab = .right }),
};

/// The window's main menu: the title bar's (right click, or Alt+Space) and
/// the tab bar's empty space. Windows has no menu bar, so it has macOS's
/// menus as submenus, with the same items where Windows has them, except
/// those the system menu above already has (Maximize, Close Window).
pub const main = [_]Item{
    .sub("&Ghostty", &app_items),
    .sub("&File", &file_items),
    .sub("&Edit", &edit_items),
    .sub("&View", &view_items),
    .sub("&Window", &window_items),
};

const app_items = [_]Item{
    .act("&Open Configuration", .{ .open_config = .os_open }),
    .act("&Reload Configuration", .reload_config),
    .separator,
    .act("&Quit Ghostty", .quit),
};

const file_items = [_]Item{
    .act("New &Window", .new_window),
    .act("New &Tab", .new_tab),
    .shellsIn("New Window With S&hell", .window),
    .shellsIn("New Tab With Sh&ell", .tab),
    .separator,
    .act("Split &Right", .{ .new_split = .right }),
    .act("Split &Left", .{ .new_split = .left }),
    .act("Split &Down", .{ .new_split = .down }),
    .act("Split &Up", .{ .new_split = .up }),
    .separator,
    .act("&Close", .close_surface),
    .act("Close T&ab", .{ .close_tab = .this }),
    .act("Close All W&indows", .close_all_windows),
};

const edit_items = [_]Item{
    .act("&Undo", .undo),
    .act("&Redo", .redo),
    .separator,
    .act("&Copy", .{ .copy_to_clipboard = .mixed }),
    .act("&Paste", .paste_from_clipboard),
    .act("Paste &Selection", .paste_from_selection),
    .act("Select &All", .select_all),
    .separator,
    .act("&Find…", .start_search),
    .act("Find &Next", .{ .navigate_search = .next }),
    .act("Find Pre&vious", .{ .navigate_search = .previous }),
    .act("&Hide Find Bar", .end_search),
    .act("Use Selection for Fin&d", .search_selection),
    .act("&Jump to Selection", .scroll_to_selection),
};

const view_items = [_]Item{
    .act("&Reset Font Size", .reset_font_size),
    .act("&Increase Font Size", .{ .increase_font_size = 1 }),
    .act("&Decrease Font Size", .{ .decrease_font_size = 1 }),
    .separator,
    .act("Command &Palette", .toggle_command_palette),
    .separator,
    .act("Change Tab &Title…", .prompt_tab_title),
    .act("Change Ter&minal Title…", .prompt_surface_title),
    .act("Change &Window Title…", .prompt_window_title),
    .separator,
    .act("Terminal Read-&only", .toggle_readonly),
    .act("&Quick Terminal", .toggle_quick_terminal),
    .act("Terminal I&nspector", .{ .inspector = .toggle }),
    .separator,
    .act("Cl&ear", .clear_screen),
    .act("Re&set", .reset),
};

/// Only what's about the window. The macOS app's Window menu also has
/// its split commands (zoom, select, equalize), which are keyboard
/// commands here (and in the command palette), and "Show/Hide All
/// Terminals", which on Windows left no window to get them back from:
/// `toggle_visibility` is for a global keybind.
const window_items = [_]Item{
    .act("&Full Screen", .toggle_fullscreen),
    .act("Float on &Top", .toggle_window_float_on_top),
    .act("Return to &Default Size", .reset_window_size),
};

/// For labels that have no translation of their own (they follow the
/// macOS app's menus, which aren't translated), a message with one that
/// says the same, from GTK's menus or the command palette. Keyed by the
/// label without its access key.
const translated_as: std.StaticStringMap([:0]const u8) = .initComptime(.{
    .{ "Find Next", "Next Match" },
    .{ "Find Previous", "Previous Match" },
    .{ "Float on Top", "Toggle Float on Top" },
    .{ "Full Screen", "Toggle Fullscreen" },
    .{ "Hide Find Bar", "End Search" },
    .{ "Jump to Selection", "Scroll to Selection" },
    .{ "Open Configuration", "Open Configuration in OS Editor" },
    .{ "Paste Selection", "Paste from Selection" },
    .{ "Quit Ghostty", "Quit" },
    .{ "Reopen Closed Tab", "Undo" },
    .{ "Return to Default Size", "Reset Window Size" },
    .{ "Terminal Read-only", "Toggle Read-Only Mode" },
    .{ "Use Selection for Find", "Search Selection" },
});

/// A label in the user's language, if we have a translation for it;
/// otherwise as it is, with its access key. Translations come from GTK's
/// menus, which have no access keys; Windows then takes an item's first
/// letter.
fn localized(label: []const u8) []const u8 {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (label) |ch| {
        if (ch == '&') continue;
        if (len + 1 == buf.len) return label;
        buf[len] = ch;
        len += 1;
    }
    buf[len] = 0;
    const plain = buf[0..len :0];
    if (i18n.translation(plain)) |v| return v;
    if (translated_as.get(plain)) |msgid| {
        if (i18n.translation(msgid)) |v| return v;
    }
    return label;
}

test localized {
    const testing = std.testing;
    if (comptime !i18n.embedded) return error.SkipZigTest;

    // English, as written.
    try testing.expectEqualStrings("&Copy", localized("&Copy"));
    try testing.expectEqualStrings("Find &Next", localized("Find &Next"));

    try testing.expect(i18n.useEmbeddedLocale("de"));
    defer _ = i18n.useEmbeddedLocale(null);
    try testing.expectEqualStrings("Kopieren", localized("&Copy"));
    try testing.expectEqualStrings("Tabtitel ändern…", localized("Change Tab &Title…"));
    // By way of another message.
    try testing.expectEqualStrings("Nächste Übereinstimmung", localized("Find &Next"));
    // Nothing to translate it with.
    try testing.expectEqualStrings("&File", localized("&File"));
    const long: [200]u8 = @splat('a');
    try testing.expectEqualStrings(&long, localized(&long));
}

test "menu labels translated by way of another message" {
    const testing = std.testing;
    if (comptime !i18n.embedded) return error.SkipZigTest;
    defer _ = i18n.useEmbeddedLocale(null);

    // Each is the label of an item, and names a message that some locale
    // translates: upstream renaming one would otherwise go unnoticed.
    const locales = @import("../../os/i18n_locales.zig").locales;
    for (translated_as.keys(), translated_as.values()) |label, msgid| {
        errdefer std.debug.print("label: {s}, message: {s}\n", .{ label, msgid });
        try testing.expect(hasLabel(&main, label) or hasLabel(&context, label) or hasLabel(&tab, label));
        const found = for (locales) |locale| {
            try testing.expect(i18n.useEmbeddedLocale(locale));
            if (i18n.translation(msgid) != null) break true;
        } else false;
        try testing.expect(found);
    }
}

/// Whether a menu has an item with the label, not counting access keys.
fn hasLabel(items: []const Item, plain: []const u8) bool {
    for (items) |item| {
        const label = switch (item) {
            .separator => continue,
            .action => |a| a.label,
            .submenu => |s| label: {
                if (hasLabel(s.items, plain)) return true;
                break :label s.label;
            },
            .shells => |s| s.label,
        };
        var it = std.mem.tokenizeScalar(u8, label, '&');
        var rest = plain;
        const same = while (it.next()) |part| {
            if (!std.mem.startsWith(u8, rest, part)) break false;
            rest = rest[part.len..];
        } else rest.len == 0;
        if (same) return true;
    }
    return false;
}

/// The ID of the first item in the system menu. Windows uses the low four
/// bits of system menu command IDs, and IDs from 0xF000 are its own.
const sys_id_shift = 4;

/// Show a popup menu at a screen position and run the chosen item on the
/// surface.
///
/// This native menu pumps messages: the surface may close while it's open.
pub fn track(
    items: []const Item,
    surface: *Surface,
    owner: c.HWND,
    pt: c.POINT,
    flags: c_uint,
) void {
    var arena: std.heap.ArenaAllocator = .init(surface.app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    const list = shellsFor(alloc, items);
    var next_id: usize = 1;
    build(alloc, menu, items, surface, list, &next_id, 0) catch |err| {
        log.warn("error building menu err={}", .{err});
        return;
    };

    const hwnd = surface.hwnd;
    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    const selected = c.TrackPopupMenu(
        menu,
        @as(c_uint, c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON) | flags,
        pt.x,
        pt.y,
        0,
        owner,
        null,
    );
    if (selected <= 0 or c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;
    if (choiceAt(items, @intCast(selected))) |choice| perform(surface, choice, list);
}

/// Do what a chosen item does on the surface, with the shells the menu was
/// built with.
pub fn perform(surface: *Surface, choice: Choice, list: []const shells.Shell) void {
    switch (choice) {
        .action => |action| surface.performMenuAction(action),
        .shell => |shell| if (shell.index < list.len) {
            surface.openShell(shell.target, list[shell.index].command);
        },
    }
}

/// The shells for the items' shell submenus, if they have any.
pub fn shellsFor(alloc: Allocator, items: []const Item) []const shells.Shell {
    if (!hasShells(items)) return &.{};
    return shells.list(alloc) catch |err| {
        log.warn("error listing shells err={}", .{err});
        return &.{};
    };
}

fn hasShells(items: []const Item) bool {
    for (items) |item| switch (item) {
        .shells => return true,
        .submenu => |s| if (hasShells(s.items)) return true,
        else => {},
    };
    return false;
}

/// Append the shells to a menu with consecutive IDs (shifted left by
/// `shift`) from `first_id`, with a separator after the configured one.
pub fn appendShells(
    alloc: Allocator,
    menu: c.HMENU,
    list: []const shells.Shell,
    first_id: usize,
    shift: u6,
) !void {
    for (list, 0..) |shell, i| {
        _ = c.AppendMenuW(
            menu,
            c.MF_STRING,
            (first_id + i) << shift,
            (try util.utf16Alloc(alloc, shell.label)).ptr,
        );
        if (i == 0 and list.len > 1) _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    }
}

/// Add the items to the end of a window's system menu, after a separator.
/// Its shell submenus list `list`, which perform needs when the command
/// comes.
pub fn appendToSystemMenu(
    alloc: Allocator,
    menu: c.HMENU,
    items: []const Item,
    surface: ?*Surface,
    list: []const shells.Shell,
) !void {
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    var next_id: usize = 1;
    try build(alloc, menu, items, surface, list, &next_id, sys_id_shift);
}

/// What a system menu command does, if it's one of our items.
pub fn systemCommand(items: []const Item, wparam: c.WPARAM) ?Choice {
    const id = wparam & 0xFFF0;
    if (id == 0 or id >= 0xF000) return null;
    return choiceAt(items, id >> sys_id_shift);
}

/// The shortcut to show for an action. The reverse map leaves out
/// performable bindings (like ctrl+shift+f for Find and ctrl+shift+c for
/// Copy) so that toolkits don't register them as shortcuts that would take
/// the key; our menus only show the text, so they can show those too.
pub fn shortcut(set: *const Binding.Set, action: Binding.Action) ?Binding.Trigger {
    if (set.getTrigger(action)) |t| return t;
    var it = set.bindings.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        .leaf => |leaf| if (leaf.action.hash() == action.hash()) return entry.key_ptr.*,
        else => {},
    };
    return null;
}

/// Append items to a menu. Actions get consecutive IDs (shifted left by
/// `shift`) in depth-first order, which actionAt follows. Items are
/// disabled if they don't apply to the surface.
fn build(
    alloc: Allocator,
    menu: c.HMENU,
    items: []const Item,
    surface: ?*Surface,
    list: []const shells.Shell,
    next_id: *usize,
    shift: u6,
) !void {
    for (items) |item| switch (item) {
        .separator => _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null),
        .action => |a| {
            const id = next_id.* << shift;
            next_id.* += 1;
            const name = localized(a.label);
            const label = if (surface) |s| label: {
                const trigger = shortcut(&s.app.config.keybind.set, a.action) orelse
                    break :label name;
                var buf: [64]u8 = undefined;
                const text = triggerText(&buf, trigger) catch break :label name;
                break :label try std.fmt.allocPrint(alloc, "{s}\t{s}", .{ name, text });
            } else name;
            var flags: c_uint = c.MF_STRING;
            if (surface) |s| if (!enabled(s, a.action)) {
                flags |= c.MF_GRAYED;
            };
            _ = c.AppendMenuW(menu, flags, id, (try util.utf16Alloc(alloc, label)).ptr);
        },
        .submenu => |s| {
            const submenu = c.CreatePopupMenu() orelse return error.CreateMenuFailed;
            errdefer _ = c.DestroyMenu(submenu);
            try build(alloc, submenu, s.items, surface, list, next_id, shift);
            try appendSubmenu(alloc, menu, c.MF_POPUP, submenu, localized(s.label));
        },
        .shells => |s| {
            const submenu = c.CreatePopupMenu() orelse return error.CreateMenuFailed;
            errdefer _ = c.DestroyMenu(submenu);
            const first = shell_id_base + @as(usize, @backingInt(s.target)) * max_shells;
            try appendShells(alloc, submenu, list[0..@min(list.len, max_shells)], first, shift);
            var flags: c_uint = c.MF_POPUP;
            if (list.len == 0) flags |= c.MF_GRAYED;
            if (surface) |sf| if (!sf.core_initialized) {
                flags |= c.MF_GRAYED;
            };
            try appendSubmenu(alloc, menu, flags, submenu, localized(s.label));
        },
    };
}

/// Append a submenu, which the menu then owns (destroying it with itself).
fn appendSubmenu(alloc: Allocator, menu: c.HMENU, flags: c_uint, submenu: c.HMENU, label: []const u8) !void {
    const text = try util.utf16Alloc(alloc, label);
    if (c.AppendMenuW(menu, flags, @intFromPtr(submenu), text.ptr) == 0) return error.AppendMenuFailed;
}

/// Whether an item applies to the surface right now.
fn enabled(surface: *Surface, action: Binding.Action) bool {
    if (!surface.core_initialized) return false;
    return switch (action) {
        .copy_to_clipboard => surface.core_surface.hasSelection(),
        .undo => surface.window.canUndo(),
        else => true,
    };
}

/// What the item with the given ID (from 1, unshifted) does.
fn choiceAt(items: []const Item, id: usize) ?Choice {
    if (id >= shell_id_base) {
        const offset = id - shell_id_base;
        const target = std.enums.fromInt(Target, offset / max_shells) orelse return null;
        return .{ .shell = .{ .target = target, .index = offset % max_shells } };
    }
    if (id == 0) return null;
    const action = actionAt(items, id - 1) orelse return null;
    return .{ .action = action };
}

/// The action of the item with the given index, counting actions in
/// depth-first order.
fn actionAt(items: []const Item, index: usize) ?Binding.Action {
    var i = index;
    return actionAtInner(items, &i);
}

fn actionAtInner(items: []const Item, i: *usize) ?Binding.Action {
    for (items) |item| switch (item) {
        .separator => {},
        .action => |a| {
            if (i.* == 0) return a.action;
            i.* -= 1;
        },
        .submenu => |s| if (actionAtInner(s.items, i)) |a| return a,
        .shells => {},
    };
    return null;
}

/// Format a trigger like Windows menus do, for example "Ctrl+Shift+T".
pub fn triggerText(buf: []u8, trigger: Binding.Trigger) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    if (trigger.mods.ctrl) try writer.writeAll("Ctrl+");
    if (trigger.mods.alt) try writer.writeAll("Alt+");
    if (trigger.mods.shift) try writer.writeAll("Shift+");
    if (trigger.mods.super) try writer.writeAll("Win+");
    switch (trigger.key) {
        .physical => |key| switch (key) {
            .space => try writer.writeAll("Space"),
            .arrow_up => try writer.writeAll("Up"),
            .arrow_down => try writer.writeAll("Down"),
            .arrow_left => try writer.writeAll("Left"),
            .arrow_right => try writer.writeAll("Right"),
            .page_up => try writer.writeAll("PgUp"),
            .page_down => try writer.writeAll("PgDn"),
            .escape => try writer.writeAll("Esc"),
            .delete => try writer.writeAll("Del"),
            .insert => try writer.writeAll("Ins"),
            else => if (key.codepoint()) |cp|
                try writeKeyCodepoint(&writer, cp)
            else
                try writeKeyName(&writer, @tagName(key)),
        },
        .unicode => |cp| try writeKeyCodepoint(&writer, cp),
        .catch_all => return error.NoKey,
    }
    return writer.buffered();
}

fn writeKeyCodepoint(writer: *std.Io.Writer, cp: u21) !void {
    const upper: u21 = if (cp < 0x80) std.ascii.toUpper(@intCast(cp)) else cp;
    try writer.print("{u}", .{upper});
}

/// Write a key's tag name in title case, for example "page_up" as
/// "Page Up" and "f1" as "F1".
fn writeKeyName(writer: *std.Io.Writer, name: []const u8) !void {
    var start = true;
    for (name) |ch| {
        if (ch == '_') {
            try writer.writeByte(' ');
            start = true;
            continue;
        }
        try writer.writeByte(if (start) std.ascii.toUpper(ch) else ch);
        start = false;
    }
}

test triggerText {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+T", try triggerText(&buf, .{
        .key = .{ .physical = .key_t },
        .mods = .{ .ctrl = true, .shift = true },
    }));
    try testing.expectEqualStrings("Ctrl+,", try triggerText(&buf, .{
        .key = .{ .physical = .comma },
        .mods = .{ .ctrl = true },
    }));
    try testing.expectEqualStrings("Alt+Enter", try triggerText(&buf, .{
        .key = .{ .physical = .enter },
        .mods = .{ .alt = true },
    }));
    try testing.expectEqualStrings("Ctrl+PgUp", try triggerText(&buf, .{
        .key = .{ .physical = .page_up },
        .mods = .{ .ctrl = true },
    }));
    try testing.expectEqualStrings("Win+F11", try triggerText(&buf, .{
        .key = .{ .physical = .f11 },
        .mods = .{ .super = true },
    }));
    try testing.expectEqualStrings("Ctrl+A", try triggerText(&buf, .{
        .key = .{ .unicode = 'a' },
        .mods = .{ .ctrl = true },
    }));
}

test actionAt {
    const testing = std.testing;
    const items = [_]Item{
        .act("a", .new_tab),
        .separator,
        .sub("s", &.{ .act("b", .new_window), .act("c", .quit) }),
        .act("d", .reset),
    };
    try testing.expectEqual(Binding.Action.new_tab, actionAt(&items, 0).?);
    try testing.expectEqual(Binding.Action.new_window, actionAt(&items, 1).?);
    try testing.expectEqual(Binding.Action.quit, actionAt(&items, 2).?);
    try testing.expectEqual(Binding.Action.reset, actionAt(&items, 3).?);
    try testing.expect(actionAt(&items, 4) == null);
}

test systemCommand {
    const testing = std.testing;
    try testing.expectEqual(Choice{ .action = .{ .open_config = .os_open } }, systemCommand(&main, 1 << sys_id_shift).?);
    try testing.expect(systemCommand(&main, 0xF060) == null);
    try testing.expect(systemCommand(&main, 0) == null);

    // Shells, after the actions, for each target.
    try testing.expectEqual(
        Choice{ .shell = .{ .target = .tab, .index = 2 } },
        systemCommand(&main, (shell_id_base + 2) << sys_id_shift).?,
    );
    try testing.expectEqual(
        Choice{ .shell = .{ .target = .window, .index = 0 } },
        systemCommand(&main, (shell_id_base + max_shells) << sys_id_shift).?,
    );
    try testing.expect(((shell_id_base + 2 * max_shells) << sys_id_shift) <= 0xF000);
}

test "menus have fewer actions than the first shell ID" {
    const testing = std.testing;
    for ([_][]const Item{ &main, &context, &tab }) |items| {
        var count: usize = 0;
        while (actionAt(items, count) != null) count += 1;
        try testing.expect(count < shell_id_base);
    }
}

/// The access key of a label (the letter after `&`), lowercased, if it
/// has one.
fn accessKey(label: []const u8) ?u8 {
    const i = std.mem.indexOfScalar(u8, label, '&') orelse return null;
    if (i + 1 >= label.len) return null;
    return std.ascii.toLower(label[i + 1]);
}

/// Checks that each item in a menu (not counting its submenus) has an
/// access key, no other item in the menu has the same one, and separators
/// only go between items.
fn expectAccessKeys(items: []const Item) !void {
    const testing = std.testing;
    var seen: std.StaticBitSet(256) = .empty;
    for (items, 0..) |item, i| {
        const label = switch (item) {
            .separator => {
                try testing.expect(i > 0 and i + 1 < items.len);
                try testing.expect(items[i + 1] != .separator);
                continue;
            },
            .action => |a| a.label,
            .submenu => |s| label: {
                try expectAccessKeys(s.items);
                break :label s.label;
            },
            .shells => |s| s.label,
        };
        const key = accessKey(label) orelse {
            std.debug.print("no access key: {s}\n", .{label});
            return error.TestExpectedAccessKey;
        };
        if (seen.isSet(key)) {
            std.debug.print("access key '{c}' used twice, again by: {s}\n", .{ key, label });
            return error.TestDuplicateAccessKey;
        }
        seen.set(key);
    }
}

test "menu items have their own access keys" {
    try std.testing.expectEqual(@as(?u8, 't'), accessKey("Change &Title…"));
    try std.testing.expectEqual(@as(?u8, null), accessKey("Title"));
    for ([_][]const Item{ &main, &context, &tab }) |items| try expectAccessKeys(items);
}
