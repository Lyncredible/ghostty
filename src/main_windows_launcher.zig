//! A console program installed as `ghostty.com` next to `ghostty.exe` on
//! Windows. Shells run `ghostty.com` before `ghostty.exe` when given
//! `ghostty`, since `.COM` comes first in PATHEXT.
//!
//! `ghostty.exe` is a GUI program, so a shell doesn't wait for it and keeps
//! reading the console's input. That's right for opening a window, but a
//! CLI action (`ghostty +list-themes`) then can't read keys, and its output
//! arrives after the shell's next prompt. This launcher starts
//! `ghostty.exe` with the console's handles for a CLI action and waits for
//! it, exiting with its exit code. Otherwise it starts the GUI without them
//! (so its logs don't go to the console) and returns at once.

const std = @import("std");
const windows = std.os.windows;

const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const WCHAR = u16;

pub fn main() void {
    // The whole exit code, not `std.process.exit`'s byte of it: 256
    // would become 0, a failure reported as success.
    ExitProcess(run());
}

fn run() DWORD {
    // ghostty.exe is next to us.
    var path_buf: [32 * 1024]WCHAR = undefined;
    const path_len = GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (path_len == 0 or path_len >= path_buf.len) return fail("can't find our own path");
    const self_path = path_buf[0..path_len];
    const dir_end = (std.mem.lastIndexOfScalar(WCHAR, self_path, '\\') orelse
        return fail("can't find our own directory")) + 1;
    const exe_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty.exe");
    if (dir_end + exe_name.len + 1 > path_buf.len) return fail("our path is too long");
    @memcpy(path_buf[dir_end..][0..exe_name.len], exe_name);
    path_buf[dir_end + exe_name.len] = 0;
    const exe_path = path_buf[0 .. dir_end + exe_name.len :0];

    // Our arguments, as given, after our own program name.
    const args = argsAfterProgram(std.mem.span(GetCommandLineW()));
    const action = isAction(args);

    // The new command line: "<dir>\ghostty.exe" <args>
    var cmdline_buf: [32 * 1024]WCHAR = undefined;
    var len: usize = 0;
    for ([_][]const WCHAR{ &.{'"'}, exe_path, &.{ '"', ' ' }, args }) |part| {
        if (len + part.len + 1 > cmdline_buf.len) return fail("the command line is too long");
        @memcpy(cmdline_buf[len..][0..part.len], part);
        len += part.len;
    }
    cmdline_buf[len] = 0;

    var startup: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    startup.cb = @sizeOf(STARTUPINFOW);
    if (action) {
        // Redirected handles (pipes and files) are passed on. Console
        // handles don't reach a GUI program this way, so for those it
        // attaches to our console and opens it itself, knowing from this
        // variable that we wait for it (see os/windows.zig).
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = redirected(STD_INPUT_HANDLE);
        startup.hStdOutput = redirected(STD_OUTPUT_HANDLE);
        startup.hStdError = redirected(STD_ERROR_HANDLE);
        _ = SetEnvironmentVariableW(
            std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_CONSOLE_LAUNCHER"),
            std.unicode.utf8ToUtf16LeStringLiteral("1"),
        );
    }

    var info: PROCESS_INFORMATION = undefined;
    if (CreateProcessW(
        exe_path.ptr,
        @ptrCast(&cmdline_buf),
        null,
        null,
        if (action) .TRUE else .FALSE,
        0,
        null,
        null,
        &startup,
        &info,
    ) == .FALSE) return fail("can't start ghostty.exe");
    defer _ = CloseHandle(info.hProcess);
    _ = CloseHandle(info.hThread);
    if (!action) return 0;

    // Ctrl+C goes to every process on the console. The action handles it
    // (or exits from it); we just wait for it.
    _ = SetConsoleCtrlHandler(null, .TRUE);
    _ = WaitForSingleObject(info.hProcess, INFINITE);
    var code: DWORD = 1;
    _ = GetExitCodeProcess(info.hProcess, &code);
    return code;
}

/// A standard handle if it's redirected (not the console), made
/// inheritable, or null.
fn redirected(which: DWORD) ?HANDLE {
    const handle = GetStdHandle(which) orelse return null;
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    if (GetFileType(handle) == FILE_TYPE_CHAR) return null;
    _ = SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    return handle;
}

/// The rest of a command line after its program name, which is quoted or
/// ends at the first space or tab, as Windows parses it.
fn argsAfterProgram(cmdline: []const WCHAR) []const WCHAR {
    var i: usize = 0;
    if (cmdline.len > 0 and cmdline[0] == '"') {
        i = 1;
        while (i < cmdline.len and cmdline[i] != '"') i += 1;
        if (i < cmdline.len) i += 1;
    } else {
        while (i < cmdline.len and cmdline[i] != ' ' and cmdline[i] != '\t') i += 1;
    }
    while (i < cmdline.len and (cmdline[i] == ' ' or cmdline[i] == '\t')) i += 1;
    return cmdline[i..];
}

/// Whether the arguments run a CLI action, as `ghostty.exe` decides (see
/// cli/action.zig and cli/ghostty.zig): any argument that starts with `+`,
/// or is `--version`, `--help` or `-h`, unless a `-e` comes first (what
/// follows that is the command to run in the terminal).
fn isAction(args: []const WCHAR) bool {
    // Each argument's first units are enough to tell.
    var word: [12]u8 = undefined;
    var len: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i <= args.len) : (i += 1) {
        const end = i == args.len;
        const ch: WCHAR = if (end) ' ' else args[i];
        if (!end and ch == '"') {
            // A quote after a backslash is the character; any other
            // starts or ends a quoted part, and isn't in the argument.
            if (i > 0 and args[i - 1] == '\\') {
                if (len > 0 and len <= word.len) word[len - 1] = '"';
                continue;
            }
            quoted = !quoted;
            continue;
        }
        if (end or (!quoted and (ch == ' ' or ch == '\t'))) {
            const arg = word[0..@min(len, word.len)];
            const whole = len <= word.len;
            if (whole and std.mem.eql(u8, arg, "-e")) return false;
            if (len > 0 and arg[0] == '+') return true;
            if (whole and (std.mem.eql(u8, arg, "--version") or
                std.mem.eql(u8, arg, "--help") or
                std.mem.eql(u8, arg, "-h"))) return true;
            len = 0;
            continue;
        }
        if (len < word.len) word[len] = if (ch < 0x80) @intCast(ch) else 0xFF;
        len += 1;
    }
    return false;
}

fn fail(message: []const u8) DWORD {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "ghostty: {s}\r\n", .{message}) catch return 1;
    var written: DWORD = 0;
    _ = WriteFile(GetStdHandle(STD_ERROR_HANDLE), text.ptr, @intCast(text.len), &written, null);
    return 1;
}

test argsAfterProgram {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const testing = std.testing;
    try testing.expectEqualSlices(WCHAR, L("+version"), argsAfterProgram(L("ghostty +version")));
    try testing.expectEqualSlices(WCHAR, L("+list-themes --plain"), argsAfterProgram(L("\"C:\\a b\\ghostty.com\"  +list-themes --plain")));
    try testing.expectEqualSlices(WCHAR, L(""), argsAfterProgram(L("ghostty")));
    try testing.expectEqualSlices(WCHAR, L("--title=\"x y\""), argsAfterProgram(L("ghostty.com\t--title=\"x y\"")));
}

test isAction {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    @setEvalBranchQuota(10_000);
    const expect = std.testing.expect;
    try expect(isAction(L("+version")));
    try expect(!isAction(L("--title=x")));
    try expect(!isAction(L("")));
    // After other arguments, and quoted.
    try expect(isAction(L("--config-file=a.conf +validate-config")));
    try expect(isAction(L("--title=\"a b\"\t\"+list-fonts\"")));
    try expect(isAction(L("+no-such-action")));
    // The ones without a plus.
    try expect(isAction(L("--version")));
    try expect(isAction(L("--title=x --help")));
    try expect(isAction(L("-h")));
    try expect(!isAction(L("--versions")));
    try expect(!isAction(L("--help=1")));
    try expect(!isAction(L("-hx")));
    // What follows -e is the terminal's command, whatever it says.
    try expect(!isAction(L("-e ghostty +version")));
    try expect(!isAction(L("--title=x -e cmd --help")));
    try expect(isAction(L("+version -e")));
    try expect(isAction(L("-ex +version")));
    // A plus inside an argument, or inside a quoted one, is nothing.
    try expect(!isAction(L("--title=a+b \"--title=x +y\" --font-size=+1")));
    // A quote after a backslash doesn't open a quoted part.
    try expect(isAction(L("--title=a\\\"b +version")));
    // Long arguments, and letters outside ASCII.
    try expect(!isAction(L("--command=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
    try expect(!isAction(L("--versionaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
    try expect(!isAction(L("--title=\u{444}\u{444}")));
}

const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
const STARTF_USESTDHANDLES: DWORD = 0x100;
const INFINITE: DWORD = 0xFFFFFFFF;
const FILE_TYPE_CHAR: DWORD = 2;
const HANDLE_FLAG_INHERIT: DWORD = 1;

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]WCHAR,
    lpDesktop: ?[*:0]WCHAR,
    lpTitle: ?[*:0]WCHAR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

extern "kernel32" fn ExitProcess(code: DWORD) callconv(.winapi) noreturn;
extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, filename: [*]WCHAR, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const WCHAR;
extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateProcessW(
    application_name: ?[*:0]const WCHAR,
    command_line: ?[*:0]WCHAR,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: BOOL,
    creation_flags: DWORD,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const WCHAR,
    startup_info: *STARTUPINFOW,
    process_information: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const anyopaque, add: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileType(file: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn SetHandleInformation(handle: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const WCHAR, value: ?[*:0]const WCHAR) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: ?HANDLE, buffer: [*]const u8, len: DWORD, written: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
