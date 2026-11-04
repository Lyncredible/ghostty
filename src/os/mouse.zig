const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

const log = std.log.scoped(.os);

/// The system-configured double-click interval if its available.
pub fn clickInterval() ?u32 {
    return switch (builtin.target.os.tag) {
        // On macOS, we can ask the system.
        .macos => macos: {
            const NSEvent = objc.getClass("NSEvent") orelse {
                log.err("NSEvent class not found. Can't get click interval.", .{});
                return null;
            };

            // Get the interval and convert to ms
            const interval = NSEvent.msgSend(f64, objc.sel("doubleClickInterval"), .{});
            const ms = @as(u32, @intFromFloat(@ceil(interval * 1000)));
            break :macos ms;
        },

        // On Windows, we can ask the system. This is in milliseconds.
        .windows => GetDoubleClickTime(),

        else => null,
    };
}

extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;

/// Whether the system hides the pointer while typing, if it has such a
/// setting. On Windows, this is "Hide pointer while typing" in the mouse
/// settings, which is on by default and which text editors follow.
pub fn hideWhileTyping() ?bool {
    return switch (builtin.target.os.tag) {
        .windows => windows: {
            const SPI_GETMOUSEVANISH = 0x1020;
            var on: i32 = 0;
            if (SystemParametersInfoW(SPI_GETMOUSEVANISH, 0, &on, 0) == 0) break :windows null;
            break :windows on != 0;
        },
        else => null,
    };
}

extern "user32" fn SystemParametersInfoW(action: u32, param: u32, value: ?*anyopaque, ini: u32) callconv(.winapi) i32;
