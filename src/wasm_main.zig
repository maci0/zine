//! WebAssembly entry point for Zine (WASI CLI mode).
//!
//! This module provides a standard `main()` entry point for the WASM
//! build, allowing Zine to run on WASI runtimes like wasmtime. It
//! initializes the guest environment and starts the interpreter.
//!
//! In WASM mode, Zine only supports software interpretation of x86 code,
//! as it cannot execute native x86 instructions directly.

const std = @import("std");
const platform = @import("platform.zig");
const pe = @import("pe.zig");
const teb = @import("win32/teb.zig");
const path_utils = @import("path_utils.zig");
const Module = @import("loader/module.zig").Module;
const Environment = @import("loader/env.zig").Environment;
const loader = @import("loader/loader.zig");
const x86_cpu = @import("x86/cpu.zig");
const x86_execute = @import("x86/execute.zig");
const x86_memory = @import("x86/memory.zig");
const x86_thunks = @import("x86/thunks.zig");
const trace = @import("trace.zig");
const log = @import("log.zig");

// Stub DLL modules
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

// Re-export platform to ensure WASM imports are declared
comptime {
    _ = platform;
}

/// Fallback for unimplemented Win32 APIs in WASM mode.
fn not_implemented() callconv(.c) void {
    const ra = @returnAddress();
    const name = x86_thunks.lookupUnresolvedName(ra);
    if (name) |func_name| {
        log.fatal("Unimplemented Win32 API: {s} (called from 0x{X})", .{ func_name, ra });
    } else {
        log.fatal("Unimplemented Win32 API called from 0x{X}", .{ra});
    }
    // On WASM we can't call std.process.exit, so halt via trap
    @trap();
}

/// The entry point for the WASM build of Zine.
/// It sets up guest memory, loads the PE, and starts the x86 interpreter.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();

    var target_exe_opt: ?[]const u8 = null;
    var app_args: std.ArrayListUnmanaged(?[*:0]u8) = .{};
    var use_jit = false;
    var end_of_options = false;
    while (args.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--trace") or std.mem.eql(u8, arg, "-t"))) {
            trace.enable_tracing = true;
            trace.enable_instructions = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--trace-api")) {
            trace.enable_tracing = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--trace-insn")) {
            trace.enable_instructions = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--jit")) {
            use_jit = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            const stdout = std.fs.File{ .handle = 1 };
            stdout.writeAll(
                \\Usage: zine [options] [--] <target.exe> [args...]
                \\
                \\Run a Win32 PE executable in a WebAssembly environment.
                \\
                \\Options:
                \\  -t, --trace         Enable all tracing output (API + instructions)
                \\      --trace-api     Enable API tracing only
                \\      --trace-insn    Enable x86 instruction tracing only
                \\      --jit           Use JIT compiler (accepted, uses interpreter on WASM)
                \\  -h, --help          Show this help message
                \\  -v, --version       Show version information
                \\  --                  Stop processing options
                \\
                \\Examples:
                \\  wasmtime --dir=. zine.wasm -- myapp.exe
                \\  wasmtime --dir=. zine.wasm -- --trace myapp.exe
                \\
            ) catch {};
            std.process.exit(0);
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            const stdout = std.fs.File{ .handle = 1 };
            stdout.writeAll("zine 0.1.0\n") catch {};
            std.process.exit(0);
        }
        if (!end_of_options and target_exe_opt == null and arg.len > 1 and arg[0] == '-') {
            const stderr = std.fs.File{ .handle = 2 };
            var err_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "Error: unknown option '{s}'.\nTry 'zine --help' for more information.\n", .{arg}) catch "Error: unknown option.\n";
            stderr.writeAll(msg) catch {};
            std.process.exit(2);
        }

        if (target_exe_opt == null) {
            target_exe_opt = arg;
            // First positional arg is the target exe — convert to Win32 path for argv[0]
            var win_buf: [1024]u8 = undefined;
            const win_len = path_utils.posixToWin32(arg, &win_buf);
            if (win_len > 0) {
                try app_args.append(allocator, try allocator.dupeZ(u8, win_buf[0..win_len]));
            } else {
                try app_args.append(allocator, try allocator.dupeZ(u8, arg));
            }
        } else {
            // Convert absolute POSIX paths to Win32 for guest PE arguments.
            // Distinguish paths from MSVC-style options: /Fo/tmp/x.obj is an
            // option (first component "Fo" is <=2 chars), /tmp/hello.c is a
            // real path (first component "tmp" is >=3 chars).
            const is_posix_path = blk: {
                if (arg.len <= 2 or arg[0] != '/') break :blk false;
                const rest = arg[1..];
                const next_slash = std.mem.indexOfScalar(u8, rest, '/') orelse break :blk false;
                // First path component must be >= 3 chars to distinguish from
                // MSVC options like /Fo, /Fe, /I, /O1, /Ob, /Od, /Zi, etc.
                break :blk next_slash >= 3;
            };
            if (is_posix_path) {
                var win_buf: [1024]u8 = undefined;
                const win_len = path_utils.posixToWin32(arg, &win_buf);
                if (win_len > 0) {
                    try app_args.append(allocator, try allocator.dupeZ(u8, win_buf[0..win_len]));
                } else {
                    try app_args.append(allocator, try allocator.dupeZ(u8, arg));
                }
            } else {
                try app_args.append(allocator, try allocator.dupeZ(u8, arg));
            }
        }
    }

    if (target_exe_opt == null) {
        std.fs.File.stderr().writeAll("Error: missing required argument <target.exe>.\nTry 'zine --help' for more information.\n") catch {};
        std.process.exit(2);
    }
    const target_exe = target_exe_opt.?;

    log.info("wasm: loading PE from '{s}'", .{target_exe});

    // --- Set up Environment and register all stub DLLs ---
    var environment = Environment.init(allocator);

    try environment.addBuiltinExport("builtin", "not_implemented", @intFromPtr(&not_implemented));

    try stubs_msvcrt.register(&environment);
    try stubs_kernel32.register(&environment);
    try stubs_advapi32.register(&environment);
    try stubs_imagehlp.register(&environment);
    try stubs_user32.register(&environment);
    try stubs_rpcrt4.register(&environment);
    try stubs_comdlg32.register(&environment);
    try stubs_ntdll.register(&environment);
    try stubs_mfc42.register(&environment);
    try stubs_winmm.register(&environment);
    try stubs_ddraw.register(&environment);
    try stubs_gdi32.register(&environment);
    try stubs_dinput.register(&environment);
    try stubs_dsound.register(&environment);
    try stubs_d3d8.register(&environment);
    try stubs_mss32.register(&environment);
    try stubs_shell32.register(&environment);
    try stubs_comctl32.register(&environment);
    try stubs_ole32.register(&environment);
    try stubs_imm32.register(&environment);
    try stubs_version.register(&environment);
    try stubs_wsock32.register(&environment);
    try stubs_ws2_32.register(&environment);
    try stubs_winspool.register(&environment);
    try stubs_nddeapi.register(&environment);
    try stubs_cards.register(&environment);
    try stubs_icmp.register(&environment);
    try stubs_vdmdbg.register(&environment);
    try stubs_mag_hook.register(&environment);

    // Add search paths (current dir + exe directory)
    try environment.registry.addSearchPath(".");
    const fixed_target = try allocator.dupe(u8, target_exe);
    std.mem.replaceScalar(u8, fixed_target, '\\', '/');
    if (std.fs.path.dirname(fixed_target)) |dir| {
        try environment.registry.addSearchPath(dir);
    }

    // --- Load the main executable via the registry ---
    const exe_name = std.fs.path.basename(target_exe);
    const main_module = try environment.registry.loadModule(exe_name);
    // On WASM, the module handle must be the GUEST base VA (not a host pointer)
    // so the x86 interpreter's address translation works correctly.
    stubs_kernel32.main_module_handle = main_module.parser.getNtHeaders().OptionalHeader.ImageBase;

    log.info("wasm: loaded PE '{s}' at 0x{X} (size={d})", .{
        exe_name,
        main_module.image_base,
        main_module.mapped_memory.len,
    });

    const preferred_base: u32 = main_module.parser.getNtHeaders().OptionalHeader.ImageBase;
    const image_size: u32 = @truncate(main_module.mapped_memory.len);

    const STACK_SIZE: u32 = 64 * 1024;
    const THUNK_RESERVE: u32 = 32 * 1024;
    const HEAP_RESERVE: u32 = 32 * 1024 * 1024; // 32 MB guest heap
    const combined_size = image_size + STACK_SIZE + THUNK_RESERVE + HEAP_RESERVE;
    const combined_buf = try allocator.alloc(u8, combined_size);

    // Zero the stack area
    @memset(combined_buf[image_size .. image_size + STACK_SIZE], 0);

    // Fill the thunk area with INT3 (0xCC) for safety
    @memset(combined_buf[image_size + STACK_SIZE ..], 0xCC);

    // Thunks start after PE image + stack
    const thunk_base_addr = preferred_base +% image_size +% STACK_SIZE;

    // Create a GuestMemory view using the combined buffer
    var thunk_guest_mem = x86_memory.GuestMemory{
        .base = combined_buf,
        .base_addr = preferred_base,
    };
    loader.setThunkMemory(&thunk_guest_mem, thunk_base_addr);

    // On WASM, data exports like _iob must be in guest memory (32-bit virtual
    // addresses) so the x86 interpreter can dereference them. relocateDataExports
    // iterates all is_data=true exports, allocates guest memory, copies data, and
    // updates export addresses — driven entirely by registered exports.
    {
        // Set up guest heap early so we can guestAlloc
        thunk_guest_mem.heap_start = image_size + STACK_SIZE + THUNK_RESERVE;
        thunk_guest_mem.heap_cursor = thunk_guest_mem.heap_start;

        // Relocate ALL data exports into guest memory in one call
        environment.relocateDataExports(&thunk_guest_mem, combined_buf, preferred_base);

        // Post-relocation fixups for exports that need extra initialization:

        // _iob: pre-allocate stdout/stderr buffers and set FILE* flags
        const io_mod = @import("win32/msvcrt/io.zig");
        if (environment.resolveExport("MSVCRT.dll", "_iob")) |iob_exp| {
            io_mod.initGuestIob(&thunk_guest_mem, combined_buf, preferred_base, @intCast(iob_exp.addr));
        }

        // __pioinfo: fix up pointer from host→guest so CRT's _osfile validation works.
        // __pioinfo[0] must point to the GUEST address of ioinfo_table0.
        if (environment.resolveExport("MSVCRT.dll", "__pioinfo")) |pioinfo_exp| {
            if (environment.resolveExport("MSVCRT.dll", "_nhandle")) |_| {
                // ioinfo_table0 was also relocated as part of __pioinfo data.
                // We need to allocate ioinfo_table0 separately in guest memory
                // and patch __pioinfo[0] to point to it.
                const ioinfo_size: u32 = @intCast(io_mod.ioinfo_table0.len);
                const ioinfo_guest_va = thunk_guest_mem.guestAlloc(ioinfo_size);
                if (ioinfo_guest_va != 0) {
                    // Copy ioinfo_table0 data to guest memory
                    const ioinfo_offset = ioinfo_guest_va - preferred_base;
                    @memcpy(combined_buf[ioinfo_offset..][0..ioinfo_size], &io_mod.ioinfo_table0);

                    // Patch __pioinfo[0] in guest memory to point to guest ioinfo_table0
                    const pioinfo_offset = @as(u32, @intCast(pioinfo_exp.addr)) - preferred_base;
                    const pioinfo_ptr = @as(*align(1) u32, @ptrCast(combined_buf[pioinfo_offset..].ptr));
                    pioinfo_ptr.* = ioinfo_guest_va;

                    // Also update the host copy so __p__iob-style accessors work
                    io_mod.pioinfo[0] = ioinfo_guest_va;
                }
            }
        }

        // _acmdln: track guest VA for ensureGuestArgs
        if (environment.resolveExport("MSVCRT.dll", "_acmdln")) |acmdln_exp| {
            stubs_msvcrt.msvcrt_acmdln_guest = acmdln_exp.addr;
        }
    }

    // --- Resolve imports iteratively ---
    // IMPORTANT: This must happen BEFORE copying the PE image into combined_buf,
    // because resolveImports patches mod.mapped_memory (IAT slots). If we copy
    // first, the patched IAT entries would be lost.
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
            try loader.resolveImports(&environment, mod);
        }
        resolved_count = to_resolve.items.len;
    }

    // Copy the PE image (now with patched IAT) into the combined buffer
    @memcpy(combined_buf[0..image_size], main_module.mapped_memory[0..image_size]);

    // On WASM, the PE was mapped at a host address that differs from the
    // preferred ImageBase. Module.load applied relocations for that host
    // address. But combined_buf uses preferred_base for the GuestMemory
    // base_addr. We must undo those relocations so absolute addresses in
    // the code match the preferred base (= GuestMemory virtual addresses).
    // Skip IAT slots since resolveImports already wrote correct thunk addresses.
    {
        const actual_base: u32 = @truncate(main_module.image_base);
        if (actual_base != preferred_base) {
            const reverse_delta = preferred_base -% actual_base;
            const opt_header = &main_module.parser.getNtHeaders().OptionalHeader;

            // Collect IAT ranges to skip during relocation
            const import_dir_entry = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_IMPORT];
            var iat_ranges: [32][2]u32 = undefined;
            var iat_range_count: usize = 0;

            if (import_dir_entry.Size > 0) {
                var imp_off = import_dir_entry.VirtualAddress;
                while (imp_off + 20 <= image_size) {
                    const imp_name = @as(*align(1) const u32, @ptrCast(combined_buf[imp_off + 12 ..].ptr)).*;
                    if (imp_name == 0) break;
                    const first_thunk_rva = @as(*align(1) const u32, @ptrCast(combined_buf[imp_off + 16 ..].ptr)).*;
                    const orig_thunk_rva_raw = @as(*align(1) const u32, @ptrCast(combined_buf[imp_off ..].ptr)).*;
                    const ilt_rva = if (orig_thunk_rva_raw == 0) first_thunk_rva else orig_thunk_rva_raw;
                    // Count entries in this import
                    var count: u32 = 0;
                    while (ilt_rva + (count + 1) * 4 <= image_size) {
                        const e = @as(*align(1) const u32, @ptrCast(combined_buf[ilt_rva + count * 4 ..].ptr)).*;
                        if (e == 0) break;
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
                var reloc_count: u32 = 0;
                var skip_count: u32 = 0;

                while (reloc_offset < reloc_end) {
                    const block_va = @as(*align(1) const u32, @ptrCast(combined_buf[reloc_offset..].ptr)).*;
                    const block_size = @as(*align(1) const u32, @ptrCast(combined_buf[reloc_offset + 4 ..].ptr)).*;
                    if (block_size == 0) break;

                    const entries_count = (block_size - 8) / 2;
                    const entries_start = reloc_offset + 8;

                    for (0..entries_count) |e| {
                        const entry = @as(*align(1) const u16, @ptrCast(combined_buf[entries_start + e * 2 ..].ptr)).*;
                        const reloc_type = entry >> 12;
                        const offset = entry & 0x0FFF;

                        if (reloc_type == 3) { // IMAGE_REL_BASED_HIGHLOW
                            const patch_addr = block_va + offset;
                            // Skip if this address is inside an IAT range
                            var in_iat = false;
                            for (iat_ranges[0..iat_range_count]) |range| {
                                if (patch_addr >= range[0] and patch_addr < range[1]) {
                                    in_iat = true;
                                    break;
                                }
                            }
                            if (in_iat) {
                                skip_count += 1;
                                continue;
                            }
                            if (patch_addr + 4 <= image_size) {
                                const ptr = @as(*align(1) u32, @ptrCast(combined_buf[patch_addr..].ptr));
                                ptr.* = ptr.* +% reverse_delta;
                                reloc_count += 1;
                            }
                        }
                    }
                    reloc_offset += block_size;
                }
                log.info("wasm: applied {d} reverse relocations, skipped {d} IAT entries (delta=0x{X})", .{ reloc_count, skip_count, reverse_delta });
            }
        }
    }

    // --- Initialize MSVCRT globals ---
    // Build proper argv and _acmdln from collected guest arguments
    try app_args.append(allocator, null);

    stubs_msvcrt.global_argc = @intCast(app_args.items.len - 1);
    stubs_msvcrt.global_argv = app_args.items.ptr;

    // Build _acmdln string (space-joined command line) in guest memory
    // so the CRT can read it through the interpreter's address translation.
    {
        const cmdline_guest_va = thunk_guest_mem.guestAlloc(4096);
        if (cmdline_guest_va != 0) {
            const cmdline_offset = cmdline_guest_va - preferred_base;
            var pos: usize = 0;
            for (app_args.items) |arg_opt| {
                if (arg_opt) |arg| {
                    const span = std.mem.span(arg);
                    if (pos > 0 and pos < 4095) {
                        combined_buf[cmdline_offset + pos] = ' ';
                        pos += 1;
                    }
                    const copy_len = @min(span.len, 4095 - pos);
                    @memcpy(combined_buf[cmdline_offset + pos ..][0..copy_len], span[0..copy_len]);
                    pos += copy_len;
                }
            }
            combined_buf[cmdline_offset + pos] = 0;
            stubs_msvcrt.msvcrt_acmdln = cmdline_guest_va;

            // Also update the guest memory copy of _acmdln data export
            // so the CRT can read the pointer through the interpreter
            if (stubs_msvcrt.msvcrt_acmdln_guest != 0) {
                const acmdln_offset = @as(u32, @intCast(stubs_msvcrt.msvcrt_acmdln_guest)) - preferred_base;
                @as(*align(1) u32, @ptrCast(combined_buf[acmdln_offset..].ptr)).* = cmdline_guest_va;
            }
        }
    }

    // Set virtual CWD so file opens resolve correctly
    // On WASI, realpath is not available, so we just use \".\" as the CWD.
    {
        const kernel32_path = @import("win32/kernel32/path.zig");
        const cwd_str = ".";
        @memcpy(kernel32_path.current_directory[0..cwd_str.len], cwd_str);
        kernel32_path.current_directory_len = cwd_str.len;
    }

    // Pass through host environment variables to the guest.
    // Convert path-valued env vars (INCLUDE, LIB, PATH, TMP, TEMP) to Win32 style.
    {
        var env_list: std.ArrayListUnmanaged(?[*:0]u8) = .{};
        var env_iter = std.process.getEnvMap(allocator) catch null;
        if (env_iter) |*env_map| {
            var it = env_map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;

                // Convert path-valued variables to Win32 style
                const is_path_var = std.ascii.eqlIgnoreCase(key, "INCLUDE") or
                    std.ascii.eqlIgnoreCase(key, "LIB") or
                    std.ascii.eqlIgnoreCase(key, "PATH") or
                    std.ascii.eqlIgnoreCase(key, "TMP") or
                    std.ascii.eqlIgnoreCase(key, "TEMP");

                if (is_path_var and val.len > 0) {
                    // Convert each path component (split by : on POSIX)
                    var win_val_buf: [4096]u8 = undefined;
                    var win_pos: usize = 0;
                    var path_iter = std.mem.splitScalar(u8, val, ':');
                    var first = true;
                    while (path_iter.next()) |component| {
                        if (component.len == 0) continue;
                        if (!first and win_pos < win_val_buf.len) {
                            win_val_buf[win_pos] = ';'; // Win32 path separator
                            win_pos += 1;
                        }
                        first = false;
                        var comp_buf: [1024]u8 = undefined;
                        const comp_len = path_utils.posixToWin32(component, &comp_buf);
                        if (comp_len > 0 and win_pos + comp_len < win_val_buf.len) {
                            @memcpy(win_val_buf[win_pos..][0..comp_len], comp_buf[0..comp_len]);
                            win_pos += comp_len;
                        }
                    }

                    const total_len = key.len + 1 + win_pos;
                    const env_str = allocator.allocSentinel(u8, total_len, 0) catch continue;
                    @memcpy(env_str[0..key.len], key);
                    env_str[key.len] = '=';
                    @memcpy(env_str[key.len + 1 ..][0..win_pos], win_val_buf[0..win_pos]);
                    try env_list.append(allocator, env_str.ptr);
                } else {
                    const total_len = key.len + 1 + val.len;
                    const env_str = allocator.allocSentinel(u8, total_len, 0) catch continue;
                    @memcpy(env_str[0..key.len], key);
                    env_str[key.len] = '=';
                    @memcpy(env_str[key.len + 1 ..][0..val.len], val);
                    try env_list.append(allocator, env_str.ptr);
                }
            }
        }
        try env_list.append(allocator, null); // null-terminate
        stubs_msvcrt.global_envp = env_list.items.ptr;
        stubs_msvcrt.global_env_initialized = true;
    }

    // --- Initialize TEB/PEB ---
    const thread_env = try teb.initTEB(allocator);

    // Set up PEB environment block (minimal)
    const peb_ptr = @as(*teb.PEB, @ptrFromInt(thread_env.ProcessEnvironmentBlock));
    const params = @as(*teb.RTL_USER_PROCESS_PARAMETERS, @ptrFromInt(peb_ptr.ProcessParameters));
    _ = params; // Environment block stays at 0 (empty)

    // On WASM, setupFS is a no-op (interpreter uses cpu.fs_base directly)
    try teb.setupFS(thread_env);

    // --- Set up CPU and run interpreter ---
    const ep_rva: u32 = main_module.parser.getNtHeaders().OptionalHeader.AddressOfEntryPoint;
    if (ep_rva == 0) {
        std.fs.File.stderr().writeAll("Error: no entry point found in executable.\n") catch {};
        std.process.exit(1);
    }

    var cpu = x86_cpu.Cpu{};
    cpu.memory = x86_memory.GuestMemory{
        .base = combined_buf,
        .base_addr = preferred_base,
        .heap_start = image_size + STACK_SIZE + THUNK_RESERVE,
        // Carry over heap_cursor from loading phase so runtime malloc
        // doesn't overwrite data exports allocated during PE loading.
        .heap_cursor = thunk_guest_mem.heap_cursor,
    };
    cpu.eip = preferred_base +% ep_rva;

    // PE section write protection: protect .rsrc from guest buffer overflows.
    // Only .rsrc is protected — .rdata/.text must remain writable because
    // some CRT startup code writes to IAT slots and other "read-only" areas.
    for (main_module.parser.sections) |sec| {
        const name = &sec.Name;
        const is_rsrc = (name[0] == '.' and name[1] == 'r' and name[2] == 's' and name[3] == 'r' and name[4] == 'c');
        if (is_rsrc) {
            cpu.memory.pe_image_end = preferred_base +% image_size;
            const rsrc_start = preferred_base +% sec.VirtualAddress;
            const rsrc_end = rsrc_start +% sec.Misc.VirtualSize;
            // Mark everything writable EXCEPT .rsrc
            if (rsrc_start > preferred_base) {
                cpu.memory.addWritableSection(preferred_base, rsrc_start);
            }
            if (rsrc_end < preferred_base +% image_size) {
                cpu.memory.addWritableSection(rsrc_end, preferred_base +% image_size);
            }
            break;
        }
    }

    // Wire up guest heap for all stubs (VirtualAlloc, HeapAlloc, malloc, etc.)
    const stub_common = @import("win32/shared.zig");
    stub_common.guest_memory = &cpu.memory;

    // Register spawn handler so _spawnvp can load child PEs in-process
    stub_common.spawn_handler = &wasmSpawnHandler;

    // Stack occupies the region between the PE image and the thunk area.
    // ESP starts near the top of the stack region (just below thunks).
    cpu.esp = thunk_base_addr -% 16;
    cpu.ebp = cpu.esp;

    // Point FS at the TEB for interpreter FS-relative accesses
    cpu.fs_base = @truncate(@intFromPtr(thread_env));

    log.info("wasm: starting x86 interpreter at EIP=0x{X}, ESP=0x{X}, FS_BASE=0x{X}", .{
        cpu.eip,
        cpu.esp,
        cpu.fs_base,
    });

    if (use_jit) {
        if (comptime build_options.enable_jit_host) {
            log.info("JIT mode: compiling and executing x86 blocks via host runtime", .{});
            runWithJitHost(&cpu, allocator);
        } else {
            log.info("JIT mode: compiling x86 blocks to WASM (compile-only, no host)", .{});
            runWithJit(&cpu, allocator);
        }
    } else {
        x86_execute.run(&cpu);
    }

    log.info("wasm: interpreter halted, EAX=0x{X}", .{cpu.eax});

    // Propagate the guest process exit code to the WASM host.
    // Note: wasmtime clamps exit codes ≥126 to 1; wasmer passes them through.
    std.process.exit(@truncate(cpu.eax));
}

// ---------------------------------------------------------------------------
// WASM in-process spawn handler
// ---------------------------------------------------------------------------
// Implements _spawnvp for WASM by loading and executing a child PE in the
// same interpreter. Used by DUMPBIN/LIB/EDITBIN which are thin wrappers
// that exec LINK.EXE.

fn wasmSpawnHandler(cmdname: []const u8, argv_ptr: usize) i32 {
    // Resolve the PE path: convert Win32 path to POSIX
    var posix_buf: [1024]u8 = undefined;
    const posix_len = path_utils.win32ToPosix(cmdname, &posix_buf);
    const exe_path = if (posix_len > 0) posix_buf[0..posix_len] else cmdname;

    log.info("wasm: spawn handler loading child PE '{s}'", .{exe_path});

    // Collect argv strings from parent's guest memory (translate guest VAs).
    // argv_ptr is a guest VA pointing to a null-terminated array of guest VA
    // string pointers. Each must be translated through the parent's GuestMemory.
    var arg_strings: std.ArrayListUnmanaged([]const u8) = .{};
    if (argv_ptr != 0) {
        const host_argv_addr = trace.addr(argv_ptr);
        if (host_argv_addr >= 0x10000) {
            const argv = @as([*]const u32, @ptrFromInt(host_argv_addr));
            var i: usize = 0;
            while (argv[i] != 0) : (i += 1) {
                const s = trace.c_span(argv[i]);
                arg_strings.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, s) catch "") catch break;
            }
        }
    }

    // Save parent state
    const shared = @import("win32/shared.zig");
    const msvcrt_process = @import("win32/msvcrt/process.zig");
    const saved_guest_memory = shared.guest_memory;
    const saved_argc = stubs_msvcrt.global_argc;
    const saved_argv = stubs_msvcrt.global_argv;
    const saved_thunk = loader.saveThunkState();

    defer {
        // Restore parent state
        shared.guest_memory = saved_guest_memory;
        stubs_msvcrt.global_argc = saved_argc;
        stubs_msvcrt.global_argv = saved_argv;
        loader.restoreThunkState(saved_thunk);
        @import("win32/kernel32/process.zig").resetCommandLine();
        msvcrt_process.resetGuestArgs();
    }

    // Load the child PE
    const child_alloc = std.heap.page_allocator;
    var child_env = Environment.init(child_alloc);

    // Register all stub DLLs (same as main)
    stubs_msvcrt.register(&child_env) catch return -1;
    stubs_kernel32.register(&child_env) catch return -1;
    stubs_advapi32.register(&child_env) catch return -1;
    stubs_user32.register(&child_env) catch return -1;
    stubs_ntdll.register(&child_env) catch return -1;
    stubs_shell32.register(&child_env) catch return -1;
    stubs_gdi32.register(&child_env) catch return -1;
    stubs_ole32.register(&child_env) catch return -1;
    stubs_comctl32.register(&child_env) catch return -1;
    stubs_version.register(&child_env) catch return -1;
    stubs_winmm.register(&child_env) catch return -1;
    stubs_imm32.register(&child_env) catch return -1;

    child_env.addBuiltinExport("builtin", "not_implemented", @intFromPtr(&not_implemented)) catch return -1;

    // Add search paths
    child_env.registry.addSearchPath(".") catch {};
    {
        const fixed = child_alloc.dupe(u8, exe_path) catch return -1;
        std.mem.replaceScalar(u8, fixed, '\\', '/');
        if (std.fs.path.dirname(fixed)) |dir| {
            child_env.registry.addSearchPath(dir) catch {};
        }
    }
    // Add host PATH directories
    if (std.process.getEnvVarOwned(child_alloc, "PATH")) |host_path| {
        var it = std.mem.tokenizeScalar(u8, host_path, ':');
        while (it.next()) |p| {
            if (p.len > 0) child_env.registry.addSearchPath(child_alloc.dupe(u8, p) catch continue) catch {};
        }
    } else |_| {}

    const exe_name = std.fs.path.basename(exe_path);
    const child_module = child_env.registry.loadModule(exe_name) catch |err| {
        log.err("wasm: spawn handler failed to load '{s}': {}", .{ exe_name, err });
        return -1;
    };

    const child_image_size: u32 = @truncate(child_module.mapped_memory.len);
    const CHILD_STACK: u32 = 64 * 1024;
    const CHILD_THUNK: u32 = 32 * 1024;
    const CHILD_HEAP: u32 = 16 * 1024 * 1024;
    const child_combined_size = child_image_size + CHILD_STACK + CHILD_THUNK + CHILD_HEAP;
    const child_buf = child_alloc.alloc(u8, child_combined_size) catch return -1;

    // Use the buffer's host address as base_addr so each child gets a unique
    // address range in WASM linear memory (avoids collisions with parent).
    const child_preferred: u32 = @intCast(@intFromPtr(child_buf.ptr));

    @memset(child_buf[child_image_size .. child_image_size + CHILD_STACK], 0);
    @memset(child_buf[child_image_size + CHILD_STACK ..], 0xCC);

    const child_thunk_base = child_preferred +% child_image_size +% CHILD_STACK;
    var child_guest_mem = x86_memory.GuestMemory{
        .base = child_buf,
        .base_addr = child_preferred,
    };
    loader.setThunkMemory(&child_guest_mem, child_thunk_base);

    child_guest_mem.heap_start = child_image_size + CHILD_STACK + CHILD_THUNK;
    child_guest_mem.heap_cursor = child_guest_mem.heap_start;
    child_env.relocateDataExports(&child_guest_mem, child_buf, child_preferred);

    // Resolve imports
    var resolved_count: usize = 0;
    while (true) {
        var to_resolve: std.ArrayListUnmanaged(*Module) = .{};
        defer to_resolve.deinit(child_alloc);
        var it = child_env.registry.modules.iterator();
        while (it.next()) |entry| {
            to_resolve.append(child_alloc, entry.value_ptr.*) catch break;
        }
        if (to_resolve.items.len == resolved_count) break;
        for (to_resolve.items) |mod| {
            loader.resolveImports(&child_env, mod) catch {};
        }
        resolved_count = to_resolve.items.len;
    }

    @memcpy(child_buf[0..child_image_size], child_module.mapped_memory[0..child_image_size]);

    // Reverse relocations (same as main PE loading)
    {
        const actual_base: u32 = @truncate(child_module.image_base);
        if (actual_base != child_preferred) {
            const reverse_delta = child_preferred -% actual_base;
            const opt_header = &child_module.parser.getNtHeaders().OptionalHeader;
            const reloc_dir = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC];
            if (reloc_dir.Size > 0) {
                var reloc_offset = reloc_dir.VirtualAddress;
                const reloc_end = reloc_offset + reloc_dir.Size;
                while (reloc_offset < reloc_end) {
                    const block_va = @as(*align(1) const u32, @ptrCast(child_buf[reloc_offset..].ptr)).*;
                    const block_size = @as(*align(1) const u32, @ptrCast(child_buf[reloc_offset + 4 ..].ptr)).*;
                    if (block_size == 0) break;
                    const entries_count = (block_size - 8) / 2;
                    for (0..entries_count) |e| {
                        const entry = @as(*align(1) const u16, @ptrCast(child_buf[reloc_offset + 8 + e * 2 ..].ptr)).*;
                        if (entry >> 12 == 3) {
                            const patch_addr = block_va + (entry & 0x0FFF);
                            if (patch_addr + 4 <= child_image_size) {
                                const ptr = @as(*align(1) u32, @ptrCast(child_buf[patch_addr..].ptr));
                                ptr.* = ptr.* +% reverse_delta;
                            }
                        }
                    }
                    reloc_offset += block_size;
                }
            }
        }
    }

    // Zero-fill BSS sections
    for (child_module.parser.sections) |sec| {
        const vsize = sec.Misc.VirtualSize;
        if (vsize > sec.SizeOfRawData) {
            const bss_start = sec.VirtualAddress + sec.SizeOfRawData;
            const bss_end = sec.VirtualAddress + vsize;
            if (bss_end <= child_buf.len) {
                @memset(child_buf[bss_start..bss_end], 0);
            }
        }
    }

    // Build argv in child's guest memory so the interpreter's string functions
    // can access argv strings via GuestMemory translation.
    var child_argv_ptrs: std.ArrayListUnmanaged(?[*:0]u8) = .{};
    for (arg_strings.items) |s| {
        // Allocate string in child guest heap
        const guest_va = child_guest_mem.guestAlloc(@intCast(s.len + 1));
        if (guest_va != 0) {
            const offset = guest_va - child_preferred;
            @memcpy(child_buf[offset..][0..s.len], s);
            child_buf[offset + s.len] = 0; // null terminator
            // The argv pointer must be a guest VA (u32), stored as a [*:0]u8
            // When the thunk dispatcher reads it, c_span(argv[i]) will call
            // trace.addr() which translates through guest_memory.
            child_argv_ptrs.append(std.heap.page_allocator, @ptrFromInt(guest_va)) catch {};
        }
    }
    child_argv_ptrs.append(std.heap.page_allocator, null) catch {};

    stubs_msvcrt.global_argc = @intCast(arg_strings.items.len);
    stubs_msvcrt.global_argv = child_argv_ptrs.items.ptr;
    @import("win32/kernel32/process.zig").resetCommandLine();
    @import("win32/msvcrt/process.zig").resetGuestArgs();

    // Set up child CPU
    const ep_rva = child_module.parser.getNtHeaders().OptionalHeader.AddressOfEntryPoint;
    if (ep_rva == 0) return -1;

    var child_cpu = x86_cpu.Cpu{};
    child_cpu.memory = x86_memory.GuestMemory{
        .base = child_buf,
        .base_addr = child_preferred,
        .heap_start = child_image_size + CHILD_STACK + CHILD_THUNK,
        .heap_cursor = child_guest_mem.heap_cursor,
    };
    child_cpu.eip = child_preferred +% ep_rva;
    child_cpu.esp = child_thunk_base -% 16;
    child_cpu.ebp = child_cpu.esp;

    // Reuse parent's TEB
    child_cpu.fs_base = @truncate(teb.teb_base_addr);

    shared.guest_memory = &child_cpu.memory;

    // .rsrc write protection for child
    for (child_module.parser.sections) |sec| {
        const name = &sec.Name;
        if (name[0] == '.' and name[1] == 'r' and name[2] == 's' and name[3] == 'r' and name[4] == 'c') {
            child_cpu.memory.pe_image_end = child_preferred +% child_image_size;
            const rsrc_start = child_preferred +% sec.VirtualAddress;
            const rsrc_end = rsrc_start +% sec.Misc.VirtualSize;
            if (rsrc_start > child_preferred)
                child_cpu.memory.addWritableSection(child_preferred, rsrc_start);
            if (rsrc_end < child_preferred +% child_image_size)
                child_cpu.memory.addWritableSection(rsrc_end, child_preferred +% child_image_size);
            break;
        }
    }

    log.info("wasm: child PE '{s}' at EIP=0x{X}, ESP=0x{X}", .{ exe_name, child_cpu.eip, child_cpu.esp });

    // Set up child exit code capture + CPU pointer for halt
    var exit_code: i32 = 0;
    shared.child_exit_code = &exit_code;
    shared.child_cpu = &child_cpu;
    defer {
        shared.child_exit_code = null;
        shared.child_cpu = null;
    }

    // Run child interpreter
    x86_execute.run(&child_cpu);

    log.info("wasm: child PE '{s}' exited with code {d}", .{ exe_name, exit_code });
    return exit_code;
}

// ---------------------------------------------------------------------------
// JIT-integrated execution loop
// ---------------------------------------------------------------------------

const jit_compiler = @import("jit/compiler.zig");
const jit_host_mod = @import("jit/host.zig");
const x86_decoder = @import("x86/decoder.zig");

const build_options = @import("build_options");

/// JIT-integrated execution loop with host execution support.
/// When enable_jit_host is true (build option), compiled WASM blocks are
/// sent to the host runtime (browser/zine-host) for actual execution.
/// CPU state is transferred via JitCpuState in shared linear memory.
fn runWithJitHost(cpu: *x86_cpu.Cpu, allocator: std.mem.Allocator) void {
    const host_wasm = @import("jit/host_wasm.zig");
    const jit_host = host_wasm.wasmJitHost();

    // Allocate the JitCpuState in the arena — its WASM linear memory
    // address is used by the generated code for state transfer.
    var jit_state = jit_host_mod.JitCpuState{};
    const state_addr: u32 = @intFromPtr(&jit_state);

    // mem_base = wasm_linear_addr_of_buffer - guest_va_base
    // This allows JIT'd code to translate guest VAs to WASM linear memory offsets.
    jit_state.mem_base = @as(i32, @bitCast(@as(u32, @intFromPtr(cpu.memory.base.ptr)) -% cpu.memory.base_addr));

    var jit = jit_compiler.JitCompiler.init(allocator, state_addr);
    defer jit.deinit();

    // Cache: guest_eip → host block id
    var block_ids = std.AutoHashMap(u32, jit_host_mod.BlockId).init(allocator);
    defer block_ids.deinit();

    var blocks_compiled: u32 = 0;
    var blocks_executed: u32 = 0;
    var expected_next_eip: u32 = 0;

    while (!cpu.halted) {
        const eip = cpu.eip;

        // Only attempt JIT at basic block entries (discontinuous EIP changes)
        if (eip != expected_next_eip) {
            // Try to execute a cached JIT block
            if (block_ids.get(eip)) |block_id| {
                // Transfer CPU state to the shared struct
                jit_state.eax = cpu.eax;
                jit_state.ecx = cpu.ecx;
                jit_state.edx = cpu.edx;
                jit_state.ebx = cpu.ebx;
                jit_state.esp = cpu.esp;
                jit_state.ebp = cpu.ebp;
                jit_state.esi = cpu.esi;
                jit_state.edi = cpu.edi;
                jit_state.eip = eip;
                jit_state.eflags = cpu.flags.toEflags();
                jit_state.status = jit_host_mod.JitCpuState.STATUS_CONTINUE;

                // Execute the compiled block via the host
                jit_host.call(block_id);

                // Read state back
                cpu.eax = jit_state.eax;
                cpu.ecx = jit_state.ecx;
                cpu.edx = jit_state.edx;
                cpu.ebx = jit_state.ebx;
                cpu.esp = jit_state.esp;
                cpu.ebp = jit_state.ebp;
                cpu.esi = jit_state.esi;
                cpu.edi = jit_state.edi;
                cpu.eip = jit_state.eip;
                cpu.flags.fromEflags(jit_state.eflags);

                blocks_executed += 1;
                expected_next_eip = cpu.eip;
                continue;
            }

            // Compile a new block if we haven't seen this EIP
            if (!jit.block_cache.contains(eip)) {
                if (cpu.memory.readSlice(eip, 256)) |code| {
                    const block_len = scanBlock(code);
                    if (block_len > 0) {
                        jit.module.deinit();
                        jit.module = @import("jit/emitter.zig").WasmModule.init(allocator);

                        if (jit.compile(eip, code[0..block_len])) |wasm_bin| {
                            // Send to host for compilation
                            if (jit_host.compile(wasm_bin)) |block_id| {
                                block_ids.put(eip, block_id) catch {};
                                blocks_compiled += 1;
                                if (blocks_compiled <= 10) {
                                    log.info("JIT: compiled+loaded block at EIP=0x{X} ({d} x86 bytes -> {d} WASM bytes)", .{
                                        eip, block_len, wasm_bin.len,
                                    });
                                } else if (blocks_compiled == 11) {
                                    log.info("JIT: (suppressing further compilation logs)", .{});
                                }
                            }
                            allocator.free(wasm_bin);
                        } else |_| {}
                    }
                }
            }
        }

        // Fall back to interpreter for one instruction
        x86_execute.step(cpu);
        expected_next_eip = cpu.eip;
    }

    log.info("JIT: compiled {d} blocks, executed {d} block calls", .{ blocks_compiled, blocks_executed });
}

/// Compile-only JIT loop (no host execution).
/// Validates the JIT compiler on real PE code; compiled WASM is discarded.
fn runWithJit(cpu: *x86_cpu.Cpu, allocator: std.mem.Allocator) void {
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
                    jit.module = @import("jit/emitter.zig").WasmModule.init(allocator);

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

/// Scan x86 code to find the end of a basic block (up to a terminating
/// instruction like RET, JMP, HLT, or INT3).
fn scanBlock(code: []const u8) usize {
    var offset: usize = 0;
    while (offset < code.len) {
        const insn = x86_decoder.decode(code[offset..]);
        if (insn.length == 0) break;
        offset += insn.length;

        // Block terminators
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
