//! Shared PE loading and execution pipeline.
//!
//! Contains the common logic used by both native (main.zig) and WASM
//! (wasm_main.zig) entry points: DLL stub registration, search path setup,
//! import resolution, and JIT.

const std = @import("std");
const runtime = @import("runtime.zig");
const loader = @import("loader/loader.zig");
const x86_cpu = @import("x86/cpu.zig");
const x86_execute = @import("x86/execute.zig");
const x86_decoder = @import("x86/decoder.zig");
const log = @import("log.zig");
const trace = @import("trace.zig");
const Environment = @import("loader/env.zig").Environment;
const Module = @import("loader/module.zig").Module;
const build_options = @import("build_options");

/// Whether Win32 stubs are compiled into the binary (true) or loaded
/// from external DLLs at runtime (false).  Controlled by -Dexternal-stubs.
pub const embed_stubs = build_options.embed_stubs;

// DLL stub modules — only pulled in when stubs are embedded.
const stubs_msvcrt = if (embed_stubs) @import("win32/msvcrt.zig") else void;
const stubs_kernel32 = if (embed_stubs) @import("win32/kernel32.zig") else void;
const stubs_advapi32 = if (embed_stubs) @import("win32/advapi32.zig") else void;
const stubs_imagehlp = if (embed_stubs) @import("win32/imagehlp.zig") else void;
const stubs_user32 = if (embed_stubs) @import("win32/user32.zig") else void;
const stubs_rpcrt4 = if (embed_stubs) @import("win32/rpcrt4.zig") else void;
const stubs_comdlg32 = if (embed_stubs) @import("win32/comdlg32.zig") else void;
const stubs_ntdll = if (embed_stubs) @import("win32/ntdll.zig") else void;
const stubs_mfc42 = if (embed_stubs) @import("win32/mfc42.zig") else void;
const stubs_winmm = if (embed_stubs) @import("win32/winmm.zig") else void;
const stubs_ddraw = if (embed_stubs) @import("win32/ddraw.zig") else void;
const stubs_gdi32 = if (embed_stubs) @import("win32/gdi32.zig") else void;
const stubs_dinput = if (embed_stubs) @import("win32/dinput.zig") else void;
const stubs_dinput8 = if (embed_stubs) @import("win32/dinput8.zig") else void;
const stubs_dsound = if (embed_stubs) @import("win32/dsound.zig") else void;
const stubs_d3d8 = if (embed_stubs) @import("win32/d3d8.zig") else void;
const stubs_mss32 = if (embed_stubs) @import("win32/mss32.zig") else void;
const stubs_shell32 = if (embed_stubs) @import("win32/shell32.zig") else void;
const stubs_comctl32 = if (embed_stubs) @import("win32/comctl32.zig") else void;
const stubs_ole32 = if (embed_stubs) @import("win32/ole32.zig") else void;
const stubs_oleaut32 = if (embed_stubs) @import("win32/oleaut32.zig") else void;
const stubs_imm32 = if (embed_stubs) @import("win32/imm32.zig") else void;
const stubs_version = if (embed_stubs) @import("win32/version.zig") else void;
const stubs_wsock32 = if (embed_stubs) @import("win32/wsock32.zig") else void;
const stubs_ws2_32 = if (embed_stubs) @import("win32/ws2_32.zig") else void;
const stubs_winspool = if (embed_stubs) @import("win32/winspool.zig") else void;
const stubs_nddeapi = if (embed_stubs) @import("win32/nddeapi.zig") else void;
const stubs_cards = if (embed_stubs) @import("win32/cards.zig") else void;
const stubs_icmp = if (embed_stubs) @import("win32/icmp.zig") else void;
const stubs_vdmdbg = if (embed_stubs) @import("win32/vdmdbg.zig") else void;
const stubs_mag_hook = if (embed_stubs) @import("win32/mag_hook.zig") else void;
const stubs_shlwapi = if (embed_stubs) @import("win32/shlwapi.zig") else void;
const stubs_msvcp60 = if (embed_stubs) @import("win32/msvcp60.zig") else void;
const stubs_setupapi = if (embed_stubs) @import("win32/setupapi.zig") else void;
const stubs_mpr = if (embed_stubs) @import("win32/mpr.zig") else void;
const stubs_mspdb60 = if (embed_stubs) @import("win32/mspdb60.zig") else void;
const stubs_rcdll = if (embed_stubs) @import("win32/rcdll.zig") else void;

// -----------------------------------------------------------------------
// DLL Stub Registration
// -----------------------------------------------------------------------

/// Register all Win32 DLL stubs with the given environment.
/// In embedded mode (default): registers all stub functions directly.
/// In external mode (-Dexternal-stubs): skips registration so the loader
/// picks up the DLLs from disk via the registry search paths.
pub fn registerAllStubs(environment: *Environment, not_implemented_addr: usize) !void {
    try environment.addBuiltinExport("builtin", "not_implemented", not_implemented_addr);

    if (comptime !embed_stubs) {
        // External mode: stubs will be loaded as PE DLLs from the search path.
        // Add the default DLL directory next to the zine binary.
        if (std.process.executableDirPath(runtime.io(), &dll_path_buf)) |self_dir_len| {
            const self_dir = dll_path_buf[0..self_dir_len];
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dll_dir = std.fmt.bufPrint(&buf, "{s}/dll", .{self_dir}) catch self_dir;
            environment.registry.addSearchPath(dll_dir) catch {};
        } else |_| {}
        return;
    }

    try stubs_msvcrt.register(environment);
    try stubs_kernel32.register(environment);
    try stubs_advapi32.register(environment);
    @import("win32/advapi32/registry.zig").initConfig(environment.allocator);
    try stubs_imagehlp.register(environment);
    try stubs_user32.register(environment);
    try stubs_rpcrt4.register(environment);
    try stubs_comdlg32.register(environment);
    try stubs_ntdll.register(environment);
    try stubs_mfc42.register(environment);
    try stubs_winmm.register(environment);
    try stubs_ddraw.register(environment);
    try stubs_gdi32.register(environment);
    try stubs_dinput.register(environment);
    try stubs_dinput8.register(environment);
    try stubs_dsound.register(environment);
    try stubs_d3d8.register(environment);
    try stubs_mss32.register(environment);
    try stubs_shell32.register(environment);
    try stubs_comctl32.register(environment);
    try stubs_ole32.register(environment);
    try stubs_oleaut32.register(environment);
    try stubs_imm32.register(environment);
    try stubs_version.register(environment);
    try stubs_wsock32.register(environment);
    try stubs_ws2_32.register(environment);
    try stubs_winspool.register(environment);
    try stubs_nddeapi.register(environment);
    try stubs_cards.register(environment);
    try stubs_icmp.register(environment);
    try stubs_vdmdbg.register(environment);
    try stubs_mag_hook.register(environment);
    try stubs_shlwapi.register(environment);
    try stubs_msvcp60.register(environment);
    try stubs_setupapi.register(environment);
    try stubs_mpr.register(environment);

    // MSPDB60 and RCDLL stubs. The real RCDLL.DLL fails to compile DIALOG
    // templates under the emulator on native, so register the embedded stub
    // (which now handles STRINGTABLE + DIALOG) on every platform. MSPDB60's
    // stub is only needed on WASM where the real DLL cannot run.
    const platform = @import("platform.zig");
    if (comptime platform.is_wasm) {
        try stubs_mspdb60.register(environment);
    }
    try stubs_rcdll.register(environment);
}

var dll_path_buf: [std.fs.max_path_bytes]u8 = undefined;

// -----------------------------------------------------------------------
// Search Path Setup
// -----------------------------------------------------------------------

/// Configure module search paths: CWD, exe directory, and optional extras.
pub fn setupSearchPaths(
    environment: *Environment,
    allocator: std.mem.Allocator,
    target_exe: []const u8,
    extra_paths: []const []const u8,
) !void {
    try environment.registry.addSearchPath(".");

    const fixed_target = try allocator.dupe(u8, target_exe);
    std.mem.replaceScalar(u8, fixed_target, '\\', '/');
    if (std.fs.path.dirname(fixed_target)) |dir| {
        try environment.registry.addSearchPath(dir);
    }

    for (extra_paths) |p| {
        if (p.len > 0) try environment.registry.addSearchPath(p);
    }
}

/// Build a list of search paths from the host PATH environment variable.
pub fn getHostPathDirs(allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    const path_utils = @import("path_utils.zig");
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    if (runtime.environ().getAlloc(allocator, "PATH")) |host_path| {
        defer allocator.free(host_path);
        var i: usize = 0;
        var start: usize = 0;
        while (i <= host_path.len) {
            const is_end = (i == host_path.len);
            var is_delim = false;
            if (!is_end) {
                const c = host_path[i];
                if (c == ';') {
                    is_delim = true;
                } else if (c == ':') {
                    // Check if it's a drive letter like C:
                    if (i > 0 and i == start + 1 and std.ascii.isAlphabetic(host_path[i - 1])) {
                        is_delim = false;
                    } else {
                        is_delim = true;
                    }
                }
            }
            if (is_delim or is_end) {
                if (i > start) {
                    var p = host_path[start..i];
                    if (p.len >= 2 and p[0] == '"' and p[p.len - 1] == '"') {
                        p = p[1 .. p.len - 1];
                    }
                    var posix_buf: [1024]u8 = undefined;
                    if (path_utils.win32ToPosix(p, &posix_buf)) |posix_len| {
                        try dirs.append(allocator, try allocator.dupe(u8, posix_buf[0..posix_len]));
                    } else |_| {
                        try dirs.append(allocator, try allocator.dupe(u8, p));
                    }
                }
                start = i + 1;
            }
            i += 1;
        }
    } else |_| {}
    return dirs;
}

// -----------------------------------------------------------------------
// Import Resolution
// -----------------------------------------------------------------------

/// Iteratively resolve all PE imports until no new modules are loaded.
pub fn resolveAllImports(environment: *Environment, allocator: std.mem.Allocator) !void {
    var resolved_count: usize = 0;
    while (true) {
        var to_resolve: std.ArrayListUnmanaged(*Module) = .empty;
        defer to_resolve.deinit(allocator);

        var it = environment.registry.modules.iterator();
        while (it.next()) |entry| {
            try to_resolve.append(allocator, entry.value_ptr.*);
        }

        if (to_resolve.items.len == resolved_count) break;

        for (to_resolve.items) |mod| {
            try loader.resolveImports(environment, mod);
        }
        resolved_count = to_resolve.items.len;
    }
}

// -----------------------------------------------------------------------
// JIT / Interpreter Helpers
// -----------------------------------------------------------------------

/// Scan x86 code to find the end of a basic block (up to a terminating
/// instruction like RET, JMP, HLT, or INT3).
pub fn scanBlock(code: []const u8) usize {
    var offset: usize = 0;
    while (offset < code.len) {
        const insn = x86_decoder.decode(code[offset..]);
        if (insn.length == 0) break;
        offset += insn.length;

        switch (insn.opcode) {
            0xC3,
            0xC2, // RET, RET imm16
            0xCB,
            0xCA, // RETF
            0xE9,
            0xEB, // JMP rel32, JMP rel8
            0xF4, // HLT
            0xCC, // INT3
            => break,
            else => {},
        }
    }
    return offset;
}

const jit_compiler = @import("jit/compiler.zig");
const jit_emitter = @import("jit/emitter.zig");

/// JIT validation loop: compiles x86 blocks to WASM while executing via
/// the software interpreter. Compiled blocks are validated but not executed
/// — the interpreter handles all actual instruction execution.
pub fn runWithJit(cpu: *x86_cpu.Cpu, allocator: std.mem.Allocator) void {
    var jit = jit_compiler.JitCompiler.init(allocator, 0);
    defer jit.deinit();

    var blocks_compiled: u32 = 0;
    var expected_next_eip: u32 = 0;

    while (!cpu.halted) {
        const eip = cpu.eip;

        if (eip != expected_next_eip and !jit.isCached(eip)) {
            if (cpu.memory.readSlice(eip, 256)) |code| {
                const block_len = scanBlock(code);
                if (block_len > 0) {
                    jit.module.deinit();
                    jit.module = jit_emitter.WasmModule.init(allocator);

                    if (jit.compile(eip, code[0..block_len])) |wasm_bin| {
                        blocks_compiled += 1;
                        if (blocks_compiled <= 10) {
                            log.info("JIT: compiled block at EIP=0x{X} ({d} x86 bytes -> {d} WASM bytes)", .{
                                eip, block_len, wasm_bin.len,
                            });
                        } else if (blocks_compiled == 11) {
                            log.info("JIT: (suppressing further compilation logs)", .{});
                        }
                        allocator.free(wasm_bin);
                    } else |jit_err| {
                        log.warn("JIT: failed to compile block at EIP=0x{X} ({d} bytes): {}", .{
                            eip, block_len, jit_err,
                        });
                    }
                }
            }
        }

        x86_execute.step(cpu);
        expected_next_eip = cpu.eip;
    }

    log.info("JIT: compiled {d} unique basic blocks", .{blocks_compiled});
}
