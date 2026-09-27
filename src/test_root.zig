//! Unified test root — imports all modules that contain embedded tests.
//! This avoids "import of file outside module path" errors that occur
//! when running zig test on individual files under subdirectories.

comptime {
    // x86 interpreter tests
    _ = @import("x86/flags.zig");
    _ = @import("x86/memory.zig");
    _ = @import("x86/fpu.zig");
    _ = @import("x86/cpu.zig");
    _ = @import("x86/decoder.zig");
    _ = @import("x86/decode_cache.zig");
    _ = @import("x86/execute.zig");
    _ = @import("x86/sse.zig");
    _ = @import("x86/thunks.zig");

    // JIT compiler tests
    _ = @import("jit/compiler.zig");

    // Loader tests
    _ = @import("loader/menu_parser.zig");
    _ = @import("loader/module.zig");
    _ = @import("loader/registry.zig");
    _ = @import("loader/loader.zig");

    // Profiler tests
    _ = @import("profiler.zig");

    // Fuzz harness regression tests (seed corpus + mutation replay)
    _ = @import("fuzz/replay.zig");

    // Core utility tests
    _ = @import("config.zig");
    _ = @import("runtime.zig");
    _ = @import("log.zig");
    _ = @import("path_utils.zig");
    _ = @import("bat.zig");
    _ = @import("pe.zig");
    _ = @import("runner.zig");
    _ = @import("gui/web_ui.zig");

    // Win32 stub tests
    _ = @import("win32/ansi.zig");
    _ = @import("win32/unicase.zig");
    _ = @import("win32/user32.zig");
    _ = @import("win32/host_io.zig");
    _ = @import("win32/comdlg32/dialogs.zig");
    _ = @import("win32/civil_time.zig");
    _ = @import("win32/kernel32/time.zig");
    _ = @import("win32/kernel32/locale.zig");
    _ = @import("win32/kernel32/file.zig");
    _ = @import("win32/kernel32/sync.zig");
    _ = @import("win32/kernel32/sysinfo.zig");
    _ = @import("win32/kernel32/process.zig");
    _ = @import("win32/rcdll.zig");
    _ = @import("win32/msvcrt/io.zig");
    _ = @import("win32/msvcrt/string.zig");
    _ = @import("win32/msvcrt/fmt.zig");
    _ = @import("win32/msvcrt/time.zig");
    _ = @import("win32/ntdll/ntapi.zig");
    _ = @import("win32/advapi32/registry.zig");
    _ = @import("win32/advapi32/registry_config.zig");
    _ = @import("win32/advapi32/services.zig");
    _ = @import("win32/advapi32/security.zig");
    _ = @import("win32/gdi32/drawing.zig");
    _ = @import("win32/gdi32/object.zig");
    _ = @import("win32/gdi32/dc.zig");
    _ = @import("win32/ws2_32/winsock.zig");
    _ = @import("win32/d3d7/rasterizer.zig");
}
