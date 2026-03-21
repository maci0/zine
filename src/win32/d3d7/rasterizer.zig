//! Software triangle rasterizer for D3D3/D3D7 DrawPrimitive calls.
//!
//! Transforms vertices through the World×View×Projection matrix chain,
//! applies perspective divide and viewport mapping, then rasterizes
//! flat-shaded triangles with z-buffer depth testing.
//!
//! Hot paths use `inline` and `@Vector` SIMD. Vertex parsing is
//! comptime-parameterised on `is_tl` to eliminate branches in the inner loop.

const std = @import("std");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const w32cc = @import("../calling_convention.zig");
const ddraw_stubs = @import("../ddraw/ddraw.zig");

// ===== Types =====

/// Screen-space vertex after transform + viewport mapping.
const ScreenVertex = struct {
    x: f32,
    y: f32,
    z: f32, // depth (0..1) for z-buffer
    color: u32, // ARGB packed color
};

/// 4-component vector for homogeneous coordinates.
const Vec4 = @Vector(4, f32);

// ===== Z-Buffer =====

var z_buffer: []f32 = &[_]f32{};
var z_buffer_w: u32 = 0;
var z_buffer_h: u32 = 0;

fn ensureZBuffer(w: u32, h: u32) void {
    if (z_buffer_w == w and z_buffer_h == h and z_buffer.len > 0) return;
    if (@import("../kernel32.zig").global_env) |genv| {
        if (z_buffer.len > 0) genv.allocator.free(z_buffer);
        z_buffer = genv.allocator.alloc(f32, @as(usize, w) * @as(usize, h)) catch return;
        @memset(z_buffer, 1.0); // far plane
        z_buffer_w = w;
        z_buffer_h = h;
    }
}

pub fn clearZBuffer(depth: f32) void {
    if (z_buffer.len > 0) {
        @memset(z_buffer, depth);
    }
}

// ===== Transform Pipeline =====

/// Import transform/state storage from d3d7.zig
const d3d7 = @import("d3d7.zig");

/// Transform a position through a 4×4 matrix using SIMD, returning homogeneous coords.
inline fn transformVec4(m: [16]f32, v: Vec4) Vec4 {
    // Column vectors — each @reduce(.Add, v * col) is a SIMD dot product
    const c0: Vec4 = .{ m[0], m[4], m[8], m[12] };
    const c1: Vec4 = .{ m[1], m[5], m[9], m[13] };
    const c2: Vec4 = .{ m[2], m[6], m[10], m[14] };
    const c3: Vec4 = .{ m[3], m[7], m[11], m[15] };
    return .{
        @reduce(.Add, v * c0),
        @reduce(.Add, v * c1),
        @reduce(.Add, v * c2),
        @reduce(.Add, v * c3),
    };
}

/// Build combined World×View×Projection matrix using SIMD multiply.
inline fn getWVPMatrix() [16]f32 {
    const world = d3d7.transform_matrices[1]; // D3DTRANSFORMSTATE_WORLD
    const view = d3d7.transform_matrices[2]; // D3DTRANSFORMSTATE_VIEW
    const proj = d3d7.transform_matrices[3]; // D3DTRANSFORMSTATE_PROJECTION
    const wv = d3d7.mat4x4Multiply(world, view);
    return d3d7.mat4x4Multiply(wv, proj);
}

/// Transform a 3D vertex to screen space.
inline fn transformToScreen(pos: Vec4, wvp: [16]f32, vp_x: f32, vp_y: f32, vp_w: f32, vp_h: f32) ScreenVertex {
    const clip = transformVec4(wvp, pos);
    const w = clip[3];
    if (w == 0) return .{ .x = 0, .y = 0, .z = 0, .color = 0 };
    const inv_w = 1.0 / w;

    // NDC: [-1,1] → viewport
    const ndc_x = clip[0] * inv_w;
    const ndc_y = clip[1] * inv_w;
    const ndc_z = clip[2] * inv_w;

    return .{
        .x = vp_x + (1.0 + ndc_x) * 0.5 * vp_w,
        .y = vp_y + (1.0 - ndc_y) * 0.5 * vp_h, // Y is flipped
        .z = (ndc_z + 1.0) * 0.5, // map to [0,1]
        .color = 0,
    };
}

// ===== Triangle Rasterizer =====

/// Rasterize a single flat-shaded triangle with z-buffer test.
/// Marked inline — this is called per-triangle in the draw loop.
inline fn rasterizeTriangle(v0: ScreenVertex, v1: ScreenVertex, v2: ScreenVertex, buf: []u8, w: u32, h: u32) void {
    // Bounding box (clamped to viewport)
    const min_x = @max(@as(i32, @intFromFloat(@floor(@min(@min(v0.x, v1.x), v2.x)))), 0);
    const max_x = @min(@as(i32, @intFromFloat(@ceil(@max(@max(v0.x, v1.x), v2.x)))), @as(i32, @intCast(w)) - 1);
    const min_y = @max(@as(i32, @intFromFloat(@floor(@min(@min(v0.y, v1.y), v2.y)))), 0);
    const max_y = @min(@as(i32, @intFromFloat(@ceil(@max(@max(v0.y, v1.y), v2.y)))), @as(i32, @intCast(h)) - 1);

    if (min_x > max_x or min_y > max_y) return;

    // Edge function setup (2× signed area)
    const area = (v1.x - v0.x) * (v2.y - v0.y) - (v2.x - v0.x) * (v1.y - v0.y);
    if (area == 0) return; // degenerate
    const inv_area = 1.0 / area;
    const positive_area = area > 0;

    // Use first vertex color for flat shading
    const color = v0.color;
    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    var py = min_y;
    while (py <= max_y) : (py += 1) {
        var px = min_x;
        while (px <= max_x) : (px += 1) {
            const fx: f32 = @floatFromInt(px);
            const fy: f32 = @floatFromInt(py);

            // Barycentric coordinates via edge functions
            const w0 = (v1.x - v0.x) * (fy - v0.y) - (v1.y - v0.y) * (fx - v0.x);
            const w1 = (v2.x - v1.x) * (fy - v1.y) - (v2.y - v1.y) * (fx - v1.x);
            const w2 = (v0.x - v2.x) * (fy - v2.y) - (v0.y - v2.y) * (fx - v2.x);

            // Inside test (handle both CW and CCW winding)
            const outside = if (positive_area)
                (w0 < 0 or w1 < 0 or w2 < 0)
            else
                (w0 > 0 or w1 > 0 or w2 > 0);
            if (outside) continue;

            // Interpolate depth
            const z = v0.z * (w1 * inv_area) + v1.z * (w2 * inv_area) + v2.z * (w0 * inv_area);

            // Z-buffer test + pixel write
            const idx = @as(usize, @intCast(py)) * @as(usize, w) + @as(usize, @intCast(px));
            if (idx < z_buffer.len and z < z_buffer[idx]) {
                z_buffer[idx] = z;
                const di = idx * 4;
                if (di + 3 < buf.len) {
                    buf[di + 0] = r;
                    buf[di + 1] = g;
                    buf[di + 2] = b;
                    buf[di + 3] = 255;
                }
            }
        }
    }
}

// ===== Vertex Parsing =====

/// D3DPT_* primitive types
const D3DPT_TRIANGLELIST = 4;
const D3DPT_TRIANGLESTRIP = 5;
const D3DPT_TRIANGLEFAN = 6;

/// Parse a vertex from guest memory. `comptime is_tl` eliminates the transform
/// branch — LLVM gets separate code paths for transformed vs untransformed vertices.
inline fn parseVertex(ptr: usize, stride: usize, idx: usize, wvp: [16]f32, vp_x: f32, vp_y: f32, vp_w: f32, vp_h: f32, comptime is_tl: bool) ScreenVertex {
    const base = ptr + idx * stride;
    const x = @as(*const f32, @ptrFromInt(base)).*;
    const y = @as(*const f32, @ptrFromInt(base + 4)).*;
    const z = @as(*const f32, @ptrFromInt(base + 8)).*;

    if (is_tl) {
        // Pre-transformed: x,y are screen coords, z is depth, rhw at +12
        const color = @as(*const u32, @ptrFromInt(base + 16)).*;
        return .{ .x = x, .y = y, .z = z, .color = color };
    } else {
        // Transform through WVP
        var sv = transformToScreen(.{ x, y, z, 1.0 }, wvp, vp_x, vp_y, vp_w, vp_h);
        // Read diffuse color at offset 16 (D3DLVERTEX layout)
        if (stride >= 32) {
            sv.color = @as(*const u32, @ptrFromInt(base + 16)).*;
        } else {
            sv.color = 0xFFFFFFFF;
        }
        return sv;
    }
}

// ===== Draw Loop (comptime-parameterised) =====

/// Generic draw loop, monomorphised on `comptime is_tl` to avoid per-vertex branch.
fn drawTriangles(comptime is_tl: bool, primType: usize, lpVertices: usize, count: usize, indices_opt: ?[*]const u16, wvp: [16]f32, vp_x: f32, vp_y: f32, vp_w: f32, vp_h: f32, buf: []u8, vw: u32, vh: u32) void {
    const stride: usize = 32;

    // Helper to fetch vertex index
    const getIdx = struct {
        inline fn get(idx: usize, idxs: ?[*]const u16) usize {
            return if (idxs) |ib| ib[idx] else idx;
        }
    }.get;

    switch (primType) {
        D3DPT_TRIANGLELIST => {
            var i: usize = 0;
            while (i + 2 < count) : (i += 3) {
                const sv0 = parseVertex(lpVertices, stride, getIdx(i, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                const sv1 = parseVertex(lpVertices, stride, getIdx(i + 1, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                const sv2 = parseVertex(lpVertices, stride, getIdx(i + 2, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                rasterizeTriangle(sv0, sv1, sv2, buf, vw, vh);
            }
        },
        D3DPT_TRIANGLESTRIP => {
            var i: usize = 0;
            while (i + 2 < count) : (i += 1) {
                const sv0 = parseVertex(lpVertices, stride, getIdx(i, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                const sv1 = parseVertex(lpVertices, stride, getIdx(i + 1, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                const sv2 = parseVertex(lpVertices, stride, getIdx(i + 2, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                if (i % 2 == 0)
                    rasterizeTriangle(sv0, sv1, sv2, buf, vw, vh)
                else
                    rasterizeTriangle(sv0, sv2, sv1, buf, vw, vh);
            }
        },
        D3DPT_TRIANGLEFAN => {
            const sv0 = parseVertex(lpVertices, stride, getIdx(0, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
            var i: usize = 1;
            while (i + 1 < count) : (i += 1) {
                const sv1 = parseVertex(lpVertices, stride, getIdx(i, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                const sv2 = parseVertex(lpVertices, stride, getIdx(i + 1, indices_opt), wvp, vp_x, vp_y, vp_w, vp_h, is_tl);
                rasterizeTriangle(sv0, sv1, sv2, buf, vw, vh);
            }
        },
        else => {},
    }
}

/// Shared setup for both DrawPrimitive and DrawIndexedPrimitive.
fn setupDraw(vertexTypeOrFVF: usize, vw: u32, vh: u32) struct { is_tl: bool, wvp: [16]f32, vp_x: f32, vp_y: f32, vp_w: f32, vp_h: f32, buf: []u8 } {
    const is_tl = (vertexTypeOrFVF == 3) or (vertexTypeOrFVF & 0x004) != 0;
    const wvp = if (!is_tl) getWVPMatrix() else d3d7.identity_4x4;
    const buf = if (ddraw_stubs.surface_buffer.len >= @as(usize, vw) * @as(usize, vh) * 4)
        ddraw_stubs.surface_buffer
    else
        renderer.global_framebuf;
    return .{
        .is_tl = is_tl,
        .wvp = wvp,
        .vp_x = 0,
        .vp_y = 0,
        .vp_w = @floatFromInt(vw),
        .vp_h = @floatFromInt(vh),
        .buf = buf,
    };
}

// ===== Public Entry Points =====

/// DrawPrimitive: (this, primType, vertexType, lpVertices, dwVertexCount, dwFlags)
pub fn impl_DrawPrimitive(this: usize, primType: usize, vertexTypeOrFVF: usize, lpVertices: usize, dwVertexCount: usize, dwFlags: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    _ = dwFlags;
    if (lpVertices == 0 or dwVertexCount < 3) return 0;
    if (trace.enable_tracing) trace.print("D3D7: DrawPrimitive(type={d}, vtxType={d}, count={d})\n", .{ primType, vertexTypeOrFVF, dwVertexCount });

    const vw = renderer.global_width;
    const vh = renderer.global_height;
    if (vw == 0 or vh == 0) return 0;
    ensureZBuffer(vw, vh);

    const s = setupDraw(vertexTypeOrFVF, vw, vh);
    // Runtime branch here, but the hot loop inside is fully monomorphised
    if (s.is_tl)
        drawTriangles(true, primType, lpVertices, dwVertexCount, null, s.wvp, s.vp_x, s.vp_y, s.vp_w, s.vp_h, s.buf, vw, vh)
    else
        drawTriangles(false, primType, lpVertices, dwVertexCount, null, s.wvp, s.vp_x, s.vp_y, s.vp_w, s.vp_h, s.buf, vw, vh);
    return 0;
}

/// DrawIndexedPrimitive: (this, primType, vertexType, lpVertices, dwVertexCount, lpIndices, dwIndexCount, dwFlags)
pub fn impl_DrawIndexedPrimitive(this: usize, primType: usize, vertexTypeOrFVF: usize, lpVertices: usize, dwVertexCount: usize, lpIndices: usize, dwIndexCount: usize, dwFlags: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    _ = dwVertexCount;
    _ = dwFlags;
    if (lpVertices == 0 or lpIndices == 0 or dwIndexCount < 3) return 0;
    if (trace.enable_tracing) trace.print("D3D7: DrawIndexedPrimitive(type={d}, count={d})\n", .{ primType, dwIndexCount });

    const vw = renderer.global_width;
    const vh = renderer.global_height;
    if (vw == 0 or vh == 0) return 0;
    ensureZBuffer(vw, vh);

    const s = setupDraw(vertexTypeOrFVF, vw, vh);
    const indices = @as([*]const u16, @ptrFromInt(lpIndices));
    if (s.is_tl)
        drawTriangles(true, primType, lpVertices, dwIndexCount, indices, s.wvp, s.vp_x, s.vp_y, s.vp_w, s.vp_h, s.buf, vw, vh)
    else
        drawTriangles(false, primType, lpVertices, dwIndexCount, indices, s.wvp, s.vp_x, s.vp_y, s.vp_w, s.vp_h, s.buf, vw, vh);
    return 0;
}
