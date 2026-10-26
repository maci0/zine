//! JIT host interface and CPU state transfer struct.
//!
//! Defines the interface between JIT-compiled WASM blocks and the host
//! runtime (browser, wasmtime, wasmer). Uses a state-via-memory approach:
//! CPU registers are read/written from a fixed struct in WASM linear memory.

const std = @import("std");

/// CPU state transfer struct for JIT compiled blocks.
/// Lives at a known address in WASM linear memory (64 bytes).
/// JIT'd functions load registers on entry and store back on exit.
pub const JitCpuState = extern struct {
    // General purpose registers (offsets 0–31)
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    // Instruction pointer (offset 32)
    eip: u32 = 0,
    // Packed EFLAGS (offset 36)
    eflags: u32 = 0x202,
    // Execution status (offset 40): 0=continue, 1=exit to interpreter
    status: u32 = 0,
    // Memory base adjustment: wasm_linear_offset - guest_va_base (offset 44).
    // Added to guest virtual addresses before WASM memory load/store ops.
    mem_base: i32 = 0,
    // Guest FS segment base (offset 48) — TEB address. Needed for FS-relative
    // memory ops (SEH chain install/read: mov fs:[0], esp).
    fs_base: u32 = 0,
    // Padding to 64 bytes (offsets 52–63)
    _pad: [3]u32 = @splat(0),

    // Field offsets for WASM code generation (used by compiler.zig prologue/epilogue)
    pub const OFF_EIP: u32 = 32;
    pub const OFF_EFLAGS: u32 = 36;
    pub const OFF_STATUS: u32 = 40;
    pub const OFF_MEM_BASE: u32 = 44;
    pub const OFF_FS_BASE: u32 = 48;
    pub const SIZE: u32 = 64;

    // Status codes
    pub const STATUS_CONTINUE: u32 = 0;
    pub const STATUS_EXIT_TO_INTERP: u32 = 1;

    comptime {
        std.debug.assert(@sizeOf(JitCpuState) == SIZE);
    }
};

/// Opaque block identifier returned by the host's compile import.
pub const BlockId = u32;
