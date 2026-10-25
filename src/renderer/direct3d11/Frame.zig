//! Wrapper for handling frames.
//!
//! Direct3D 11 has an immediate context so commands are submitted as they
//! are recorded. Completing a frame presents the target and then reports
//! the frame as completed to the renderer.
const Self = @This();

const std = @import("std");

const com = @import("com.zig");
const c = com.c;
const Renderer = @import("../generic.zig").Renderer(Direct3D11);
const Direct3D11 = @import("../Direct3D11.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.direct3d11);

/// Options for beginning a frame.
pub const Options = struct {
    context: *c.ID3D11DeviceContext,
    rasterizer: *c.ID3D11RasterizerState,
    default_sampler: *c.ID3D11SamplerState,
};

opts: Options,
renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    return .{
        .opts = opts,
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .context = self.opts.context,
        .rasterizer = self.opts.rasterizer,
        .default_sampler = self.opts.default_sampler,
        .attachments = attachments,
    });
}

/// Complete this frame and present the target.
///
/// Presenting is always synchronous for Direct3D 11, so `sync` is unused.
pub fn complete(self: *Self, sync: bool) void {
    _ = sync;

    const health: Health = if (self.renderer.api.present(self.target.*)) |_|
        .healthy
    else |err| health: {
        log.err("failed to present render target err={}", .{err});
        break :health .unhealthy;
    };

    self.renderer.frameCompleted(health);
}
