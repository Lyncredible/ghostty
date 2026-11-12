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
    _ = @import("win32/Dialog.zig");
    _ = @import("win32/CommandPalette.zig");
    _ = @import("win32/drop.zig");
    _ = @import("win32/SaveState.zig");
    _ = @import("win32/SplitDrag.zig");
    _ = @import("win32/Accessibility.zig");
    _ = @import("win32/TabBarAccessibility.zig");
    _ = @import("win32/TextRange.zig");
    _ = @import("win32/link.zig");
    _ = @import("win32/Handoff.zig");
    _ = @import("win32/JumpList.zig");
    _ = @import("win32/util.zig");
    _ = @import("win32/TabBar.zig");
    _ = @import("win32/TabGhost.zig");
    _ = @import("win32/Tab.zig");
    _ = @import("win32/Scrollbar.zig");
    _ = @import("win32/SearchBar.zig");
    _ = @import("win32/Badge.zig");
    _ = @import("win32/BellAudio.zig");
    _ = @import("win32/LinkPreview.zig");
    _ = @import("win32/shells.zig");
    _ = @import("win32/shell.zig");
}
