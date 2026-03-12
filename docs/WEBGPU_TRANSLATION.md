# Translating DirectDraw / Direct3D to WebGPU

This document describes how the Zine emulator's `ddraw.dll`, `d3d8.dll`,
`d3d9.dll`, `d3d10.dll`, `d3d10_1.dll`, `d3d11.dll`, `d3d12.dll`, `vulkan-1.dll`,
and GDI32 rendering stubs can be reimplemented on top of WebGPU when running in
the browser via the WASM target.

The Direct3D versions covered span a wide range of Windows gaming eras:

| API | Shader Model | Era | Key Games |
|---|---|---|---|
| DirectDraw | N/A (2D only) | 1995–2001 | Age of Empires, StarCraft, Diablo II |
| Direct3D 7 | Fixed-function | 1999–2002 | Deus Ex, Max Payne, Gothic |
| Direct3D 8 | SM 1.0–1.4 | 2001–2004 | Morrowind, GTA Vice City, Warcraft III |
| Direct3D 9 | SM 2.0–3.0 | 2004–2009 | Half-Life 2, WoW, Oblivion, Crysis |
| Direct3D 10/10.1 | SM 4.0–4.1 | 2007–2010 | Assassin's Creed, Lost Planet, Bioshock |
| Direct3D 11 | SM 5.0 | 2009–2015+ | Skyrim, Battlefield 3, The Witcher 3 |
| Direct3D 12 | SM 5.1–6.x | 2015+ | Forza Horizon 4, Cyberpunk 2077, Halo Infinite |
| Vulkan | SPIR-V | 2016+ | Doom (2016), Wolfenstein II, Baldur's Gate 3 |

## Table of Contents

1. [Current Architecture](#current-architecture)
2. [Why WebGPU](#why-webgpu)
3. [Translation Strategy Overview](#translation-strategy-overview)
4. [Tier 1: Framebuffer Presentation](#tier-1-framebuffer-presentation)
   - JS-Side Setup · WGSL Fullscreen Quad Shader · Frame Upload Path · BGRA Format Match · Zig-Side Changes
5. [Tier 2: GPU-Accelerated Blitting](#tier-2-gpu-accelerated-blitting)
   - Surface Model · DirectDraw API → WebGPU Mapping · RGB565 Compute Shader · Color-Keyed Blit · Palette Support
6. [Tier 3: Fixed-Function Pipeline (D3D7, then D3D8)](#tier-3-fixed-function-pipeline-emulation-d3d7-then-d3d8)
   - 3a. D3D7 — Architecture · API Mapping · Shared WGSL Shaders · Blend Factors · Pipeline Caching
   - 3b. D3D8 — Additions Over D3D7 · API Mapping
7. [Tier 4: D3D9 Programmable Shaders](#tier-4-d3d9-programmable-shader-emulation)
   - What's New · Architecture · Shader Translation (Bytecode → WGSL) · SM2/SM3 Instructions · Vertex Declarations · Type Mapping · API Mapping · Sampler States · Fixed-Function Fallback
8. [Tier 5: D3D10 Modern Pipeline](#tier-5-d3d10-modern-pipeline-emulation)
   - What's New · Why D3D10 Maps Well · Architecture · API Mapping · Constant Buffers · Geometry Shader Emulation · SM4 Bytecode · DXGI Format Table
9. [Tier 6: D3D11 Full Pipeline](#tier-6-d3d11-full-pipeline-emulation)
   - What's New · Tessellation Emulation · Compute Shaders · Device/Context Split · Feature Levels · API Mapping
10. [Tier 7: D3D12 Explicit Pipeline](#tier-7-d3d12-explicit-pipeline-emulation)
    - What's New · Why D3D12 Maps Well to WebGPU · Architecture · Command Lists · PSOs · Root Signatures · API Mapping
11. [Tier 8: Vulkan](#tier-8-vulkan-emulation)
    - Why Vulkan Maps to WebGPU · Architecture · SPIR-V → WGSL · Descriptor Sets · API Mapping
12. [Cross-Cutting Concerns](#cross-cutting-concerns)
    - Frame Pacing & VSync · Alpha Test Emulation · Compressed Textures (DXT/BC) · Device Loss Recovery · MSAA
13. [Integration with WASM Architecture](#integration-with-wasm-architecture)
    - JS Import/Export Interface · Conditional Compilation · Fallback (`pushFrame` Software Path)
14. [Implementation Phases](#implementation-phases)
    - Phase A (Tier 1) · Phase B (Tier 2) · Phase C (D3D7/8) · Phase D (D3D9) · Phase E (D3D10) · Phase F (D3D11) · Phase G (D3D12) · Phase H (Vulkan) · Phase I (Refinement)
15. [Open Questions](#open-questions)
16. [Alternative: wgpu-native for Desktop Rendering](#alternative-wgpu-native-for-desktop-rendering)
17. [Alternative: DXVK as Universal Translation Layer](#alternative-dxvk-as-universal-translation-layer)
18. [References](#references)

---

## Current Architecture

Today, all three rendering paths converge on a shared CPU-side framebuffer:

```
Guest App
 ├── DDRAW.dll stubs  → surface_buffer[] ──┐
 ├── d3d8.dll stubs   → surface_buffer[] ──┤  pushSurfaceFrame() / pushFrame()
 └── GDI32 BitBlt etc → renderer.global_framebuf[] ──→ renderer.pushFrame()
                                                         ↓
                                                   WebSocket → browser canvas
```

Every rendering path currently:
1. Writes BGRA/RGB565 pixels into a CPU buffer
2. Converts to RGBA in `renderer.global_framebuf`
3. Pushes the frame over WebSocket as raw pixel data

This is inherently slow — all pixel conversion and blitting happens on the CPU
inside the WASM interpreter, and the entire framebuffer is serialized over a
WebSocket every frame.

---

## Why WebGPU

WebGPU is the successor to WebGL, offering:

| Feature | Benefit for Zine |
|---|---|
| Compute shaders | Pixel format conversion on the GPU (BGR→RGB, 16bpp→32bpp) |
| GPUBuffer / GPUTexture | Zero-copy surface management — guest writes to mapped buffer, GPU reads directly |
| Render pipelines + WGSL shaders | D3D7/8/9 fixed-function pipeline can be reimplemented as WGSL vertex/fragment shaders |
| `copyExternalImageToTexture` / `writeTexture` | Efficient CPU→GPU texture upload without readback |
| Full browser support (2025+) | Chrome 113+, Firefox 141+, Safari 26, Edge 113+ (~83% global coverage) |

> **Note — WebGPU limitations:** WebGPU deliberately omits several features
> present in native APIs. The most impactful for this project are:
> - **No tessellation shaders** (hull/domain) — must emulate via compute
> - **No geometry shaders** — must emulate via compute or vertex shader tricks
> - **No push constants** (Vulkan) — use uniform buffers; "immediate data" is
>   under active spec development
> - **No multi-queue** — single `GPUQueue` per device
> - **No sparse/tiled resources** — all textures must be fully committed

The key insight: **most games we emulate don't need the full complexity of their
D3D version**. They either software-render to a framebuffer (DirectDraw
Lock/Unlock pattern), use only basic fixed-function features (D3D7/8), or use a
subset of programmable shaders (D3D9). We can handle all of these efficiently
with WebGPU.

---

## Translation Strategy Overview

Eight tiers of complexity, implemented incrementally:

### Tier 1: Framebuffer Presentation (replaces current `pushFrame`)
- Guest writes to a CPU buffer → upload to `GPUTexture` → fullscreen quad
- Handles: DirectDraw Lock/Unlock, GDI BitBlt/StretchDIBits, software rendering
- **Immediate benefit**: eliminates per-pixel CPU conversion and WebSocket overhead

### Tier 2: GPU-Accelerated Blitting (replaces DirectDraw Blt/BltFast/Flip)
- Surface operations mapped to GPU texture copies and compute shader transforms
- Color key transparency via fragment shader discard
- Palette lookups via 256-entry texture or uniform buffer

### Tier 3: D3D7/D3D8 Fixed-Function Emulation
- Transform + lighting via WGSL vertex shader with uniform matrices
- Texture mapping, alpha blending, fog via fragment shader
- Vertex/index buffers mapped to `GPUBuffer`
- D3D7 and D3D8 share the same emulation layer (nearly identical fixed-function model)

### Tier 4: D3D9 Programmable Shaders
- HLSL vertex/pixel shaders (SM 2.0–3.0) translated to WGSL
- Vertex declarations replace FVF for flexible vertex layout
- Multiple render targets, sRGB, and extended blend states

### Tier 5: D3D10 Modern Pipeline
- SM 4.0 shaders (vertex, geometry, pixel) translated to WGSL
- Constant buffers map directly to WebGPU uniform buffers
- Geometry shader emulation (limited — expand to vertex shader or compute pass)
- Fully explicit state objects match WebGPU's immutable pipeline model

### Tier 6: D3D11 Full Pipeline
- SM 5.0 shaders with tessellation (hull/domain) and compute shaders
- Tessellation emulated via compute pre-pass generating tessellated geometry
- Compute shaders map directly to WebGPU compute pipelines
- Device/context split maps to WebGPU's device + command encoder model
- Feature levels allow a single D3D11 API to target D3D9–11 hardware

### Tier 7: D3D12 Explicit Pipeline
- Low-level explicit API — maps very naturally to WebGPU's design
- Pipeline State Objects (PSOs) map 1:1 to `GPURenderPipeline`
- Command lists map to `GPUCommandEncoder` + `GPUCommandBuffer`
- Root signatures map to `GPUPipelineLayout` + `GPUBindGroupLayout`
- Descriptor heaps map to bind groups
- Explicit memory management and synchronization

### Tier 8: Vulkan
- The closest native API to WebGPU — nearly 1:1 conceptual mapping
- SPIR-V shaders translated to WGSL via naga (trivially convertible by design)
- `VkDescriptorSet` maps to `GPUBindGroup`; `VkPipelineLayout` maps to `GPUPipelineLayout`
- Command buffers, render passes, and pipelines map directly
- Vulkan's explicit memory and synchronization simplified by WebGPU's automation

---

## Tier 1: Framebuffer Presentation

This replaces `renderer.pushFrame()` and the pixel-conversion loops in
`ddraw.zig::pushSurfaceFrame()` and `d3d8.zig::device_Present()`.

**Implementation Checklist:**
- [ ] Add WebGPU canvas context setup in `host.js` (`requestAdapter`, `requestDevice`, `configure`)
- [ ] Create fullscreen quad WGSL shader module
- [ ] Create render pipeline with fullscreen quad vertex/fragment shaders
- [ ] Create `GPUSampler` with `nearest` filtering
- [ ] Implement `presentFrame()` JS function (texture creation, `writeTexture`, draw)
- [ ] Add `presentFrame` extern import in `platform/wasm.zig`
- [ ] Wire ddraw `Unlock`/`Flip` to call `presentFrame` (WASM path)
- [ ] Wire d3d8 `Present` to call `presentFrame` (WASM path)
- [ ] Handle BGRA→bgra8unorm zero-conversion path (32bpp)
- [ ] Handle RGB565 CPU fallback conversion (16bpp)
- [ ] Handle canvas resize on `SetDisplayMode` / resolution change
- [ ] Verify with a DirectDraw Lock/Unlock game

### JS-Side Setup

```javascript
// host.js — WebGPU initialization
const adapter = await navigator.gpu.requestAdapter();
const device = await adapter.requestDevice();
const canvas = document.getElementById('game-canvas');
const context = canvas.getContext('webgpu');

context.configure({
  device,
  format: navigator.gpu.getPreferredCanvasFormat(),  // typically 'bgra8unorm'
  alphaMode: 'opaque',
});

// Fullscreen quad pipeline — renders a texture across the entire canvas
const shaderModule = device.createShaderModule({
  code: FULLSCREEN_QUAD_WGSL,  // see below
});

const pipeline = device.createRenderPipeline({
  layout: 'auto',
  vertex:   { module: shaderModule, entryPoint: 'vs_main' },
  fragment: {
    module: shaderModule,
    entryPoint: 'fs_main',
    targets: [{ format: navigator.gpu.getPreferredCanvasFormat() }],
  },
});

const sampler = device.createSampler({
  magFilter: 'nearest',  // pixel-perfect scaling for retro games
  minFilter: 'nearest',
});
```

### WGSL Fullscreen Quad Shader

```wgsl
// Vertex shader: generates a fullscreen triangle (no vertex buffer needed)
@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f {
  // Oversized triangle covering clip space [-1,1]
  let x = f32(i32(idx & 1u)) * 4.0 - 1.0;
  let y = f32(i32(idx >> 1u)) * 4.0 - 1.0;
  return vec4f(x, y, 0.0, 1.0);
}

struct VsOutput {
  @builtin(position) pos: vec4f,
  @location(0)       uv:  vec2f,
};

@vertex
fn vs_main_uv(@builtin(vertex_index) idx: u32) -> VsOutput {
  var out: VsOutput;
  // Full-screen triangle trick: 3 vertices, no buffer
  let x = f32(i32(idx & 1u)) * 4.0 - 1.0;
  let y = f32(i32(idx >> 1u)) * 4.0 - 1.0;
  out.pos = vec4f(x, y, 0.0, 1.0);
  // Map clip coords to UV: [-1,1] → [0,1], flip Y for top-down framebuffer
  out.uv = vec2f((x + 1.0) * 0.5, (1.0 - y) * 0.5);
  return out;
}

@group(0) @binding(0) var frame_sampler: sampler;
@group(0) @binding(1) var frame_texture: texture_2d<f32>;

@fragment
fn fs_main(in: VsOutput) -> @location(0) vec4f {
  return textureSample(frame_texture, frame_sampler, in.uv);
}
```

### Frame Upload Path

When the guest calls `Unlock()` (DirectDraw) or `Present()` (D3D8), instead of
the current per-pixel CPU loop, we:

```javascript
// Called from WASM via JS import
function presentFrame(bufferPtr, width, height, format) {
  const byteLength = width * height * (format === 'rgb565' ? 2 : 4);
  const pixels = new Uint8Array(wasmMemory.buffer, bufferPtr, byteLength);

  // Create or resize texture if dimensions changed
  if (!frameTexture || frameTexture.width !== width || frameTexture.height !== height) {
    frameTexture?.destroy();
    frameTexture = device.createTexture({
      size: [width, height],
      format: 'bgra8unorm',  // matches DirectDraw's native BGRA format!
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    // Recreate bind group with new texture
    bindGroup = device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: sampler },
        { binding: 1, resource: frameTexture.createView() },
      ],
    });
  }

  // Upload pixels — this is the critical path
  if (format === 'bgra8888') {
    // DirectDraw 32bpp and D3D8 both use BGRA — maps directly to bgra8unorm!
    // NO pixel conversion needed. This is a huge win over the current approach.
    device.queue.writeTexture(
      { texture: frameTexture },
      pixels,
      { bytesPerRow: width * 4 },
      [width, height]
    );
  } else if (format === 'rgb565') {
    // 16bpp needs conversion — use a compute shader (see Tier 2)
    // Fallback: convert on CPU for Tier 1
    convertRGB565ToBGRA(pixels, width, height);
  }

  // Render the fullscreen quad
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginRenderPass({
    colorAttachments: [{
      view: context.getCurrentTexture().createView(),
      loadOp: 'clear',
      storeOp: 'store',
    }],
  });
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.draw(3);  // fullscreen triangle
  pass.end();
  device.queue.submit([encoder.finish()]);
}
```

### Key Optimization: BGRA Format Match

DirectDraw's native pixel format is BGRA (32bpp) or BGR (24bpp), and the most
common WebGPU canvas format is `bgra8unorm`. This means:

- **32bpp DirectDraw surfaces can be uploaded with zero pixel conversion**
- The current code in `pushSurfaceFrame()` that swaps R↔B channels is eliminated
- `device.queue.writeTexture()` handles the DMA efficiently

### Zig-Side Changes (stub integration)

The WASM platform backend needs a new JS import for frame presentation:

```zig
// platform/wasm.zig — new extern for WebGPU frame presentation
extern "webgpu" fn presentFrame(
    buffer_ptr: [*]const u8,
    width: u32,
    height: u32,
    format: u32,     // 0 = BGRA8888, 1 = RGB565
) void;
```

The ddraw and d3d8 stubs change from:
```zig
// Before: CPU pixel conversion + pushFrame
fn pushSurfaceFrame() void {
    // ... per-pixel BGR→RGB loop ...
    renderer.pushFrame();
}
```
to:
```zig
// After: direct GPU upload
fn pushSurfaceFrame() void {
    const format: u32 = if (display_mode_bpp == 16) 1 else 0;
    presentFrame(surface_buffer.ptr, display_mode_w, display_mode_h, format);
}
```

---

## Tier 2: GPU-Accelerated Blitting

This replaces the DirectDraw `Blt`, `BltFast`, and `Flip` operations with GPU
texture operations, and adds GPU-side format conversion for 16bpp modes.

**Implementation Checklist:**
- [ ] Create `DDSurface` class wrapping `GPUTexture` + staging buffer
- [ ] Implement `createSurface` / `destroySurface` JS imports
- [ ] Implement `lockSurface` / `unlockSurface` (staging buffer map → `writeTexture`)
- [ ] Implement `blitSurface` via `copyTextureToTexture` (simple copy)
- [ ] Implement `flipSurfaces` (swap front/back texture references)
- [ ] Write RGB565 → BGRA8888 compute shader
- [ ] Implement compute dispatch for 16bpp surface uploads
- [ ] Write color-keyed blit fragment shader (`DDBLT_KEYSRC` → discard)
- [ ] Write palettized (8bpp) fragment shader with 256-entry palette lookup
- [ ] Implement `SetColorKey` → update color key uniform
- [ ] Implement `SetPalette` → update palette storage buffer
- [ ] Handle `GetDC`/`ReleaseDC` (lock to CPU, apply GDI, upload on release)
- [ ] Verify with a multi-surface DirectDraw game (e.g., Age of Empires)

### Surface Model

Each DirectDraw surface becomes a `GPUTexture`:

```javascript
class DDSurface {
  constructor(device, width, height, bpp) {
    this.width = width;
    this.height = height;
    this.bpp = bpp;

    // The "lock buffer" — CPU-writable staging buffer
    this.stagingBuffer = device.createBuffer({
      size: width * height * (bpp === 16 ? 2 : 4),
      usage: GPUBufferUsage.MAP_WRITE | GPUBufferUsage.COPY_SRC,
    });

    // The GPU texture (used for blitting and presentation)
    this.texture = device.createTexture({
      size: [width, height],
      format: 'bgra8unorm',
      usage: GPUTextureUsage.TEXTURE_BINDING
           | GPUTextureUsage.COPY_DST
           | GPUTextureUsage.COPY_SRC
           | GPUTextureUsage.RENDER_ATTACHMENT,
    });
  }
}
```

### DirectDraw API → WebGPU Mapping

| DirectDraw Call | WebGPU Equivalent |
|---|---|
| `CreateSurface(w, h)` | `device.createTexture({size: [w,h], ...})` |
| `Lock()` → app writes pixels → `Unlock()` | `writeTexture()` from WASM linear memory |
| `Blt(dst, src, rect, flags)` | `copyTextureToTexture()` or render pass with shader |
| `BltFast(x, y, src, rect)` | `copyTextureToTexture()` (no stretching, simple copy) |
| `Flip()` | Swap front/back texture references, present back |
| `SetColorKey(key)` | Fragment shader `if (color == key) { discard; }` |
| `SetDisplayMode(w, h, bpp)` | Resize canvas + recreate textures |
| `GetDC()` / `ReleaseDC()` | Lock to CPU buffer, apply GDI ops, upload on release |
| `SetClipper(hwnd)` | Set scissor rect on render pass |

### Why DirectDraw Is Awkward on WebGPU

DirectDraw is a 2D blitting API being mapped onto a 3D GPU pipeline. The
fundamental mismatch creates several pain points:

| Challenge | Problem | Mitigation |
|---|---|---|
| **CPU-side pixel access** | Games call `Lock()` to get a CPU pointer and write pixels directly. WebGPU textures can't be memory-mapped for random access. | Use staging buffers: `Lock()` returns WASM memory, `Unlock()` triggers `writeTexture()` upload. |
| **Frequent Lock/Unlock** | Some games lock/unlock every frame (software rendering). Each cycle requires a CPU→GPU upload. | Batch uploads, use `writeTexture()` which is faster than `mapAsync()`. |
| **Pixel format zoo** | DirectDraw supports 8bpp palettized, RGB555, RGB565, XRGB888, ARGB8888. WebGPU has a fixed set of texture formats. | Compute shaders for format conversion; palette lookup shader for 8bpp. |
| **Arbitrary Blt operations** | `Blt()` can do stretch, mirror, rotate, color key, and color fill in one call. WebGPU has no "blit" primitive. | Decompose into `copyTextureToTexture` (simple), render pass + fragment shader (color key/stretch). |
| **GDI interop** | `GetDC()` returns an HDC for GDI drawing on a surface. GDI can't draw into GPU textures. | Lock surface to CPU, let GDI draw, re-upload on `ReleaseDC()`. Slow but correct. |
| **Primary surface = screen** | DirectDraw's primary surface represents the display. There's no explicit "present" call in many code paths. | Detect writes to primary surface and trigger presentation. |

### RGB565 → BGRA8888 Compute Shader

For 16bpp DirectDraw modes, a compute shader converts in-place on the GPU:

```wgsl
@group(0) @binding(0) var<storage, read>       src: array<u32>;  // packed RGB565 pairs
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;  // BGRA8888 output

@compute @workgroup_size(256)
fn convert_rgb565(@builtin(global_invocation_id) gid: vec3u) {
  let idx = gid.x;
  // Each u32 in src contains two RGB565 pixels (little-endian)
  let packed = src[idx];
  let lo = packed & 0xFFFFu;
  let hi = (packed >> 16u) & 0xFFFFu;

  // RGB565 → BGRA8888
  let r0 = ((lo >> 11u) & 0x1Fu) << 3u;
  let g0 = ((lo >>  5u) & 0x3Fu) << 2u;
  let b0 = ( lo         & 0x1Fu) << 3u;
  dst[idx * 2u]     = b0 | (g0 << 8u) | (r0 << 16u) | 0xFF000000u;

  let r1 = ((hi >> 11u) & 0x1Fu) << 3u;
  let g1 = ((hi >>  5u) & 0x3Fu) << 2u;
  let b1 = ( hi         & 0x1Fu) << 3u;
  dst[idx * 2u + 1u] = b1 | (g1 << 8u) | (r1 << 16u) | 0xFF000000u;
}
```

### Color-Keyed Blit Shader

DirectDraw's `DDBLT_KEYSRC` flag enables source color key transparency. In
WebGPU, this becomes a render pass with a fragment shader that discards:

```wgsl
@group(0) @binding(0) var src_sampler: sampler;
@group(0) @binding(1) var src_texture: texture_2d<f32>;
@group(0) @binding(2) var<uniform> color_key: vec4f;  // normalized BGRA

@fragment
fn fs_colorkey(in: VsOutput) -> @location(0) vec4f {
  let color = textureSample(src_texture, src_sampler, in.uv);
  // Compare with tolerance for rounding in format conversion
  if (distance(color.rgb, color_key.rgb) < 0.02) {
    discard;
  }
  return color;
}
```

### Palette Support (8bpp modes)

Some older DirectDraw games use 8bpp palettized modes. This maps to:

```wgsl
@group(0) @binding(0) var<storage, read> palette: array<u32, 256>;  // BGRA entries
@group(0) @binding(1) var idx_texture: texture_2d<u32>;             // 8-bit indices

@fragment
fn fs_palettized(in: VsOutput) -> @location(0) vec4f {
  let idx = textureLoad(idx_texture, vec2i(in.uv * vec2f(textureDimensions(idx_texture))), 0).r;
  let bgra = palette[idx];
  return vec4f(
    f32((bgra >> 16u) & 0xFFu) / 255.0,  // R
    f32((bgra >>  8u) & 0xFFu) / 255.0,  // G
    f32( bgra         & 0xFFu) / 255.0,  // B
    1.0
  );
}
```

---

## Tier 3: Fixed-Function Pipeline Emulation (D3D7, then D3D8)

D3D7 introduced the fixed-function 3D pipeline: transforms
(world/view/projection), per-vertex lighting, texture mapping, fog, and alpha
blending. D3D8 kept the same pipeline and added optional shader programs
(VS/PS 1.0–1.4). For our purposes, both map to the same WebGPU emulation layer.

**Implementation Checklist (D3D7):**
- [ ] Create `SceneUniforms` uniform buffer (transforms, lights, materials, fog)
- [ ] Write `vs_fixed` WGSL vertex shader (transform + lighting)
- [ ] Write `fs_fixed` WGSL fragment shader (texture sampling + fog)
- [ ] Create `d3d7.zig` stub module with `IDirect3D7` / `IDirect3DDevice7` COM interfaces
- [ ] Implement `SetTransform` → write matrix to uniform buffer
- [ ] Implement `SetLight` / `LightEnable` → update light array in uniform buffer
- [ ] Implement `SetMaterial` → write material data to uniform buffer
- [ ] Implement `SetRenderState` → update pipeline state flags
- [ ] Implement `SetTexture` / `SetTextureStageState` → update bind group
- [ ] Implement `DrawPrimitive` (inline vertex data upload → `pass.draw()`)
- [ ] Implement `DrawPrimitiveVB` (vertex buffer path → `pass.draw()`)
- [ ] Implement `DrawIndexedPrimitive` / `DrawIndexedPrimitiveVB`
- [ ] Implement FVF parsing → `GPUVertexBufferLayout` creation
- [ ] Implement pipeline state cache (keyed on blend/cull/depth state)
- [ ] Implement `BeginScene` / `EndScene` → render pass lifecycle
- [ ] Implement `Clear` → render pass clear values
- [ ] Implement `SetViewport` → `pass.setViewport()`
- [ ] Verify with a D3D7 game (e.g., Gothic, Deus Ex)

**Implementation Checklist (D3D8 additions):**
- [ ] Create `d3d8.zig` stub sharing the same WebGPU backend as D3D7
- [ ] Implement `IDirect3D8::CreateDevice` (separate from DirectDraw)
- [ ] Implement `CreateVertexBuffer` / `CreateIndexBuffer` → `GPUBuffer`
- [ ] Implement `SetStreamSource` / `SetIndices`
- [ ] Implement `SetVertexShader(fvf)` → FVF parsing (fixed-function path)
- [ ] Implement `DrawPrimitiveUP` / `DrawIndexedPrimitiveUP` (inline data)
- [ ] Implement `Present` → `device.queue.submit()`
- [ ] Stub VS/PS 1.0–1.4 creation (log + fall back to fixed-function)
- [ ] Verify with a D3D8 game (e.g., Morrowind, GTA Vice City)

### Why D3D7/8 Fixed-Function Is Hard on WebGPU

WebGPU has **no fixed-function pipeline**. Every stage that D3D7/8 handles
automatically (transform, lighting, fog, texture combiners) must be emulated
in WGSL shaders. This creates several challenges:

| Challenge | Problem | Mitigation |
|---|---|---|
| **No T&L hardware** | WebGPU has no built-in transform and lighting. D3D7/8 games expect the driver to handle `SetTransform`, `SetLight`, `SetMaterial`. | Emulate entirely in vertex shader with a `SceneUniforms` uniform buffer. |
| **Texture stage combiners** | D3D7/8 have up to 8 texture stages with configurable ops (MODULATE, ADD, BLEND, etc.). Each combo is a different shader. | Generate shader variants per texture stage config, or use a über-shader with branches. |
| **Mutable pipeline state** | D3D7/8 let you change blend/cull/depth state per-draw with `SetRenderState()`. WebGPU pipelines are immutable. | Pipeline state cache keyed on state bits — may create hundreds of pipelines. |
| **FVF complexity** | Flexible Vertex Format allows arbitrary vertex layouts described by flag bits. Each combo needs a different `GPUVertexBufferLayout`. | Parse FVF flags → build layout descriptor at `SetVertexShader(fvf)` time. |
| **Inline vertex data** | D3D7's `DrawPrimitive` passes vertex data inline (no buffer). WebGPU requires GPU buffers. | Upload inline data to a transient vertex buffer per draw call. |
| **D3D7+DirectDraw coupling** | D3D7 devices are obtained from DirectDraw surfaces. Surface management, display mode, and rendering are intertwined. | Maintain a unified surface → texture mapping shared between DDraw and D3D7 stubs. |
| **State blocks** | D3D7 has `ApplyStateBlock()` that batch-applies captured render state. Need to replay these efficiently. | Store state block as a delta to apply to current state. |

### 3a. D3D7 — The Base Fixed-Function API

D3D7 is tightly integrated with DirectDraw — a game creates an IDirectDraw7
object, then obtains an IDirect3DDevice7 from it. All rendering uses the
fixed-function pipeline; there are no programmable shaders.

#### Architecture (D3D7)

```
D3D7 App
  ├── IDirectDraw7::CreateDevice(IID_IDirect3DHALDevice, surface, &dev7)
  │    → requestAdapter() + requestDevice() + configure context
  ├── SetTransform(D3DTRANSFORMSTATE_WORLD, &matrix)  →  Update uniform buffer
  ├── SetTransform(D3DTRANSFORMSTATE_VIEW, &matrix)    →  Update uniform buffer
  ├── SetTransform(D3DTRANSFORMSTATE_PROJECTION, &mat) →  Update uniform buffer
  ├── SetLight(0, &light)                    →  Update uniform buffer
  ├── SetMaterial(&material)                 →  Update uniform buffer
  ├── SetRenderState(D3DRENDERSTATE_*, val)  →  Rebuild pipeline or update uniforms
  ├── SetTexture(0, tex)                     →  Update bind group
  ├── SetTextureStageState(stage, state, val) → Select shader variant
  ├── BeginScene()                           →  Begin render pass
  ├── DrawPrimitive(type, fvf, verts, count, flags)  →  Encode draw call
  ├── EndScene()                             →  End render pass
  └── Flip() / Present via DirectDraw        →  Submit command buffer
```

#### D3D7 API → WebGPU Mapping

| D3D7 Call | WebGPU Action |
|---|---|
| `IDirectDraw7::CreateDevice(IID_IDirect3DHALDevice, surf, &dev7)` | `requestAdapter()` + `requestDevice()` + configure context |
| `SetTransform(state, &mat)` | Write 64 bytes to uniform buffer at offset |
| `SetLight(idx, &light)` | Write light data to uniform buffer |
| `LightEnable(idx, true)` | Update `light_count` in uniform buffer |
| `SetMaterial(&mat)` | Write material data to uniform buffer |
| `SetRenderState(D3DRENDERSTATE_*, val)` | Update pipeline state or uniform; rebuild pipeline if blend/cull changes |
| `SetTexture(stage, tex)` | Recreate bind group with new texture view |
| `SetTextureStageState(stage, state, val)` | Select different fragment shader variant |
| `DrawPrimitive(type, fvf, verts, count, flags)` | Upload inline vertex data → `pass.draw()` (UP-style) |
| `DrawPrimitiveStrided(type, fvf, strided, count, flags)` | Assemble vertex buffer from strided components → `pass.draw()` |
| `DrawPrimitiveVB(type, vb, start, count, flags)` | `pass.draw()` from vertex buffer |
| `DrawIndexedPrimitive(type, fvf, verts, vcount, indices, icount, flags)` | `pass.drawIndexed()` |
| `DrawIndexedPrimitiveVB(type, vb, startV, numV, indices, icount, flags)` | `pass.drawIndexed()` from vertex buffer |
| `BeginScene()` | `encoder.beginRenderPass(...)` |
| `EndScene()` | `pass.end()` |
| `Clear(count, rects, flags, color, z, stencil)` | Set `loadOp: 'clear'` + `clearValue` in render pass |
| `SetViewport(&vp)` | `pass.setViewport(x, y, w, h, minZ, maxZ)` |
| `MultiplyTransform(state, &mat)` | CPU multiply + write to uniform buffer |
| `Load(dstTex, dstPoint, srcTex, srcRect, flags)` | `copyTextureToTexture()` |
| `ApplyStateBlock(handle)` | Batch-apply cached render states |

#### Shared WGSL Shaders (used by D3D7 and D3D8)

These shaders emulate the fixed-function transform & lighting pipeline. They
are used by both D3D7 (always) and D3D8 (when no programmable shaders are set).

##### Uniform Buffer Layout

```wgsl
struct SceneUniforms {
  world:      mat4x4f,
  view:       mat4x4f,
  projection: mat4x4f,
  wvp:        mat4x4f,   // precomputed: projection * view * world

  // Lighting (up to 8 lights, matching D3D7/8 MaxActiveLights)
  light_count: u32,
  _pad0: u32, _pad1: u32, _pad2: u32,
  lights: array<Light, 8>,

  // Material
  mat_diffuse:  vec4f,
  mat_ambient:  vec4f,
  mat_specular: vec4f,
  mat_emissive: vec4f,
  mat_power:    f32,

  // Fog
  fog_enable: u32,
  fog_color:  vec4f,
  fog_start:  f32,
  fog_end:    f32,

  // Global ambient
  ambient: vec4f,
};

struct Light {
  type_:     u32,   // 1=point, 2=spot, 3=directional
  _pad: u32, _p2: u32, _p3: u32,
  diffuse:   vec4f,
  specular:  vec4f,
  ambient:   vec4f,
  position:  vec3f, range: f32,
  direction: vec3f, falloff: f32,
  attenuation: vec3f, _apad: f32,
  theta: f32, phi: f32, _lpad2: f32, _lpad3: f32,
};
```

##### Vertex Shader (Fixed-Function Emulation)

```wgsl
@group(0) @binding(0) var<uniform> scene: SceneUniforms;

struct VertexInput {
  @location(0) position: vec3f,
  @location(1) normal:   vec3f,
  @location(2) color:    vec4f,
  @location(3) uv:       vec2f,
};

struct VertexOutput {
  @builtin(position) clip_pos: vec4f,
  @location(0) color:    vec4f,
  @location(1) uv:       vec2f,
  @location(2) fog_factor: f32,
};

@vertex
fn vs_fixed(in: VertexInput) -> VertexOutput {
  var out: VertexOutput;

  // Transform
  let world_pos = scene.world * vec4f(in.position, 1.0);
  let view_pos  = scene.view * world_pos;
  out.clip_pos  = scene.projection * view_pos;

  // Lighting
  let world_normal = normalize((scene.world * vec4f(in.normal, 0.0)).xyz);
  var lit_color = scene.mat_emissive + scene.ambient * scene.mat_ambient;

  for (var i = 0u; i < scene.light_count; i++) {
    let light = scene.lights[i];
    var n_dot_l: f32;
    if (light.type_ == 3u) {
      // Directional
      n_dot_l = max(dot(world_normal, -normalize(light.direction)), 0.0);
    } else {
      // Point/Spot
      let light_dir = normalize(light.position - world_pos.xyz);
      n_dot_l = max(dot(world_normal, light_dir), 0.0);
    }
    lit_color += light.diffuse * scene.mat_diffuse * n_dot_l;
    lit_color += light.ambient * scene.mat_ambient;
  }

  out.color = clamp(lit_color, vec4f(0.0), vec4f(1.0));

  // If vertex colors are provided, modulate
  if (in.color.a > 0.0) {
    out.color *= in.color;
  }

  out.uv = in.uv;

  // Fog (linear, based on view-space Z)
  if (scene.fog_enable != 0u) {
    let dist = length(view_pos.xyz);
    out.fog_factor = clamp(
      (scene.fog_end - dist) / (scene.fog_end - scene.fog_start),
      0.0, 1.0
    );
  } else {
    out.fog_factor = 1.0;
  }

  return out;
}
```

##### Fragment Shader (Fixed-Function Emulation)

```wgsl
@group(0) @binding(0) var<uniform> scene: SceneUniforms;
@group(1) @binding(0) var tex_sampler: sampler;
@group(1) @binding(1) var tex: texture_2d<f32>;

@fragment
fn fs_fixed(in: VertexOutput) -> @location(0) vec4f {
  var color = in.color;

  // Texture stage 0 modulate
  let tex_color = textureSample(tex, tex_sampler, in.uv);
  color *= tex_color;

  // Fog blend
  color = vec4f(
    mix(scene.fog_color.rgb, color.rgb, in.fog_factor),
    color.a
  );

  return color;
}
```

#### Blend Factor Mapping (shared by D3D7/8/9)

| D3DBLEND | WebGPU GPUBlendFactor |
|---|---|
| `D3DBLEND_ZERO` | `'zero'` |
| `D3DBLEND_ONE` | `'one'` |
| `D3DBLEND_SRCCOLOR` | `'src'` |
| `D3DBLEND_INVSRCCOLOR` | `'one-minus-src'` |
| `D3DBLEND_SRCALPHA` | `'src-alpha'` |
| `D3DBLEND_INVSRCALPHA` | `'one-minus-src-alpha'` |
| `D3DBLEND_DESTALPHA` | `'dst-alpha'` |
| `D3DBLEND_INVDESTALPHA` | `'one-minus-dst-alpha'` |
| `D3DBLEND_DESTCOLOR` | `'dst'` |
| `D3DBLEND_INVDESTCOLOR` | `'one-minus-dst'` |

#### Pipeline State Caching (shared by D3D7/8)

D3D7 and D3D8 allow changing render states call-by-call, but WebGPU pipelines
are immutable. We need a pipeline cache keyed on the mutable state bits:

```javascript
// Key: blend_enable | blend_src | blend_dst | cull_mode | depth_enable | depth_func
const pipelineCache = new Map();

function getPipeline(state) {
  const key = state.blendEnable
    | (state.blendSrc << 1)
    | (state.blendDst << 5)
    | (state.cullMode << 9)
    | (state.depthEnable << 11)
    | (state.depthFunc << 12);

  if (!pipelineCache.has(key)) {
    pipelineCache.set(key, device.createRenderPipeline({
      layout: pipelineLayout,
      vertex:   { module: shaderModule, entryPoint: 'vs_fixed', buffers: vertexLayouts },
      fragment: {
        module: shaderModule,
        entryPoint: 'fs_fixed',
        targets: [{
          format: canvasFormat,
          blend: state.blendEnable ? {
            color: { srcFactor: mapBlendFactor(state.blendSrc), dstFactor: mapBlendFactor(state.blendDst), operation: 'add' },
            alpha: { srcFactor: 'one', dstFactor: 'zero', operation: 'add' },
          } : undefined,
        }],
      },
      depthStencil: state.depthEnable ? {
        format: 'depth24plus',
        depthWriteEnabled: true,
        depthCompare: mapCompareFunc(state.depthFunc),
      } : undefined,
      primitive: { topology: 'triangle-list', cullMode: mapCullMode(state.cullMode) },
    }));
  }
  return pipelineCache.get(key);
}
```

### 3b. D3D8 — Additions Over D3D7

D3D8 separated Direct3D from DirectDraw into its own IDirect3D8 interface and
added optional programmable vertex/pixel shaders (SM 1.0–1.4). The fixed-function
pipeline remains identical — D3D8 games that don't use shaders are handled by
the same `vs_fixed`/`fs_fixed` WGSL shaders above.

**What D3D8 adds:**

| Feature | Change from D3D7 |
|---|---|
| Separate device creation | `IDirect3D8::CreateDevice()` instead of going through DirectDraw |
| Vertex shaders (VS 1.0–1.1) | Optional replacement for fixed-function T&L |
| Pixel shaders (PS 1.0–1.4) | Optional replacement for fixed-function texture stages |
| `CreateVertexBuffer` / `CreateIndexBuffer` | Explicit GPU buffer objects (D3D7 had these too via DirectDraw) |
| `SetVertexShader(fvf_or_handle)` | Dual-purpose: FVF code for fixed-function, handle for programmable |
| `Present()` | Replaces DirectDraw's `Flip()` — same WebGPU action |

#### D3D8 API → WebGPU Mapping (additions over D3D7)

D3D8 inherits all D3D7 mappings. These are the calls with changed or new semantics:

| D3D8 Call | WebGPU Action |
|---|---|
| `IDirect3D8::CreateDevice(adapter, type, hwnd, flags, &params, &dev)` | `requestAdapter()` + `requestDevice()` + configure context |
| `CreateTexture(w, h, levels, usage, fmt, pool)` | `device.createTexture(...)` |
| `CreateVertexBuffer(len, usage, fvf, pool)` | `device.createBuffer({usage: VERTEX})` |
| `CreateIndexBuffer(len, usage, fmt, pool)` | `device.createBuffer({usage: INDEX})` |
| `SetVertexShader(fvf)` | Parse FVF → create `GPUVertexBufferLayout`, use `vs_fixed` |
| `SetStreamSource(stream, vb, stride)` | Set vertex buffer + stride for draw calls |
| `SetIndices(ib, baseVertex)` | Set index buffer for indexed draw calls |
| `DrawPrimitive(type, start, count)` | `pass.draw(vertexCount)` |
| `DrawIndexedPrimitive(type, minIdx, numV, startIdx, primCount)` | `pass.drawIndexed(indexCount)` |
| `DrawPrimitiveUP(type, count, data, stride)` | Upload inline data → `pass.draw()` (same as D3D7 inline) |
| `DrawIndexedPrimitiveUP(...)` | Upload inline data → `pass.drawIndexed()` |
| `Present(src, dst, hwnd, dirty)` | `device.queue.submit(...)` |
| `SetRenderState(D3DRS_*, val)` | Same as D3D7 but with D3DRS_* constants (numerically different) |

---

## Tier 4: D3D9 Programmable Shader Emulation

Direct3D 9 extends D3D8 significantly by adding HLSL (High-Level Shader Language)
with Shader Model 2.0–3.0, vertex declarations, multiple render targets, and
numerous texture/blend state additions. Many late-era Win32 games (2004–2009 and
beyond) use D3D9.

**Implementation Checklist:**
- [ ] Create `d3d9.zig` stub module with `IDirect3D9` / `IDirect3DDevice9` COM interfaces
- [ ] Build SM2/SM3 bytecode → WGSL translator (register-based ISA, ~100 opcodes)
- [ ] Implement `CreateVertexShader` / `CreatePixelShader` → translate + `createShaderModule()`
- [ ] Implement `SetVertexShader` / `SetPixelShader` → select shader modules for pipeline
- [ ] Implement `SetVertexShaderConstantF` / `SetPixelShaderConstantF` → uniform buffer writes
- [ ] Implement `SetVertexShaderConstantI` / `SetVertexShaderConstantB` (integer/bool constants)
- [ ] Implement `CreateVertexDeclaration` → build `GPUVertexBufferLayout`
- [ ] Implement `D3DVERTEXELEMENT9` → WebGPU format mapping
- [ ] Implement `SetSamplerState` → create/select `GPUSampler`
- [ ] Implement `CreateRenderTarget` → `createTexture({usage: RENDER_ATTACHMENT})`
- [ ] Implement `SetRenderTarget` → change render pass color attachments
- [ ] Implement `StretchRect` → render pass with textured quad
- [ ] Implement `SetScissorRect` → `pass.setScissorRect()`
- [ ] Support fixed-function fallback (`SetVertexShader(NULL)` → use `vs_fixed`)
- [ ] Implement `GetRenderTargetData` → `copyTextureToBuffer()` for readback
- [ ] Support DXT1/3/5 compressed texture creation (request `texture-compression-bc`)
- [ ] Implement `CreateQuery(D3DQUERYTYPE_OCCLUSION)` → occlusion queries
- [ ] Verify with a D3D9 fixed-function game
- [ ] Verify with a D3D9 shader-based game (e.g., Half-Life 2)

### What's New in D3D9 vs D3D8

| Feature | D3D8 | D3D9 |
|---|---|---|
| Shader language | Assembly (vs_1_0, ps_1_0) | HLSL + assembly (vs_2_0/3_0, ps_2_0/3_0) |
| Vertex format | FVF only | FVF + `D3DVERTEXELEMENT9` declarations |
| Shader constants | Limited (96 VS, 8 PS) | Expanded (256 VS, 224 PS for SM3) |
| Flow control | None in shaders | Loops, branches in SM2/SM3 |
| MRT | No | Up to 4 simultaneous render targets |
| sRGB | No | Read/write sRGB textures |
| Instancing | No | Hardware instancing (SM3) |
| Texture formats | ~20 common | ~40 + compressed (DXT1-5), floating-point formats |
| Shared resources | No | Cross-process texture/buffer sharing |

### Why D3D9 Is the Hardest Translation

D3D9 is arguably the most difficult API to translate to WebGPU. It combines
an implicit, mutable state machine with programmable shaders, creating a
"worst of both worlds" situation:

| Challenge | Problem | Mitigation |
|---|---|---|
| **Implicit state machine** | D3D9 has hundreds of render states that can be changed individually between draw calls. WebGPU needs all state up front in immutable pipelines. | Massive pipeline cache. Hot path: hash current state → lookup/create pipeline. |
| **Shader bytecode (SM2/3)** | D3D9 uses a proprietary register-based bytecode. No existing WASM-targeting translator exists. | Build a custom bytecode → WGSL translator (~100 opcodes, feasible but significant work). |
| **Mixed fixed-function + shader** | D3D9 games can use fixed-function for some passes and shaders for others, even in the same frame. `SetVertexShader(NULL)` reverts to fixed-function. | Support both paths: fixed-function `vs_fixed`/`fs_fixed` from Tier 3, plus translated shaders. |
| **Immediate mode drawing** | `DrawPrimitiveUP` passes raw vertex arrays on the stack. No pre-created GPU buffers. | Upload to a ring buffer of transient vertex buffers each frame. |
| **Texture stage state (FFP)** | When using fixed-function, D3D9 still has texture stage states (COLOROP, ALPHAOP, etc.) controlling pixel blending. | Same über-shader approach as Tier 3, expanded for D3D9's additional ops. |
| **SetRenderState sprawl** | Over 200 render state values control everything from alpha test to stencil ops to fog density. Each change may require a pipeline rebuild. | Classify states into pipeline-affecting (need rebuild) vs uniform-only (cheap update). |
| **Swizzled/compressed textures** | D3D9 games create textures in many formats including DXT1-5, V8U8 (signed normal), L8 (luminance), A8P8 (palettized+alpha). | Map common formats directly; decompress/convert rare formats on CPU. |
| **Query objects** | Occlusion queries (`D3DQUERYTYPE_OCCLUSION`) used for lens flare, etc. | WebGPU supports occlusion queries natively — one of the easier parts. |

### Architecture

```
D3D9 App
  ├── CreateVertexDeclaration(elements[])  →  Create GPUVertexBufferLayout
  ├── CreateVertexShader(bytecode)          →  Translate SM2/3 bytecode → WGSL
  ├── CreatePixelShader(bytecode)           →  Translate SM2/3 bytecode → WGSL
  ├── SetVertexShader(vs) / SetPixelShader(ps)
  │    → Select or compile GPURenderPipeline with translated WGSL
  ├── SetVertexShaderConstantF(reg, data, count)
  │    → Write to uniform buffer (float4 registers)
  ├── SetTexture(stage, tex)                →  Update bind group
  ├── SetSamplerState(stage, type, value)   →  Create/select GPUSampler
  ├── BeginScene / EndScene / Present       →  Same as D3D8
  └── DrawPrimitive / DrawIndexedPrimitive  →  Same as D3D8
```

### Shader Translation: D3D9 Bytecode → WGSL

D3D9 shaders can be provided as either:
1. **Pre-compiled bytecode** (output of `D3DXCompileShader` or `fxc.exe`)
2. **HLSL source** (compiled at runtime via `D3DXCompileShader`)

For our emulator, the guest app passes bytecode to `CreateVertexShader()` /
`CreatePixelShader()`. We need to translate this bytecode to WGSL.

**SM2/SM3 bytecode** is a simple register-based ISA with ~100 opcodes:

```
; Example: ps_2_0 bytecode (disassembled)
ps_2_0
dcl t0.xy            ; declare texcoord input
dcl_2d s0            ; declare sampler
texld r0, t0, s0     ; sample texture
mul r0, r0, c0       ; modulate by constant
mov oC0, r0          ; output color
```

This translates mechanically to WGSL:

```wgsl
// Translated from ps_2_0 bytecode
@group(0) @binding(0) var<uniform> ps_constants: array<vec4f, 224>;
@group(1) @binding(0) var s0: sampler;
@group(1) @binding(1) var t_s0: texture_2d<f32>;

struct PsInput {
  @location(0) t0: vec2f,
};

@fragment
fn fs_translated(in: PsInput) -> @location(0) vec4f {
  var r0: vec4f;
  r0 = textureSample(t_s0, s0, in.t0);         // texld r0, t0, s0
  r0 = r0 * ps_constants[0];                    // mul r0, r0, c0
  return r0;                                     // mov oC0, r0
}
```

### Key SM2/SM3 Instructions → WGSL

| D3D9 SM Instruction | WGSL Equivalent |
|---|---|
| `add dst, src0, src1` | `dst = src0 + src1` |
| `mul dst, src0, src1` | `dst = src0 * src1` |
| `mad dst, src0, src1, src2` | `dst = src0 * src1 + src2` (fma) |
| `dp3 dst, src0, src1` | `dst = vec4f(dot(src0.xyz, src1.xyz))` |
| `dp4 dst, src0, src1` | `dst = vec4f(dot(src0, src1))` |
| `rsq dst, src` | `dst = inverseSqrt(src)` |
| `rcp dst, src` | `dst = 1.0 / src` |
| `nrm dst, src` | `dst = normalize(src)` |
| `pow dst, src0, src1` | `dst = pow(src0, src1)` |
| `texld dst, uv, sampler` | `dst = textureSample(tex, samp, uv)` |
| `texldl dst, uv, sampler` | `dst = textureSampleLevel(tex, samp, uv.xy, uv.w)` |
| `if_gt src0, src1 ... endif` | `if (src0 > src1) { ... }` |
| `rep count ... endrep` | `for (var i = 0u; i < count; i++) { ... }` |
| `m4x4 dst, src, mat` | `dst = mat * src` (4 dp4 instructions) |

### D3D9 Vertex Declarations → GPUVertexBufferLayout

D3D9 introduced `D3DVERTEXELEMENT9` arrays for flexible vertex format description:

```c
// D3D9 vertex declaration example
D3DVERTEXELEMENT9 decl[] = {
  { 0,  0, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0 },
  { 0, 12, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_NORMAL,   0 },
  { 0, 24, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0 },
  D3DDECL_END()
};
```

This maps to WebGPU:

```javascript
const vertexBufferLayout = {
  arrayStride: 32,  // 12 + 12 + 8
  attributes: [
    { format: 'float32x3', offset:  0, shaderLocation: 0 },  // POSITION
    { format: 'float32x3', offset: 12, shaderLocation: 1 },  // NORMAL
    { format: 'float32x2', offset: 24, shaderLocation: 2 },  // TEXCOORD0
  ],
};
```

### D3D9 Type Mapping

| D3DDECLTYPE | WebGPU Format |
|---|---|
| `D3DDECLTYPE_FLOAT1` | `'float32'` |
| `D3DDECLTYPE_FLOAT2` | `'float32x2'` |
| `D3DDECLTYPE_FLOAT3` | `'float32x3'` |
| `D3DDECLTYPE_FLOAT4` | `'float32x4'` |
| `D3DDECLTYPE_D3DCOLOR` | `'unorm8x4'` (BGRA → swizzle in shader) |
| `D3DDECLTYPE_UBYTE4` | `'uint8x4'` |
| `D3DDECLTYPE_SHORT2` | `'sint16x2'` |
| `D3DDECLTYPE_SHORT4` | `'sint16x4'` |
| `D3DDECLTYPE_UBYTE4N` | `'unorm8x4'` |
| `D3DDECLTYPE_SHORT2N` | `'snorm16x2'` |
| `D3DDECLTYPE_SHORT4N` | `'snorm16x4'` |
| `D3DDECLTYPE_FLOAT16_2` | `'float16x2'` |
| `D3DDECLTYPE_FLOAT16_4` | `'float16x4'` |

### D3D9 API → WebGPU Mapping (additions over D3D8)

| D3D9 Call | WebGPU Action |
|---|---|
| `CreateVertexDeclaration(elements)` | Build `GPUVertexBufferLayout` from element array |
| `CreateVertexShader(bytecode, len)` | Translate bytecode → WGSL, `createShaderModule()` |
| `CreatePixelShader(bytecode, len)` | Translate bytecode → WGSL, `createShaderModule()` |
| `SetVertexShader(vs)` | Select vertex shader module for next pipeline |
| `SetPixelShader(ps)` | Select fragment shader module for next pipeline |
| `SetVertexShaderConstantF(reg, data, n)` | Write `n` vec4f values at register offset in uniform buffer |
| `SetPixelShaderConstantF(reg, data, n)` | Write `n` vec4f values in pixel shader uniform buffer |
| `SetVertexShaderConstantI(reg, data, n)` | Write integer constants (used for loop counters) |
| `SetVertexShaderConstantB(reg, data, n)` | Write boolean constants (flow control) |
| `SetSamplerState(stage, type, value)` | Create new `GPUSampler` with updated state |
| `SetVertexDeclaration(decl)` | Set active `GPUVertexBufferLayout` |
| `CreateRenderTarget(w, h, fmt, ...)` | `createTexture({usage: RENDER_ATTACHMENT})` |
| `SetRenderTarget(idx, surface)` | Change render pass color attachment |
| `GetRenderTargetData(rt, offscreen)` | `copyTextureToBuffer()` for render target readback |
| `StretchRect(src, srcR, dst, dstR, filter)` | Render pass with textured quad + sampler |
| `SetScissorRect(rect)` | `pass.setScissorRect(x, y, w, h)` |
| `CreateQuery(D3DQUERYTYPE_OCCLUSION, ...)` | `pass.beginOcclusionQuery()` / `endOcclusionQuery()` |

### Sampler State Mapping

| D3DSAMPLERSTATETYPE | WebGPU GPUSamplerDescriptor Field |
|---|---|
| `D3DSAMP_MAGFILTER` | `magFilter: 'nearest' / 'linear'` |
| `D3DSAMP_MINFILTER` | `minFilter: 'nearest' / 'linear'` |
| `D3DSAMP_MIPFILTER` | `mipmapFilter: 'nearest' / 'linear'` |
| `D3DSAMP_ADDRESSU` | `addressModeU: 'repeat' / 'mirror-repeat' / 'clamp-to-edge'` |
| `D3DSAMP_ADDRESSV` | `addressModeV: ...` |
| `D3DSAMP_ADDRESSW` | `addressModeW: ...` |
| `D3DSAMP_MAXANISOTROPY` | `maxAnisotropy: value` |
| `D3DSAMP_MIPMAPLODBIAS` | `lodMinClamp` / `lodMaxClamp` (approximate) |
| `D3DSAMP_BORDERCOLOR` | Not directly supported in WebGPU; use `'clamp-to-edge'` |

### Fixed-Function Fallback for D3D9

Many D3D9 games still use the fixed-function pipeline (no custom shaders). When
`SetVertexShader(NULL)` is called, D3D9 falls back to fixed-function T&L — we
use the same WGSL shaders from Tier 3 (`vs_fixed` / `fs_fixed`).

---

## Tier 5: D3D10 Modern Pipeline Emulation

Direct3D 10 represents a major architectural shift. It removes the fixed-function
pipeline entirely, requires Shader Model 4.0 for all rendering, introduces
geometry shaders, and uses an explicit state-object model that actually maps well
to WebGPU's design.

**Implementation Checklist:**
- [ ] Create `d3d10.zig` stub module with `ID3D10Device` COM interface
- [ ] Build SM4 bytecode (DXBC) → WGSL translator
- [ ] Implement `CreateVertexShader` / `CreatePixelShader` → translate + `createShaderModule()`
- [ ] Implement `CreateInputLayout` → build `GPUVertexBufferLayout` from element desc + bytecode
- [ ] Implement `CreateBuffer` (vertex, index, constant) → `createBuffer()` with appropriate usage
- [ ] Implement `CreateBlendState` → store `GPUBlendState` descriptor
- [ ] Implement `CreateRasterizerState` → store cull/fill mode
- [ ] Implement `CreateDepthStencilState` → store `GPUDepthStencilState` descriptor
- [ ] Implement immutable pipeline creation from combined state objects
- [ ] Implement `VSSetConstantBuffers` / `PSSetConstantBuffers` → bind uniform buffers
- [ ] Implement `PSSetShaderResources` / `PSSetSamplers` → bind texture views + samplers
- [ ] Implement `IASetInputLayout` / `IASetPrimitiveTopology`
- [ ] Implement `Map` / `Unmap` → staging buffer or `mapAsync()`
- [ ] Implement `UpdateSubresource` → `queue.writeBuffer()` / `queue.writeTexture()`
- [ ] Implement `CreateTexture2D` → `createTexture()` with DXGI format mapping
- [ ] Implement `CreateShaderResourceView` / `CreateRenderTargetView` → texture views
- [ ] Implement `Draw` / `DrawIndexed` / `DrawInstanced` / `DrawIndexedInstanced`
- [ ] Implement `OMSetRenderTargets` → set render pass attachments
- [ ] Implement `ClearRenderTargetView` / `ClearDepthStencilView`
- [ ] Implement geometry shader emulation for point sprite expansion (compute pre-pass)
- [ ] Implement stream output emulation (compute shader → storage buffer)
- [ ] Implement `D3D10CreateDevice1` for D3D10.1 (report `FEATURE_LEVEL_10_1`)
- [ ] Extend SM4 translator with SM4.1 opcodes (`SampleGrad`, `Gather`, cubemap arrays)
- [ ] Support independent blend per render target (D3D10.1)
- [ ] Verify with a D3D10 game (e.g., Assassin's Creed)

### What's New in D3D10 vs D3D9

| Feature | D3D9 | D3D10 |
|---|---|---|
| Fixed-function pipeline | Available as fallback | **Removed entirely** |
| Shader model | SM 2.0–3.0 | **SM 4.0 required** |
| Shader language | HLSL (compiled to SM bytecode) | HLSL (compiled to SM4 bytecode) |
| Geometry shader | Not available | **New pipeline stage** |
| Input layout | Vertex declarations / FVF | `ID3D10InputLayout` |
| Constant management | `SetXxxShaderConstantF()` registers | **Constant buffers** (structured) |
| Resource binding | Slots per stage | Resource views (SRV, RTV, DSV, UAV) |
| State objects | Per-call render states | **Immutable state objects** |
| Resource access | `Lock()` / `Unlock()` | **`Map()` / `Unmap()`** |
| Validation | Runtime, often at draw time | **Creation-time validation** |
| Texture arrays | No | Texture2DArray, volume textures |
| Stream output | No | Geometry shader → buffer output |

### Why D3D10 Maps Well to WebGPU

D3D10's design philosophy is remarkably similar to WebGPU's:

1. **Immutable state objects**: D3D10's `ID3D10BlendState`, `ID3D10RasterizerState`,
   `ID3D10DepthStencilState` map directly to WebGPU's pipeline descriptor fields.
   No more pipeline cache hacking — the app already creates explicit state objects.

2. **Constant buffers**: D3D10's `ID3D10Buffer` with constant buffer usage maps
   1:1 to WebGPU's `GPUBuffer` with `UNIFORM` usage.

3. **Resource views**: D3D10's Shader Resource Views (SRV) correspond to WebGPU's
   `GPUTextureView` + bind groups.

4. **Input layouts**: `ID3D10InputLayout` maps directly to `GPUVertexBufferLayout`.

### Architecture

```
D3D10 App
  ├── CreateInputLayout(desc[], bytecode)   →  Create GPUVertexBufferLayout
  ├── CreateVertexShader(bytecode, len)      →  Translate SM4 bytecode → WGSL
  ├── CreateGeometryShader(bytecode, len)    →  See geometry shader section
  ├── CreatePixelShader(bytecode, len)       →  Translate SM4 bytecode → WGSL
  ├── CreateBlendState(desc)                 →  Store for pipeline creation
  ├── CreateRasterizerState(desc)            →  Store for pipeline creation
  ├── CreateDepthStencilState(desc)          →  Store for pipeline creation
  ├── CreateBuffer(desc, data) [constant]    →  device.createBuffer({usage: UNIFORM})
  ├── CreateBuffer(desc, data) [vertex]      →  device.createBuffer({usage: VERTEX})
  ├── CreateBuffer(desc, data) [index]       →  device.createBuffer({usage: INDEX})
  ├── IASetInputLayout(layout)               →  Select vertex layout
  ├── IASetPrimitiveTopology(topology)        →  Set pipeline primitive topology
  ├── VSSetShader(vs)                         →  Select vertex shader
  ├── PSSetShader(ps)                         →  Select pixel shader
  ├── VSSetConstantBuffers(slot, count, bufs) →  Update bind group entries
  ├── PSSetShaderResources(slot, count, srvs) →  Update texture bind group
  ├── OMSetBlendState(state, factor, mask)    →  Select blend state for pipeline
  ├── OMSetRenderTargets(count, rtvs, dsv)    →  Set render pass attachments
  ├── Draw(vertexCount, startVertex)          →  pass.draw()
  └── DrawIndexed(indexCount, startIdx, baseV)→  pass.drawIndexed()
```

### D3D10 API → WebGPU Mapping

| D3D10 Call | WebGPU Action |
|---|---|
| `CreateInputLayout(elements, bytecodeRef)` | Build `GPUVertexBufferLayout` |
| `CreateVertexShader(bytecode)` | Translate SM4 → WGSL, `createShaderModule()` |
| `CreatePixelShader(bytecode)` | Translate SM4 → WGSL, `createShaderModule()` |
| `CreateGeometryShader(bytecode)` | Expand into VS/compute (see below) |
| `CreateBlendState(desc)` | Store `GPUBlendState` descriptor |
| `CreateRasterizerState(desc)` | Store cull/fill mode for pipeline |
| `CreateDepthStencilState(desc)` | Store `GPUDepthStencilState` descriptor |
| `CreateBuffer(CONSTANT_BUFFER)` | `createBuffer({usage: UNIFORM})` |
| `CreateBuffer(VERTEX_BUFFER)` | `createBuffer({usage: VERTEX})` |
| `CreateBuffer(INDEX_BUFFER)` | `createBuffer({usage: INDEX})` |
| `CreateTexture2D(desc)` | `createTexture({...})` |
| `CreateShaderResourceView(res, desc)` | `texture.createView({...})` |
| `CreateRenderTargetView(res, desc)` | `texture.createView({...})` for color attachment |
| `Map(resource, subresource, type)` | `buffer.mapAsync()` or staging buffer |
| `Unmap(resource, subresource)` | `buffer.unmap()` or `writeTexture()` |
| `UpdateSubresource(res, data)` | `queue.writeBuffer()` or `queue.writeTexture()` |
| `IASetInputLayout(layout)` | Select active vertex buffer layout |
| `IASetPrimitiveTopology(topo)` | Set `primitive.topology` on pipeline |
| `VSSetConstantBuffers(slot, bufs)` | Bind uniform buffers in bind group |
| `PSSetConstantBuffers(slot, bufs)` | Bind uniform buffers in bind group |
| `PSSetShaderResources(slot, srvs)` | Bind texture views in bind group |
| `PSSetSamplers(slot, samplers)` | Bind samplers in bind group |
| `OMSetBlendState(state, ...)` | Select blend state for pipeline creation |
| `OMSetDepthStencilState(state, ref)` | Select depth state for pipeline creation |
| `RSSetState(state)` | Select rasterizer state for pipeline creation |
| `RSSetViewports(count, viewports)` | `pass.setViewport(...)` |
| `RSSetScissorRects(count, rects)` | `pass.setScissorRect(...)` |
| `Draw(vertexCount, startVertex)` | `pass.draw(vertexCount, 1, startVertex)` |
| `DrawIndexed(idxCount, startIdx, baseV)` | `pass.drawIndexed(idxCount, 1, startIdx, baseV)` |
| `DrawInstanced(vertPerInst, instCount, ...)` | `pass.draw(vertPerInst, instCount, ...)` |
| `DrawIndexedInstanced(...)` | `pass.drawIndexed(...)` |
| `ClearRenderTargetView(rtv, color)` | `loadOp: 'clear', clearValue: color` |
| `ClearDepthStencilView(dsv, flags, d, s)` | `depthClearValue: d, stencilClearValue: s` |

### D3D10 Constant Buffers → WebGPU Uniform Buffers

D3D10 replaced per-register shader constants with structured constant buffers.
This maps very naturally to WebGPU:

```c
// D3D10: App creates a constant buffer
cbuffer PerFrame : register(b0) {
  float4x4 viewProjection;
  float3   cameraPos;
  float    time;
};
```

```wgsl
// WebGPU: Direct translation
struct PerFrame {
  view_projection: mat4x4f,
  camera_pos:      vec3f,
  time:            f32,
};
@group(0) @binding(0) var<uniform> per_frame: PerFrame;
```

The app calls `UpdateSubresource()` or `Map()/Unmap()` to update the buffer,
which becomes `queue.writeBuffer()` in WebGPU.

### Geometry Shader Emulation

WebGPU does **not** have geometry shaders. D3D10 geometry shaders must be
emulated. Fortunately, most D3D10 games use geometry shaders sparingly, for:

1. **Point sprite expansion** (point → quad): Emit 4 vertices per point
2. **Billboard generation**: Similar to point sprites
3. **Shadow volume extrusion**: Extrude silhouette edges
4. **Single-pass cubemap rendering**: Render to 6 faces using `SV_RenderTargetArrayIndex`

**Emulation strategies**:

| GS Use Case | WebGPU Emulation |
|---|---|
| Point sprite expansion | Vertex shader with instance ID trick: draw 6 vertices per point |
| Simple amplification (1→N) | Pre-expand into vertex buffer via compute pass |
| Stream output (transform feedback) | Compute shader writing to storage buffer |
| Render target array indexing | Multiple render passes (one per layer) |
| Complex topology changes | Compute shader pre-pass generating output vertex buffer |

For the compute-based approach:

```wgsl
// Compute shader emulating a geometry shader that expands points to quads
@group(0) @binding(0) var<storage, read>       input_verts: array<vec4f>;
@group(0) @binding(1) var<storage, read_write>  output_verts: array<QuadVertex>;
@group(0) @binding(2) var<uniform>              params: GsParams;

struct QuadVertex {
  position: vec4f,
  uv:       vec2f,
  color:    vec4f,
};

@compute @workgroup_size(64)
fn gs_point_to_quad(@builtin(global_invocation_id) gid: vec3u) {
  let idx = gid.x;
  if (idx >= params.vertex_count) { return; }

  let center = input_verts[idx];
  let size = params.point_size;

  // Emit 4 vertices (2 triangles = 6 indices via index buffer)
  let base = idx * 4u;
  output_verts[base + 0u] = QuadVertex(center + vec4f(-size, -size, 0, 0), vec2f(0, 1), params.color);
  output_verts[base + 1u] = QuadVertex(center + vec4f( size, -size, 0, 0), vec2f(1, 1), params.color);
  output_verts[base + 2u] = QuadVertex(center + vec4f(-size,  size, 0, 0), vec2f(0, 0), params.color);
  output_verts[base + 3u] = QuadVertex(center + vec4f( size,  size, 0, 0), vec2f(1, 0), params.color);
}
```

### SM4 Bytecode Translation

SM4 bytecode (DXBC format) is more complex than SM2/3 but still translatable:

| SM4 Feature | WGSL Support |
|---|---|
| Integer arithmetic (iadd, imul, etc.) | Full support (`i32`, `u32` ops) |
| Bitwise operations (and, or, xor, shl, shr) | Full support |
| Structured buffers | `var<storage>` buffers |
| Texture arrays | `texture_2d_array<f32>` |
| `SV_InstanceID` | `@builtin(instance_index)` |
| `SV_VertexID` | `@builtin(vertex_index)` |
| `SV_PrimitiveID` | Not available in vertex/fragment (GS limitation) |
| Sample instructions (`sample`, `sample_l`, `sample_c`) | `textureSample*()` family |
| `discard` (clip/texkill) | `discard` statement |
| Dynamic indexing of constant buffers | Array indexing in uniform struct |

### D3D10.1 Additions (Shader Model 4.1)

D3D10.1 is a minor revision shipped with Windows Vista SP1. Most D3D10 games
also work on D3D10.1 hardware. The additions are small but some games require
them:

| D3D10.1 Feature | WebGPU Mapping | Notes |
|---|---|---|
| **SM 4.1** (vs_4_1, ps_4_1, gs_4_1) | Extend SM4 translator with new opcodes | Adds `SampleGrad`, `Gather`, cubemap array sampling |
| **Cubemap arrays** (`TextureCubeArray`) | `texture_cube_array<f32>` | WebGPU supports cube array textures natively |
| **MSAA sample access** (`SV_SampleIndex`, `Sample()`) | `@builtin(sample_index)` + `textureSampleLevel()` | Per-sample shading for AA |
| **Independent blend per RT** | `GPURenderPipeline` targets array with per-target blend | WebGPU supports independent blend per color attachment |
| **Extended formats** | Same DXGI format table below | Adds `DXGI_FORMAT_R16G16B16A16_TYPELESS` variants |
| **`CopySubresourceRegion1`** | `encoder.copyTextureToTexture()` with subregion | Box copy within textures |
| **Read-only depth/stencil views** | Depth texture as both attachment and SRV | Bind depth as read-only + sample in shader |

**Strategy**: D3D10.1 features are handled within the Tier 5 SM4 translator —
no separate tier needed. When a game requests a `D3D10_1` device via
`D3D10CreateDevice1()`, we report `D3D10_FEATURE_LEVEL_10_1` and enable the
extra opcodes in the shader translator.

```zig
// d3d10.zig — handle both D3D10 and D3D10.1 device creation
fn D3D10CreateDevice1(adapter: ?*anyopaque, driver_type: u32, ...) u32 {
    // Same as D3D10CreateDevice but report feature level 10_1
    return createD3D10Device(.feature_level_10_1);
}
```

### DXGI Format → WebGPU Texture Format Mapping

D3D10 uses `DXGI_FORMAT` enum values instead of D3D8/9's `D3DFMT_*`. The most
common formats map as follows:

| DXGI_FORMAT | WebGPU GPUTextureFormat | Notes |
|---|---|---|
| `DXGI_FORMAT_R8G8B8A8_UNORM` | `'rgba8unorm'` | Standard color |
| `DXGI_FORMAT_R8G8B8A8_UNORM_SRGB` | `'rgba8unorm-srgb'` | sRGB color |
| `DXGI_FORMAT_B8G8R8A8_UNORM` | `'bgra8unorm'` | D3D's native BGRA |
| `DXGI_FORMAT_B8G8R8A8_UNORM_SRGB` | `'bgra8unorm-srgb'` | sRGB BGRA |
| `DXGI_FORMAT_R16G16B16A16_FLOAT` | `'rgba16float'` | HDR color |
| `DXGI_FORMAT_R32G32B32A32_FLOAT` | `'rgba32float'` | Full precision HDR |
| `DXGI_FORMAT_R32_FLOAT` | `'r32float'` | Depth / single-channel |
| `DXGI_FORMAT_R16_FLOAT` | `'r16float'` | Half-precision single |
| `DXGI_FORMAT_R8_UNORM` | `'r8unorm'` | Grayscale / alpha mask |
| `DXGI_FORMAT_R8G8_UNORM` | `'rg8unorm'` | Normal map (2-channel) |
| `DXGI_FORMAT_R16G16_FLOAT` | `'rg16float'` | HDR normal map |
| `DXGI_FORMAT_R32_UINT` | `'r32uint'` | Integer ID buffer |
| `DXGI_FORMAT_R10G10B10A2_UNORM` | `'rgb10a2unorm'` | 10-bit color |
| `DXGI_FORMAT_R11G11B10_FLOAT` | `'rg11b10ufloat'` | Compact HDR |
| `DXGI_FORMAT_D24_UNORM_S8_UINT` | `'depth24plus-stencil8'` | Depth+stencil |
| `DXGI_FORMAT_D32_FLOAT` | `'depth32float'` | Float depth |
| `DXGI_FORMAT_D16_UNORM` | `'depth16unorm'` | 16-bit depth |
| `DXGI_FORMAT_BC1_UNORM` | `'bc1-rgba-unorm'` | DXT1 compressed |
| `DXGI_FORMAT_BC2_UNORM` | `'bc2-rgba-unorm'` | DXT3 compressed |
| `DXGI_FORMAT_BC3_UNORM` | `'bc3-rgba-unorm'` | DXT5 compressed |
| `DXGI_FORMAT_BC4_UNORM` | `'bc4-r-unorm'` | Single-channel compressed |
| `DXGI_FORMAT_BC5_UNORM` | `'bc5-rg-unorm'` | Normal map compressed |
| `DXGI_FORMAT_BC7_UNORM` | `'bc7-rgba-unorm'` | High-quality compressed |

---

## Tier 6: D3D11 Full Pipeline Emulation

Direct3D 11 is the most widely used D3D version for PC gaming (2009–2015+).
It extends D3D10 with tessellation, compute shaders, SM 5.0, and a
device/context architecture split. It also introduces feature levels, allowing
a single API to target hardware from D3D9 through D3D11.

**Implementation Checklist:**
- [ ] Create `d3d11.zig` stub module with `ID3D11Device` / `ID3D11DeviceContext` COM interfaces
- [ ] Extend SM4 bytecode translator to support SM5 (new opcodes, doubled constant limits)
- [ ] Implement `CreateComputeShader` → translate SM5 → WGSL, `createComputePipeline()`
- [ ] Implement `Dispatch` / `DispatchIndirect` → `computePass.dispatchWorkgroups()`
- [ ] Implement UAV (Unordered Access View) → `var<storage, read_write>` in WGSL
- [ ] Implement tessellation emulation via compute pre-pass (see below)
- [ ] Implement `CreateHullShader` / `CreateDomainShader` → fold into tessellation compute
- [ ] Implement deferred context → record command list + replay
- [ ] Implement feature level reporting (`D3D_FEATURE_LEVEL_11_0`)
- [ ] Implement `ID3D11DeviceContext::Map` / `Unmap` (deferred updates)
- [ ] Implement structured buffers / append-consume buffers → `var<storage>`
- [ ] Implement `CSSetShaderResources` / `CSSetUnorderedAccessViews` → compute bind groups
- [ ] Verify with a D3D11 game (e.g., Skyrim)

### Why D3D11 Is Challenging

D3D11 maps better than D3D9 but has two features that WebGPU fundamentally
lacks, requiring creative emulation:

| Challenge | Problem | Mitigation |
|---|---|---|
| **Tessellation** | D3D11's hull/tessellator/domain shader pipeline has no WebGPU equivalent. This is the single biggest gap. | Compute pre-pass: run hull+tessellator+domain logic in a compute shader, output to storage buffer, draw from that buffer. |
| **Deferred contexts** | D3D11 allows recording commands on background threads. WASM is single-threaded, so true parallelism is impossible. | Record commands to a list (in WASM linear memory), replay into a single encoder. No real performance benefit, but correct behavior. |
| **Dynamic shader linkage** | D3D11's `ID3D11ClassLinkage` allows runtime polymorphism in shaders by swapping interface implementations. | Pre-compile all variants at shader creation time, select the right one at bind time. |
| **Unordered Access Views (UAVs)** | UAVs on pixel shader output (`OMSetRenderTargetsAndUnorderedAccessViews`) mix render attachments and storage bindings. | Map to WebGPU storage textures/buffers in a separate bind group. |
| **Append/Consume buffers** | `AppendStructuredBuffer` / `ConsumeStructuredBuffer` use atomic counters for producer-consumer patterns. | Emulate counters via atomic operations on a storage buffer. |
| **SM5 scope** | SM5 adds ~40 new opcodes over SM4, plus extended resource types and doubled register counts. | Extend the SM4 translator incrementally; many SM5 opcodes are straightforward WGSL mappings. |

### What's New in D3D11 vs D3D10

| Feature | D3D10 | D3D11 |
|---|---|---|
| Shader model | SM 4.0 | **SM 5.0** |
| Tessellation | Not available | **Hull + Tessellator + Domain shader** |
| Compute shaders | Limited (cs_4_0/4_1) | **Full DirectCompute (cs_5_0)** |
| API architecture | `ID3D10Device` (unified) | **`ID3D11Device` + `ID3D11DeviceContext`** (split) |
| Multithreaded rendering | Limited | **Deferred contexts** for true MT command recording |
| Feature levels | D3D10 hardware only | **D3D9–D3D11 hardware** via feature levels |
| Dynamic shader linkage | Not available | **Interface-based shader polymorphism** |
| UAV (compute read/write) | Not available | **Unordered Access Views** on all shader stages |
| Structured buffers | Not available | **StructuredBuffer / RWStructuredBuffer** |
| Append/consume buffers | Not available | **AppendStructuredBuffer / ConsumeStructuredBuffer** |
| BC6H/BC7 textures | Not available | **HDR and high-quality compression** |

### Device / Context Split → WebGPU Mapping

D3D11 split `ID3D10Device` into two objects:
- **`ID3D11Device`** — resource creation (thread-safe)
- **`ID3D11DeviceContext`** — command recording + submission

This maps naturally to WebGPU:

| D3D11 Object | WebGPU Equivalent |
|---|---|
| `ID3D11Device` | `GPUDevice` (resource creation is thread-safe) |
| `ID3D11DeviceContext` (immediate) | `GPUCommandEncoder` + `queue.submit()` |
| `ID3D11DeviceContext` (deferred) | Record commands into a list, replay later |
| `ID3D11ClassLinkage` | Compile multiple WGSL shader variants, select at bind time |

### Tessellation Emulation

D3D11 added three tessellation stages: hull shader → fixed-function tessellator
→ domain shader. WebGPU does **not** support tessellation. Emulation options:

| Strategy | Approach | Tradeoff |
|---|---|---|
| Compute pre-pass | Hull + tessellator + domain shader logic in a compute shader that generates output vertices into a storage buffer, then draw from that buffer | Most general, works for all tessellation modes |
| Pre-tessellated meshes | Detect static tessellation factors, pre-generate subdivided meshes on the CPU at load time | Simple, good for fixed-factor cases like terrain |
| Skip tessellation | Use the control mesh directly (low-poly fallback) | Fast, visually degraded but acceptable for many games |

Compute-based tessellation emulation:

```wgsl
// Compute shader: tessellation emulation
// Input: control points (patches), tessellation factors from hull shader
// Output: tessellated triangles written to storage buffer

struct ControlPoint {
  position: vec3f,
  normal:   vec3f,
  uv:       vec2f,
};

@group(0) @binding(0) var<storage, read>       input_patches: array<ControlPoint>;
@group(0) @binding(1) var<storage, read_write>  output_verts:  array<ControlPoint>;
@group(0) @binding(2) var<uniform>              tess_params: TessParams;

struct TessParams {
  tess_factor: f32,     // e.g., 4.0 = subdivide each edge into 4
  patch_count: u32,
};

@compute @workgroup_size(64)
fn tessellate(@builtin(global_invocation_id) gid: vec3u) {
  let patch_id = gid.x;
  if (patch_id >= tess_params.patch_count) { return; }

  // Read 3 control points (triangle patch)
  let cp0 = input_patches[patch_id * 3u + 0u];
  let cp1 = input_patches[patch_id * 3u + 1u];
  let cp2 = input_patches[patch_id * 3u + 2u];

  // Generate subdivided triangles using barycentric interpolation
  let n = u32(tess_params.tess_factor);
  var out_idx = patch_id * n * n * 3u;  // approximate output offset

  // ... subdivision logic ...
  // Write interpolated vertices to output_verts[out_idx++]
}
```

### Compute Shaders → WebGPU Compute Pipelines

D3D11 compute shaders map almost directly to WebGPU compute:

| D3D11 Compute Concept | WebGPU Equivalent |
|---|---|
| `CreateComputeShader(bytecode)` | Translate SM5 → WGSL, `createComputePipeline()` |
| `CSSetShader(cs)` | Select compute pipeline |
| `CSSetConstantBuffers(slot, bufs)` | Bind uniform buffers |
| `CSSetShaderResources(slot, srvs)` | Bind texture views (read-only) |
| `CSSetUnorderedAccessViews(slot, uavs)` | Bind storage buffers/textures (read-write) |
| `Dispatch(x, y, z)` | `computePass.dispatchWorkgroups(x, y, z)` |
| `DispatchIndirect(buffer, offset)` | `computePass.dispatchWorkgroupsIndirect(buffer, offset)` |
| `StructuredBuffer<T>` (SRV) | `var<storage, read> buf: array<T>` |
| `RWStructuredBuffer<T>` (UAV) | `var<storage, read_write> buf: array<T>` |
| `groupshared` memory | `var<workgroup>` in WGSL |
| `[numthreads(x,y,z)]` | `@workgroup_size(x,y,z)` |
| `SV_GroupID` | `@builtin(workgroup_id)` |
| `SV_GroupThreadID` | `@builtin(local_invocation_id)` |
| `SV_DispatchThreadID` | `@builtin(global_invocation_id)` |

### D3D11 API → WebGPU Mapping (additions over D3D10)

| D3D11 Call | WebGPU Action |
|---|---|
| `D3D11CreateDevice(adapter, type, flags, featureLevels)` | `requestAdapter()` + `requestDevice()` |
| `CreateHullShader(bytecode)` | Fold into tessellation compute pipeline |
| `CreateDomainShader(bytecode)` | Fold into tessellation compute pipeline |
| `CreateComputeShader(bytecode)` | Translate SM5 → WGSL, `createComputePipeline()` |
| `Dispatch(x, y, z)` | `computePass.dispatchWorkgroups(x, y, z)` |
| `CSSetUnorderedAccessViews(slot, uavs)` | Bind `var<storage, read_write>` buffers |
| `OMSetRenderTargetsAndUnorderedAccessViews(...)` | Bind both color attachments and storage bindings |
| `CreateDeferredContext(&ctx)` | Create separate command encoder |
| `FinishCommandList(restore, &cmdList)` | `encoder.finish()` → store `GPUCommandBuffer` |
| `ExecuteCommandList(cmdList, restore)` | `queue.submit([cmdBuffer])` |
| `CheckFeatureSupport(feature, data)` | Return capabilities based on WebGPU limits |
| `GetFeatureLevel()` | Return `D3D_FEATURE_LEVEL_11_0` |

### Feature Levels

D3D11's feature level system lets an app query hardware capability:

| Feature Level | Our Response | Rationale |
|---|---|---|
| `D3D_FEATURE_LEVEL_9_1` – `9_3` | Report if only Tier 3 implemented | Matches fixed-function capability |
| `D3D_FEATURE_LEVEL_10_0` – `10_1` | Report if Tier 5 implemented | SM4 shaders available |
| `D3D_FEATURE_LEVEL_11_0` | Report if Tier 6 implemented | SM5, compute, (emulated) tessellation |

For games that check feature level and fall back gracefully, we can initially
report a lower level and upgrade as we implement more tiers.

---

## Tier 7: D3D12 Explicit Pipeline Emulation

Direct3D 12 is a low-level, explicit API designed for maximum GPU efficiency.
Ironically, its design philosophy is so close to WebGPU's that many concepts
map 1:1 — making it in some ways *easier* to translate than D3D9's implicit
state machine.

**Implementation Checklist:**
- [ ] Create `d3d12.zig` stub module with `ID3D12Device` / `ID3D12CommandQueue` /
      `ID3D12GraphicsCommandList` COM interfaces
- [ ] Implement `CreateCommandAllocator` / `CreateCommandList` → `createCommandEncoder()`
- [ ] Implement `CreateGraphicsPipelineState(desc)` → `createRenderPipeline(desc)`
- [ ] Implement `CreateComputePipelineState(desc)` → `createComputePipeline(desc)`
- [ ] Implement `CreateRootSignature(blob)` → `createPipelineLayout()` + `createBindGroupLayout()`
- [ ] Implement `CreateDescriptorHeap(desc)` → manage bind group entries
- [ ] Implement `CreateCommittedResource(heap, desc)` → `createBuffer()` / `createTexture()`
- [ ] Implement `ExecuteCommandLists(count, lists)` → `queue.submit(cmdBuffers)`
- [ ] Implement `ResourceBarrier(count, barriers)` → no-op (WebGPU handles transitions)
- [ ] Implement fence/signal synchronization → `queue.onSubmittedWorkDone()`
- [ ] Implement `SetGraphicsRootDescriptorTable(idx, handle)` → `pass.setBindGroup(idx, bg)`
- [ ] Implement `SetGraphicsRootConstantBufferView` / `SetGraphicsRoot32BitConstants`
- [ ] Extend SM4 translator to handle SM5.1+ features (dynamic indexing, root constants)
- [ ] Implement swap chain creation via `IDXGISwapChain` → canvas context
- [ ] Verify with a D3D12 game

### What's New in D3D12 vs D3D11

| Feature | D3D11 | D3D12 |
|---|---|---|
| API style | High-level, driver-managed | **Low-level, app-managed** |
| Command recording | Immediate + deferred contexts | **Command lists + command queues** |
| Pipeline state | Separate state objects | **Monolithic PSO (Pipeline State Object)** |
| Resource binding | Fixed slots per stage | **Root signatures + descriptor heaps** |
| Memory management | Driver-managed (pool system) | **Explicit heaps + placed/committed resources** |
| Synchronization | Implicit (driver handles) | **Explicit fences + barriers** |
| Resource state | Driver-tracked | **App-managed transitions (`ResourceBarrier`)** |
| Multi-GPU | Implicit (driver routes) | **Explicit multi-adapter** |
| Shader model | SM 5.0 | **SM 5.1 + SM 6.x** |
| Bundle reuse | Deferred contexts (limited) | **Bundles (lightweight secondary cmd lists)** |

### Why D3D12 Maps Well to WebGPU

D3D12 and WebGPU share the same design DNA (both inspired by Vulkan/Metal):

| D3D12 Concept | WebGPU Equivalent | Notes |
|---|---|---|
| `ID3D12Device` | `GPUDevice` | Resource creation |
| `ID3D12CommandQueue` | `GPUQueue` | Submission point |
| `ID3D12CommandAllocator` | (internal to encoder) | WebGPU manages allocators internally |
| `ID3D12GraphicsCommandList` | `GPUCommandEncoder` → `GPUCommandBuffer` | Record then submit |
| `ID3D12PipelineState` (graphics) | `GPURenderPipeline` | Immutable, pre-validated |
| `ID3D12PipelineState` (compute) | `GPUComputePipeline` | Immutable, pre-validated |
| `ID3D12RootSignature` | `GPUPipelineLayout` + `GPUBindGroupLayout[]` | Describes binding model |
| `ID3D12DescriptorHeap` | Bind groups (`GPUBindGroup`) | Resource binding |
| Root constants | `pass.setBindGroup()` with dynamic offsets | Or inline into uniform buffer |
| Root CBV/SRV/UAV | Entries in `GPUBindGroup` | Direct resource binding |
| `ResourceBarrier` | No-op | WebGPU tracks resource state internally |
| `ID3D12Fence` | `queue.onSubmittedWorkDone()` | CPU→GPU sync |
| Swap chain (`IDXGISwapChain`) | `context.getCurrentTexture()` | Canvas presentation |
| `ExecuteCommandLists` | `queue.submit(cmdBuffers)` | Batch submission |

### Architecture

```
D3D12 App
  ├── CreateRootSignature(serialized)        →  createPipelineLayout() + createBindGroupLayout()
  ├── CreateGraphicsPipelineState(desc)       →  createRenderPipeline(desc)  [1:1 mapping!]
  ├── CreateCommandAllocator(type)             →  (managed internally by encoder)
  ├── CreateCommandList(type, alloc, pso)      →  createCommandEncoder()
  ├── list->SetGraphicsRootSignature(rs)       →  pipeline already has layout
  ├── list->SetPipelineState(pso)              →  pass.setPipeline(pipeline)
  ├── list->SetDescriptorHeaps(count, heaps)   →  (bind groups manage this)
  ├── list->SetGraphicsRootDescriptorTable(i, handle) → pass.setBindGroup(i, bg)
  ├── list->IASetVertexBuffers(slot, count, views)    → pass.setVertexBuffer(slot, buf)
  ├── list->IASetIndexBuffer(view)             →  pass.setIndexBuffer(buf, fmt)
  ├── list->IASetPrimitiveTopology(topo)       →  (set in pipeline primitive.topology)
  ├── list->RSSetViewports(count, viewports)   →  pass.setViewport(...)
  ├── list->OMSetRenderTargets(count, rtvs, dsv) →  beginRenderPass({colorAttachments, depthStencil})
  ├── list->DrawInstanced(vertPerInst, inst, startV, startI) → pass.draw(...)
  ├── list->DrawIndexedInstanced(...)          →  pass.drawIndexed(...)
  ├── list->ResourceBarrier(count, barriers)   →  no-op
  ├── list->Close()                            →  encoder.finish() → cmdBuffer
  └── queue->ExecuteCommandLists(count, lists) →  queue.submit([cmdBuffer])
```

### D3D12 API → WebGPU Mapping

| D3D12 Call | WebGPU Action |
|---|---|
| `D3D12CreateDevice(adapter, featureLevel)` | `requestAdapter()` + `requestDevice()` |
| `CreateCommandQueue(desc)` | Use `device.queue` (single queue) |
| `CreateCommandAllocator(type)` | (internal to `GPUCommandEncoder`) |
| `CreateCommandList(nodeMask, type, alloc, pso)` | `device.createCommandEncoder()` |
| `CreateGraphicsPipelineState(desc)` | `device.createRenderPipeline(desc)` |
| `CreateComputePipelineState(desc)` | `device.createComputePipeline(desc)` |
| `CreateRootSignature(blob)` | `createPipelineLayout()` + `createBindGroupLayout()` |
| `CreateDescriptorHeap(desc)` | Manage as bind group entry pool |
| `CreateCommittedResource(heap, desc)` | `createBuffer()` or `createTexture()` |
| `CreateShaderResourceView(res, desc, handle)` | `texture.createView()` / buffer binding |
| `CreateRenderTargetView(res, desc, handle)` | `texture.createView()` for color attachment |
| `CreateDepthStencilView(res, desc, handle)` | `texture.createView()` for depth attachment |
| `CreateConstantBufferView(desc, handle)` | Buffer entry in bind group |
| `list->SetPipelineState(pso)` | `pass.setPipeline(pipeline)` |
| `list->SetGraphicsRootSignature(rs)` | (encoded in pipeline layout) |
| `list->SetGraphicsRootDescriptorTable(i, h)` | `pass.setBindGroup(i, bindGroup)` |
| `list->SetGraphicsRoot32BitConstants(i, n, d, o)` | Write to dynamic uniform buffer |
| `list->SetGraphicsRootConstantBufferView(i, gpu)` | Bind group entry with buffer |
| `list->IASetVertexBuffers(slot, count, views)` | `pass.setVertexBuffer(slot, buf, offset, size)` |
| `list->IASetIndexBuffer(view)` | `pass.setIndexBuffer(buf, fmt, offset, size)` |
| `list->DrawInstanced(v, inst, sv, si)` | `pass.draw(v, inst, sv, si)` |
| `list->DrawIndexedInstanced(i, inst, si, bv, sI)` | `pass.drawIndexed(i, inst, si, bv, sI)` |
| `list->Dispatch(x, y, z)` | `computePass.dispatchWorkgroups(x, y, z)` |
| `list->ResourceBarrier(n, barriers)` | No-op (WebGPU auto-tracks) |
| `list->ClearRenderTargetView(rtv, color, n, r)` | `loadOp: 'clear', clearValue: color` |
| `list->ClearDepthStencilView(dsv, f, d, s, n, r)` | `depthLoadOp: 'clear', depthClearValue: d` |
| `list->Close()` | `encoder.finish()` → `GPUCommandBuffer` |
| `queue->ExecuteCommandLists(n, lists)` | `queue.submit(commandBuffers)` |
| `queue->Signal(fence, value)` | `queue.onSubmittedWorkDone()` |
| `fence->SetEventOnCompletion(value, event)` | `await queue.onSubmittedWorkDone()` |
| `CreateSwapChain(queue, desc)` | `canvas.getContext('webgpu')` + `context.configure()` |
| `swapChain->GetCurrentBackBufferIndex()` | `context.getCurrentTexture()` |
| `swapChain->Present(interval, flags)` | (implicit when render pass uses canvas texture) |

### Resource Barriers: Why They Become No-Ops

D3D12 requires explicit `ResourceBarrier` calls to transition resources between
states (e.g., render target → shader resource). WebGPU handles this internally:

```javascript
// D3D12: explicit barrier required
cmdList.ResourceBarrier(1, &CD3DX12_RESOURCE_BARRIER::Transition(
  texture, D3D12_RESOURCE_STATE_RENDER_TARGET,
  D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE
));

// WebGPU: nothing needed — the runtime tracks state automatically
// Just use the texture in a bind group, and WebGPU inserts barriers.
```

Our D3D12 `ResourceBarrier` stub simply logs the transition for debugging and
returns. This is one of the few cases where the translation *simplifies* things.

---

## Tier 8: Vulkan Emulation

Vulkan is WebGPU's closest relative — WebGPU was designed as a safe, portable
abstraction over Vulkan (and Metal/D3D12). Many concepts map 1:1 or near-1:1.
Some Windows games ship with Vulkan renderers (id Tech, Source 2, many
Linux-ported titles via Proton/DXVK), and emulating Vulkan on WebGPU is arguably
the most natural translation of all the APIs covered here.

**Implementation Checklist:**
- [ ] Create `vulkan-1.zig` stub (Vulkan ICD / loader shim)
- [ ] Implement `vkCreateInstance` / `vkCreateDevice` → `requestAdapter()` + `requestDevice()`
- [ ] Implement SPIR-V → WGSL translator (via naga or Tint compiled to WASM)
- [ ] Implement `vkCreateGraphicsPipelines` → `createRenderPipeline()`
- [ ] Implement `vkCreateComputePipelines` → `createComputePipeline()`
- [ ] Implement `vkCreateDescriptorSetLayout` → `createBindGroupLayout()`
- [ ] Implement `vkAllocateDescriptorSets` / `vkUpdateDescriptorSets` → `createBindGroup()`
- [ ] Implement `vkAllocateCommandBuffers` / `vkBeginCommandBuffer` → `createCommandEncoder()`
- [ ] Implement `vkCmdBeginRenderPass` → `encoder.beginRenderPass()`
- [ ] Implement `vkCmdBindPipeline` → `pass.setPipeline()`
- [ ] Implement `vkCmdBindDescriptorSets` → `pass.setBindGroup()`
- [ ] Implement `vkCmdDraw` / `vkCmdDrawIndexed` → `pass.draw()` / `pass.drawIndexed()`
- [ ] Implement `vkCmdDispatch` → `computePass.dispatchWorkgroups()`
- [ ] Implement `vkQueueSubmit` → `queue.submit()`
- [ ] Implement `vkCreateBuffer` / `vkCreateImage` → `createBuffer()` / `createTexture()`
- [ ] Implement memory management (consolidate VkDeviceMemory → WebGPU managed)
- [ ] Implement synchronization stubs (`vkCreateSemaphore`, `vkCreateFence` → simplified)
- [ ] Implement `vkCmdPipelineBarrier` → no-op (WebGPU auto-tracks)
- [ ] Implement swap chain via `vkCreateSwapchainKHR` → canvas context
- [ ] Verify with a Vulkan game (e.g., Doom 2016)

### Why Vulkan Maps to WebGPU

WebGPU was explicitly designed as a "Vulkan-like" API for the web. WGSL was
designed to be "trivially convertible" to/from SPIR-V. The conceptual overlap
is so large that the main challenge is *removing* Vulkan's complexity rather
than *adding* missing features:

| Vulkan Concept | WebGPU Equivalent | Simplification |
|---|---|---|
| `VkInstance` | (implicit) | WebGPU has no instance |
| `VkPhysicalDevice` | `GPUAdapter` | Adapter selected automatically |
| `VkDevice` | `GPUDevice` | Same role |
| `VkQueue` | `GPUQueue` | Single queue (WebGPU) vs multiple (Vulkan) |
| `VkCommandPool` | (internal) | WebGPU manages command memory |
| `VkCommandBuffer` | `GPUCommandEncoder` → `GPUCommandBuffer` | Same model |
| `VkRenderPass` + `VkFramebuffer` | `GPURenderPassDescriptor` | Merged into one object |
| `VkPipeline` (graphics) | `GPURenderPipeline` | Same — immutable, pre-compiled |
| `VkPipeline` (compute) | `GPUComputePipeline` | Same |
| `VkPipelineLayout` | `GPUPipelineLayout` | Same |
| `VkDescriptorSetLayout` | `GPUBindGroupLayout` | Same |
| `VkDescriptorPool` + `VkDescriptorSet` | `GPUBindGroup` | Pool eliminated |
| `VkShaderModule` (SPIR-V) | `GPUShaderModule` (WGSL) | Translate SPIR-V → WGSL |
| `VkBuffer` | `GPUBuffer` | Same |
| `VkImage` + `VkImageView` | `GPUTexture` + `GPUTextureView` | Same |
| `VkSampler` | `GPUSampler` | Same |
| `VkSemaphore` / `VkFence` | `queue.onSubmittedWorkDone()` | Greatly simplified |
| `VkDeviceMemory` | (managed by WebGPU) | No manual memory allocation |
| `vkCmdPipelineBarrier` | No-op | WebGPU auto-tracks resource state |
| `VkSwapchainKHR` | `GPUCanvasContext` | Canvas replaces the swap chain |

### Architecture

```
Vulkan App
  ├── vkCreateInstance(info)                    →  (no-op, implicit)
  ├── vkEnumeratePhysicalDevices(inst)           →  requestAdapter()
  ├── vkCreateDevice(phys, info)                 →  requestDevice()
  ├── vkCreateRenderPass(dev, info)              →  (deferred to beginRenderPass)
  ├── vkCreateDescriptorSetLayout(dev, info)     →  createBindGroupLayout(info)
  ├── vkCreatePipelineLayout(dev, info)          →  createPipelineLayout(info)
  ├── vkCreateShaderModule(dev, spirv)           →  translate SPIR-V→WGSL, createShaderModule(wgsl)
  ├── vkCreateGraphicsPipelines(dev, cache, info)→  createRenderPipeline(desc)
  ├── vkAllocateCommandBuffers(dev, info)        →  createCommandEncoder()
  ├── vkBeginCommandBuffer(cmd, info)            →  (encoder is ready immediately)
  ├── vkCmdBeginRenderPass(cmd, info, contents)  →  encoder.beginRenderPass(desc)
  ├── vkCmdBindPipeline(cmd, point, pipeline)    →  pass.setPipeline(pipeline)
  ├── vkCmdBindDescriptorSets(cmd, point, layout, sets) → pass.setBindGroup(i, bg)
  ├── vkCmdBindVertexBuffers(cmd, first, bufs)   →  pass.setVertexBuffer(slot, buf)
  ├── vkCmdBindIndexBuffer(cmd, buf, off, type)  →  pass.setIndexBuffer(buf, fmt)
  ├── vkCmdDraw(cmd, v, inst, fv, fi)            →  pass.draw(v, inst, fv, fi)
  ├── vkCmdDrawIndexed(cmd, i, inst, fi, vo, fI) →  pass.drawIndexed(i, inst, fi, vo, fI)
  ├── vkCmdPipelineBarrier(cmd, ...)             →  no-op
  ├── vkCmdEndRenderPass(cmd)                    →  pass.end()
  ├── vkEndCommandBuffer(cmd)                    →  encoder.finish() → cmdBuffer
  └── vkQueueSubmit(queue, submits, fence)       →  queue.submit([cmdBuffer])
```

### SPIR-V → WGSL Shader Translation

Vulkan shaders are SPIR-V bytecode. WGSL was designed to be trivially convertible
from SPIR-V, so this is the most straightforward shader translation of all tiers:

**Translation approach**: Use naga (Rust, can compile to WASM) or Tint (C++, can
compile to WASM) to convert SPIR-V → WGSL at `vkCreateShaderModule` time:

```javascript
// JS host: SPIR-V → WGSL translation
function createShaderModule(spirvBytes) {
  // naga compiled to WASM handles the translation
  const wgslSource = nagaSpirvToWgsl(spirvBytes);
  return device.createShaderModule({ code: wgslSource });
}
```

**Key mappings in the translation:**

| SPIR-V / GLSL Concept | WGSL Equivalent |
|---|---|
| `layout(set=N, binding=M)` | `@group(N) @binding(M)` |
| `layout(location=N) in` | `@location(N)` in struct |
| `uniform` block | `var<uniform>` |
| `buffer` block (SSBO) | `var<storage, read>` or `var<storage, read_write>` |
| `sampler2D` / `texture2D` | `sampler` + `texture_2d<f32>` (separate) |
| `gl_Position` | `@builtin(position)` |
| `gl_FragCoord` | `@builtin(position)` |
| `gl_VertexIndex` | `@builtin(vertex_index)` |
| `gl_InstanceIndex` | `@builtin(instance_index)` |
| `gl_GlobalInvocationID` | `@builtin(global_invocation_id)` |
| `gl_LocalInvocationID` | `@builtin(local_invocation_id)` |
| `gl_WorkGroupID` | `@builtin(workgroup_id)` |
| `push_constant` | Inline into uniform buffer (WebGPU has no push constants) |
| `subpassInput` | Read from previous render pass output texture |
| `shared` (compute) | `var<workgroup>` |
| `barrier()` | `workgroupBarrier()` |

### Vulkan-Specific Challenges

**Push constants**: Vulkan's `vkCmdPushConstants` allows small amounts of data
to be pushed directly without buffer allocation. WebGPU has no push constants.
Emulate by maintaining a small dynamic uniform buffer that is updated per-draw:

```javascript
// Emulate push constants with a small uniform buffer
const pushConstantBuffer = device.createBuffer({
  size: 256,  // Vulkan guarantees at least 128 bytes, most support 256
  usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
});

function cmdPushConstants(stageFlags, offset, size, data) {
  device.queue.writeBuffer(pushConstantBuffer, offset, data);
  // Bind group already references this buffer
}
```

**Multiple queues**: Vulkan apps may use separate graphics, compute, and transfer
queues for async operations. WebGPU has a single queue. For our emulation, all
queue submissions go to `device.queue`. This means async compute/transfer
overlap won't provide performance benefits, but correctness is maintained.

**Render pass compatibility**: Vulkan has an elaborate render pass system with
subpasses, dependencies, and load/store ops. WebGPU's render passes are simpler
(no subpasses). Multi-subpass render passes must be split into multiple WebGPU
render passes with intermediate textures.

**Memory allocation**: Vulkan requires explicit `vkAllocateMemory` +
`vkBindBufferMemory`/`vkBindImageMemory`. WebGPU manages memory internally.
Our stubs simply ignore the memory allocation calls and let WebGPU handle it:

```zig
// vkAllocateMemory → return a dummy handle
// vkBindBufferMemory → no-op (buffer already has memory in WebGPU)
// vkFreeMemory → no-op
```

### Vulkan API → WebGPU Mapping

| Vulkan Call | WebGPU Action |
|---|---|
| `vkCreateInstance(info)` | No-op (implicit in WebGPU) |
| `vkEnumeratePhysicalDevices(inst)` | `navigator.gpu.requestAdapter()` |
| `vkCreateDevice(phys, info)` | `adapter.requestDevice()` |
| `vkGetDeviceQueue(dev, family, idx)` | `device.queue` |
| `vkCreateShaderModule(dev, spirv)` | Translate SPIR-V→WGSL via naga, `createShaderModule()` |
| `vkCreateDescriptorSetLayout(dev, info)` | `createBindGroupLayout(desc)` |
| `vkCreatePipelineLayout(dev, info)` | `createPipelineLayout(desc)` |
| `vkCreateGraphicsPipelines(dev, cache, infos)` | `createRenderPipeline(desc)` |
| `vkCreateComputePipelines(dev, cache, infos)` | `createComputePipeline(desc)` |
| `vkCreateDescriptorPool(dev, info)` | (no pool needed — create bind groups directly) |
| `vkAllocateDescriptorSets(dev, info)` | `createBindGroup(desc)` |
| `vkUpdateDescriptorSets(dev, writes, copies)` | Recreate `createBindGroup()` with new entries |
| `vkCreateBuffer(dev, info)` | `createBuffer({size, usage})` |
| `vkCreateImage(dev, info)` | `createTexture({size, format, usage})` |
| `vkCreateImageView(dev, info)` | `texture.createView(desc)` |
| `vkCreateSampler(dev, info)` | `createSampler(desc)` |
| `vkAllocateMemory(dev, info)` | No-op (WebGPU manages memory) |
| `vkBindBufferMemory(dev, buf, mem, off)` | No-op |
| `vkBindImageMemory(dev, img, mem, off)` | No-op |
| `vkMapMemory(dev, mem, off, size)` | `buffer.mapAsync()` or staging buffer |
| `vkUnmapMemory(dev, mem)` | `buffer.unmap()` |
| `vkCreateRenderPass(dev, info)` | Store descriptor for later use in `beginRenderPass()` |
| `vkCreateFramebuffer(dev, info)` | Store attachment references |
| `vkAllocateCommandBuffers(dev, info)` | `createCommandEncoder()` |
| `vkBeginCommandBuffer(cmd, info)` | (encoder ready immediately) |
| `vkCmdBeginRenderPass(cmd, info, contents)` | `encoder.beginRenderPass(desc)` |
| `vkCmdEndRenderPass(cmd)` | `pass.end()` |
| `vkCmdBindPipeline(cmd, point, pipe)` | `pass.setPipeline(pipeline)` |
| `vkCmdBindDescriptorSets(cmd, ...)` | `pass.setBindGroup(idx, bg)` |
| `vkCmdBindVertexBuffers(cmd, first, bufs)` | `pass.setVertexBuffer(slot, buf, off, size)` |
| `vkCmdBindIndexBuffer(cmd, buf, off, type)` | `pass.setIndexBuffer(buf, fmt, off, size)` |
| `vkCmdSetViewport(cmd, first, viewports)` | `pass.setViewport(x, y, w, h, minD, maxD)` |
| `vkCmdSetScissor(cmd, first, scissors)` | `pass.setScissorRect(x, y, w, h)` |
| `vkCmdDraw(cmd, vtx, inst, fv, fi)` | `pass.draw(vtx, inst, fv, fi)` |
| `vkCmdDrawIndexed(cmd, idx, inst, fi, vo, fI)` | `pass.drawIndexed(idx, inst, fi, vo, fI)` |
| `vkCmdDispatch(cmd, x, y, z)` | `computePass.dispatchWorkgroups(x, y, z)` |
| `vkCmdCopyBuffer(cmd, src, dst, regions)` | `encoder.copyBufferToBuffer(src, sOff, dst, dOff, size)` |
| `vkCmdCopyBufferToImage(cmd, ...)` | `encoder.copyBufferToTexture(src, dst, size)` |
| `vkCmdCopyImageToBuffer(cmd, ...)` | `encoder.copyTextureToBuffer(src, dst, size)` |
| `vkCmdCopyImage(cmd, src, dst, regions)` | `encoder.copyTextureToTexture(src, dst, size)` |
| `vkCmdPipelineBarrier(cmd, ...)` | No-op |
| `vkCmdPushConstants(cmd, layout, stage, off, size, data)` | Write to push constant uniform buffer |
| `vkEndCommandBuffer(cmd)` | `encoder.finish()` → `GPUCommandBuffer` |
| `vkQueueSubmit(queue, submits, fence)` | `queue.submit(cmdBuffers)` |
| `vkQueueWaitIdle(queue)` | `await queue.onSubmittedWorkDone()` |
| `vkDeviceWaitIdle(dev)` | `await queue.onSubmittedWorkDone()` |
| `vkCreateSemaphore(dev, info)` | No-op (single queue, implicit ordering) |
| `vkCreateFence(dev, info)` | Track submission count |
| `vkWaitForFences(dev, fences, all, timeout)` | `await queue.onSubmittedWorkDone()` |
| `vkCreateSwapchainKHR(dev, info)` | `canvas.getContext('webgpu')` + `context.configure()` |
| `vkAcquireNextImageKHR(dev, swap, ...)` | `context.getCurrentTexture()` |
| `vkQueuePresentKHR(queue, info)` | (implicit on canvas texture) |

---

## Cross-Cutting Concerns

These topics apply across all tiers and D3D versions.

**Implementation Checklist:**
- [ ] Implement `requestAnimationFrame`-based frame pacing (replace `sleep()` loop)
- [ ] Implement alpha test emulation via WGSL `discard` in fragment shaders
- [ ] Implement DXT1/DXT3/DXT5 → BC1/BC2/BC3 compressed texture upload path
- [ ] Check `texture-compression-bc` feature support at adapter request time
- [ ] Implement software DXT decompression fallback for browsers without BC support
- [ ] Implement WebGPU device loss handler (`device.lost` promise) with auto-recovery
- [ ] Implement MSAA texture creation and resolve pass for games requesting multisampling
- [ ] Add VSync / frame rate cap configuration

### Frame Pacing and VSync

The current native path uses `std.Thread.sleep(16ms)` in `renderer.pushFrame()`
to cap at ~60fps. In the browser, this changes fundamentally:

- **`requestAnimationFrame`** provides natural VSync-aligned frame timing
- The emulator's main loop must become **non-blocking** — the x86 interpreter
  runs a time-budgeted slice per rAF callback rather than blocking in a sleep
- Frame presentation via `device.queue.submit()` is inherently non-blocking

```javascript
// Browser render loop
function gameLoop(timestamp) {
  const budget_ms = 16;  // ~60fps frame budget
  const deadline = performance.now() + budget_ms;

  // Run the x86 interpreter until frame budget exhausted or frame presented
  while (performance.now() < deadline) {
    const result = wasmExports.runInterpreterSlice(1000);  // run 1000 instructions
    if (result === FRAME_PRESENTED) break;  // guest called Present/Flip/Unlock
    if (result === HALTED) return;          // guest exited
  }

  requestAnimationFrame(gameLoop);
}
requestAnimationFrame(gameLoop);
```

For D3D's `Present()` and DirectDraw's `Flip()`, the call acts as the
frame boundary. The stub signals the JS host that a frame is ready, and the
host defers the next interpreter slice to the next rAF callback. This naturally
implements VSync without any explicit sleep.

**`WaitForVerticalBlank`** (DirectDraw) becomes a no-op — the rAF-driven loop
already synchronizes to vertical blank.

### Alpha Test Emulation

D3D7/8/9 provide fixed-function alpha testing via render states:
- `D3DRS_ALPHATESTENABLE` — enable/disable
- `D3DRS_ALPHAREF` — reference value (0–255)
- `D3DRS_ALPHAFUNC` — comparison function (NEVER, LESS, EQUAL, LEQUAL, etc.)

WebGPU has **no** alpha test stage. This must be emulated in the fragment shader
with a conditional `discard`. This is critical for correct rendering of foliage,
fences, text sprites, and any masked geometry:

```wgsl
// Added to all fragment shaders when alpha test is enabled
@group(0) @binding(1) var<uniform> alpha_test: AlphaTestParams;

struct AlphaTestParams {
  enabled:  u32,
  ref_val:  f32,     // alphaRef / 255.0
  func:     u32,     // D3DCMP_* enum
  _pad:     u32,
};

fn applyAlphaTest(alpha: f32) {
  if (alpha_test.enabled == 0u) { return; }
  let ref = alpha_test.ref_val;
  var pass = false;
  switch (alpha_test.func) {
    case 1u: { pass = false; }              // D3DCMP_NEVER
    case 2u: { pass = alpha < ref; }        // D3DCMP_LESS
    case 3u: { pass = alpha == ref; }       // D3DCMP_EQUAL
    case 4u: { pass = alpha <= ref; }       // D3DCMP_LESSEQUAL
    case 5u: { pass = alpha > ref; }        // D3DCMP_GREATER
    case 6u: { pass = alpha != ref; }       // D3DCMP_NOTEQUAL
    case 7u: { pass = alpha >= ref; }       // D3DCMP_GREATEREQUAL
    case 8u: { pass = true; }               // D3DCMP_ALWAYS
    default: { pass = true; }
  }
  if (!pass) { discard; }
}

// Usage in fragment shader:
@fragment
fn fs_fixed(in: VertexOutput) -> @location(0) vec4f {
  var color = computeColor(in);
  applyAlphaTest(color.a);
  return color;
}
```

**Performance note**: `discard` in fragment shaders disables early-Z on some
GPUs. Games that abuse alpha test for large-area effects (like chain-link fences
covering the screen) may see performance impact. This matches the cost of real
hardware alpha test, so it's authentic behavior.

### Compressed Texture Formats (DXT / BC)

Many Win32 games load DDS texture files with DXT-compressed data. These must be
supported for correct rendering — without them, most textured 3D games will show
solid colors or garbage.

WebGPU supports BC compression via the `texture-compression-bc` device feature:

```javascript
// Request BC texture support at device creation
const device = await adapter.requestDevice({
  requiredFeatures: ['texture-compression-bc'],
});
```

| D3D Format | DDS FourCC | WebGPU Format | Notes |
|---|---|---|---|
| `D3DFMT_DXT1` | `DXT1` | `'bc1-rgba-unorm'` | 4:1 compression, 1-bit alpha |
| `D3DFMT_DXT2` | `DXT2` | `'bc2-rgba-unorm'` | Pre-multiplied alpha (treat as DXT3) |
| `D3DFMT_DXT3` | `DXT3` | `'bc2-rgba-unorm'` | 4:1 compression, explicit alpha |
| `D3DFMT_DXT4` | `DXT4` | `'bc3-rgba-unorm'` | Pre-multiplied alpha (treat as DXT5) |
| `D3DFMT_DXT5` | `DXT5` | `'bc3-rgba-unorm'` | 4:1 compression, interpolated alpha |

The compressed data from the guest's `Lock()`/`Unlock()` or `UpdateSubresource()`
can be uploaded directly to the WebGPU texture — no decompression needed on the
CPU side. The GPU handles decompression in hardware.

```javascript
// Upload DXT-compressed texture data
device.queue.writeTexture(
  { texture: gpuTexture },
  compressedData,
  {
    bytesPerRow: Math.ceil(width / 4) * blockSize,  // 8 for BC1, 16 for BC2/BC3
    rowsPerImage: Math.ceil(height / 4),
  },
  [width, height]
);
```

**Fallback**: If `texture-compression-bc` is not available (some mobile GPU
browsers), decompress DXT→RGBA on the CPU. Libraries like `texture2ddecoder`
(JS) can do this. Performance cost is high but it's an edge case.

### WebGPU Device Loss and Recovery

WebGPU devices can be lost at any time (tab backgrounded on mobile, GPU driver
crash, OS-level GPU reset). The emulator must handle this gracefully:

```javascript
device.lost.then((info) => {
  console.error(`WebGPU device lost: ${info.reason} - ${info.message}`);

  if (info.reason === 'destroyed') {
    return;  // Intentional destruction, don't recover
  }

  // Recreate everything
  reinitializeWebGPU().then(() => {
    // Recreate all GPU resources (textures, buffers, pipelines)
    recreateAllSurfaces();
    recreatePipelineCache();
    // Resume the render loop
    requestAnimationFrame(gameLoop);
  });
});
```

**Resource tracking**: The JS host must maintain a registry of all created GPU
resources (textures, buffers, bind groups, pipelines) so they can be recreated
after device loss. The guest app's CPU-side data (surface buffers in WASM linear
memory) survives device loss — only the GPU-side mirrors need rebuilding.

**Stale handles**: D3D8/9's `TestCooperativeLevel()` and `Reset()` map
naturally to device loss recovery. When device is lost:
- `TestCooperativeLevel()` → return `D3DERR_DEVICELOST`
- Guest calls `Reset()` → trigger resource recreation
- `TestCooperativeLevel()` → return `D3D_OK` after recovery

### Multi-Sample Anti-Aliasing (MSAA)

D3D8/9/10 all support MSAA. WebGPU supports it via `sampleCount` (1, 4) on
render pipelines and textures.

| D3D Concept | WebGPU Equivalent |
|---|---|
| `D3DMULTISAMPLE_4_SAMPLES` | `sampleCount: 4` on render pipeline + MSAA texture |
| `D3DMULTISAMPLE_NONE` | `sampleCount: 1` (default) |
| `CheckDeviceMultiSampleType()` | Return `D3D_OK` for `NONE` and `4_SAMPLES`, fail others |
| MSAA render target | `createTexture({sampleCount: 4, usage: RENDER_ATTACHMENT})` |
| MSAA resolve | `resolveTarget` in color attachment → non-MSAA texture |

```javascript
// MSAA setup
const msaaTexture = device.createTexture({
  size: [width, height],
  format: canvasFormat,
  sampleCount: 4,
  usage: GPUTextureUsage.RENDER_ATTACHMENT,
});

// Render pass resolves MSAA → presentable texture
const pass = encoder.beginRenderPass({
  colorAttachments: [{
    view: msaaTexture.createView(),
    resolveTarget: context.getCurrentTexture().createView(),  // resolve here
    loadOp: 'clear',
    storeOp: 'discard',  // MSAA texture discarded after resolve
  }],
});
```

**Practical note**: Most of our target games (late 90s–2000s era) won't request
MSAA, or will check `CheckDeviceMultiSampleType()` and fall back gracefully when
it reports limited support. We can initially report only `D3DMULTISAMPLE_NONE`
as supported and add MSAA later when needed.

---

## Integration with WASM Architecture

### JS Import/Export Interface

The WASM module exports surface data pointers; the JS host handles all WebGPU
calls. Communication flows through a thin set of JS imports:

```javascript
// Imports provided to the WASM module
const wasmImports = {
  webgpu: {
    // Tier 1: framebuffer presentation
    presentFrame(bufPtr, width, height, format) { ... },

    // Tier 2: surface management
    createSurface(id, width, height, bpp) { ... },
    destroySurface(id) { ... },
    lockSurface(id) { return bufPtr; },  // returns CPU-mapped buffer address
    unlockSurface(id) { ... },          // triggers upload to GPU texture
    blitSurface(dstId, srcId, dstX, dstY, srcX, srcY, w, h, flags) { ... },
    flipSurfaces(frontId, backId) { ... },

    // Tier 3: D3D8 commands
    d3dSetTransform(type, matPtr) { ... },
    d3dSetLight(index, lightPtr) { ... },
    d3dSetMaterial(matPtr) { ... },
    d3dSetRenderState(state, value) { ... },
    d3dSetTexture(stage, surfaceId) { ... },
    d3dBeginScene() { ... },
    d3dEndScene() { ... },
    d3dClear(flags, color, z, stencil) { ... },
    d3dDrawPrimitive(type, startVertex, primCount) { ... },
    d3dDrawIndexedPrimitive(type, minIdx, numVerts, startIdx, primCount) { ... },
    d3dPresent() { ... },
    d3dCreateVertexBuffer(id, size, fvf) { ... },
    d3dCreateIndexBuffer(id, size, fmt) { ... },
    d3dLockBuffer(id) { return bufPtr; },
    d3dUnlockBuffer(id) { ... },
  }
};
```

### Conditional Compilation in Zig

The stubs use comptime platform selection to choose between native rendering
(current WebSocket path) and WebGPU:

```zig
const platform = @import("../platform/interface.zig");

fn pushSurfaceFrame() void {
    if (platform.is_wasm) {
        // WebGPU path: direct GPU upload
        platform.wasm.presentFrame(surface_buffer.ptr, display_mode_w, display_mode_h, format);
    } else {
        // Native path: existing CPU conversion + WebSocket
        // ... current code ...
        renderer.pushFrame();
    }
}
```

### Fallback: Retaining the `pushFrame` Software Path

The current CPU-side rendering path (`renderer.pushFrame()` → WebSocket → canvas)
should be preserved as a fallback for environments where WebGPU is unavailable.
This also serves as the default path during incremental development — each tier
can be brought up while the fallback handles everything else.

**Runtime detection on the JS side:**

```javascript
// host.js — detect WebGPU availability at startup
let renderBackend = 'software';  // default to CPU path

async function initRendering() {
  if (navigator.gpu) {
    const adapter = await navigator.gpu.requestAdapter();
    if (adapter) {
      const device = await adapter.requestDevice();
      if (device) {
        renderBackend = 'webgpu';
        await initWebGPU(device);
        return;
      }
    }
  }
  // WebGPU not available — fall back to existing WebSocket + Canvas2D path
  console.warn('WebGPU unavailable, using software rendering fallback');
  initSoftwareFallback();
}
```

**WASM import dispatch:** The JS host provides both backends behind the same
import names. When WebGPU is unavailable, the imports route to the existing
logic:

```javascript
function presentFrame(bufPtr, width, height, format) {
  if (renderBackend === 'webgpu') {
    presentFrameWebGPU(bufPtr, width, height, format);  // Tier 1 path
  } else {
    presentFrameSoftware(bufPtr, width, height, format); // existing pushFrame
  }
}

function presentFrameSoftware(bufPtr, width, height, format) {
  // Recreate the current behavior: read pixels from WASM memory,
  // convert BGRA→RGBA, draw onto a Canvas2D context, and display.
  const pixels = new Uint8Array(wasmMemory.buffer, bufPtr, width * height * 4);
  const imageData = new ImageData(width, height);
  for (let i = 0; i < width * height; i++) {
    imageData.data[i * 4 + 0] = pixels[i * 4 + 2]; // R ← B
    imageData.data[i * 4 + 1] = pixels[i * 4 + 1]; // G
    imageData.data[i * 4 + 2] = pixels[i * 4 + 0]; // B ← R
    imageData.data[i * 4 + 3] = 255;                // A
  }
  ctx2d.putImageData(imageData, 0, 0);
}
```

**Zig-side comptime selection:** For the native Linux target, the existing
WebSocket-based `renderer.pushFrame()` path remains completely unchanged.
The platform abstraction selects the right path:

```zig
// In any stub's frame presentation function
fn pushSurfaceFrame() void {
    if (comptime platform.is_wasm) {
        // WASM target: call JS import (which internally picks WebGPU or Canvas2D)
        const format: u32 = if (display_mode_bpp == 16) 1 else 0;
        platform.wasm.presentFrame(surface_buffer.ptr, display_mode_w, display_mode_h, format);
    } else {
        // Native target: existing pixel conversion + WebSocket push (unchanged)
        convertAndCopyToFramebuf();
        renderer.pushFrame();
    }
}
```

**Tier-level fallback:** Even within the WASM target, higher tiers can fall
back to lower tiers. If Tier 3 (D3D fixed-function) encounters an unimplemented
D3D call, it can silently render via Tier 1 (framebuffer upload) by having the
stub write to a CPU surface buffer and calling `presentFrame`. This means
partially-implemented D3D support still produces visible output:

```
Tier 8 (Vulkan) ─unsupported──→ Tier 7 (D3D12) ─unsupported──→ Tier 6 (D3D11)
                                                                     │
                                                             unsupported call?
                                                                     ↓
Tier 5 (D3D10) ─unsupported──→ Tier 4 (D3D9) ─unsupported──→ Tier 3 (D3D7/8)
                                                                   │
                                                           unsupported call?
                                                                   ↓
                                     Tier 1 (framebuffer upload via presentFrame)
```

---

## Implementation Phases

### Phase A: Tier 1 Only (1 week)
- Add `presentFrame` JS import to `platform/wasm.zig`
- Implement WebGPU canvas setup + fullscreen quad pipeline in `host.js`
- Wire up ddraw `Unlock`/`Flip` and d3d8 `Present` to call `presentFrame`
- Result: all games that software-render work with GPU-accelerated display

### Phase B: Tier 2 Surfaces (1-2 weeks)
- Replace the surface pool (`surface_pool[]`) with GPU-backed surfaces
- Implement `Lock`/`Unlock` via staging buffers
- Implement `Blt`/`BltFast` via `copyTextureToTexture`
- Add RGB565 compute shader and color key fragment shader
- Result: DirectDraw games with multi-surface blitting work

### Phase C: Tier 3 D3D7/D3D8 Pipeline (2-3 weeks)
- Implement uniform buffer management for transforms/lights/materials
- Write WGSL fixed-function vertex and fragment shaders
- Implement pipeline state caching
- Map `CreateVertexBuffer`/`CreateIndexBuffer` to GPU buffers
- Wire up `DrawPrimitive`/`DrawIndexedPrimitive`
- Create `d3d7.zig` stub module (IDirect3D7/IDirect3DDevice7) sharing the
  same WebGPU backend as D3D8
- Result: D3D7 and D3D8 games with basic 3D rendering work

### Phase D: Tier 4 D3D9 Shader Support (3-4 weeks)
- Build SM2/SM3 bytecode translator (DXBC → WGSL)
- Implement vertex declaration → vertex buffer layout converter
- Add per-stage sampler state management
- Implement shader constant register file as uniform buffers
- Create `d3d9.zig` stub module (IDirect3D9/IDirect3DDevice9)
- Support fixed-function fallback via Tier 3 shaders
- Result: D3D9 games with both fixed-function and shader-based rendering work

### Phase E: Tier 5 D3D10 Pipeline (4-6 weeks)
- Build SM4 bytecode translator (DXBC → WGSL)
- Implement constant buffer management (direct WebGPU uniform buffer mapping)
- Implement geometry shader emulation via compute pre-pass
- Map D3D10 state objects to WebGPU pipeline descriptors
- Create `d3d10.zig` stub module (ID3D10Device)
- Result: D3D10 games with vertex+pixel shaders work; geometry shader support
  for common patterns (point sprites, billboards)

### Phase F: Tier 6 D3D11 Pipeline (6-8 weeks)
- Extend SM4 translator to SM5 (new opcodes, doubled limits)
- Implement compute shader support (DirectCompute → WebGPU compute pipelines)
- Implement tessellation emulation via compute pre-pass
- Implement device/context split (ID3D11Device + ID3D11DeviceContext)
- Implement feature level reporting
- Create `d3d11.zig` stub module
- Result: D3D11 games with VS+PS+CS work; tessellation for common patterns

### Phase G: Tier 7 D3D12 Pipeline (6-10 weeks)
- Map command list model to WebGPU command encoders
- Map PSO creation to GPURenderPipeline / GPUComputePipeline
- Map root signatures to pipeline layouts + bind group layouts
- Implement descriptor heap management as bind group pools
- Implement resource barrier stubs (no-ops)
- Implement fence/sync via onSubmittedWorkDone
- Extend bytecode translator for SM5.1+ features
- Create `d3d12.zig` stub module
- Result: D3D12 games that don't use advanced features (mesh shaders, raytracing)

### Phase H: Tier 8 Vulkan Pipeline (4-6 weeks)
- Integrate naga (or Tint) SPIR-V→WGSL translator compiled to WASM
- Map Vulkan descriptor sets to WebGPU bind groups
- Map Vulkan command buffers to WebGPU command encoders
- Implement memory management stubs (VkDeviceMemory → no-ops)
- Implement push constant emulation via dynamic uniform buffer
- Implement render pass/subpass translation
- Implement synchronization stubs (semaphores/fences → simplified)
- Create `vulkan-1.zig` stub module
- Result: Vulkan games with standard features work; most concepts map 1:1

### Phase I: Refinement (ongoing)
- Add texture stage state support (multiple texture stages for D3D7/8)
- Implement more blend modes and comparison functions
- Add specular highlights and per-pixel fog
- Support `DrawPrimitiveUP` / `DrawIndexedPrimitiveUP` (inline vertex data)
- Profile and optimize texture upload paths
- Handle edge cases: lost devices, mode switches, GDI interop
- Expand geometry shader emulation coverage
- Add floating-point texture format support (D3D9/10 HDR rendering)

---

## Open Questions

1. **Vertex format detection**: D3D7/8 use FVF (Flexible Vertex Format) flags to
   describe vertex layout. We need to parse FVF at `SetVertexShader(fvf)` time
   and create matching `GPUVertexBufferLayout` descriptors. How many distinct
   FVF combinations do our target games actually use?

2. **Texture format mapping**: D3D8 supports ~20, D3D9 ~40, D3D10 ~50+ texture
   formats (`D3DFMT_*` / `DXGI_FORMAT_*`). We should audit which formats our
   target games create and map only those. Priority: `A8R8G8B8`, `X8R8G8B8`,
   `R5G6B5`, `A1R5G5B5`, `DXT1/3/5`, `R32F`, `R16F`.

3. **Multi-texturing**: D3D7/8 support up to 8 texture stages with configurable
   operations (modulate, add, blend, etc.). How many stages do our target
   games actually use? Most use 1-2.

4. **Render targets**: D3D8/9/10 games render to off-screen textures, then
   use those as inputs. This maps naturally to WebGPU's render-to-texture
   capability, but adds complexity to surface management.

5. **Shader bytecode translation complexity**: SM2/3 bytecode is simple (~100
   opcodes, register-based). SM4 is more complex (DXBC container format,
   structured buffers, typed resources). Should we build a standalone
   translator or use an existing library like `spirv-cross` compiled to WASM?

6. **Geometry shader prevalence**: How many of our target D3D10 games actually
   use geometry shaders? If rare, we can defer GS emulation and focus on
   VS+PS support. Games that only use GS for point sprites are easy; complex
   topology manipulation is hard.

7. **Tessellation prevalence and complexity**: How many of our target D3D11
   games use tessellation heavily? Games that only use it for terrain or water
   LOD may work fine with a compute pre-pass. Games with heavy character
   tessellation (e.g., Crysis 2) will be more demanding.

8. **D3D12 command list granularity**: D3D12 apps may submit many small command
   lists per frame. Does WebGPU's `queue.submit()` handle this efficiently, or
   should we batch multiple D3D12 command lists into a single `GPUCommandBuffer`?

9. **SM6 features**: D3D12 games may use SM6.x features (wave intrinsics, mesh
   shaders, raytracing). Wave intrinsics map to WGSL subgroup operations (partial
   support). Mesh shaders and raytracing have no WebGPU equivalent. Should we
   detect and reject these, or try partial emulation?

10. **Vulkan subpass emulation**: Vulkan render passes support multiple subpasses
    with dependencies (used for deferred rendering, tiled GPUs). WebGPU has no
    subpass concept. Should we split multi-subpass render passes into multiple
    WebGPU render passes, or try to merge them when possible?

11. **SPIR-V extension coverage**: Vulkan games may use SPIR-V extensions
    (e.g., `SPV_KHR_ray_tracing`, `SPV_KHR_mesh_shader`). The naga translator
    handles core SPIR-V well but may not support all extensions. Which extensions
    do our target games actually use?

12. **Fallback granularity**: The fallback strategy (see "Retaining the
    `pushFrame` Software Path" section) describes runtime WebGPU detection
    and tier-level fallback. The remaining question is: should we also support
    **per-feature** fallback within a tier (e.g., fall back to CPU for
    unsupported texture formats while using WebGPU for everything else)?

---

## Alternative: wgpu-native for Desktop Rendering

All the WebGPU translation work described in this document targets the browser
via WASM. But what if we could use the **exact same WebGPU rendering code** on
the native desktop target too? That's what wgpu-native enables.

### What is wgpu-native?

[wgpu](https://github.com/gfx-rs/wgpu) is Mozilla's Rust implementation of the
WebGPU specification. It runs natively on desktop/mobile by translating WebGPU
calls to the platform's native API:

| Platform | Backend |
|---|---|
| Windows | Vulkan or Direct3D 12 |
| macOS / iOS | Metal |
| Linux | Vulkan |
| Android | Vulkan |
| Web (WASM) | Browser's native WebGPU |

[wgpu-native](https://github.com/gfx-rs/wgpu-native) exposes wgpu's
functionality via a C API conforming to the
[webgpu.h](https://github.com/webgpu-native/webgpu-headers) header — the
emerging standard C interface for WebGPU. This means any code written against
`webgpu.h` works on both wgpu-native (desktop) and browser WebGPU (WASM).

### Why This Matters for Zine

Currently, Zine's native target renders via CPU pixel conversion → WebSocket →
browser canvas. This is inherently slow and requires a browser to be open.
With wgpu-native, we could:

```
Current native path:       Guest → CPU framebuffer → WebSocket → Browser canvas
                                                      (slow, requires browser)

wgpu-native path:          Guest → WebGPU calls → wgpu-native → Vulkan/Metal/D3D12 → Native window
                                                      (fast, standalone, no browser needed)

WASM path (unchanged):     Guest → WebGPU calls → Browser WebGPU → Canvas
                                                      (fast, runs in browser)
```

**One rendering backend, two targets** — the same `presentFrame()`,
`drawPrimitive()`, shader translation, and pipeline management code runs on
both WASM and native.

### Architecture: Unified WebGPU Backend

```
                    ┌─── WASM target ───────────┐
                    │  JS host calls browser     │
                    │  WebGPU API directly       │
Zine Stubs ────┐    │                            │
(ddraw, d3d9,  │    ├─── Native target ──────────┤
 d3d11, etc.)  ├──→ │  webgpu.h C API calls      │
               │    │  wgpu-native library        │
               │    │  → Vulkan / Metal / D3D12   │
               └────┤                            │
                    └────────────────────────────┘
                    ↑
              Same WebGPU code
              (shaders, pipelines, state management)
```

### Zig Integration via webgpu.h

The `webgpu.h` header defines a standard C API that Zig can consume directly
via `@cImport`. Both wgpu-native and Dawn (Google's C++ implementation)
conform to this header:

```zig
// platform/webgpu.zig — unified WebGPU interface
const c = @cImport({
    @cInclude("webgpu.h");
});

pub const Device = c.WGPUDevice;
pub const Queue = c.WGPUQueue;
pub const RenderPipeline = c.WGPURenderPipeline;
pub const CommandEncoder = c.WGPUCommandEncoder;
pub const TextureFormat = c.WGPUTextureFormat;

pub fn createShaderModule(device: Device, wgsl_code: []const u8) c.WGPUShaderModule {
    const descriptor = c.WGPUShaderModuleWGSLDescriptor{
        .chain = .{ .sType = c.WGPUSType_ShaderModuleWGSLDescriptor },
        .code = wgsl_code.ptr,
    };
    return c.wgpuDeviceCreateShaderModule(device, &.{
        .nextInChain = @ptrCast(&descriptor),
    });
}

pub fn presentFrame(device: Device, queue: Queue, texture_view: c.WGPUTextureView,
                     pipeline: RenderPipeline, bind_group: c.WGPUBindGroup) void {
    const encoder = c.wgpuDeviceCreateCommandEncoder(device, null);
    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
        .colorAttachmentCount = 1,
        .colorAttachments = &.{.{
            .view = texture_view,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
        }},
    });
    c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
    c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
    c.wgpuRenderPassEncoderEnd(pass);
    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuQueueSubmit(queue, 1, &cmd_buf);
}
```

### Platform Abstraction

The platform layer selects the backend at comptime:

```zig
// platform/interface.zig
const builtin = @import("builtin");

pub const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const gpu = if (is_wasm)
    @import("wasm_webgpu.zig")    // Calls JS host via imports
else
    @import("native_webgpu.zig"); // Calls wgpu-native via @cImport

// Both expose the same interface:
//   gpu.init() → Device, Queue
//   gpu.presentFrame(buffer, w, h, format)
//   gpu.createPipeline(desc) → RenderPipeline
//   gpu.createTexture(desc) → Texture
//   etc.
```

### Comparison: wgpu-native vs Dawn

Two major native WebGPU implementations exist:

| Aspect | wgpu-native | Dawn |
|---|---|---|
| **Language** | Rust | C++ |
| **Maintainer** | Mozilla / gfx-rs team | Google (Chrome team) |
| **C API** | `webgpu.h` conformant | `webgpu.h` conformant |
| **Backends** | Vulkan, Metal, D3D12, OpenGL (fallback) | Vulkan, Metal, D3D12 |
| **Binary size** | ~5–10 MB (release) | ~10–15 MB (release) |
| **Zig integration** | Easy (`@cImport` + link `libwgpu_native.a`) | Harder (C++ build system, larger) |
| **Existing Zig bindings** | [wgpu_native_zig](https://github.com/bronter/wgpu_native_zig), [zig-wgpu-native](https://github.com/silverclaw/zig-wgpu-native) | Limited |
| **Pre-built binaries** | Yes (all major platforms) | Build from source |
| **WASM target** | Passes through to browser WebGPU | Passes through to browser WebGPU |

**Recommendation**: wgpu-native is the better fit for Zine because:
- Zig can link it as a static library with `@cImport`
- Pre-built binaries are available for Windows/macOS/Linux
- Smaller binary footprint
- Active Zig community support

### Build Integration

```zig
// build.zig — link wgpu-native
const wgpu_dep = b.dependency("wgpu-native", .{ .target = target, .optimize = optimize });
exe.linkLibrary(wgpu_dep.artifact("wgpu_native"));
exe.addIncludePath(wgpu_dep.path("include"));

// For WASM target, don't link wgpu-native — use JS imports instead
if (target.cpu_arch != .wasm32) {
    exe.linkLibrary(wgpu_dep.artifact("wgpu_native"));
}
```

### Benefits of the Unified Approach

| Benefit | Impact |
|---|---|
| **Single rendering codebase** | All shader code, pipeline management, state tracking shared between WASM and native |
| **No WebSocket dependency** | Native target renders directly to a window — no browser needed |
| **Better native performance** | GPU-accelerated rendering with proper VSync, no WebSocket frame serialization |
| **Easier testing** | Test rendering on desktop, deploy to browser — same code |
| **Windowing** | Use GLFW or SDL2 on native for window management (wgpu-native supports both) |
| **Debuggable** | WebGPU debugging tools (RenderDoc, Xcode GPU debugger) work on native |

### Native Window Setup

For the native target, we need a window to render into. wgpu-native can create
a surface from GLFW, SDL2, or raw platform handles:

```zig
// platform/native_webgpu.zig — window + surface setup
const glfw = @cImport(@cInclude("GLFW/glfw3.h"));
const wgpu = @cImport(@cInclude("webgpu.h"));

pub fn init(width: u32, height: u32) !struct { Device, Queue, Surface } {
    // Create window
    glfw.glfwInit();
    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    const window = glfw.glfwCreateWindow(width, height, "Zine", null, null);

    // Create WebGPU instance + surface from window
    const instance = wgpu.wgpuCreateInstance(null);
    const surface = wgpu.wgpuInstanceCreateSurface(instance, &.{
        // Platform-specific: HWND on Windows, CAMetalLayer on macOS, etc.
        // GLFW helpers handle this automatically
    });

    // Request adapter + device (same as browser path)
    const adapter = requestAdapter(instance, surface);
    const device = requestDevice(adapter);
    const queue = wgpu.wgpuDeviceGetQueue(device);

    return .{ device, queue, surface };
}
```

---

## Alternative: DXVK as Universal Translation Layer

Instead of implementing Tiers 3–7 (D3D7 through D3D12) individually, we could
use **DXVK** to translate all Direct3D calls into Vulkan, and then only
implement the Vulkan → WebGPU layer (Tier 8). This dramatically reduces the
amount of custom translation code.

### What is DXVK?

[DXVK](https://github.com/doitsujin/dxvk) is a Vulkan-based translation layer
for Direct3D. It's the core technology behind Steam's Proton and Wine's D3D
support:

| DXVK Module | Translates | Status |
|---|---|---|
| `d3d9.dll` (DXVK) | D3D9 → Vulkan | Mature, production-ready |
| `d3d10.dll` / `d3d10_1.dll` | D3D10/10.1 → Vulkan | Mature |
| `d3d11.dll` (DXVK) | D3D11 → Vulkan | Mature, production-ready |
| `dxgi.dll` (DXVK) | DXGI → Vulkan WSI | Mature |
| `d3d8.dll` ([d3d8to9](https://github.com/crosire/d3d8to9)) | D3D8 → D3D9 | Stable |
| `ddraw.dll` ([dxWrapper](https://github.com/elishacloud/dxwrapper)) | DDraw/D3D7 → D3D9 | Stable |

With d3d8to9 + dxWrapper feeding into DXVK, the entire D3D stack (DDraw through
D3D11) collapses into Vulkan calls.

### Architecture: DXVK Approach vs Direct Approach

**Direct approach** (Tiers 1–7, as documented above):
```
Game ────┬── DDraw calls ──→ ddraw.zig stub ───→ WebGPU (Tier 1/2)
        ├── D3D7 calls  ──→ d3d7.zig stub  ───→ WebGPU (Tier 3)
        ├── D3D8 calls  ──→ d3d8.zig stub  ───→ WebGPU (Tier 3)
        ├── D3D9 calls  ──→ d3d9.zig stub  ───→ WebGPU (Tier 4)
        ├── D3D10 calls ──→ d3d10.zig stub ───→ WebGPU (Tier 5)
        ├── D3D11 calls ──→ d3d11.zig stub ───→ WebGPU (Tier 6)
        └── D3D12 calls ──→ d3d12.zig stub ───→ WebGPU (Tier 7)
                         7 translation layers to build & maintain
```

**DXVK approach** (DDraw→D3D11 all route through Vulkan):
```
Game ────┬── DDraw calls ──→ dxWrapper ─┬──→ DXVK d3d9 ─┬──→ Vulkan calls ──→ vulkan.zig ──→ WebGPU
        ├── D3D7 calls  ──→ dxWrapper ─┘             │
        ├── D3D8 calls  ──→ d3d8to9  ───────────┘             │
        ├── D3D9 calls  ──→ DXVK d3d9  ────────────────────┤
        ├── D3D10 calls ──→ DXVK d3d10 ────────────────────┤
        ├── D3D11 calls ──→ DXVK d3d11 ────────────────────┘
        └── D3D12 calls ──→ vkd3d-proton ──────────────────┘
                         1 translation layer to build (Vulkan → WebGPU)
```

### Pros vs Cons

| Aspect | Direct (Tiers 3–7) | DXVK + Vulkan→WebGPU |
|---|---|---|
| **Translation layers to build** | 7 (one per D3D version) | 1 (Vulkan → WebGPU only) |
| **Shader translation** | 3 bytecode formats (SM1–3, SM4, SM5) | 1 (SPIR-V → WGSL via naga) |
| **Game compatibility** | We implement what we need | DXVK already handles thousands of games |
| **Code to maintain** | Large (all D3D APIs) | Small (just Vulkan layer) |
| **Correctness risk** | High (our D3D emulation may have bugs) | Low (DXVK is battle-tested) |
| **Performance overhead** | 1 translation hop | 2 hops (D3D → Vulkan → WebGPU) |
| **Binary size** | Smaller (Zig stubs only) | Larger (DXVK is ~5MB compiled) |
| **Build complexity** | Simpler (pure Zig) | Harder (DXVK is C++, needs cross-compilation to WASM) |
| **D3D12 support** | Our stubs | vkd3d-proton (separate project, also mature) |
| **Runtime dependency** | None | DXVK + d3d8to9 + dxWrapper as WASM modules |

### How It Would Work in Zine

1. **Compile DXVK to WASM**: DXVK is C++ and uses Vulkan as its backend. We
   would compile it (or a stripped-down subset) to WASM, with the Vulkan ICD
   (Installable Client Driver) pointing to our `vulkan-1.zig` stub.

2. **Load as DLL shims**: When the guest app loads `d3d9.dll`, instead of our
   minimal Zig stub, it loads the DXVK version. DXVK internally calls Vulkan
   functions, which our Vulkan stub translates to WebGPU.

3. **Shader pipeline**: Game → HLSL bytecode → DXVK translates to SPIR-V →
   our Vulkan stub sends SPIR-V to naga → WGSL → WebGPU shader module.

```
Game (HLSL bytecode) ──→ DXVK (SPIR-V) ──→ vulkan.zig ──→ naga (WGSL) ──→ WebGPU
```

### Build Strategy

```bash
# 1. Cross-compile DXVK to WASM (needs wasi-sdk or emscripten)
#    Strip out Linux/Windows-specific Vulkan loader code
#    Replace with direct function calls to our vulkan-1.zig exports

# 2. Cross-compile d3d8to9 to WASM (small C++ shim)

# 3. Cross-compile naga SPIR-V frontend to WASM (Rust → wasm32-wasi)

# 4. Link everything:
#    Guest PE   →  loads d3d9.dll (DXVK)   →  Vulkan calls
#              →  loads d3d8.dll (d3d8to9) →  D3D9 calls → DXVK → Vulkan calls
#    vulkan-1.zig  →  Vulkan → WebGPU (our only custom code)
```

### Key Challenges

1. **DXVK binary size**: Full DXVK is ~5MB compiled. For WASM, every byte counts.
   We may need to strip features (e.g., HUD overlay, advanced extension support)
   to reduce size.

2. **C++ to WASM compilation**: DXVK uses modern C++17 with templates, smart
   pointers, and STL. Cross-compiling to WASM via wasi-sdk or emscripten is
   feasible but requires patching platform-specific code (threading, file I/O,
   windowing).

3. **Threading model**: DXVK uses a background compilation thread for shader
   pipelines. In our single-threaded WASM environment, this must become
   synchronous. DXVK has a `dxvk.enableAsync = false` mode for this.

4. **Vulkan ICD shim**: DXVK expects to load `vulkan-1.dll` at runtime via the
   loader. In our WASM build, we'd link directly against our `vulkan-1.zig`
   exports, bypassing the loader entirely.

5. **vkd3d-proton for D3D12**: This is a separate project from DXVK (by the same
   team). It translates D3D12 → Vulkan. Same build/integration challenges apply.

### Recommended Hybrid Strategy

The most pragmatic approach combines both strategies:

| API | Strategy | Rationale |
|---|---|---|
| DirectDraw (2D) | **Direct** (Tiers 1–2) | Simple blitting, no 3D pipeline. DXVK overkill. |
| D3D7 | **Direct** (Tier 3) or dxWrapper→DXVK | Few games; direct stub is simpler if scope is small. |
| D3D8 | **d3d8to9 + DXVK** | Avoids building a separate D3D8 backend entirely. |
| D3D9 | **DXVK** | DXVK's D3D9 support is rock-solid. Saves months of work. |
| D3D10/10.1 | **DXVK** | Handled by same DXVK binary. |
| D3D11 | **DXVK** | Most games. DXVK handles this perfectly. |
| D3D12 | **vkd3d-proton** | If D3D12 games are in scope. |
| Vulkan (native) | **Direct** (Tier 8) | Games that already use Vulkan need no DXVK. |

This gives us:
- **Tier 1–2**: Direct (DirectDraw → WebGPU) — small, simple
- **Tier 3**: Direct (D3D7 → WebGPU) — only if D3D7 games are high priority
- **DXVK**: D3D8/9/10/11 → Vulkan — battle-tested, huge game coverage
- **Tier 8**: Direct (Vulkan → WebGPU) — the one layer we always need

### Implementation Estimate (DXVK Path)

| Phase | Work | Timeline |
|---|---|---|
| Build Vulkan→WebGPU layer (Tier 8) | Core translation | 4–6 weeks |
| Compile naga to WASM | SPIR-V → WGSL | 1–2 weeks |
| Compile DXVK to WASM | Cross-compilation + patching | 3–4 weeks |
| Compile d3d8to9 to WASM | Simple C++ shim | 1 week |
| Integration testing | Wire up PE loader + DLL shims | 2–3 weeks |
| **Total** | | **~11–16 weeks** |

Compare to the direct approach total: Phase C + D + E + F + G = 2–3 + 3–4 +
4–6 + 6–8 + 6–10 = **21–31 weeks** for Tiers 3–7.

The DXVK path is roughly **half the development time** and produces better
compatibility because DXVK has been tested against thousands of real games.

### Decision Criteria

Choose the **direct path** if:
- You need minimal binary size (no C++ dependencies)
- You want full control over the translation for debugging/optimization
- Your target game list is small and well-defined
- You want to avoid C++ cross-compilation complexity

Choose the **DXVK path** if:
- You want maximum game compatibility with minimum effort
- D3D9–11 games are a high priority
- You're willing to invest in the C++ → WASM build pipeline
- Binary size isn't a critical constraint (~5–10MB for DXVK+naga)

> **⚠ Feasibility Note:** Research indicates that compiling DXVK to WASM is
> *theoretically possible* but faces several non-trivial challenges:
> - DXVK uses C++17 with heavy STL/template usage; emscripten can compile it
>   but platform-specific code (threading, windowing, file I/O) must be patched
> - DXVK expects a Vulkan ICD at link time; in WASM this becomes direct calls
>   to our `vulkan-1.zig` exports (no loader)
> - DXVK's async shader compilation thread must become synchronous
>   (`dxvk.enableAsync = false`)
> - No known project has successfully compiled DXVK to WASM as of early 2026;
>   this would be a novel effort
> - An alternative is [vkQuake](https://github.com/nicoverbruggen/vkQuake3)
>   or other small Vulkan apps as a proof-of-concept for the Vulkan→WebGPU layer
>   before attempting DXVK

---

## References

### Specifications

- [WebGPU Specification (W3C)](https://www.w3.org/TR/webgpu/) — the official API spec
- [WGSL Specification (W3C)](https://www.w3.org/TR/WGSL/) — WebGPU Shading Language
- [WebGPU Explainer](https://gpuweb.github.io/gpuweb/explainer/) — design rationale and overview
- [SPIR-V Specification (Khronos)](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
- [Vulkan Specification (Khronos)](https://registry.khronos.org/vulkan/specs/1.3-extensions/html/vkspec.html)

### Browser Support

- [caniuse.com — WebGPU](https://caniuse.com/webgpu) — ~83% global coverage (Dec 2025)
- Chrome: stable since v113 (Windows/macOS/ChromeOS), Android v121+
- Firefox: stable since v141 (Windows), v145 (macOS ARM64)
- Safari: stable since v26.0 (macOS Tahoe 26, iOS 26, iPadOS 26)
- [WebGPU Status](https://github.com/nicoverbruggen/webgpu-status) — live tracking

### Shader Translation Tools

- [naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga) — Rust shader translator
  (SPIR-V/GLSL/HLSL ↔ WGSL), part of the wgpu project. v28.0 (Dec 2025).
  Compiles to WASM via `wasm32-unknown-unknown` target.
- [Tint](https://dawn.googlesource.com/tint/) — Google's C++ WGSL compiler,
  part of the Dawn WebGPU implementation. Handles SPIR-V ↔ WGSL.
- [spirv-cross](https://github.com/KhronosGroup/SPIRV-Cross) — Khronos SPIR-V
  reflection and cross-compilation library (SPIR-V → GLSL/HLSL/MSL).

### Direct3D Documentation

- [DirectDraw Reference (MSDN)](https://learn.microsoft.com/en-us/windows/win32/directdraw/directdraw-reference)
- [Direct3D 7 Reference (MSDN)](https://learn.microsoft.com/en-us/windows/win32/direct3d7/dx8-notavail)
- [Direct3D 8 Reference (MSDN)](https://learn.microsoft.com/en-us/windows/win32/direct3d8/dx8-graphics-reference)
- [Direct3D 9 Programming Guide](https://learn.microsoft.com/en-us/windows/win32/direct3d9/dx9-graphics-programming-guide)
- [Direct3D 10 Programming Guide](https://learn.microsoft.com/en-us/windows/win32/direct3d10/d3d10-graphics-programming-guide)
- [Direct3D 11 Programming Guide](https://learn.microsoft.com/en-us/windows/win32/direct3d11/dx-graphics-overviews)
- [Direct3D 12 Programming Guide](https://learn.microsoft.com/en-us/windows/win32/direct3d12/directx-12-programming-guide)
- [HLSL Shader Model Reference](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-models)

### Translation Layers & Related Projects

- [DXVK](https://github.com/doitsujin/dxvk) — D3D9/10/11 → Vulkan translation
  layer (C++). Core of Steam Proton.
- [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) — D3D12 →
  Vulkan translation layer. Fork of Wine's vkd3d.
- [d3d8to9](https://github.com/crosire/d3d8to9) — D3D8 → D3D9 shim (C++).
- [dxwrapper](https://github.com/elishacloud/dxwrapper) — DDraw/D3D1–7 → D3D9
  wrapper with compatibility fixes.
- [WineD3D](https://wiki.winehq.org/WineD3D) — Wine's D3D → OpenGL translation;
  reference for API coverage and edge cases.
- [Mesa / Zink](https://docs.mesa3d.org/drivers/zink.html) — OpenGL → Vulkan
  translation layer (relevant if OpenGL games are ever in scope).
- [ANGLE](https://chromium.googlesource.com/angle/angle/) — OpenGL ES → Vulkan/
  Metal/D3D11 translation; used by Chrome for WebGL.

### Native WebGPU Implementations

- [wgpu](https://github.com/gfx-rs/wgpu) — Rust WebGPU implementation by
  Mozilla / gfx-rs. Backends: Vulkan, Metal, D3D12, OpenGL.
- [wgpu-native](https://github.com/gfx-rs/wgpu-native) — C API bindings for
  wgpu, conforming to the `webgpu.h` header. Pre-built binaries available.
- [Dawn](https://dawn.googlesource.com/dawn/) — Google's C++ WebGPU
  implementation, used by Chrome. Also exposes `webgpu.h` C API.
- [webgpu.h](https://github.com/webgpu-native/webgpu-headers) — standard C
  header for native WebGPU, shared by wgpu-native and Dawn.
- [wgpu_native_zig](https://github.com/bronter/wgpu_native_zig) — Zig bindings
  for wgpu-native (both raw C and idiomatic Zig APIs).
- [zig-wgpu-native](https://github.com/silverclaw/zig-wgpu-native) — alternative
  Zig bindings for wgpu-native.

### WebGPU Learning Resources

- [WebGPU Fundamentals](https://webgpufundamentals.org/) — comprehensive tutorials
- [WebGPU Samples](https://webgpu.github.io/webgpu-samples/) — official samples
- [Tour of WGSL](https://google.github.io/tour-of-wgsl/) — interactive WGSL learning
- [Raw WebGPU](https://alain.xyz/blog/raw-webgpu/) — low-level tutorial
