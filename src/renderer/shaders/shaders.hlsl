// HLSL shaders for the Direct3D 11 renderer.
//
// These are ports of the GLSL shaders in `glsl/`, so keep them in sync.
// Each stage is a separate entry point in this file, compiled at runtime
// with D3DCompile using the vs_5_0/ps_5_0 profiles.
//
// Resource bindings (see direct3d11/RenderPass.zig):
// - b0: the global uniforms
// - t0..t7: step textures, in order
// - t8..: step buffers 1.., as structured buffers (buffer 0 is the
//   vertex buffer)
// - s0: the step sampler (or the default linear clamp sampler)

//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//
cbuffer Globals : register(b0) {
    float4x4 projection_matrix;
    float2 screen_size;
    float2 cell_size;
    uint grid_size_packed_2u16;
    float4 grid_padding;
    uint padding_extend;
    float min_contrast;
    uint cursor_pos_packed_2u16;
    uint cursor_color_packed_4u8;
    uint bg_color_packed_4u8;
    uint bools;
};

// Bools
static const uint CURSOR_WIDE = 1u;
static const uint USE_DISPLAY_P3 = 2u;
static const uint USE_LINEAR_BLENDING = 4u;
static const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend enum
static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.

uint4 unpack4u8(uint packed_value) {
    return uint4(
        (packed_value >> 0) & 0xFFu,
        (packed_value >> 8) & 0xFFu,
        (packed_value >> 16) & 0xFFu,
        (packed_value >> 24) & 0xFFu
    );
}

uint2 unpack2u16(uint packed_value) {
    return uint2(
        (packed_value >> 0) & 0xFFFFu,
        (packed_value >> 16) & 0xFFFFu
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(float3 color1, float3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(float3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(float3(0.0, 0.0, 0.0), bg.rgb);
        if (white_ratio > black_ratio) {
            return float4(1.0, 1.0, 1.0, 1.0);
        } else {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    return fg;
}

// Converts a color from sRGB gamma encoding to linear.
float4 linearize(float4 srgb) {
    float3 cutoff = (float3)(srgb.rgb <= float3(0.04045, 0.04045, 0.04045));
    float3 higher = pow(abs((srgb.rgb + 0.055) / 1.055), 2.4);
    float3 lower = srgb.rgb / 12.92;

    return float4(lerp(higher, lower, cutoff), srgb.a);
}
float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow(abs((v + 0.055) / 1.055), 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
float4 unlinearize(float4 linear_color) {
    float3 cutoff = (float3)(linear_color.rgb <= float3(0.0031308, 0.0031308, 0.0031308));
    float3 higher = pow(abs(linear_color.rgb), 1.0 / 2.4) * 1.055 - 0.055;
    float3 lower = linear_color.rgb * 12.92;

    return float4(lerp(higher, lower, cutoff), linear_color.a);
}
float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(abs(v), 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
//
// `linear` controls whether the returned color is linear or gamma encoded.
float4 load_color(uint4 in_color, bool linear_out) {
    // 0 .. 255 -> 0.0 .. 1.0
    float4 color = float4(in_color) / 255.0f;

    // Linearize if necessary.
    if (linear_out) color = linearize(color);

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}

// GLSL-style mod, which is always non-negative for positive y.
float2 glsl_mod(float2 x, float2 y) {
    return x - y * floor(x / y);
}

// The position of a vertex of a single triangle covering the viewport.
//
// X <- vid == 0: (-1, -3)
// |\
// | \
// |  \
// |###\
// |#+# \ `+` is (0, 0). `#`s are viewport area.
// |###  \
// X------X <- vid == 2: (3, 1)
// ^
// vid == 1: (-1, 1)
float4 full_screen_position(uint vid) {
    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;
    return position;
}

// We use a triangle strip with 4 vertices to render quads,
// so we determine which corner of the quad a vertex is in
// based on the vertex ID.
//
//   0 --> 1
//   |   .'|
//   |  /  |
//   | L   |
//   2 --> 3
//
// 0 = top-left  (0, 0)
// 1 = top-right (1, 0)
// 2 = bot-left  (0, 1)
// 3 = bot-right (1, 1)
float2 quad_corner(uint vid) {
    float2 corner;
    corner.x = (vid == 1 || vid == 3) ? 1.0 : 0.0;
    corner.y = (vid == 2 || vid == 3) ? 1.0 : 0.0;
    return corner;
}

//----------------------------------------------------------------------------//
// Full Screen Vertex Shader
//----------------------------------------------------------------------------//

float4 full_screen_vertex(uint vid : SV_VertexID) : SV_Position {
    return full_screen_position(vid);
}

//----------------------------------------------------------------------------//
// Background Color Shader
//----------------------------------------------------------------------------//

float4 bg_color_fragment(float4 position : SV_Position) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    return load_color(
        unpack4u8(bg_color_packed_4u8),
        use_linear_blending
    );
}

//----------------------------------------------------------------------------//
// Cell Background Shader
//----------------------------------------------------------------------------//

StructuredBuffer<uint> bg_cells : register(t8);

float4 cell_bg_fragment(float4 position : SV_Position) : SV_Target {
    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    int2 grid_pos = int2(floor((position.xy - grid_padding.wx) / cell_size));
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 bg = float4(0.0, 0.0, 0.0, 0.0);

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > int(grid_size.x) - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = int(grid_size.x) - 1;
        } else {
            return bg;
        }
    }

    // Clamp y position if we should extend, otherwise discard if out of bounds.
    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.y > int(grid_size.y) - 1) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = int(grid_size.y) - 1;
        } else {
            return bg;
        }
    }

    // Load the color for the cell.
    return load_color(
        unpack4u8(bg_cells[uint(grid_pos.y) * grid_size.x + uint(grid_pos.x)]),
        use_linear_blending
    );
}

//----------------------------------------------------------------------------//
// Cell Text Shader
//----------------------------------------------------------------------------//

// Values `atlas` can take.
static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;

// Masks for the `glyph_bools` attribute
static const uint NO_MIN_CONTRAST = 1u;
static const uint IS_CURSOR_GLYPH = 2u;

struct CellTextVertexIn {
    // The position of the glyph in the texture (x, y)
    uint2 glyph_pos : ATTR0;

    // The size of the glyph in the texture (w, h)
    uint2 glyph_size : ATTR1;

    // The left and top bearings for the glyph (x, y)
    int2 bearings : ATTR2;

    // The grid coordinates (x, y) where x < columns and y < rows
    uint2 grid_pos : ATTR3;

    // The color of the rendered text glyph.
    uint4 color : ATTR4;

    // Which atlas this glyph is in.
    uint atlas : ATTR5;

    // Misc glyph properties.
    uint glyph_bools : ATTR6;

    uint vid : SV_VertexID;
};

struct CellTextVertexOut {
    float4 position : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 bg_color : COLOR1;
    float2 tex_coord : TEXCOORD0;
};

CellTextVertexOut cell_text_vertex(CellTextVertexIn input) {
    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    CellTextVertexOut output;

    // Convert the grid x, y into world space x, y by accounting for cell size
    float2 cell_pos = cell_size * float2(input.grid_pos);

    float2 corner = quad_corner(input.vid);

    output.atlas = input.atlas;

    // In order to get the top left of the glyph, we compute an offset based on
    // the bearings. The Y bearing is the distance from the bottom of the cell
    // to the top of the glyph, so we subtract it from the cell height to get
    // the y offset. The X bearing is the distance from the left of the cell
    // to the left of the glyph, so it works as the x offset directly.
    float2 size = float2(input.glyph_size);
    float2 offset = float2(input.bearings);

    offset.y = cell_size.y - offset.y;

    // Calculate the final position of the cell which uses our glyph size
    // and glyph offset to create the correct bounding box for the glyph.
    cell_pos = cell_pos + size * corner + offset;
    output.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

    // Calculate the texture coordinate in pixels. This is NOT normalized
    // (between 0.0 and 1.0), and does not need to be, since the texture
    // is read with integer texel coordinates.
    output.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * corner;

    // Get our color. We always fetch a linearized version to
    // make it easier to handle minimum contrast calculations.
    output.color = load_color(input.color, true);
    // Get the BG color
    output.bg_color = load_color(
        unpack4u8(bg_cells[input.grid_pos.y * grid_size.x + input.grid_pos.x]),
        true
    );
    // Blend it with the global bg color
    float4 global_bg = load_color(
        unpack4u8(bg_color_packed_4u8),
        true
    );
    output.bg_color += global_bg * (1.0 - output.bg_color.a);

    // If we have a minimum contrast, we need to check if we need to
    // change the color of the text to ensure it has enough contrast
    // with the background.
    if (min_contrast > 1.0f && (input.glyph_bools & NO_MIN_CONTRAST) == 0) {
        // Ensure our minimum contrast
        output.color = contrasted_color(min_contrast, output.color, output.bg_color);
    }

    // Check if current position is under cursor (including wide cursor)
    bool is_cursor_pos = ((input.grid_pos.x == cursor_pos.x) ||
        (cursor_wide && (input.grid_pos.x == (cursor_pos.x + 1)))) &&
        (input.grid_pos.y == cursor_pos.y);

    // If this cell is the cursor cell, but we're not processing
    // the cursor glyph itself, then we need to change the color.
    if ((input.glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
        output.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    return output;
}

Texture2D<float> atlas_grayscale : register(t0);
Texture2D<float4> atlas_color : register(t1);

float4 cell_text_fragment(CellTextVertexOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    int3 texel = int3(int2(floor(input.tex_coord)), 0);

    if (input.atlas == ATLAS_COLOR) {
        // For now, we assume that color glyphs
        // are already premultiplied linear colors.
        float4 color = atlas_color.Load(texel);

        // If we are doing linear blending, we can return this right away.
        if (use_linear_blending) {
            return color;
        }

        // Otherwise we need to unlinearize the color. Since the alpha is
        // premultiplied, we need to divide it out before unlinearizing.
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;

        return color;
    }

    // Grayscale atlas.

    // Our input color is always linear.
    float4 color = input.color;

    // If we're not doing linear blending, then we need to
    // re-apply the gamma encoding to our color manually.
    //
    // Since the alpha is premultiplied, we need to divide
    // it out before unlinearizing and re-multiply it after.
    if (!use_linear_blending) {
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
    }

    // Fetch our alpha mask for this pixel.
    float a = atlas_grayscale.Load(texel);

    // Linear blending weight correction corrects the alpha value to
    // produce blending results which match gamma-incorrect blending.
    if (use_linear_correction) {
        // See the GLSL shader for an explanation of how this works.
        float4 bg = input.bg_color;
        float fg_l = luminance(color.rgb);
        float bg_l = luminance(bg.rgb);
        // To avoid numbers going haywire, we don't apply correction
        // when the bg and fg luminances are within 0.001 of each other.
        if (abs(fg_l - bg_l) > 0.001) {
            float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
        }
    }

    // Multiply our whole color by the alpha mask.
    // Since we use premultiplied alpha, this is
    // the correct way to apply the mask.
    return color * a;
}

//----------------------------------------------------------------------------//
// Image Shader
//----------------------------------------------------------------------------//

Texture2D<float4> image : register(t0);
SamplerState image_sampler : register(s0);

struct ImageVertexIn {
    float2 grid_pos : ATTR0;
    float2 cell_offset : ATTR1;
    float4 source_rect : ATTR2;
    float2 dest_size : ATTR3;
    uint vid : SV_VertexID;
};

struct ImageVertexOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

ImageVertexOut image_vertex(ImageVertexIn input) {
    ImageVertexOut output;

    float2 corner = quad_corner(input.vid);

    // The texture coordinates start at our source x/y
    // and add the width/height depending on the corner.
    float2 tex_coord = input.source_rect.xy;
    tex_coord += input.source_rect.zw * corner;

    // Normalize the coordinates.
    uint tex_width, tex_height;
    image.GetDimensions(tex_width, tex_height);
    output.tex_coord = tex_coord / float2(tex_width, tex_height);

    // The position of our image starts at the top-left of the grid cell and
    // adds the source rect width/height components.
    float2 image_pos = (cell_size * input.grid_pos) + input.cell_offset;
    image_pos += input.dest_size * corner;

    output.position = mul(projection_matrix, float4(image_pos.xy, 0.0, 1.0));

    return output;
}

float4 image_fragment(ImageVertexOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 rgba = image.Sample(image_sampler, input.tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= rgba.a;

    return rgba;
}

//----------------------------------------------------------------------------//
// Background Image Shader
//----------------------------------------------------------------------------//

// 4 bits of info.
static const uint BG_IMAGE_POSITION = 15u;
static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;

// 2 bits of info shifted 4.
static const uint BG_IMAGE_FIT = 3u << 4;
static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of info shifted 6.
static const uint BG_IMAGE_REPEAT = 1u << 6;

struct BgImageVertexIn {
    float opacity : ATTR0;
    uint info : ATTR1;
    uint vid : SV_VertexID;
};

struct BgImageVertexOut {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset : TEXCOORD0;
    nointerpolation float2 scale : TEXCOORD1;
    nointerpolation float opacity : TEXCOORD2;
    nointerpolation uint repeat : TEXCOORD3;
};

BgImageVertexOut bg_image_vertex(BgImageVertexIn input) {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    BgImageVertexOut output;

    output.position = full_screen_position(input.vid);
    output.opacity = input.opacity;
    output.repeat = input.info & BG_IMAGE_REPEAT;

    uint tex_width, tex_height;
    image.GetDimensions(tex_width, tex_height);
    float2 tex_size = float2(tex_width, tex_height);

    float2 dest_size = tex_size;
    uint fit = input.info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        // For `contain` we scale by a factor that makes the image
        // width match the screen width or makes the image height
        // match the screen height, whichever is smaller.
        float s = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_COVER) {
        // For `cover` we scale by a factor that makes the image
        // width match the screen width or makes the image height
        // match the screen height, whichever is larger.
        float s = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_STRETCH) {
        // For `stretch` we stretch the image to the size of
        // the screen without worrying about aspect ratio.
        dest_size = screen_size;
    } else if (fit == BG_IMAGE_NO_FIT) {
        // For `none` we just use the original texture size.
        dest_size = tex_size;
    }

    float2 start = float2(0.0, 0.0);
    float2 mid = (screen_size - dest_size) / 2.0;
    float2 end = screen_size - dest_size;

    float2 dest_offset = mid;
    uint position = input.info & BG_IMAGE_POSITION;
    if (position == BG_IMAGE_TL) {
        dest_offset = float2(start.x, start.y);
    } else if (position == BG_IMAGE_TC) {
        dest_offset = float2(mid.x, start.y);
    } else if (position == BG_IMAGE_TR) {
        dest_offset = float2(end.x, start.y);
    } else if (position == BG_IMAGE_ML) {
        dest_offset = float2(start.x, mid.y);
    } else if (position == BG_IMAGE_MC) {
        dest_offset = float2(mid.x, mid.y);
    } else if (position == BG_IMAGE_MR) {
        dest_offset = float2(end.x, mid.y);
    } else if (position == BG_IMAGE_BL) {
        dest_offset = float2(start.x, end.y);
    } else if (position == BG_IMAGE_BC) {
        dest_offset = float2(mid.x, end.y);
    } else if (position == BG_IMAGE_BR) {
        dest_offset = float2(end.x, end.y);
    }

    output.offset = dest_offset;
    output.scale = tex_size / dest_size;

    // We load a fully opaque version of the bg color and combine it with
    // the alpha separately, because we need these as separate values in
    // the fragment shader.
    uint4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    output.bg_color = float4(load_color(
        uint4(u_bg_color.rgb, 255),
        use_linear_blending
    ).rgb, float(u_bg_color.a) / 255.0);

    return output;
}

float4 bg_image_fragment(BgImageVertexOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Our texture coordinate is based on the screen position, offset by the
    // dest rect origin, and scaled by the ratio between the dest rect size
    // and the original texture size, which effectively scales the original
    // size of the texture to the dest rect size.
    float2 tex_coord = (input.position.xy - input.offset) * input.scale;

    uint tex_width, tex_height;
    image.GetDimensions(tex_width, tex_height);
    float2 tex_size = float2(tex_width, tex_height);

    // If we need to repeat the texture, wrap the coordinates.
    if (input.repeat != 0) {
        tex_coord = glsl_mod(glsl_mod(tex_coord, tex_size) + tex_size, tex_size);
    }

    float4 rgba;
    // If we're out of bounds, we have no color,
    // otherwise we sample the texture for it.
    if (any(tex_coord < float2(0.0, 0.0)) || any(tex_coord > tex_size)) {
        rgba = float4(0.0, 0.0, 0.0, 0.0);
    } else {
        // We divide by the texture size to normalize for sampling.
        rgba = image.Sample(image_sampler, tex_coord / tex_size);

        if (!use_linear_blending) {
            rgba = unlinearize(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // Multiply it by the configured opacity, but cap it at
    // the value that will make it fully opaque relative to
    // the background color alpha, so it isn't overexposed.
    rgba *= min(input.opacity, 1.0 / input.bg_color.a);

    // Blend it on to a fully opaque version of the background color.
    rgba += max(float4(0.0, 0.0, 0.0, 0.0), float4(input.bg_color.rgb, 1.0) * (1.0 - rgba.a));

    // Multiply everything by the background color alpha.
    rgba *= input.bg_color.a;

    return rgba;
}
