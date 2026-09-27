//! D3D7 transform and render state, shared by the device stubs and the
//! software rasterizer.
//!
//! Split out of d3d7.zig so the rasterizer does not have to import the
//! device module back, which would make the two mutually dependent.

/// Identity 4×4 matrix (row-major, matching D3D convention).
pub const identity_4x4: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

/// D3DTRANSFORMSTATETYPE indices used by Europa / D3D3/D3D7.
/// D3DTRANSFORMSTATE_WORLD = 1, VIEW = 2, PROJECTION = 3
/// D3D7 adds WORLD1-3 = 4-6, TEXTURE0-7 = 16-23
pub const max_transforms = 24;
pub var transform_matrices: [max_transforms][16]f32 = [_][16]f32{identity_4x4} ** max_transforms;

/// Render state table — D3DRENDERSTATETYPE values up to 255.
/// Defaults are set at comptime matching D3D7 documentation.
pub const max_render_states = 256;
pub var render_states: [max_render_states]u32 = blk: {
    var rs = [_]u32{0} ** max_render_states;
    rs[7] = 2; // D3DRS_CULLMODE = D3DCULL_CCW
    rs[14] = 1; // D3DRS_ZWRITEENABLE = TRUE
    rs[19] = 1; // D3DRS_DITHERENABLE = TRUE
    rs[24] = 1; // D3DRS_COLORVERTEX = TRUE
    rs[25] = 8; // D3DRS_ALPHAFUNC = D3DCMP_ALWAYS
    rs[27] = 2; // D3DRS_SRCBLEND = D3DBLEND_ONE
    rs[28] = 1; // D3DRS_DESTBLEND = D3DBLEND_ZERO
    rs[137] = 1; // D3DRS_LIGHTING = TRUE
    rs[174] = 0x0F; // D3DRS_COLORWRITEENABLE = all channels
    break :blk rs;
};

/// 4×4 matrix multiply using @Vector(4, f32) SIMD intrinsics.
/// result = a × b (row-major, matching D3D convention).
pub fn mat4x4Multiply(a: [16]f32, b: [16]f32) [16]f32 {
    // Extract columns of B for broadcast multiply
    const b_cols: [4]@Vector(4, f32) = .{
        .{ b[0], b[4], b[8], b[12] },
        .{ b[1], b[5], b[9], b[13] },
        .{ b[2], b[6], b[10], b[14] },
        .{ b[3], b[7], b[11], b[15] },
    };
    var r: [16]f32 = undefined;
    inline for (0..4) |row| {
        const a_row: @Vector(4, f32) = a[row * 4 ..][0..4].*;
        // Dot product of a_row with each column of B
        inline for (0..4) |col| {
            r[row * 4 + col] = @reduce(.Add, a_row * b_cols[col]);
        }
    }
    return r;
}
