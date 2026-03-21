# Pitfalls Research

## 1. Threading Race Conditions in Interpreter
- **Risk:** HIGH — Guest threads sharing memory through the interpreter's single GuestMemory
- **Warning signs:** Intermittent crashes, corrupted data, deadlocks
- **Prevention:** Use host-level locks on GuestMemory write operations; ensure CPU state is fully isolated per thread
- **Phase:** Threading implementation

## 2. D3D7 COM Vtable ABI Mismatch
- **Risk:** HIGH — Already hit this with DirectSound (32-bit vtable pointers stored as u32 not usize)
- **Warning signs:** Crashes on second vtable call, wrong function called
- **Prevention:** All COM vtable entries must be 4-byte `u32` function pointers matching x86 ABI, even on x86_64 host
- **Phase:** D3D7 rendering

## 3. D3D7 Render State Explosion
- **Risk:** MEDIUM — D3D7 has 150+ render states, games set many combinations
- **Warning signs:** Missing visual effects, wrong blending, objects invisible
- **Prevention:** Implement states incrementally; trace which states Europa 1400 actually uses before implementing all
- **Phase:** D3D7 rendering

## 4. Font Mapping Complexity
- **Risk:** MEDIUM — Windows font matching (LOGFONT → physical font) is notoriously complex
- **Warning signs:** Wrong font sizes, missing glyphs, text overflow
- **Prevention:** Start with a hardcoded bitmap font fallback for common faces (Arial, Times, MS Sans Serif); add TTF loading later
- **Phase:** GDI fonts

## 5. WASM Threading Limitations
- **Risk:** HIGH — WASM doesn't have native threads; SharedArrayBuffer requires COOP/COEP headers
- **Warning signs:** Threading works on native but not WASM
- **Prevention:** Design threading abstraction that can use cooperative scheduling on WASM; use platform abstraction layer
- **Phase:** Threading (WASM target)

## 6. JIT State Synchronization
- **Risk:** MEDIUM — Compiled WASM blocks must read/write the same CPU state as interpreter
- **Warning signs:** Wrong register values after JIT block executes
- **Prevention:** Define clear JitCpuState memory layout; verify with existing validation-mode comparison
- **Phase:** JIT execution

## 7. Guest Stack Size
- **Risk:** LOW — Win32 default thread stack is 1MB; allocating many stacks eats guest address space
- **Warning signs:** Stack overflow crashes in guest code
- **Prevention:** Use 256KB default stacks (most games don't need full 1MB); allow configuration
- **Phase:** Threading

## 8. DirectDraw ↔ Direct3D7 Surface Sharing
- **Risk:** MEDIUM — D3D7 renders to DirectDraw surfaces; existing DDraw code must interop cleanly
- **Warning signs:** Black screen despite D3D7 drawing, double-present, flicker
- **Prevention:** Ensure D3D7 device writes to the same framebuffer that DDraw presents
- **Phase:** D3D7 rendering
