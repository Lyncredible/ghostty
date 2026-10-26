//! Application runtime for native Windows, built directly on the Win32 API.
const internal_os = @import("../os/main.zig");

// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("win32/key.zig");
    _ = @import("win32/Notifier.zig");
    _ = @import("win32/TitleDialog.zig");
    _ = @import("win32/GlobalKeys.zig");
    _ = @import("win32/Ipc.zig");
    _ = @import("win32/Overrides.zig");
    _ = @import("win32/Window.zig");
    _ = @import("win32/Menu.zig");
    _ = @import("win32/CommandPalette.zig");
    _ = @import("win32/drop.zig");
    _ = @import("win32/SaveState.zig");
    _ = @import("win32/SplitDrag.zig");
}
