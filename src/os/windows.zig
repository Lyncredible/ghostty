const std = @import("std");
const windows = std.os.windows;

// NOTE: The Windows part of the Zig stdlib is currently in the process of
// having most of its features removed, with the ultimate goal of switching to
// serve as a support for higher-level functionality offered in places like
// `std.Io` only. As such this file serves as a "bridge" between type
// information (mostly coming from stdlib) and manually-defined constants and
// external functions.

// Utility functions
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;

// Primitive types
pub const BOOL = windows.BOOL;
pub const COORD = windows.COORD;
pub const DWORD = windows.DWORD;
pub const DWORD_PTR = windows.DWORD_PTR;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HPCON = windows.LPVOID;
pub const HRESULT = c_long;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const LPVOID = windows.LPVOID;
pub const LPWSTR = windows.LPWSTR;
pub const PVOID = windows.PVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const UNICODE_STRING = windows.UNICODE_STRING;

// Structs and opaque types
pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const STARTUPINFOEX = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
};

// Well-known constant values
pub const INFINITE = 4294967295;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const FALSE: windows.BOOL = .fromBool(false);
pub const TRUE: windows.BOOL = .fromBool(true);

// Bit-field and enum constant values
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const DELETE = 0x00010000;
pub const ERROR_SUCCESS = 0;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
/// GetFinalPathNameByHandleW dwFlags: normalized name with a DOS drive
/// letter (both are the zero flag values).
pub const FILE_NAME_NORMALIZED = 0x0;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
/// NtCreateFile CreateDisposition: open an existing file, never create.
/// Distinct from the Win32 CreateFileW value OPEN_EXISTING.
pub const FILE_OPEN = 0x00000001;
pub const FILE_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
pub const GENERIC_READ = 0x80000000;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub const MEM_COMMIT = 0x1000;
pub const MEM_RELEASE = 0x8000;
pub const MEM_RESERVE = 0x2000;
pub const OPEN_EXISTING = 3; // Known as FILE_OPEN in Windows docs
pub const PAGE_READWRITE = 0x04;
pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;
pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
pub const S_OK = 0;
pub const SYNCHRONIZE = 0x00100000;
pub const VOLUME_NAME_DOS = 0x0;
pub const WAIT_FAILED = 0xFFFFFFFF;

/// IOCTL that fills the output buffer with bytes from the kernel CSPRNG
/// behind `\Device\CNG` (what ProcessPrng and BCryptGenRandom draw from).
pub const IOCTL_KSEC_GEN_RANDOM: CTL_CODE = windows.IOCTL.KSEC.GEN_RANDOM;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(
    .ProcThreadAttributePseudoConsole,
    false,
    true,
    false,
);

// Types needed for ntdll calls
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const CTL_CODE = windows.CTL_CODE;
pub const FILE_ALL_INFORMATION = windows.FILE.ALL_INFORMATION;
pub const FILE_ATTRIBUTE_TAG_INFORMATION = windows.FILE.ATTRIBUTE_TAG_INFO;
pub const FILE_DISPOSITION_INFORMATION = windows.FILE.DISPOSITION.INFORMATION;
pub const FILE_DISPOSITION_INFORMATION_EX = windows.FILE.DISPOSITION.INFORMATION.EX;
pub const FILE_INFORMATION_CLASS = windows.FILE.INFORMATION_CLASS;
pub const FILE_POSITION_INFORMATION = windows.FILE.POSITION_INFORMATION;
pub const FILE_STANDARD_INFORMATION = windows.FILE.STANDARD_INFORMATION;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const NTSTATUS = windows.NTSTATUS;
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;

// Exported functions by library
pub const TH32CS_SNAPPROCESS = 0x00000002;

pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: i32,
    dwFlags: DWORD,
    szExeFile: [260]u16,
};

pub const exp = struct {
    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *HANDLE,
            hWritePipe: *HANDLE,
            lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
            nSize: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: COORD,
            hInput: HANDLE,
            hOutput: HANDLE,
            dwFlags: DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: HPCON,
            size: COORD,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn LoadLibraryExW(
            lpLibFileName: [*:0]const u16,
            hFile: ?HANDLE,
            dwFlags: DWORD,
        ) callconv(.winapi) ?*anyopaque;
        pub extern "kernel32" fn GetProcAddress(
            hModule: *anyopaque,
            lpProcName: [*:0]const u8,
        ) callconv(.winapi) ?*const anyopaque;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: DWORD,
            dwFlags: DWORD,
            lpSize: *SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: DWORD,
            Attribute: DWORD_PTR,
            lpValue: PVOID,
            cbSize: SIZE_T,
            lpPreviousValue: ?PVOID,
            lpReturnSize: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: HANDLE,
            lpBuffer: ?LPVOID,
            nBufferSize: DWORD,
            lpBytesRead: ?*DWORD,
            lpTotalBytesAvail: ?*DWORD,
            lpBytesLeftThisMessage: ?*DWORD,
        ) callconv(.winapi) BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPWSTR,
            lpCommandLine: ?LPWSTR,
            lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?LPWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: DWORD,
            lpBuffer: LPWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: HANDLE,
            dwMask: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: LPCWSTR,
            dwOpenMode: DWORD,
            dwPipeMode: DWORD,
            nMaxInstances: DWORD,
            nOutBufferSize: DWORD,
            nInBufferSize: DWORD,
            nDefaultTimeOut: DWORD,
            lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CloseHandle(
            hObject: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            flAllocationType: DWORD,
            flProtect: DWORD,
        ) callconv(.winapi) ?LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            dwFreeType: DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-discardvirtualmemory
        pub extern "kernel32" fn DiscardVirtualMemory(
            VirtualAddress: PVOID,
            Size: SIZE_T,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn WaitForSingleObject(
            hHandle: HANDLE,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: HANDLE,
            lpExitCode: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateProcess(
            hProcess: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WriteFile(
            hFile: HANDLE,
            lpBuffer: *const anyopaque,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ReadFile(
            hFile: HANDLE,
            lpBuffer: LPVOID,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/tlhelp32/nf-tlhelp32-createtoolhelp32snapshot
        pub extern "kernel32" fn CreateToolhelp32Snapshot(
            dwFlags: DWORD,
            th32ProcessID: DWORD,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn Process32FirstW(
            hSnapshot: HANDLE,
            lppe: *PROCESSENTRY32W,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn Process32NextW(
            hSnapshot: HANDLE,
            lppe: *PROCESSENTRY32W,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn OpenProcess(
            dwDesiredAccess: DWORD,
            bInheritHandle: BOOL,
            dwProcessId: DWORD,
        ) callconv(.winapi) ?HANDLE;
        pub extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
        pub extern "kernel32" fn QueryFullProcessImageNameW(
            hProcess: HANDLE,
            dwFlags: DWORD,
            lpExeName: [*]u16,
            lpdwSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
        pub extern "kernel32" fn GetFinalPathNameByHandleW(
            hFile: HANDLE,
            lpszFilePath: [*]u16,
            cchFilePath: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) DWORD;
    };
    pub const ntdll = struct {
        pub extern "ntdll" fn NtCreateFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            AllocationSize: ?*LARGE_INTEGER,
            FileAttributes: ULONG,
            ShareAccess: ULONG,
            CreateDisposition: ULONG,
            CreateOptions: ULONG,
            EaBuffer: ?*anyopaque,
            EaLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtOpenFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            ShareAccess: ULONG,
            OpenOptions: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtClose(Handle: HANDLE) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtReadFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            Buffer: *anyopaque,
            Length: ULONG,
            ByteOffset: ?*const LARGE_INTEGER,
            Key: ?*const ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtQueryInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtSetInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtDeviceIoControlFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            IoControlCode: CTL_CODE,
            InputBuffer: ?*const anyopaque,
            InputBufferLength: ULONG,
            OutputBuffer: ?*anyopaque,
            OutputBufferLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        /// Resolves a Win32 path against the process working directory and
        /// canonicalizes it, keeping any `\\?\` or `\\.\` prefix. Returns
        /// the byte length written excluding the terminator, the required
        /// byte length if the buffer is too small, or 0 on failure.
        pub extern "ntdll" fn RtlGetFullPathName_U(
            FileName: [*:0]const u16,
            BufferByteLength: ULONG,
            Buffer: [*]u16,
            ShortName: ?*[*:0]const u16,
        ) callconv(.winapi) ULONG;
        /// The futex primitives that kernel32's WaitOnAddress and
        /// WakeByAddress* forward to. Timeout is a relative (negative)
        /// interval in 100ns units, null to wait forever.
        pub extern "ntdll" fn RtlWaitOnAddress(
            Address: *const anyopaque,
            CompareAddress: *const anyopaque,
            AddressSize: SIZE_T,
            Timeout: ?*const LARGE_INTEGER,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn RtlWakeAddressSingle(Address: *const anyopaque) callconv(.winapi) void;
        pub extern "ntdll" fn RtlWakeAddressAll(Address: *const anyopaque) callconv(.winapi) void;
    };
};

pub const ProcThreadAttributeNumber = enum(DWORD) {
    ProcThreadAttributePseudoConsole = 22,
    _,
};

/// Corresponds to the ProcThreadAttributeValue define in WinBase.h
pub fn ProcThreadAttributeValue(
    comptime attribute: ProcThreadAttributeNumber,
    comptime thread: bool,
    comptime input: bool,
    comptime additive: bool,
) DWORD {
    return (@backingInt(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
        (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
        (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
        (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
}

/// Write one argument of a command line so that CommandLineToArgvW (and
/// the C runtime) read it back unchanged: as is, or quoted when it's empty
/// or has whitespace or quotes, with the backslashes before a quote (or
/// the closing quote) doubled.
pub fn writeCommandLineArg(writer: *std.Io.Writer, arg: []const u8) std.Io.Writer.Error!void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\"") == null) {
        return writer.writeAll(arg);
    }
    try writer.writeByte('"');
    var backslash_count: usize = 0;
    for (arg) |byte| {
        switch (byte) {
            '\\' => backslash_count += 1,
            '"' => {
                try writer.splatByteAll('\\', backslash_count * 2 + 1);
                try writer.writeByte('"');
                backslash_count = 0;
            },
            else => {
                try writer.splatByteAll('\\', backslash_count);
                try writer.writeByte(byte);
                backslash_count = 0;
            },
        }
    }
    try writer.splatByteAll('\\', backslash_count * 2);
    try writer.writeByte('"');
}

/// Whether `attachParentConsole` attached to the parent's console. The
/// parent (a shell) doesn't wait for a GUI program and keeps reading the
/// console's input, so we can write to it but not read keys from it.
pub var attached_parent_console = false;

/// Ghostty is a GUI program on Windows, so it has no console of its own,
/// and console shells don't connect its output to them. For CLI actions
/// (such as +version) run from a console, attach to that console so the
/// output is visible. Output that's already redirected (a pipe or file)
/// is left alone.
///
/// The `ghostty.com` launcher (src/main_windows_launcher.zig) waits for
/// us and sets GHOSTTY_CONSOLE_LAUNCHER. Console handles don't reach a GUI
/// program, so we open its console ourselves, including its input, which
/// is ours to read since nothing else is reading it.
pub fn attachParentConsole() void {
    const params = windows.peb().ProcessParameters;
    const has_stdin = validHandle(params.hStdInput);
    const has_stdout = validHandle(params.hStdOutput);
    const has_stderr = validHandle(params.hStdError);
    const launched = launchedByConsoleLauncher();
    if (has_stdout and has_stderr and (has_stdin or !launched)) return;
    if (console.AttachConsole(console.ATTACH_PARENT_PROCESS) == FALSE) return;
    attached_parent_console = !launched;

    if (!has_stdout or !has_stderr) {
        if (openConsole("CONOUT$")) |conout| {
            if (!has_stdout) _ = console.SetStdHandle(console.STD_OUTPUT_HANDLE, conout);
            if (!has_stderr) _ = console.SetStdHandle(console.STD_ERROR_HANDLE, conout);
        }
    }
    if (launched and !has_stdin) {
        if (openConsole("CONIN$")) |conin| _ = console.SetStdHandle(console.STD_INPUT_HANDLE, conin);
    }
}

fn launchedByConsoleLauncher() bool {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_CONSOLE_LAUNCHER");
    var value: [2]u16 = undefined;
    const len = console.GetEnvironmentVariableW(name, &value, value.len);
    if (len == 0) return false;
    // Don't pass it on to anything we start.
    _ = console.SetEnvironmentVariableW(name, null);
    return len == 1 and value[0] == '1';
}

fn openConsole(comptime name: []const u8) ?HANDLE {
    const handle = console.CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral(name),
        console.GENERIC_READ | console.GENERIC_WRITE,
        console.FILE_SHARE_READ | console.FILE_SHARE_WRITE,
        null,
        console.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    return handle;
}

fn validHandle(handle: HANDLE) bool {
    const value = @intFromPtr(handle);
    return value != 0 and value != @intFromPtr(windows.INVALID_HANDLE_VALUE);
}

const console = struct {
    const ATTACH_PARENT_PROCESS: DWORD = @bitCast(@as(i32, -1));
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const FILE_SHARE_READ: DWORD = 0x1;
    const FILE_SHARE_WRITE: DWORD = 0x2;
    const OPEN_EXISTING: DWORD = 3;
    const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));

    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: [*]u16, size: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) BOOL;

    extern "kernel32" fn AttachConsole(process_id: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetStdHandle(std_handle: DWORD, handle: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: DWORD,
        share: DWORD,
        security: ?*anyopaque,
        disposition: DWORD,
        flags: DWORD,
        template: ?HANDLE,
    ) callconv(.winapi) HANDLE;
};

/// A process in a snapshot of the system's processes (`processes`).
pub const ProcessEntry = struct {
    pid: DWORD,
    parent: DWORD,
    /// The executable's file name, like `pwsh.exe`.
    name: [260]u16,
    name_len: usize,

    pub fn exeName(self: *const ProcessEntry) []const u16 {
        return self.name[0..self.name_len];
    }
};

/// The processes running now. The caller frees the list.
pub fn processes(alloc: std.mem.Allocator) ![]ProcessEntry {
    const snapshot = exp.kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return error.SnapshotFailed;
    defer _ = exp.kernel32.CloseHandle(snapshot);

    var list: std.ArrayList(ProcessEntry) = .empty;
    errdefer list.deinit(alloc);
    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    var more = exp.kernel32.Process32FirstW(snapshot, &entry).toBool();
    while (more) : (more = exp.kernel32.Process32NextW(snapshot, &entry).toBool()) {
        try list.append(alloc, .{
            .pid = entry.th32ProcessID,
            .parent = entry.th32ParentProcessID,
            .name = entry.szExeFile,
            .name_len = std.mem.indexOfScalar(u16, &entry.szExeFile, 0) orelse entry.szExeFile.len,
        });
    }
    return try list.toOwnedSlice(alloc);
}

/// The newest of the deepest processes under `root` (a process ID), or
/// `root` itself if it has none. ConPTY has no foreground process group,
/// so this stands in for one: the program a shell is running.
pub fn foregroundProcess(list: []const ProcessEntry, root: DWORD) DWORD {
    var current = root;
    var current_start = processStart(root) orelse return root;
    while (true) {
        var best: ?DWORD = null;
        var best_start: u64 = 0;
        var best_depth: usize = 0;
        for (list) |entry| {
            if (entry.parent != current or entry.pid == current) continue;
            // Process IDs are reused, so a parent ID can name a newer
            // process than the one that started this one.
            const start = processStart(entry.pid) orelse continue;
            if (start < current_start) continue;
            const depth = processDepth(list, entry.pid, start, 0);
            if (best == null or depth > best_depth or (depth == best_depth and start > best_start)) {
                best = entry.pid;
                best_start = start;
                best_depth = depth;
            }
        }
        current = best orelse return current;
        current_start = best_start;
    }
}

/// How many generations of processes are under `pid`.
fn processDepth(list: []const ProcessEntry, pid: DWORD, start: u64, depth: usize) usize {
    // Windows doesn't limit it, but a shell's tree is shallow.
    if (depth >= 16) return 0;
    var deepest: usize = 0;
    for (list) |entry| {
        if (entry.parent != pid or entry.pid == pid) continue;
        const child_start = processStart(entry.pid) orelse continue;
        if (child_start < start) continue;
        deepest = @max(deepest, 1 + processDepth(list, entry.pid, child_start, depth + 1));
    }
    return deepest;
}

/// The parent of `pid`, if it's still the process that started it.
pub fn parentProcess(list: []const ProcessEntry, pid: DWORD) ?*const ProcessEntry {
    const entry = for (list) |*entry| {
        if (entry.pid == pid) break entry;
    } else return null;
    const parent = for (list) |*parent| {
        if (parent.pid == entry.parent and parent.pid != pid) break parent;
    } else return null;
    const start = processStart(pid) orelse return null;
    const parent_start = processStart(parent.pid) orelse return null;
    return if (parent_start <= start) parent else null;
}

/// When a process started, as a FILETIME.
fn processStart(pid: DWORD) ?u64 {
    const handle = exp.kernel32.OpenProcess(process.PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) orelse return null;
    defer _ = exp.kernel32.CloseHandle(handle);
    var times: [4]process.FILETIME = undefined;
    if (!process.GetProcessTimes(handle, &times[0], &times[1], &times[2], &times[3]).toBool()) return null;
    return @as(u64, times[0].high) << 32 | times[0].low;
}

const process = struct {
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
    const FILETIME = extern struct { low: DWORD, high: DWORD };

    extern "kernel32" fn GetProcessTimes(
        process: HANDLE,
        creation: *FILETIME,
        exit: *FILETIME,
        kernel: *FILETIME,
        user: *FILETIME,
    ) callconv(.winapi) BOOL;
};

test foregroundProcess {
    const builtin = @import("builtin");
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const list = try processes(testing.allocator);
    defer testing.allocator.free(list);

    // We have no child processes, so we're our own foreground.
    const self_pid = GetCurrentProcessId();
    try testing.expectEqual(self_pid, foregroundProcess(list, self_pid));
    const parent = parentProcess(list, self_pid) orelse return error.TestUnexpectedResult;
    try testing.expect(parent.pid != self_pid);

    // cmd running PowerShell: PowerShell is the foreground.
    const io = testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", "powershell.exe -NoProfile -Command Start-Sleep 3" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer _ = child.wait(io) catch {};
    const cmd = exp.kernel32.GetProcessId(child.id.?);
    for (0..100) |_| {
        const now = try processes(testing.allocator);
        defer testing.allocator.free(now);
        const pid = foregroundProcess(now, cmd);
        if (pid != cmd) {
            const entry = for (now) |*entry| {
                if (entry.pid == pid) break entry;
            } else return error.TestUnexpectedResult;
            var name_buf: [260 * 3]u8 = undefined;
            const name = name_buf[0..try std.unicode.utf16LeToUtf8(&name_buf, entry.exeName())];
            try testing.expect(std.ascii.eqlIgnoreCase(name, "powershell.exe"));
            try testing.expectEqual(cmd, parentProcess(now, pid).?.pid);
            return;
        }
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    }
    return error.TestUnexpectedResult;
}
