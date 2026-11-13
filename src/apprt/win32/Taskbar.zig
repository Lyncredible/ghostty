//! Windows taskbar progress for top-level windows.
const Taskbar = @This();

const std = @import("std");
const terminal = @import("../../terminal/main.zig");
const c = @import("util.zig").c;
const log = std.log.scoped(.win32);

list: ?*c.ITaskbarList3 = null,
com_initialized: bool = false,

pub fn init() Taskbar {
    var self: Taskbar = .{};
    const hr = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    self.com_initialized = hr >= 0;
    if (hr < 0 and hr != c.RPC_E_CHANGED_MODE) {
        log.warn("taskbar COM initialization failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return self;
    }

    var list: ?*c.ITaskbarList3 = null;
    const create_hr = c.CoCreateInstance(
        &c.CLSID_TaskbarList,
        null,
        c.CLSCTX_INPROC_SERVER,
        &c.IID_ITaskbarList3,
        @ptrCast(&list),
    );
    if (create_hr >= 0 and list != null) {
        if (list.?.lpVtbl.*.HrInit.?(list) >= 0) {
            self.list = list;
        } else {
            log.warn("taskbar HrInit failed", .{});
            _ = list.?.lpVtbl.*.Release.?(list);
        }
    } else {
        log.warn("taskbar CoCreateInstance failed hr=0x{x}", .{@as(u32, @bitCast(create_hr))});
    }
    return self;
}

pub fn deinit(self: *Taskbar) void {
    if (self.list) |list| _ = list.lpVtbl.*.Release.?(list);
    if (self.com_initialized) c.CoUninitialize();
}

pub fn clear(self: *Taskbar, hwnd: c.HWND) void {
    self.setState(hwnd, c.TBPF_NOPROGRESS);
}

pub fn setState(self: *Taskbar, hwnd: c.HWND, state: c.TBPFLAG) void {
    if (self.list) |list| {
        const hr = list.lpVtbl.*.SetProgressState.?(list, hwnd, state);
        if (hr < 0) log.warn("taskbar SetProgressState failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }
}

pub fn setValue(self: *Taskbar, hwnd: c.HWND, value: u8) void {
    if (self.list) |list| {
        const hr = list.lpVtbl.*.SetProgressValue.?(list, hwnd, value, 100);
        if (hr < 0) log.warn("taskbar SetProgressValue failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }
}

/// What a taskbar button shows for a progress report.
pub const Progress = struct {
    state: c.TBPFLAG,
    /// The percentage, unless the state has none.
    value: ?u8 = null,

    /// For `report`, with the last percentage a pause or an error without
    /// one keeps (a button can't slide in red, as our bar does).
    pub fn of(report: terminal.osc.Command.ProgressReport, last: ?u8) Progress {
        const state: c.TBPFLAG = switch (report.state) {
            .remove => return .{ .state = c.TBPF_NOPROGRESS },
            .indeterminate => return .{ .state = c.TBPF_INDETERMINATE },
            .set => if (report.progress == null) return .{ .state = c.TBPF_INDETERMINATE } else c.TBPF_NORMAL,
            .@"error" => c.TBPF_ERROR,
            .pause => c.TBPF_PAUSED,
        };
        return .{ .state = state, .value = @min(100, report.progress orelse last orelse 100) };
    }
};

test Progress {
    const testing = std.testing;
    try testing.expectEqual(Progress{ .state = c.TBPF_NOPROGRESS }, Progress.of(.{ .state = .remove, .progress = 10 }, 40));
    try testing.expectEqual(Progress{ .state = c.TBPF_NORMAL, .value = 10 }, Progress.of(.{ .state = .set, .progress = 10 }, 40));
    try testing.expectEqual(Progress{ .state = c.TBPF_INDETERMINATE }, Progress.of(.{ .state = .set, .progress = null }, 40));
    try testing.expectEqual(Progress{ .state = c.TBPF_INDETERMINATE }, Progress.of(.{ .state = .indeterminate, .progress = null }, 40));
    // An error or a pause keeps the last percentage, or fills the button
    // without one.
    try testing.expectEqual(Progress{ .state = c.TBPF_ERROR, .value = 70 }, Progress.of(.{ .state = .@"error", .progress = 70 }, 40));
    try testing.expectEqual(Progress{ .state = c.TBPF_ERROR, .value = 40 }, Progress.of(.{ .state = .@"error", .progress = null }, 40));
    try testing.expectEqual(Progress{ .state = c.TBPF_PAUSED, .value = 40 }, Progress.of(.{ .state = .pause, .progress = null }, 40));
    try testing.expectEqual(Progress{ .state = c.TBPF_PAUSED, .value = 100 }, Progress.of(.{ .state = .pause, .progress = null }, null));
    // Never past the end.
    try testing.expectEqual(Progress{ .state = c.TBPF_NORMAL, .value = 100 }, Progress.of(.{ .state = .set, .progress = 255 }, null));
}
