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

const tab_items = [_]Item{
    .act("Change Tab &Title…", .prompt_tab_title),
    .act("&New Tab", .new_tab),
    .shellsIn("New Tab With S&hell", .tab),
    .act("&Close Tab", .{ .close_tab = .this }),
};

const window_items = [_]Item{
    .act("Change Window &Title…", .prompt_window_title),
    .act("&New Window", .new_window),
    .act("&Close Window", .close_window),
};

const config_items = [_]Item{
    .act("&Open Configuration", .{ .open_config = .os_open }),
    .act("&Reload Configuration", .reload_config),
};

/// The menu for right clicks in a terminal.
pub const context = [_]Item{
    .act("&Copy", .{ .copy_to_clipboard = .mixed }),
    .act("&Paste", .paste_from_clipboard),
    .act("Select &All", .select_all),
    .separator,
    .act("Cl&ear", .clear_screen),
    .act("&Reset", .reset),
    .separator,
    .sub("&Split", &split_items),
    .sub("&Tab", &tab_items),
    .sub("&Window", &window_items),
    .separator,
    .sub("C&onfig", &config_items),
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

/// The window's main menu.
pub const main = [_]Item{
    .act("&New Window", .new_window),
    .act("New &Tab", .new_tab),
    .shellsIn("New Window &With Shell", .window),
    .shellsIn("New Tab With S&hell", .tab),
    .sub("&Split", &split_items),
    .separator,
    .act("&Copy", .{ .copy_to_clipboard = .mixed }),
    .act("&Paste", .paste_from_clipboard),
    .act("&Find…", .start_search),
    .separator,
    .act("Change Window &Title…", .prompt_window_title),
    .act("Change Tab Title…", .prompt_tab_title),
    .separator,
    .act("Cl&ear", .clear_screen),
    .act("&Reset", .reset),
    .act("F&ull Screen", .toggle_fullscreen),
    .separator,
    .act("Command Pa&lette", .toggle_command_palette),
    .act("Terminal &Inspector", .{ .inspector = .toggle }),
    .sub("C&onfig", &config_items),
    .separator,
    .act("&Quit", .quit),
};

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
            const label = if (surface) |s| label: {
                const trigger = s.app.config.keybind.set.getTrigger(a.action) orelse
                    break :label a.label;
                var buf: [64]u8 = undefined;
                const text = triggerText(&buf, trigger) catch break :label a.label;
                break :label try std.fmt.allocPrint(alloc, "{s}\t{s}", .{ a.label, text });
            } else a.label;
            var flags: c_uint = c.MF_STRING;
            if (surface) |s| if (!enabled(s, a.action)) {
                flags |= c.MF_GRAYED;
            };
            _ = c.AppendMenuW(menu, flags, id, (try util.utf16Alloc(alloc, label)).ptr);
        },
        .submenu => |s| {
            const submenu = c.CreatePopupMenu() orelse return error.CreateMenuFailed;
            try build(alloc, submenu, s.items, surface, list, next_id, shift);
            _ = c.AppendMenuW(
                menu,
                c.MF_POPUP,
                @intFromPtr(submenu),
                (try util.utf16Alloc(alloc, s.label)).ptr,
            );
        },
        .shells => |s| {
            const submenu = c.CreatePopupMenu() orelse return error.CreateMenuFailed;
            const first = shell_id_base + @as(usize, @backingInt(s.target)) * max_shells;
            try appendShells(alloc, submenu, list[0..@min(list.len, max_shells)], first, shift);
            var flags: c_uint = c.MF_POPUP;
            if (list.len == 0) flags |= c.MF_GRAYED;
            if (surface) |sf| if (!sf.core_initialized) {
                flags |= c.MF_GRAYED;
            };
            _ = c.AppendMenuW(
                menu,
                flags,
                @intFromPtr(submenu),
                (try util.utf16Alloc(alloc, s.label)).ptr,
            );
        },
    };
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
    try testing.expectEqual(Choice{ .action = .new_window }, systemCommand(&main, 1 << sys_id_shift).?);
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
