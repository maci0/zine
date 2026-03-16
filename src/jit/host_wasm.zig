//! WASM guest JIT host implementation.
//!
//! Uses extern imports in the "jit" namespace, provided by the host
//! runtime: browser JS glue or zine-host native wrapper.
//!
//! Host contract:
//!   jit_compile(ptr, len) → block_id (-1 on failure)
//!     Reads `len` bytes of WASM from guest memory at `ptr`,
//!     compiles into a callable module sharing the guest's linear memory.
//!   jit_call(block_id)
//!     Instantiates and calls the compiled module's "run" export.
//!     CPU state is transferred via JitCpuState at a known address.

const host = @import("host.zig");

// Extern imports — resolved by the host at instantiation time.
extern "jit" fn jit_compile(wasm_ptr: u32, wasm_len: u32) i32;
extern "jit" fn jit_call(block_id: i32) void;

fn compile(_: *anyopaque, wasm_bytes: []const u8) ?host.BlockId {
    const ptr: u32 = @intFromPtr(wasm_bytes.ptr);
    const len: u32 = @intCast(wasm_bytes.len);
    const result = jit_compile(ptr, len);
    if (result < 0) return null;
    return @intCast(result);
}

fn call(_: *anyopaque, block_id: host.BlockId) void {
    jit_call(@intCast(block_id));
}

fn deinitBlock(_: *anyopaque, _: host.BlockId) void {}

// Singleton context (stateless — all state lives on the host side).
var ctx: u8 = 0;

/// Returns a JitHost backed by WASM extern imports.
pub fn wasmJitHost() host.JitHost {
    return .{
        .compile_fn = &compile,
        .call_fn = &call,
        .deinit_block_fn = &deinitBlock,
        .ctx = @ptrCast(&ctx),
    };
}
