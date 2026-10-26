const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");

/// See build_config.ExeEntrypoint for why we do this.
const entrypoint = switch (build_config.exe_entrypoint) {
    .ghostty => @import("main_ghostty.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_ghostty_1 => @import("build/mdgen/main_ghostty_1.zig"),
    .mdgen_ghostty_5 => @import("build/mdgen/main_ghostty_5.zig"),
    .webgen_config => @import("build/webgen/main_config.zig"),
    .webgen_actions => @import("build/webgen/main_actions.zig"),
    .webgen_commands => @import("build/webgen/main_commands.zig"),
};

/// The main entrypoint for the program.
pub const main = entrypoint.main;

/// On Windows, Ghostty saves a crash report and tells the user where it is
/// before the default panic handler runs, since a GUI program's standard
/// error isn't visible. See crash/windows.zig.
pub const panic = if (builtin.target.os.tag == .windows and
    build_config.exe_entrypoint == .ghostty)
    std.debug.FullPanic(@import("crash/windows.zig").panic)
else
    std.debug.FullPanic(std.debug.defaultPanic);

/// Standard options such as logger overrides.
pub const std_options: std.Options = if (@hasDecl(entrypoint, "std_options"))
    entrypoint.std_options
else
    .{};

comptime {
    // Force-reference our memset override so its export is emitted.
    // See quirks_memset.zig for details on why this exists.
    _ = @import("quirks_memset.zig");
}

test {
    // Zig 0.16.0 has made test logging more strict. Now, *anything* that gets
    // printed to stderr results in a "failed command" message, even if the
    // tests ultimately passed. To reduce confusion here (and honestly, test
    // log spam in general), we bump the default testing log level to error.
    std.testing.log_level = std.log.Level.err;
    _ = entrypoint;
    _ = @import("quirks_memset.zig");
}
