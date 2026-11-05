//! Represents a render target.
//!
//! In this case, a render target is the swap chain's back buffer: each
//! frame binds it (`Direct3D11.beginFrame` resizes the swap chain to the
//! target's size and sets `rtv`), and the renderer draws straight into it.
//! A separate offscreen texture copied into the back buffer would cost a
//! third buffer the size of the surface, and a copy each frame.
const Self = @This();

const com = @import("com.zig");
const c = com.c;

/// The view used to render to the back buffer, while a frame is bound.
/// It's owned by the API.
rtv: ?*c.ID3D11RenderTargetView = null,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn deinit(self: *Self) void {
    self.* = undefined;
}
