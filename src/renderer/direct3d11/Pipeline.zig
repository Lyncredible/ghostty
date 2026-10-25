//! Wrapper for handling render pipelines.
const Self = @This();

const std = @import("std");

const com = @import("com.zig");
const c = com.c;

const log = std.log.scoped(.direct3d11);

/// Options for initializing a render pipeline.
pub const Options = struct {
    device: *c.ID3D11Device,

    /// Compiled bytecode of the vertex shader.
    vertex_bytecode: []const u8,

    /// Compiled bytecode of the pixel (fragment) shader.
    fragment_bytecode: []const u8,

    /// Vertex step function
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        per_vertex,
        per_instance,
    };
};

vertex_shader: *c.ID3D11VertexShader,
pixel_shader: *c.ID3D11PixelShader,

/// The input layout for our vertex attributes, if we have any.
input_layout: ?*c.ID3D11InputLayout,

/// The blend state, if blending is enabled.
blend_state: ?*c.ID3D11BlendState,

/// The size of a single vertex (or instance), in bytes.
stride: u32,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    var vs: ?*c.ID3D11VertexShader = null;
    try com.check(com.call(opts.device, "CreateVertexShader", .{
        opts.vertex_bytecode.ptr,
        opts.vertex_bytecode.len,
        null,
        &vs,
    }), "ID3D11Device::CreateVertexShader");
    errdefer com.releaseOpt(vs);

    var ps: ?*c.ID3D11PixelShader = null;
    try com.check(com.call(opts.device, "CreatePixelShader", .{
        opts.fragment_bytecode.ptr,
        opts.fragment_bytecode.len,
        null,
        &ps,
    }), "ID3D11Device::CreatePixelShader");
    errdefer com.releaseOpt(ps);

    var input_layout: ?*c.ID3D11InputLayout = null;
    if (VertexAttributes) |VA| {
        const elements = comptime inputElements(VA);
        const classification: c.D3D11_INPUT_CLASSIFICATION, const step_rate: c.UINT =
            switch (opts.step_fn) {
                .per_vertex => .{ c.D3D11_INPUT_PER_VERTEX_DATA, 0 },
                .per_instance => .{ c.D3D11_INPUT_PER_INSTANCE_DATA, 1 },
            };

        var descs: [elements.len]c.D3D11_INPUT_ELEMENT_DESC = undefined;
        for (&descs, elements) |*desc, elem| desc.* = .{
            .SemanticName = "ATTR",
            .SemanticIndex = elem.index,
            .Format = elem.format,
            .InputSlot = 0,
            .AlignedByteOffset = elem.offset,
            .InputSlotClass = classification,
            .InstanceDataStepRate = step_rate,
        };

        try com.check(com.call(opts.device, "CreateInputLayout", .{
            &descs,
            descs.len,
            opts.vertex_bytecode.ptr,
            opts.vertex_bytecode.len,
            &input_layout,
        }), "ID3D11Device::CreateInputLayout");
    }
    errdefer com.releaseOpt(input_layout);

    var blend_state: ?*c.ID3D11BlendState = null;
    if (opts.blending_enabled) {
        // Our shaders output premultiplied alpha.
        var desc = std.mem.zeroes(c.D3D11_BLEND_DESC);
        desc.RenderTarget[0] = .{
            .BlendEnable = c.TRUE,
            .SrcBlend = c.D3D11_BLEND_ONE,
            .DestBlend = c.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOp = c.D3D11_BLEND_OP_ADD,
            .SrcBlendAlpha = c.D3D11_BLEND_ONE,
            .DestBlendAlpha = c.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = c.D3D11_BLEND_OP_ADD,
            .RenderTargetWriteMask = c.D3D11_COLOR_WRITE_ENABLE_ALL,
        };
        try com.check(
            com.call(opts.device, "CreateBlendState", .{ &desc, &blend_state }),
            "ID3D11Device::CreateBlendState",
        );
    }

    return .{
        .vertex_shader = vs.?,
        .pixel_shader = ps.?,
        .input_layout = input_layout,
        .blend_state = blend_state,
        .stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
    };
}

pub fn deinit(self: *const Self) void {
    com.releaseOpt(self.blend_state);
    com.releaseOpt(self.input_layout);
    com.release(self.pixel_shader);
    com.release(self.vertex_shader);
}

const InputElement = struct {
    index: c.UINT,
    format: c.DXGI_FORMAT,
    offset: c.UINT,
};

/// Derive the input elements for a vertex attribute struct. Each field
/// becomes the attribute with semantic `ATTR<n>`, where n is the index
/// of the field in the struct.
fn inputElements(comptime T: type) []const InputElement {
    const info = @typeInfo(T).@"struct";
    var result: [info.field_names.len]InputElement = undefined;
    for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        const FT = switch (@typeInfo(field_type)) {
            .@"struct" => |s| s.backing_integer.?,
            .@"enum" => |e| e.tag_type,
            else => field_type,
        };

        const len, const IT = switch (@typeInfo(FT)) {
            .array => |a| .{ a.len, a.child },
            else => .{ 1, FT },
        };

        result[i] = .{
            .index = i,
            .format = vertexFormat(IT, len),
            .offset = @offsetOf(T, field_name),
        };
    }
    const final = result;
    return &final;
}

/// The DXGI format for a vertex attribute of `len` elements of type `T`.
fn vertexFormat(comptime T: type, comptime len: usize) c.DXGI_FORMAT {
    const formats: [4]c.DXGI_FORMAT = switch (T) {
        u8 => .{ c.DXGI_FORMAT_R8_UINT, c.DXGI_FORMAT_R8G8_UINT, c.DXGI_FORMAT_UNKNOWN, c.DXGI_FORMAT_R8G8B8A8_UINT },
        i8 => .{ c.DXGI_FORMAT_R8_SINT, c.DXGI_FORMAT_R8G8_SINT, c.DXGI_FORMAT_UNKNOWN, c.DXGI_FORMAT_R8G8B8A8_SINT },
        u16 => .{ c.DXGI_FORMAT_R16_UINT, c.DXGI_FORMAT_R16G16_UINT, c.DXGI_FORMAT_UNKNOWN, c.DXGI_FORMAT_R16G16B16A16_UINT },
        i16 => .{ c.DXGI_FORMAT_R16_SINT, c.DXGI_FORMAT_R16G16_SINT, c.DXGI_FORMAT_UNKNOWN, c.DXGI_FORMAT_R16G16B16A16_SINT },
        u32 => .{ c.DXGI_FORMAT_R32_UINT, c.DXGI_FORMAT_R32G32_UINT, c.DXGI_FORMAT_R32G32B32_UINT, c.DXGI_FORMAT_R32G32B32A32_UINT },
        i32 => .{ c.DXGI_FORMAT_R32_SINT, c.DXGI_FORMAT_R32G32_SINT, c.DXGI_FORMAT_R32G32B32_SINT, c.DXGI_FORMAT_R32G32B32A32_SINT },
        f32 => .{ c.DXGI_FORMAT_R32_FLOAT, c.DXGI_FORMAT_R32G32_FLOAT, c.DXGI_FORMAT_R32G32B32_FLOAT, c.DXGI_FORMAT_R32G32B32A32_FLOAT },
        else => @compileError("unsupported vertex attribute type: " ++ @typeName(T)),
    };

    const format = formats[len - 1];
    if (format == c.DXGI_FORMAT_UNKNOWN) {
        @compileError(std.fmt.comptimePrint(
            "unsupported vertex attribute: {d} x {s}",
            .{ len, @typeName(T) },
        ));
    }
    return format;
}
