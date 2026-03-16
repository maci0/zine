//! zine-host: native wrapper for running zine.wasm with JIT support.
//!
//! Replaces `wasmtime run` by providing custom JIT imports alongside WASI.
//! Uses the wasmtime C API to:
//!   1. Load zine.wasm as the main module
//!   2. Provide WASI imports (file I/O, clock, etc.)
//!   3. Add two custom imports in the "jit" namespace:
//!      - jit_compile(wasm_ptr: i32, wasm_len: i32) -> i32
//!      - jit_call(block_id: i32)
//!
//! Building requires the wasmtime C API library:
//!   zig build -Dhost
//!
//! Usage:
//!   zine-host zine.wasm -- [--jit] <target.exe> [args...]

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip argv[0]

    const wasm_path = args.next() orelse {
        std.debug.print("Usage: zine-host <zine.wasm> [-- args...]\n", .{});
        std.process.exit(1);
    };

    // Collect remaining args to pass to the WASM module
    var guest_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer guest_args.deinit(allocator);
    while (args.next()) |arg| {
        try guest_args.append(allocator, arg);
    }

    std.debug.print("zine-host: loading {s}\n", .{wasm_path});
    std.debug.print("zine-host: guest args: {d}\n", .{guest_args.items.len});

    // The host-side bridge for JIT acceleration and WASM-native interop
    // is currently handled through WASI stdio/argv passing and the 
    // zine-host wrapper script.
    //      - jit_compile: read WASM bytes from guest memory, compile via
    //        wasmtime_module_new(), cache in HashMap(i32, wasmtime_module_t)
    //      - jit_call: instantiate cached module sharing guest memory,
    //        call its "run" export
    //   5. wasmtime_linker_instantiate() — instantiate main module
    //   6. Call _start export
    //
    // For now, this is a skeleton. Build with:
    //   zig build -Dhost
    //
    // When wasmtime C API is available, link with:
    //   exe.linkSystemLibrary("wasmtime");

    std.debug.print("zine-host: wasmtime C API integration not yet implemented.\n", .{});
    std.debug.print("zine-host: use 'wasmtime run' for interpreter-only mode.\n", .{});
    std.process.exit(1);
}
