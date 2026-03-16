//! Shared PE loading and execution pipeline.
//!
//! Contains the common logic used by both native (main.zig) and WASM
//! (wasm_main.zig) entry points: DLL stub registration, search path setup,
//! import resolution, relocation, BSS zeroing, .rsrc protection, and JIT.

const std = @import("std");
const pe = @import("pe.zig");
const loader = @import("loader/loader.zig");
const x86_cpu = @import("x86/cpu.zig");
const x86_memory = @import("x86/memory.zig");
const x86_execute = @import("x86/execute.zig");
const x86_decoder = @import("x86/decoder.zig");
const log = @import("log.zig");
const trace = @import("trace.zig");
const Environment = @import("loader/env.zig").Environment;
const Module = @import("loader/module.zig").Module;

// DLL stub modules
const stubs_msvcrt = @import("win32/msvcrt.zig");
const stubs_kernel32 = @import("win32/kernel32.zig");
const stubs_advapi32 = @import("win32/advapi32.zig");
const stubs_imagehlp = @import("win32/imagehlp.zig");
const stubs_user32 = @import("win32/user32.zig");
const stubs_rpcrt4 = @import("win32/rpcrt4.zig");
const stubs_comdlg32 = @import("win32/comdlg32.zig");
const stubs_ntdll = @import("win32/ntdll.zig");
const stubs_mfc42 = @import("win32/mfc42.zig");
const stubs_winmm = @import("win32/winmm.zig");
const stubs_ddraw = @import("win32/ddraw.zig");
const stubs_gdi32 = @import("win32/gdi32.zig");
const stubs_dinput = @import("win32/dinput.zig");
const stubs_dinput8 = @import("win32/dinput8.zig");
const stubs_dsound = @import("win32/dsound.zig");
const stubs_d3d8 = @import("win32/d3d8.zig");
const stubs_mss32 = @import("win32/mss32.zig");
const stubs_shell32 = @import("win32/shell32.zig");
const stubs_comctl32 = @import("win32/comctl32.zig");
const stubs_ole32 = @import("win32/ole32.zig");
const stubs_oleaut32 = @import("win32/oleaut32.zig");
const stubs_imm32 = @import("win32/imm32.zig");
const stubs_version = @import("win32/version.zig");
const stubs_wsock32 = @import("win32/wsock32.zig");
const stubs_ws2_32 = @import("win32/ws2_32.zig");
const stubs_winspool = @import("win32/winspool.zig");
const stubs_nddeapi = @import("win32/nddeapi.zig");
const stubs_cards = @import("win32/cards.zig");
const stubs_icmp = @import("win32/icmp.zig");
const stubs_vdmdbg = @import("win32/vdmdbg.zig");
const stubs_mag_hook = @import("win32/mag_hook.zig");
const stubs_shlwapi = @import("win32/shlwapi.zig");
const stubs_msvcp60 = @import("win32/msvcp60.zig");
const stubs_setupapi = @import("win32/setupapi.zig");

// -----------------------------------------------------------------------
// DLL Stub Registration
// -----------------------------------------------------------------------

/// Register all Win32 DLL stubs with the given environment.
/// Also adds the not_implemented fallback and initializes the registry config.
pub fn registerAllStubs(environment: *Environment, not_implemented_addr: usize) !void {
    try environment.addBuiltinExport("builtin", "not_implemented", not_implemented_addr);

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
}

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
    var dirs: std.ArrayListUnmanaged([]const u8) = .{};
    if (std.process.getEnvVarOwned(allocator, "PATH")) |host_path| {
        defer allocator.free(host_path);
        var it = std.mem.tokenizeScalar(u8, host_path, ':');
        while (it.next()) |p| {
            if (p.len > 0) {
                try dirs.append(allocator, try allocator.dupe(u8, p));
            }
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
        var to_resolve: std.ArrayListUnmanaged(*Module) = .{};
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
// Reverse Relocation (WASM only)
// -----------------------------------------------------------------------

/// Apply reverse base relocations to a PE image buffer, skipping IAT slots.
/// Used in WASM mode where the PE is copied into a combined buffer at a
/// different base address than where Module.load mapped it.
pub fn applyReverseRelocations(
    buf: []u8,
    parser: anytype,
    image_size: u32,
    actual_base: u32,
    preferred_base: u32,
) void {
    if (actual_base == preferred_base) return;
    const reverse_delta = preferred_base -% actual_base;
    const opt_header = &parser.getNtHeaders().OptionalHeader;

    // Collect IAT ranges to skip (resolveImports already wrote correct thunk addresses)
    const import_dir_entry = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_IMPORT];
    var iat_ranges: [32][2]u32 = undefined;
    var iat_range_count: usize = 0;
    if (import_dir_entry.Size > 0) {
        var imp_off = import_dir_entry.VirtualAddress;
        while (imp_off + 20 <= image_size) {
            const imp_name = @as(*align(1) const u32, @ptrCast(buf[imp_off + 12 ..].ptr)).*;
            if (imp_name == 0) break;
            const first_thunk_rva = @as(*align(1) const u32, @ptrCast(buf[imp_off + 16 ..].ptr)).*;
            const orig_thunk_rva_raw = @as(*align(1) const u32, @ptrCast(buf[imp_off ..].ptr)).*;
            const ilt_rva = if (orig_thunk_rva_raw == 0) first_thunk_rva else orig_thunk_rva_raw;
            var count: u32 = 0;
            while (ilt_rva + (count + 1) * 4 <= image_size) {
                const e_val = @as(*align(1) const u32, @ptrCast(buf[ilt_rva + count * 4 ..].ptr)).*;
                if (e_val == 0) break;
                count += 1;
            }
            if (iat_range_count < iat_ranges.len) {
                iat_ranges[iat_range_count] = .{ first_thunk_rva, first_thunk_rva + count * 4 };
                iat_range_count += 1;
            }
            imp_off += 20;
        }
    }

    const reloc_dir = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC];
    if (reloc_dir.Size > 0) {
        var reloc_offset = reloc_dir.VirtualAddress;
        const reloc_end = reloc_offset + reloc_dir.Size;
        while (reloc_offset < reloc_end) {
            const block_va = @as(*align(1) const u32, @ptrCast(buf[reloc_offset..].ptr)).*;
            const block_size = @as(*align(1) const u32, @ptrCast(buf[reloc_offset + 4 ..].ptr)).*;
            if (block_size == 0) break;
            const entries_count = (block_size - 8) / 2;
            for (0..entries_count) |e| {
                const entry = @as(*align(1) const u16, @ptrCast(buf[reloc_offset + 8 + e * 2 ..].ptr)).*;
                if (entry >> 12 == 3) { // IMAGE_REL_BASED_HIGHLOW
                    const patch_addr = block_va + (entry & 0x0FFF);
                    var in_iat = false;
                    for (iat_ranges[0..iat_range_count]) |range| {
                        if (patch_addr >= range[0] and patch_addr < range[1]) {
                            in_iat = true;
                            break;
                        }
                    }
                    if (in_iat) continue;
                    if (patch_addr + 4 <= image_size) {
                        const ptr = @as(*align(1) u32, @ptrCast(buf[patch_addr..].ptr));
                        ptr.* = ptr.* +% reverse_delta;
                    }
                }
            }
            reloc_offset += block_size;
        }
    }
}

// -----------------------------------------------------------------------
// BSS Zero-Fill
// -----------------------------------------------------------------------

/// Zero-fill BSS regions in PE sections (VirtualSize > SizeOfRawData).
pub fn zeroFillBss(buf: []u8, sections: anytype) void {
    for (sections) |sec| {
        const vsize = sec.Misc.VirtualSize;
        if (vsize > sec.SizeOfRawData) {
            const bss_start = sec.VirtualAddress + sec.SizeOfRawData;
            const bss_end = sec.VirtualAddress + vsize;
            if (bss_end <= buf.len) {
                @memset(buf[bss_start..bss_end], 0);
            }
        }
    }
}

// -----------------------------------------------------------------------
// .rsrc Write Protection
// -----------------------------------------------------------------------

/// Protect the .rsrc section from guest buffer overflows.
/// Only .rsrc is protected — .rdata/.text must remain writable because
/// some CRT startup code writes to IAT slots and other "read-only" areas.
pub fn protectRsrc(
    sections: anytype,
    memory: *x86_memory.GuestMemory,
    preferred_base: u32,
    image_size: u32,
) void {
    for (sections) |sec| {
        const name = &sec.Name;
        if (name[0] == '.' and name[1] == 'r' and name[2] == 's' and name[3] == 'r' and name[4] == 'c') {
            memory.pe_image_end = preferred_base +% image_size;
            const rsrc_start = preferred_base +% sec.VirtualAddress;
            const rsrc_end = rsrc_start +% sec.Misc.VirtualSize;
            if (rsrc_start > preferred_base)
                memory.addWritableSection(preferred_base, rsrc_start);
            if (rsrc_end < preferred_base +% image_size)
                memory.addWritableSection(rsrc_end, preferred_base +% image_size);
            break;
        }
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
            0xC3, 0xC2, // RET, RET imm16
            0xCB, 0xCA, // RETF
            0xE9, 0xEB, // JMP rel32, JMP rel8
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

/// Compile-only JIT loop: validates the JIT compiler on real PE code.
/// Compiled WASM blocks are discarded (not executed).
pub fn runWithJit(cpu: *x86_cpu.Cpu, allocator: std.mem.Allocator) void {
    var jit = jit_compiler.JitCompiler.init(allocator, 0);
    defer jit.deinit();

    var blocks_compiled: u32 = 0;
    var expected_next_eip: u32 = 0;

    while (!cpu.halted) {
        const eip = cpu.eip;

        if (eip != expected_next_eip and !jit.block_cache.contains(eip)) {
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
                    } else |_| {}
                }
            }
        }

        x86_execute.step(cpu);
        expected_next_eip = cpu.eip;
    }

    log.info("JIT: compiled {d} unique basic blocks", .{blocks_compiled});
}
