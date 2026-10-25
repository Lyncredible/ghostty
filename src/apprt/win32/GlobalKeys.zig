//! System-wide keybinds (`global:` keybinds) with RegisterHotKey.
//!
//! Each global keybind is registered as a hot key on our message window,
//! which receives WM_HOTKEY with the hot key's ID while any application
//! is focused.
const GlobalKeys = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const Binding = input.Binding;
const configpkg = @import("../../config.zig");

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

/// The window that receives WM_HOTKEY.
hwnd: c.HWND,

/// The action for each registered hot key. The hot key ID is the index.
actions: std.ArrayList(Binding.Action) = .empty,

/// Owns the action data, which may point into the config.
arena: std.heap.ArenaAllocator,

pub fn init(alloc: Allocator, hwnd: c.HWND) GlobalKeys {
    return .{ .hwnd = hwnd, .arena = .init(alloc) };
}

pub fn deinit(self: *GlobalKeys) void {
    self.unregister();
    self.arena.deinit();
}

/// Register the global keybinds in the config, replacing any we had.
pub fn update(self: *GlobalKeys, config: *const configpkg.Config) void {
    self.unregister();
    _ = self.arena.reset(.retain_capacity);
    self.actions = .empty;
    const alloc = self.arena.allocator();

    var it = config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf: Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
            .leader => continue,
            inline .leaf, .leaf_chained => |leaf| leaf.generic(),
        };
        if (!leaf.flags.global) continue;

        // Like GTK, we only allow global keybinds with a single action.
        const actions = leaf.actionsSlice();
        if (actions.len != 1) continue;

        const trigger = entry.key_ptr.*;
        const hotkey = hotKey(trigger) orelse {
            log.warn("global keybind has no Windows hot key, ignoring trigger={f}", .{trigger});
            continue;
        };

        const cloned = actions[0].clone(alloc) catch |err| {
            log.warn("error copying global keybind action err={}", .{err});
            continue;
        };
        const id = self.actions.items.len;
        self.actions.append(alloc, cloned) catch continue;
        if (c.RegisterHotKey(self.hwnd, @intCast(id), hotkey.mods | c.MOD_NOREPEAT, hotkey.vk) == 0) {
            // Another application (or Windows) may own the hot key.
            log.warn("failed to register global keybind trigger={f} err={}", .{
                trigger,
                c.GetLastError(),
            });
            self.actions.items[id] = .ignore;
            continue;
        }
        log.debug("registered global keybind trigger={f}", .{trigger});
    }
}

/// The action for a WM_HOTKEY message's ID.
pub fn action(self: *const GlobalKeys, id: c.WPARAM) ?Binding.Action {
    if (id >= self.actions.items.len) return null;
    const result = self.actions.items[id];
    if (result == .ignore) return null;
    return result;
}

fn unregister(self: *GlobalKeys) void {
    for (self.actions.items, 0..) |a, id| {
        if (a != .ignore) _ = c.UnregisterHotKey(self.hwnd, @intCast(id));
    }
    self.actions = .empty;
}

const HotKey = struct { mods: c.UINT, vk: c.UINT };

/// The RegisterHotKey modifiers and virtual key for a trigger, if any.
fn hotKey(trigger: Binding.Trigger) ?HotKey {
    var mods = hotKeyMods(trigger.mods);
    const vk: c.UINT = switch (trigger.key) {
        .catch_all => return null,
        .physical => |key| vk: {
            const native = for (input.keycodes.entries) |entry| {
                if (entry.key == key) break entry.native;
            } else return null;
            if (native == 0) return null;
            break :vk c.MapVirtualKeyW(native, c.MAPVK_VSC_TO_VK_EX);
        },
        .unicode => |cp| vk: {
            if (cp > 0xFFFF) return null;
            const scan = c.VkKeyScanW(@intCast(cp));
            if (scan == -1) return null;
            const bits: u16 = @bitCast(scan);
            // The high byte is the shift state that produces the character.
            const state: u8 = @truncate(bits >> 8);
            if (state & 1 != 0) mods |= c.MOD_SHIFT;
            if (state & 2 != 0) mods |= c.MOD_CONTROL;
            if (state & 4 != 0) mods |= c.MOD_ALT;
            break :vk bits & 0xFF;
        },
    };
    if (vk == 0) return null;
    return .{ .mods = mods, .vk = vk };
}

fn hotKeyMods(mods: input.Mods) c.UINT {
    var result: c.UINT = 0;
    if (mods.shift) result |= c.MOD_SHIFT;
    if (mods.ctrl) result |= c.MOD_CONTROL;
    if (mods.alt) result |= c.MOD_ALT;
    if (mods.super) result |= c.MOD_WIN;
    return result;
}

test hotKeyMods {
    const testing = std.testing;
    try testing.expectEqual(@as(c.UINT, 0), hotKeyMods(.{}));
    try testing.expectEqual(
        @as(c.UINT, c.MOD_CONTROL | c.MOD_SHIFT),
        hotKeyMods(.{ .ctrl = true, .shift = true }),
    );
    try testing.expectEqual(
        @as(c.UINT, c.MOD_ALT | c.MOD_WIN),
        hotKeyMods(.{ .alt = true, .super = true }),
    );
}

test "hotKey catch_all" {
    try std.testing.expect(hotKey(.{ .key = .catch_all }) == null);
}
