//! Native popup menus: the terminal context menu, and the main menu,
//! which is shown from the tab bar's menu button and added to each
//! window's system menu (the title bar menu, also opened with Alt+Space).
//!
//! Items run keybind actions on a surface, so they do the same thing as
//! the equivalent keybind and show its shortcut, like GTK's menus.
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const Binding = input.Binding;

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

pub const Item = union(enum) {
    action: Action,
    submenu: Submenu,
    separator,

    pub const Action = struct {
        label: []const u8,
        action: Binding.Action,
    };

    pub const Submenu = struct {
        label: []const u8,
        items: []const Item,
    };

    fn act(label: []const u8, action: Binding.Action) Item {
        return .{ .action = .{ .label = label, .action = action } };
    }

    fn sub(label: []const u8, items: []const Item) Item {
        return .{ .submenu = .{ .label = label, .items = items } };
    }
};

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
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    var next_id: usize = 1;
    build(arena.allocator(), menu, items, surface, &next_id, 0) catch |err| {
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
    if (actionAt(items, @intCast(selected - 1))) |action| surface.performMenuAction(action);
}

/// Add the items to the end of a window's system menu, after a separator.
pub fn appendToSystemMenu(alloc: Allocator, menu: c.HMENU, items: []const Item, surface: ?*Surface) !void {
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    var next_id: usize = 1;
    try build(alloc, menu, items, surface, &next_id, sys_id_shift);
}

/// The action for a system menu command, if it's one of our items.
pub fn systemCommand(items: []const Item, wparam: c.WPARAM) ?Binding.Action {
    const id = wparam & 0xFFF0;
    if (id == 0 or id >= 0xF000) return null;
    return actionAt(items, (id >> sys_id_shift) - 1);
}

/// Append items to a menu. Actions get consecutive IDs (shifted left by
/// `shift`) in depth-first order, which actionAt follows. Items are
/// disabled if they don't apply to the surface.
fn build(
    alloc: Allocator,
    menu: c.HMENU,
    items: []const Item,
    surface: ?*Surface,
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
            try build(alloc, submenu, s.items, surface, next_id, shift);
            _ = c.AppendMenuW(
                menu,
                c.MF_POPUP,
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
        .undo => surface.window.closed_tabs.items.len > 0,
        else => true,
    };
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
    try testing.expectEqual(Binding.Action.new_window, systemCommand(&main, 1 << sys_id_shift).?);
    try testing.expect(systemCommand(&main, 0xF060) == null);
    try testing.expect(systemCommand(&main, 0) == null);
}
