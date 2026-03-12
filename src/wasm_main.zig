// WASM entry point for zine — WASI CLI mode.
//
// This module provides a standard `main()` entry point that wasmtime (or
// any WASI runtime) can call.  It reads a PE file from the filesystem,
// sets up the Win32 stub environment, resolves imports, and runs the x86
// interpreter.
//
// Usage with wasmtime:
//   wasmtime --dir=. zig-out/bin/zine.wasm -- path/to/program.exe

const std = @import("std");
const platform = @import("platform.zig");
const pe = @import("pe.zig");
const teb = @import("teb.zig");
const Module = @import("loader/module.zig").Module;
const Environment = @import("loader/env.zig").Environment;
const loader = @import("loader/loader.zig");
const x86_cpu = @import("x86/cpu.zig");
const x86_execute = @import("x86/execute.zig");
const x86_memory = @import("x86/memory.zig");
const x86_thunks = @import("x86/thunks.zig");
const trace = @import("trace.zig");

// Stub DLL modules
const stubs_msvcrt = @import("stubs/msvcrt.zig");
const stubs_kernel32 = @import("stubs/kernel32.zig");
const stubs_advapi32 = @import("stubs/advapi32.zig");
const stubs_imagehlp = @import("stubs/imagehlp.zig");
const stubs_user32 = @import("stubs/user32.zig");
const stubs_rpcrt4 = @import("stubs/rpcrt4.zig");
const stubs_comdlg32 = @import("stubs/comdlg32.zig");
const stubs_ntdll = @import("stubs/ntdll.zig");
const stubs_mfc42 = @import("stubs/mfc42.zig");
const stubs_winmm = @import("stubs/winmm.zig");
const stubs_ddraw = @import("stubs/ddraw.zig");
const stubs_gdi32 = @import("stubs/gdi32.zig");
const stubs_dinput = @import("stubs/dinput.zig");
const stubs_dsound = @import("stubs/dsound.zig");
const stubs_d3d8 = @import("stubs/d3d8.zig");
const stubs_mss32 = @import("stubs/mss32.zig");
const stubs_shell32 = @import("stubs/shell32.zig");
const stubs_comctl32 = @import("stubs/comctl32.zig");
const stubs_ole32 = @import("stubs/ole32.zig");
const stubs_imm32 = @import("stubs/imm32.zig");
const stubs_version = @import("stubs/version.zig");
const stubs_wsock32 = @import("stubs/wsock32.zig");
const stubs_ws2_32 = @import("stubs/ws2_32.zig");
const stubs_winspool = @import("stubs/winspool.zig");
const stubs_nddeapi = @import("stubs/nddeapi.zig");
const stubs_cards = @import("stubs/cards.zig");
const stubs_icmp = @import("stubs/icmp.zig");
const stubs_vdmdbg = @import("stubs/vdmdbg.zig");
const stubs_mag_hook = @import("stubs/mag_hook.zig");

// Re-export platform to ensure WASM imports are declared
comptime {
    _ = platform;
}

fn not_implemented() callconv(.c) void {
    const ra = @returnAddress();
    const name = x86_thunks.lookupUnresolvedName(ra);
    if (name) |func_name| {
        std.debug.print("\n!!! Unimplemented Win32 API: {s} (called from 0x{X}) !!!\n", .{ func_name, ra });
    } else {
        std.debug.print("\n!!! Unimplemented Win32 API called from 0x{X} !!!\n", .{ra});
    }
    // On WASM we can't call std.process.exit, so halt via trap
    @trap();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next(); // Skip executable name (zine.wasm)

    // Check for trace flags
    var target_exe_opt: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--trace") or std.mem.eql(u8, arg, "-t")) {
            trace.enable_tracing = true;
            trace.enable_instructions = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trace-api")) {
            trace.enable_tracing = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trace-insn")) {
            trace.enable_instructions = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) continue; // Skip wasmtime separator
        if (target_exe_opt == null) {
            target_exe_opt = arg;
        }
    }

    if (target_exe_opt == null) {
        std.debug.print("Usage: zine.wasm [--trace|--trace-api|--trace-insn] <target.exe>\n", .{});
        return error.InvalidArguments;
    }
    const target_exe = target_exe_opt.?;

    std.log.info("wasm: loading PE from '{s}'", .{target_exe});

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
    stubs_kernel32.main_module_handle = @intFromPtr(main_module.mapped_memory.ptr);

    std.log.info("wasm: loaded PE '{s}' at 0x{X} (size={d})", .{
        exe_name,
        main_module.image_base,
        main_module.mapped_memory.len,
    });

    // For the interpreter's GuestMemory, we use the PE's *preferred* image
    // base (from OptionalHeader.ImageBase) as the virtual base address —
    // NOT the actual mmap address. This is critical because EXEs often have
    // no relocation table, so all absolute addresses in x86 code (CALL [IAT],
    // data references, etc.) use the preferred base. The GuestMemory.translate()
    // function subtracts base_addr from virtual addresses to get buffer indices.
    const preferred_base: u32 = main_module.parser.getNtHeaders().OptionalHeader.ImageBase;
    const image_size: u32 = @truncate(main_module.mapped_memory.len);

    // --- Set up thunk memory region for WASM ---
    // IMPORTANT: We must NOT place thunks inside the PE's mapped memory!
    // The PE's SizeOfImage covers all sections including imports and data.
    //
    // Combined buffer layout:
    //   [PE image (SizeOfImage)] [stack (STACK_SIZE)] [thunks (THUNK_RESERVE)]
    //
    const STACK_SIZE: u32 = 64 * 1024;
    const THUNK_RESERVE: u32 = 32 * 1024;
    const combined_size = image_size + STACK_SIZE + THUNK_RESERVE;
    const combined_buf = try allocator.alloc(u8, combined_size);

    // Copy the PE image into the first part of the combined buffer
    @memcpy(combined_buf[0..image_size], main_module.mapped_memory[0..image_size]);

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

    // --- Resolve imports iteratively ---
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

    // --- Initialize MSVCRT globals ---
    // Minimal argv: just the program name
    const argv0 = try allocator.dupeZ(u8, target_exe);
    var argv_storage = [_]?[*:0]u8{ argv0, null };
    stubs_msvcrt.global_argc = 1;
    stubs_msvcrt.global_argv = &argv_storage;

    // Build _acmdln
    stubs_msvcrt.msvcrt_acmdln = @intFromPtr(argv0.ptr);

    // Minimal environment
    var env_storage = [_]?[*:0]u8{null};
    stubs_msvcrt.global_envp = @ptrCast(&env_storage);
    stubs_msvcrt.global_env_initialized = true;

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
        std.debug.print("Error: no entry point found in executable.\n", .{});
        return error.NoEntryPoint;
    }

    var cpu = x86_cpu.Cpu{};
    cpu.memory = x86_memory.GuestMemory{
        .base = combined_buf,
        .base_addr = preferred_base,
    };
    cpu.eip = preferred_base +% ep_rva;

    // Stack goes between the PE image end and the thunk region.
    // The combined buffer layout is: [PE image | stack space | thunks]
    // ESP points to image_size - 16 (just below the thunk area, within the buffer)
    cpu.esp = thunk_base_addr -% 16;
    cpu.ebp = cpu.esp;

    // Point FS at the TEB for interpreter FS-relative accesses
    cpu.fs_base = @truncate(@intFromPtr(thread_env));

    std.log.info("wasm: starting x86 interpreter at EIP=0x{X}, ESP=0x{X}, FS_BASE=0x{X}", .{
        cpu.eip,
        cpu.esp,
        cpu.fs_base,
    });

    x86_execute.run(&cpu);

    std.log.info("wasm: interpreter halted, EAX=0x{X}", .{cpu.eax});
}
