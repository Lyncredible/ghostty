const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const com = @import("com.zig");
const c = com.c;
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.direct3d11);

/// The HLSL source for all of our shaders. Each shader stage is a
/// separate entry point within this source.
const source = @embedFile("../shaders/shaders.hlsl");

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "bg_color_fragment",
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "cell_bg_fragment",
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = "cell_text_vertex",
            .fragment_fn = "cell_text_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = "image_vertex",
            .fragment_fn = "image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = "bg_image_vertex",
            .fragment_fn = "bg_image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(
        self: PipelineDescription,
        device: *c.ID3D11Device,
    ) !Pipeline {
        const vs = try compile(source, self.vertex_fn, "vs_5_0");
        defer com.release(vs);
        const ps = try compile(source, self.fragment_fn, "ps_5_0");
        defer com.release(ps);

        return try .init(self.vertex_attributes, .{
            .device = device,
            .vertex_bytecode = blobBytes(vs),
            .fragment_bytecode = blobBytes(ps),
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    var names: [pipeline_descs.len][]const u8 = undefined;
    var types: [pipeline_descs.len]type = @splat(Pipeline);
    var attrs: [pipeline_descs.len]std.lang.Type.Struct.FieldAttributes = @splat(.{
        .@"align" = @alignOf(Pipeline),
    });

    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};

/// This contains the state for the shaders used by the Direct3D 11 renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        device: *c.ID3D11Device,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        _ = alloc;

        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(device);
            initialized_pipelines += 1;
        }

        // TODO: custom shaders. These need the shadertoy pipeline to
        // produce HLSL via spirv-cross.
        if (post_shaders.len > 0) {
            log.warn("custom shaders are not yet supported with Direct3D 11", .{});
        }

        return .{
            .pipelines = pipelines,
            .post_pipelines = &.{},
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

/// Compile the entry point `entry` of the HLSL source `src` with the
/// given target profile (e.g. "vs_5_0"). The caller owns the blob.
fn compile(
    src: []const u8,
    entry: [:0]const u8,
    profile: [:0]const u8,
) !*c.ID3DBlob {
    const flags: c.UINT = c.D3DCOMPILE_ENABLE_STRICTNESS |
        if (builtin.mode == .debug)
            c.D3DCOMPILE_DEBUG | c.D3DCOMPILE_SKIP_OPTIMIZATION
        else
            c.D3DCOMPILE_OPTIMIZATION_LEVEL3;

    var blob: ?*c.ID3DBlob = null;
    var errors: ?*c.ID3DBlob = null;
    defer com.releaseOpt(errors);
    const hr = c.D3DCompile(
        src.ptr,
        src.len,
        "shaders.hlsl",
        null,
        null,
        entry.ptr,
        profile.ptr,
        flags,
        0,
        &blob,
        &errors,
    );

    if (errors) |e| {
        const msg = std.mem.trimEnd(u8, blobBytes(e), "\x00\r\n");
        if (hr < 0) {
            log.err("shader compilation failed entry={s} errors={s}", .{ entry, msg });
        } else if (msg.len > 0) {
            log.warn("shader compilation warnings entry={s} warnings={s}", .{ entry, msg });
        }
    }

    try com.check(hr, "D3DCompile");
    return blob.?;
}

fn blobBytes(blob: *c.ID3DBlob) []const u8 {
    const ptr: [*]const u8 = @ptrCast(com.call(blob, "GetBufferPointer", .{}).?);
    return ptr[0..com.call(blob, "GetBufferSize", .{})];
}

/// The uniforms that are passed to our shaders.
///
/// This must match the `Globals` cbuffer in shaders.hlsl. HLSL packs
/// cbuffers into 16 byte registers and doesn't let values straddle a
/// register boundary, which for this struct matches std140 (and the
/// alignment annotations below). The comptime checks below verify this.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: [4][4]f32 align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Direct3D itself will re-encode the colors for storage.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };

    comptime {
        // Offsets of the corresponding fields in the HLSL cbuffer.
        std.debug.assert(@offsetOf(Uniforms, "projection_matrix") == 0);
        std.debug.assert(@offsetOf(Uniforms, "screen_size") == 64);
        std.debug.assert(@offsetOf(Uniforms, "cell_size") == 72);
        std.debug.assert(@offsetOf(Uniforms, "grid_size") == 80);
        std.debug.assert(@offsetOf(Uniforms, "grid_padding") == 96);
        std.debug.assert(@offsetOf(Uniforms, "padding_extend") == 112);
        std.debug.assert(@offsetOf(Uniforms, "min_contrast") == 116);
        std.debug.assert(@offsetOf(Uniforms, "cursor_pos") == 120);
        std.debug.assert(@offsetOf(Uniforms, "cursor_color") == 124);
        std.debug.assert(@offsetOf(Uniforms, "bg_color") == 128);
        std.debug.assert(@offsetOf(Uniforms, "bools") == 132);
    }
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    test {
        // Minimizing the size of this struct is important,
        // so we test it in order to be aware of any changes.
        try std.testing.expectEqual(32, @sizeOf(CellText));
    }
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};
