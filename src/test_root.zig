// Unified test root — imports all modules that contain embedded tests.
// This avoids "import of file outside module path" errors that occur
// when running zig test on individual files under subdirectories.

comptime {
    // x86 interpreter tests
    _ = @import("x86/flags.zig");
    _ = @import("x86/memory.zig");
    _ = @import("x86/fpu.zig");
    _ = @import("x86/cpu.zig");
    _ = @import("x86/decoder.zig");
    _ = @import("x86/execute.zig");
    _ = @import("x86/thunks.zig");

    // JIT compiler tests
    _ = @import("jit/emitter.zig");
    _ = @import("jit/compiler.zig");

    // Profiler tests
    _ = @import("profiler.zig");
}
