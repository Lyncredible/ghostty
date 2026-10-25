//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");

const com = @import("com.zig");
const c = com.c;
const bufferpkg = @import("buffer.zig");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");

const log = std.log.scoped(.direct3d11);

/// The first shader resource slot used for structured buffers. Textures
/// use the slots below this, so this is also the maximum texture count.
///
/// Step buffer `i` (for `i >= 1`) is bound at `t(first_buffer_slot + i - 1)`.
/// Buffer 0 is always the vertex buffer.
pub const first_buffer_slot = 8;

/// The constant buffer slot the uniforms are bound to.
pub const uniforms_slot = 1;

/// The number of shader resource slots we may bind, used to clear them.
const max_srv_slots = first_buffer_slot + 8;

/// Options for beginning a render pass.
pub const Options = struct {
    context: *c.ID3D11DeviceContext,

    /// The rasterizer state to render with.
    rasterizer: *c.ID3D11RasterizerState,

    /// The sampler bound at slot 0 when a step doesn't provide its own.
    default_sampler: *c.ID3D11SamplerState,

    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?bufferpkg.Raw = null,
    buffers: []const ?bufferpkg.Raw = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

pub const Primitive = enum {
    triangle,
    triangle_strip,

    fn topology(self: Primitive) c.D3D11_PRIMITIVE_TOPOLOGY {
        return switch (self) {
            .triangle => c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
            .triangle_strip => c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
        };
    }
};

opts: Options,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    const context = opts.context;

    var rtvs: [c.D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT]?*c.ID3D11RenderTargetView = undefined;
    var width: usize = 0;
    var height: usize = 0;
    for (opts.attachments, 0..) |at, i| {
        const rtv: *c.ID3D11RenderTargetView, const w, const h = switch (at.target) {
            .texture => |t| .{ t.rtv.?, t.width, t.height },
            .target => |t| .{ t.rtv, t.width, t.height },
        };
        rtvs[i] = rtv;
        if (i == 0) {
            width = w;
            height = h;
        }

        if (at.clear_color) |color| {
            com.call(context, "ClearRenderTargetView", .{ rtv, &color });
        }
    }

    com.call(context, "OMSetRenderTargets", .{
        @as(c.UINT, @intCast(opts.attachments.len)),
        &rtvs,
        null,
    });

    const viewport: c.D3D11_VIEWPORT = .{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(width),
        .Height = @floatFromInt(height),
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    com.call(context, "RSSetViewports", .{ 1, &viewport });
    com.call(context, "RSSetState", .{opts.rasterizer});

    return .{ .opts = opts };
}

/// Add a step to this render pass.
pub fn step(self: *const Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    const context = self.opts.context;

    // Shaders and fixed function state.
    com.call(context, "VSSetShader", .{ s.pipeline.vertex_shader, null, 0 });
    com.call(context, "PSSetShader", .{ s.pipeline.pixel_shader, null, 0 });
    com.call(context, "IASetInputLayout", .{s.pipeline.input_layout});
    com.call(context, "IASetPrimitiveTopology", .{s.draw.type.topology()});
    com.call(context, "OMSetBlendState", .{
        s.pipeline.blend_state,
        null,
        @as(c.UINT, 0xFFFFFFFF),
    });

    // Uniforms are always in constant buffer slot 1, which matches
    // the binding of the uniform block in our GLSL shaders, and so of
    // the custom shaders we translate from GLSL.
    if (s.uniforms) |u| {
        const bufs = [_]?*c.ID3D11Buffer{u.buffer};
        com.call(context, "VSSetConstantBuffers", .{ uniforms_slot, 1, &bufs });
        com.call(context, "PSSetConstantBuffers", .{ uniforms_slot, 1, &bufs });
    }

    // Buffer 0 is the vertex buffer, the rest are structured buffers.
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |b| {
            const bufs = [_]?*c.ID3D11Buffer{b.buffer};
            const strides = [_]c.UINT{s.pipeline.stride};
            const offsets = [_]c.UINT{0};
            com.call(context, "IASetVertexBuffers", .{ 0, 1, &bufs, &strides, &offsets });
        }

        for (s.buffers[1..], first_buffer_slot..) |b, slot| if (b) |buf| {
            const srvs = [_]?*c.ID3D11ShaderResourceView{buf.srv};
            com.call(context, "VSSetShaderResources", .{ @as(c.UINT, @intCast(slot)), 1, &srvs });
            com.call(context, "PSSetShaderResources", .{ @as(c.UINT, @intCast(slot)), 1, &srvs });
        };
    }

    // Textures, for both stages.
    std.debug.assert(s.textures.len <= first_buffer_slot);
    for (s.textures, 0..) |t, slot| if (t) |tex| {
        const srvs = [_]?*c.ID3D11ShaderResourceView{tex.srv};
        com.call(context, "VSSetShaderResources", .{ @as(c.UINT, @intCast(slot)), 1, &srvs });
        com.call(context, "PSSetShaderResources", .{ @as(c.UINT, @intCast(slot)), 1, &srvs });
    };

    // Samplers. If we weren't given any we bind our default.
    if (s.samplers.len == 0) {
        const samplers = [_]?*c.ID3D11SamplerState{self.opts.default_sampler};
        com.call(context, "VSSetSamplers", .{ 0, 1, &samplers });
        com.call(context, "PSSetSamplers", .{ 0, 1, &samplers });
    } else for (s.samplers, 0..) |samp, slot| if (samp) |sampler| {
        const samplers = [_]?*c.ID3D11SamplerState{sampler.sampler};
        com.call(context, "VSSetSamplers", .{ @as(c.UINT, @intCast(slot)), 1, &samplers });
        com.call(context, "PSSetSamplers", .{ @as(c.UINT, @intCast(slot)), 1, &samplers });
    };

    // Draw!
    com.call(context, "DrawInstanced", .{
        @as(c.UINT, @intCast(s.draw.vertex_count)),
        @as(c.UINT, @intCast(s.draw.instance_count)),
        0,
        0,
    });
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    const context = self.opts.context;

    // Unbind our render targets and shader resources so that textures
    // we rendered to can be read by later passes (and vice versa)
    // without Direct3D having to forcibly unbind them.
    com.call(context, "OMSetRenderTargets", .{ 0, null, null });
    const srvs: [max_srv_slots]?*c.ID3D11ShaderResourceView = @splat(null);
    com.call(context, "VSSetShaderResources", .{ 0, srvs.len, &srvs });
    com.call(context, "PSSetShaderResources", .{ 0, srvs.len, &srvs });
}
