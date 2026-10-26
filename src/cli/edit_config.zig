const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const Config = configpkg.Config;
const global = @import("../global.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `edit-config` command opens the Ghostty configuration file in the
/// editor specified by the `$VISUAL` or `$EDITOR` environment variables.
///
/// IMPORTANT: This command will not reload the configuration after
/// editing. You will need to manually reload the configuration using the
/// application menu, configured keybind, or by restarting Ghostty. We
/// plan to auto-reload in the future, but Ghostty isn't capable of
/// this yet.
///
/// The filepath opened is the default user-specific configuration
/// file, which is typically located at `$XDG_CONFIG_HOME/ghostty/config.ghostty`.
/// On macOS, this may also be located at
/// `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`.
/// On macOS, whichever path exists and is non-empty will be prioritized,
/// prioritizing the Application Support directory if neither are
/// non-empty.
///
/// This command prefers the `$VISUAL` environment variable over `$EDITOR`,
/// if both are set. If neither are set, it will print an error
/// and exit. On Windows, the editor runs through `cmd.exe` (so it can be
/// a command with arguments, such as `code --wait`), and Notepad is used
/// if neither is set.
pub fn run(alloc: Allocator) !u8 {
    // Implementation note (by @mitchellh): I do proper memory cleanup
    // throughout this command, even though we plan on doing `exec`.
    // I do this out of good hygiene in case we ever change this to
    // not using `exec` anymore and because this command isn't performance
    // critical where setting up the defer cleanup is a problem.

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const result = runInner(alloc, stderr);
    // Flushing *shouldn't* fail but...
    stderr.flush() catch {};
    return result;
}

fn runInner(alloc: Allocator, stderr: *std.Io.Writer) !u8 {
    // We require libc because we want to use std.c.environ for envp
    // and not have to build that ourselves. We can remove this
    // limitation later but Ghostty already heavily requires libc
    // so this is not a big deal.
    comptime assert(builtin.link_libc);

    // We load the configuration once because that will write our
    // default configuration files to disk. We don't use the config.
    var config = try Config.load(alloc);
    defer config.deinit();

    // Find the preferred path.
    const path = try configpkg.preferredDefaultFilePath(alloc);
    defer alloc.free(path);

    // Windows has no exec, so we run the editor and wait for it.
    if (comptime builtin.target.os.tag == .windows) return try runWindows(alloc, stderr, path);

    const command = internal_os.getConfigEditCommand(alloc, path, .{ .default_editor = .failure }) catch |err| {
        switch (err) {
            error.NoEditorConfigured => {
                try stderr.print(
                    \\The $EDITOR or $VISUAL environment variable is not set or is empty.
                    \\This environment variable is required to edit the Ghostty configuration
                    \\via this CLI command.
                    \\
                    \\Please set the environment variable to your preferred terminal
                    \\text editor and try again.
                    \\
                    \\If you prefer to edit the configuration file another way,
                    \\you can find the configuration file at the following path:
                    \\
                    \\
                ,
                    .{},
                );

                // Output the path using the OSC8 sequence so that it is linked.
                try stderr.print(
                    "\x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
                    .{ path, path },
                );

                return 1;
            },
            error.WriteFailed,
            error.OutOfMemory,
            => |e| return e,
        }
    };
    defer alloc.free(command);

    // Run/replace process (using execve)
    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        command.ptr,
    };
    const envp = std.c.environ;
    const err = std.posix.errno(std.posix.system.execve(argv[0].?, &argv, envp));

    // If we reached this point then exec failed.
    try stderr.print(
        \\Failed to execute the editor (E{t}).
        \\
        \\This is usually due to the executable path not existing, invalid
        \\permissions, or the shell environment not being set up
        \\correctly.
        \\
        \\Command: {s}
        \\
    , .{
        err,
        command,
    });
    // Output the path using the OSC8 sequence so that it is linked.
    try stderr.print(
        "Path: \x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
        .{ path, path },
    );
    return 1;
}

/// Edit the config in `$VISUAL` or `$EDITOR`, or else in Notepad, and wait
/// for the editor to exit. The editor runs through cmd, so it can have
/// arguments (such as `code --wait`) and be a batch file.
fn runWindows(alloc: Allocator, stderr: *std.Io.Writer, path: []const u8) !u8 {
    const windows = internal_os.windows;
    const env = global.environ();
    const editor: ?[]const u8 = editor: {
        inline for (.{ "VISUAL", "EDITOR" }) |name| {
            if (env.containsUnempty(alloc, name) catch false) {
                break :editor env.getAlloc(alloc, name) catch null;
            }
        }
        break :editor null;
    };
    defer if (editor) |v| alloc.free(v);

    // With /s, cmd removes only the outer quotes and runs the rest as it
    // is, so the editor and the quoted path don't need more escaping.
    const command_line = if (editor) |v|
        try std.fmt.allocPrint(alloc, "cmd.exe /d /s /c \"{s} \"{s}\"\"", .{ v, path })
    else
        try std.fmt.allocPrint(alloc, "notepad.exe \"{s}\"", .{path});
    defer alloc.free(command_line);
    const command_line_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, command_line);
    defer alloc.free(command_line_w);

    // We pass on our standard handles, which may be pipes rather than the
    // console, such as when our output is redirected.
    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    startup_info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.hStdInput = GetStdHandle(@bitCast(@as(i32, -10)));
    startup_info.hStdOutput = GetStdHandle(@bitCast(@as(i32, -11)));
    startup_info.hStdError = GetStdHandle(@bitCast(@as(i32, -12)));
    var process_information: windows.PROCESS_INFORMATION = undefined;
    if (windows.exp.kernel32.CreateProcessW(
        null,
        command_line_w.ptr,
        null,
        null,
        windows.TRUE,
        0,
        null,
        null,
        &startup_info,
        &process_information,
    ) == windows.FALSE) {
        try stderr.print(
            \\Failed to start the editor ({t}).
            \\
            \\Command: {s}
            \\
            \\You can edit the configuration file at the following path:
            \\{s}
            \\
        , .{ windows.GetLastError(), command_line, path });
        return 1;
    }
    defer _ = windows.exp.kernel32.CloseHandle(process_information.hProcess);
    defer _ = windows.exp.kernel32.CloseHandle(process_information.hThread);

    _ = windows.exp.kernel32.WaitForSingleObject(process_information.hProcess, windows.INFINITE);
    var code: windows.DWORD = 1;
    _ = windows.exp.kernel32.GetExitCodeProcess(process_information.hProcess, &code);
    return @truncate(code);
}

extern "kernel32" fn GetStdHandle(std_handle: u32) callconv(.winapi) ?*anyopaque;
