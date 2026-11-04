//! Console sessions that Windows hands us as its default terminal
//! application (Windows 11, Settings > For developers > Terminal).
//!
//! When a console program starts without a console (from Explorer, Run or
//! a shortcut), Windows' console host asks the default terminal's COM
//! class to take it over, through `ITerminalHandoff3` (microsoft/terminal,
//! `src/host/proxy/ITerminalHandoff.idl`). The console host doing that is
//! Windows Terminal's OpenConsole, and the interface's proxy is Windows
//! Terminal's too, so we only implement the class. We return pipes for
//! the session and get the console's handles, which a new window's
//! terminal then shows (`Pty.adopt`).
//!
//! Each running Ghostty registers the class, so a handoff opens a window
//! in it. If none is running, COM starts us with `-Embedding`.
const std = @import("std");

const cli = @import("../../cli.zig");
const global = @import("../../global.zig");
const ptypkg = @import("../../pty.zig");
const Pty = ptypkg.Pty;
const util = @import("util.zig");
const c = util.c;
const App = @import("App.zig");

const log = std.log.scoped(.win32_handoff);

/// Ghostty's terminal handoff class.
pub const clsid: GUID = .{ .a = 0x7ec9f94f, .b = 0x09dd, .c = 0x4c7f, .d = .{ 0xa7, 0x9b, 0x57, 0x53, 0x2e, 0xba, 0xfc, 0xdd } };

/// The app that handoffs go to, while the class is registered.
var target: ?*App = null;
var cookie: u32 = 0;

/// Register our class, so that the console host can hand sessions to us.
pub fn register(app: *App) void {
    target = app;
    const hr = CoRegisterClassObject(&clsid, &factory, CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &cookie);
    if (hr < 0) {
        log.warn("couldn't register the terminal handoff class hr=0x{x}", .{@as(u32, @bitCast(hr))});
        target = null;
        return;
    }
    log.debug("registered the terminal handoff class", .{});
}

pub fn unregister() void {
    if (target == null) return;
    _ = CoRevokeClassObject(cookie);
    target = null;
}

/// Close a handoff's handles, for one that no terminal took.
pub fn close(handoff: ptypkg.ConsoleHandoff) void {
    handoff.console.close();
    _ = c.CloseHandle(handoff.in_pipe);
    _ = c.CloseHandle(handoff.out_pipe);
    _ = c.CloseHandle(handoff.client);
}

/// Whether this launch is COM starting us to take a handoff.
pub fn launchedByCom(alloc: std.mem.Allocator) bool {
    var it = cli.args.argsIterator(alloc, global.args()) catch return false;
    defer it.deinit();
    while (it.next()) |arg| {
        if (cli.args.isComEmbedding(arg)) return true;
    }
    return false;
}

/// ITerminalHandoff3::EstablishPtyHandoff. The handles we get are the
/// call's, so we duplicate the ones we keep; the pipe ends we return
/// become the caller's.
fn establish(
    in: *c.HANDLE,
    out: *c.HANDLE,
    signal: c.HANDLE,
    reference: c.HANDLE,
    server: c.HANDLE,
    client: c.HANDLE,
    info: ?*const StartupInfo,
) HRESULT {
    const app = target orelse return E_UNEXPECTED;
    if (info) |startup| log.info("console handoff title={?f} show={}", .{
        if (startup.title) |title| std.unicode.fmtUtf16Le(title[0..SysStringLen(title)]) else null,
        startup.show_window,
    });

    const pipes = Pty.createPipes() catch return E_UNEXPECTED;
    var keep: [4]*anyopaque = undefined;
    var kept: usize = 0;
    for ([_]c.HANDLE{ signal, reference, server, client }) |handle| {
        keep[kept] = duplicate(handle) orelse {
            pipes.close();
            for (keep[0..kept]) |h| _ = c.CloseHandle(h);
            return E_UNEXPECTED;
        };
        kept += 1;
    }

    app.handOff(.{
        .in_pipe = pipes.in_pipe,
        .out_pipe = pipes.out_pipe,
        .console = .{ .signal = keep[0], .reference = keep[1], .server = keep[2] },
        .client = keep[3],
    });
    in.* = pipes.in_pipe_pty;
    out.* = pipes.out_pipe_pty;
    return S_OK;
}

fn duplicate(handle: c.HANDLE) ?*anyopaque {
    var result: c.HANDLE = null;
    const process = c.GetCurrentProcess();
    if (c.DuplicateHandle(process, handle, process, &result, 0, c.FALSE, c.DUPLICATE_SAME_ACCESS) == 0) {
        log.warn("couldn't keep a handed off handle err={}", .{c.GetLastError()});
        return null;
    }
    return result;
}

/// TERMINAL_STARTUP_INFO
const StartupInfo = extern struct {
    title: ?[*:0]u16,
    icon_path: ?[*:0]u16,
    icon_index: i32,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_count_chars: u32,
    y_count_chars: u32,
    fill_attribute: u32,
    flags: u32,
    show_window: u16,
};

// The class factory and the handoff object live as long as the process,
// so they don't count references.

var factory: Interface = .{ .vtbl = &factory_vtbl };
var handoff_object: Interface = .{ .vtbl = &handoff_vtbl };

fn addRef(_: *Interface) callconv(.winapi) u32 {
    return 2;
}

fn release(_: *Interface) callconv(.winapi) u32 {
    return 1;
}

const factory_vtbl = ClassFactoryVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            if (eqlGuid(iid, &IID_IUnknown) or eqlGuid(iid, &IID_IClassFactory)) {
                out.* = i;
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }
    }.f,
    .AddRef = addRef,
    .Release = release,
    .CreateInstance = struct {
        fn f(_: *Interface, outer: ?*anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            out.* = null;
            if (outer != null) return CLASS_E_NOAGGREGATION;
            return handoff_vtbl.QueryInterface(&handoff_object, iid, out);
        }
    }.f,
    .LockServer = struct {
        fn f(_: *Interface, _: c.BOOL) callconv(.winapi) HRESULT {
            return S_OK;
        }
    }.f,
};

const handoff_vtbl = HandoffVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            if (eqlGuid(iid, &IID_IUnknown) or eqlGuid(iid, &IID_ITerminalHandoff3)) {
                out.* = i;
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }
    }.f,
    .AddRef = addRef,
    .Release = release,
    .EstablishPtyHandoff = struct {
        fn f(
            _: *Interface,
            in: *c.HANDLE,
            out: *c.HANDLE,
            signal: c.HANDLE,
            reference: c.HANDLE,
            server: c.HANDLE,
            client: c.HANDLE,
            info: ?*const StartupInfo,
        ) callconv(.winapi) HRESULT {
            return establish(in, out, signal, reference, server, client, info);
        }
    }.f,
};

const Interface = extern struct { vtbl: *const anyopaque };

const QueryInterfaceFn = *const fn (*Interface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const RefFn = *const fn (*Interface) callconv(.winapi) u32;

const ClassFactoryVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    CreateInstance: *const fn (*Interface, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    LockServer: *const fn (*Interface, c.BOOL) callconv(.winapi) HRESULT,
};

const HandoffVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    EstablishPtyHandoff: *const fn (
        *Interface,
        *c.HANDLE,
        *c.HANDLE,
        c.HANDLE,
        c.HANDLE,
        c.HANDLE,
        c.HANDLE,
        ?*const StartupInfo,
    ) callconv(.winapi) HRESULT,
};

fn eqlGuid(a: *const GUID, b: *const GUID) bool {
    return std.meta.eql(a.*, b.*);
}

const HRESULT = c.HRESULT;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_UNEXPECTED: HRESULT = @bitCast(@as(u32, 0x8000ffff));
const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));
const CLSCTX_LOCAL_SERVER = 0x4;
const REGCLS_MULTIPLEUSE = 1;

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const IID_IUnknown: GUID = .{ .a = 0, .b = 0, .c = 0, .d = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IClassFactory: GUID = .{ .a = 1, .b = 0, .c = 0, .d = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_ITerminalHandoff3: GUID = .{ .a = 0x6f23da90, .b = 0x15c5, .c = 0x4203, .d = .{ 0x9d, 0xb0, 0x64, 0xe7, 0x3f, 0x1b, 0x1b, 0x00 } };

extern "ole32" fn CoRegisterClassObject(clsid: *const GUID, unknown: *Interface, context: u32, flags: u32, cookie: *u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoRevokeClassObject(cookie: u32) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysStringLen(string: [*:0]const u16) callconv(.winapi) u32;
