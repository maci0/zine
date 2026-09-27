//! WebAssembly entry point for Zine (WASI CLI mode).
//!
//! This module provides a standard `main()` entry point for the WASM
//! build, allowing Zine to run on WASI runtimes like wasmtime. It
//! initializes the guest environment and starts execution.
//!
//! It supports software interpretation (default) and JIT compilation
//! (--jit) of x86 code. Native x86 execution is not available on WASM.

const std = @import("std");
const platform = @import("platform.zig");
const pe = @import("pe.zig");
const teb = @import("win32/teb.zig");
const path_utils = @import("path_utils.zig");
const text_utils = @import("text_utils.zig");
const Module = @import("loader/module.zig").Module;
const Environment = @import("loader/env.zig").Environment;
const loader = @import("loader/loader.zig");
const x86_cpu = @import("x86/cpu.zig");
const x86_execute = @import("x86/execute.zig");
const x86_memory = @import("x86/memory.zig");
const x86_thunks = @import("x86/thunks.zig");
const trace = @import("trace.zig");
const log = @import("log.zig");
const profiler = @import("profiler.zig");
const version = @import("version.zig");
const stub_common = @import("win32/shared.zig");

const runner = @import("runner.zig");
const stubs_msvcrt = @import("win32/msvcrt.zig");
const stubs_kernel32 = @import("win32/kernel32.zig");
const x86_decoder = @import("x86/decoder.zig");

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

const runtime = @import("runtime.zig");

/// Upper bound on the guest working directory, excluding the "Z:\" prefix and
/// the terminating NUL that `path_utils` appends.
const max_guest_cwd_len = 1021;

/// Parses a `--jit-max-eip` value. A rejected value is a usage error, so the
/// diagnostic names the option and the offending text, and the process ends
/// with the usage status rather than continuing with the default bound.
fn parseJitMaxEip(val: []const u8) u32 {
    if (val.len == 0) {
        std.debug.print("{s}", .{"Error: --jit-max-eip requires a non-empty value.\nTry 'zine --help' for more information.\n"});
        std.process.exit(2);
    }
    return std.fmt.parseInt(u32, val, 0) catch {
        var err_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "Error: --jit-max-eip requires a u32 value (decimal or 0x-prefixed hex), got '{s}'.\nTry 'zine --help' for more information.\n", .{val}) catch "Error: --jit-max-eip requires a u32 value.\nTry 'zine --help' for more information.\n";
        std.debug.print("{s}", .{msg});
        std.process.exit(2);
    };
}

/// The entry point for the WASM build of Zine.
/// It sets up guest memory, loads the PE, and starts the x86 interpreter.
pub fn main(init: std.process.Init) !void {
    runtime.init(init.io, init.gpa, init.minimal.environ);
    const allocator = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(allocator);
    _ = args.next();

    var target_exe_opt: ?[]const u8 = null;
    var argv0_opt: ?[]const u8 = null;
    var app_args: std.ArrayListUnmanaged(?[*:0]u8) = .empty;
    var use_jit = false;
    var jit_max_eip: u32 = 0xFFFFFFFF;
    var end_of_options = false;

    log.initFromEnv(init.environ_map) catch {
        std.debug.print("{s}", .{"Error: ZINE_LOG_LEVEL must be one of: fatal, error, err, warn, info, trace.\n"});
        std.process.exit(2);
    };

    // ZINE_CWD is validated with the other startup settings, before any output
    // and before the guest loads, so `--version` reports a rejected value
    // instead of exiting 0 over it.
    const zine_cwd: ?[]const u8 = init.environ_map.get("ZINE_CWD");
    if (zine_cwd) |cwd| {
        if (cwd.len == 0 or cwd[0] != '/') {
            std.debug.print("Error: ZINE_CWD must be an absolute POSIX path, got '{s}'.\n", .{cwd});
            std.process.exit(2);
        }
        if (cwd.len > max_guest_cwd_len) {
            std.debug.print("Error: ZINE_CWD must be at most {d} bytes, got {d}.\n", .{ max_guest_cwd_len, cwd.len });
            std.process.exit(2);
        }
    }

    {
        const env_map = init.environ_map;
        if (env_map.get("ZINE_TRACE") != null) {
            trace.enable_tracing = true;
        }
        if (env_map.get("ZINE_TRACE_INSN") != null) {
            trace.enable_instructions = true;
        }
        if (env_map.get("ZINE_PROFILE") != null) {
            profiler.enabled = true;
        }
    }

    var arg_count: usize = 0;
    while (args.next()) |arg| {
        const is_first_arg = arg_count == 0;
        arg_count += 1;
        // wasmtime forwards its own `--` separator as the first guest
        // argument. Consuming it here keeps the options behind it parseable; a
        // second `--` still ends option parsing as usual.
        if (std.mem.eql(u8, arg, "--")) {
            if (!is_first_arg) end_of_options = true;
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
        if (!end_of_options and (std.mem.eql(u8, arg, "--interpret") or std.mem.eql(u8, arg, "-i"))) {
            // WASM always uses the interpreter; accept silently
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--jit")) {
            use_jit = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--jit-max-eip")) {
            // Same two spellings as --argv0: a separate argument, or "=".
            const val = args.next() orelse {
                std.debug.print("{s}", .{"Error: --jit-max-eip requires a value.\nTry 'zine --help' for more information.\n"});
                std.process.exit(2);
            };
            jit_max_eip = parseJitMaxEip(val);
            continue;
        }
        if (!end_of_options and std.mem.startsWith(u8, arg, "--jit-max-eip=")) {
            jit_max_eip = parseJitMaxEip(arg["--jit-max-eip=".len..]);
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--profile")) {
            profiler.enabled = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q"))) {
            // A flag wins over ZINE_LOG_LEVEL, so this overrides whatever the
            // environment selected at startup.
            log.min_level = .warn;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            runtime.writeCliOut(
                \\Usage: zine [options] [--] <target.exe> [args...]
                \\
                \\Run a Win32 PE executable in a WebAssembly environment.
                \\
                \\Options:
                \\  -i, --interpret     Use x86 software interpreter (default on WASM)
                \\      --jit           Use JIT compiler (x86-to-WASM translation)
                \\      --jit-max-eip <u32>
                \\                      Only JIT blocks below this EIP (decimal or
                \\                      0x-prefixed hex; debugging). Also accepted
                \\                      as --jit-max-eip=<u32>
                \\      --argv0 <name>  Override argv[0] passed to the target
                \\  -t, --trace         Enable all tracing (API + instructions)
                \\      --trace-api     Enable API tracing only
                \\      --trace-insn    Enable x86 instruction tracing only
                \\      --profile       Enable profiling (hot code, opcodes, stubs)
                \\  -q, --quiet         Only report warnings and errors on stderr
                \\
                \\  -h, --help          Show this help message
                \\  -v, --version       Show version information
                \\  --                  Stop processing options
                \\
                \\Environment:
                \\  ZINE_TRACE          Set to any value to enable API tracing
                \\  ZINE_TRACE_INSN     Set to any value to enable instruction tracing
                \\  ZINE_PROFILE        Set to any value to enable profiling
                \\  ZINE_LOG_LEVEL      fatal, error, err, warn, info, trace (default: trace)
                \\  ZINE_CWD            Absolute POSIX path used as the guest working
                \\                      directory (default: .)
                \\  ZINE_VIRTUAL_CLOCK_NS
                \\                      Guest clock start in ns since the Unix
                \\                      epoch; unset uses the host clock
                \\  ZINE_CLOCK_STEP_NS  Guest clock advance per read, ns
                \\                      (default: 1000000; needs ZINE_VIRTUAL_CLOCK_NS)
                \\
                \\Examples:
                \\  wasmtime --dir=. zine.wasm32.wasm -- myapp.exe
                \\  wasmtime --dir=. zine.wasm32.wasm -- --trace myapp.exe
                \\  wasmtime --dir=. zine.wasm32.wasm -- --argv0 editor notepad.exe
                \\
            );
            std.process.exit(0);
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            runtime.writeCliOut("zine " ++ version.string ++ "\n");
            std.process.exit(0);
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--argv0") or std.mem.startsWith(u8, arg, "--argv0="))) {
            if (std.mem.startsWith(u8, arg, "--argv0=")) {
                const val = arg["--argv0=".len..];
                if (val.len == 0) {
                    std.debug.print("{s}", .{"Error: --argv0 requires a non-empty value.\nTry 'zine --help' for more information.\n"});
                    std.process.exit(2);
                }
                argv0_opt = val;
            } else if (args.next()) |val| {
                if (val.len == 0) {
                    std.debug.print("{s}", .{"Error: --argv0 requires a non-empty value.\nTry 'zine --help' for more information.\n"});
                    std.process.exit(2);
                }
                argv0_opt = val;
            } else {
                std.debug.print("{s}", .{"Error: --argv0 requires a value.\nTry 'zine --help' for more information.\n"});
                std.process.exit(2);
            }
            continue;
        }
        if (!end_of_options and target_exe_opt == null and arg.len > 1 and arg[0] == '-') {
            var err_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "Error: unknown option '{s}'.\nTry 'zine --help' for more information.\n", .{arg}) catch "Error: unknown option.\n";
            std.debug.print("{s}", .{msg});
            std.process.exit(2);
        }

        if (target_exe_opt == null) {
            target_exe_opt = arg;
            end_of_options = true; // Stop parsing emulator flags once target is found
            // First positional arg is the target exe — convert to Win32 path for argv[0]
            const first_arg = if (argv0_opt) |a0| a0 else arg;
            var win_buf: [1024]u8 = undefined;
            const win_len = try path_utils.posixToWin32(first_arg, &win_buf);
            if (win_len > 0) {
                try app_args.append(allocator, try allocator.dupeZ(u8, win_buf[0..win_len]));
            } else {
                try app_args.append(allocator, try allocator.dupeZ(u8, first_arg));
            }
        } else {
            // Convert absolute POSIX paths to Win32 for guest PE arguments.
            // Distinguish paths from MSVC-style options:
            //  - /Fo/tmp/x.obj, /I/usr/include → short-name option (first
            //    component "Fo"/"I" is <=2 chars), passed through as-is;
            //  - /tmp/hello.c → real path (first component "tmp" is >=3 chars);
            //  - /LIBPATH:/x/y, /OUT:e2e.exe → option carrying a ':'-separated
            //    value. Only the value is converted when it is a POSIX path,
            //    so LINK's /LIBPATH:Z:\...\Lib resolves instead of being
            //    mistaken for an input file named "Lib.obj".
            const is_posix_path = blk: {
                if (arg.len <= 2 or arg[0] != '/') break :blk false;
                const rest = arg[1..];
                const next_slash = std.mem.indexOfScalar(u8, rest, '/') orelse break :blk false;
                // First path component must be >= 3 chars to distinguish from
                // MSVC options like /Fo, /Fe, /I, /O1, /Ob, /Od, /Zi, etc.
                break :blk next_slash >= 3;
            };
            // Index of the ':' in "/NAME:value" when the option name part
            // contains it before any path slash (i.e. "/LIBPATH:/x/y").
            const opt_value_colon = blk: {
                if (arg.len <= 2 or arg[0] != '/') break :blk null;
                const rest = arg[1..];
                const colon = std.mem.indexOfScalar(u8, rest, ':') orelse break :blk null;
                const next_slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
                break :blk if (colon < next_slash) colon + 1 else null;
            };
            if (opt_value_colon) |colon_idx| {
                // Convert the value after ':' if it is an absolute POSIX path;
                // otherwise pass the option through unchanged.
                const value = arg[colon_idx + 1 ..];
                if (value.len > 0 and value[0] == '/') {
                    var win_buf: [1024]u8 = undefined;
                    const win_len = try path_utils.posixToWin32(value, &win_buf);
                    if (win_len > 0) {
                        const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ arg[0 .. colon_idx + 1], win_buf[0..win_len] });
                        try app_args.append(allocator, try allocator.dupeZ(u8, joined));
                        continue;
                    }
                }
                try app_args.append(allocator, try allocator.dupeZ(u8, arg));
            } else if (is_posix_path) {
                var win_buf: [1024]u8 = undefined;
                const win_len = try path_utils.posixToWin32(arg, &win_buf);
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
        std.debug.print("{s}", .{"Error: missing required argument <target.exe>.\nTry 'zine --help' for more information.\n"});
        std.process.exit(2);
    }
    const target_exe = target_exe_opt.?;

    log.info("wasm: loading PE from '{s}'", .{target_exe});

    var environment = Environment.init(allocator);

    try runner.registerAllStubs(&environment, @intFromPtr(&not_implemented));

    var host_dirs = try runner.getHostPathDirs(allocator);
    defer runner.freeHostPathDirs(allocator, &host_dirs);
    try runner.setupSearchPaths(&environment, allocator, target_exe, host_dirs.items);

    const exe_name = std.fs.path.basename(target_exe);
    const main_module = environment.registry.loadModule(exe_name) catch |err| {
        runner.failTargetLoad(target_exe, err);
    };
    // Per-application registry overrides (app:<MODULE>: sections).
    @import("win32/advapi32/registry.zig").setAppModule(exe_name);
    // On WASM, the module handle must be the GUEST base VA (not a host pointer)
    // so the x86 interpreter's address translation works correctly.
    stubs_kernel32.main_module_handle = main_module.parser.getNtHeaders().OptionalHeader.ImageBase;

    // WASI builds have no browser/FLTK backend — GUI apps (WinMain / windows
    // subsystem) run headless like native `--no-gui`. The renderer stays
    // uninitialized (g_allocator undefined); renderer cache paths check
    // g_allocator_ready, and setResolution's backend switch skips the
    // .web_ui/.fltk branches when active_backend is .none.
    const renderer = @import("gui/renderer.zig");
    renderer.active_backend = .none;

    // Set main_exe_dir so GetModuleFileNameA can return the correct path.
    // Convert to Windows-style path with backslashes and drive letter.
    if (std.fs.path.dirname(target_exe)) |dir| {
        var win_dir: [512]u8 = undefined;
        var wlen: usize = 0;
        // Add synthetic drive letter for Windows path compatibility
        win_dir[0] = 'Z';
        win_dir[1] = ':';
        wlen = 2;
        for (dir) |c| {
            if (wlen >= win_dir.len - 2) break;
            win_dir[wlen] = if (c == '/') '\\' else c;
            wlen += 1;
        }
        if (wlen > 0 and win_dir[wlen - 1] != '\\') {
            win_dir[wlen] = '\\';
            wlen += 1;
        }
        @memcpy(runtime.main_exe_dir[0..wlen], win_dir[0..wlen]);
        runtime.main_exe_dir_len = wlen;
    }

    log.info("wasm: loaded PE '{s}' at 0x{X} (size={d})", .{
        exe_name,
        main_module.image_base,
        main_module.mapped_memory.len,
    });

    const preferred_base: u32 = main_module.parser.getNtHeaders().OptionalHeader.ImageBase;
    const image_size: u32 = @truncate(main_module.mapped_memory.len);

    const STACK_SIZE: u32 = 64 * 1024;
    const THUNK_RESERVE: u32 = 32 * 1024;
    // MSVC c1.dll's CHeap requests multi-MB arenas (its default limit is
    // ~50MB); a small guest heap made those VirtualAlloc calls fail and the
    // compiler reported C1076/C1063 "heap space exhausted". The WASM module
    // allows up to 2GB, so reserve plenty of room for the compiler heap.
    const HEAP_RESERVE: u32 = 512 * 1024 * 1024; // 512 MB guest heap
    const combined_size = image_size + STACK_SIZE + THUNK_RESERVE + HEAP_RESERVE;
    const combined_buf = try allocator.alloc(u8, combined_size);

    @memset(combined_buf[image_size .. image_size + STACK_SIZE], 0);

    // Fill the thunk area with INT3 (0xCC) for safety
    @memset(combined_buf[image_size + STACK_SIZE ..], 0xCC);

    const thunk_base_addr = preferred_base +% image_size +% STACK_SIZE;

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

    // Set guest_memory BEFORE resolveAllImports so that copyModuleToGuest
    // (which copies PE DLL dependencies into the interpreter's address space)
    // can allocate from the guest heap.
    x86_memory.guest_memory = &thunk_guest_mem;

    // Resolve imports BEFORE copying the PE into combined_buf (patches IAT in mapped_memory)
    try runner.resolveAllImports(&environment, allocator);

    // Copy the PE image (now with patched IAT) into the combined buffer
    @memcpy(combined_buf[0..image_size], main_module.mapped_memory[0..image_size]);

    // On WASM, the PE was mapped at a host address that differs from the
    // preferred ImageBase. Module.load applied relocations for that host address.
    // Reverse relocations: undo Module.load's adjustments so absolute
    // addresses match preferred_base (= GuestMemory virtual addresses).
    loader.applyReverseRelocations(
        combined_buf,
        &main_module.parser,
        image_size,
        @truncate(main_module.image_base),
        preferred_base,
    );

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
                    const copy_len = text_utils.truncateUtf8(span, 4095 - pos).len;
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

    // Set virtual CWD so file opens resolve correctly.
    // On WASI, realpath is not available, so we default to \".\". If the host
    // provides ZINE_CWD (absolute POSIX path of the working directory), use it
    // as \"Z:\\...\" so toHostPath turns every relative path into an absolute
    // one. That is required on runtimes whose \".\" preopen lacks write rights
    // (e.g. wasmer), where cwd()-relative file creation fails with
    // PermissionDenied but absolute-path creation via the \"/\" preopen works.
    {
        var cwd_buf: [max_guest_cwd_len + 3]u8 = undefined;
        var cwd_str: []const u8 = ".";
        if (zine_cwd) |cwd| {
            @memcpy(cwd_buf[0..3], "Z:\\");
            var j: usize = 3;
            for (cwd[1..]) |c| {
                cwd_buf[j] = if (c == '/') '\\' else c;
                j += 1;
            }
            cwd_str = cwd_buf[0..j];
        }
        @memcpy(path_utils.current_directory[0..cwd_str.len], cwd_str);
        path_utils.current_directory_len = cwd_str.len;
    }

    // Pass through host environment variables to the guest.
    // Convert path-valued env vars (INCLUDE, LIB, PATH, TMP, TEMP) to Win32 style.
    {
        var env_list: std.ArrayListUnmanaged(?[*:0]u8) = .empty;
        const env_map_ptr: ?*std.process.Environ.Map = init.environ_map;
        if (env_map_ptr) |env_map| {
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
                        const comp_len = try path_utils.posixToWin32(component, &comp_buf);
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

    // On WASM, setupFS is a no-op (interpreter uses cpu.fs_base directly)
    try teb.setupFS(thread_env);

    // --- Set up CPU and run interpreter ---
    const ep_rva: u32 = main_module.parser.getNtHeaders().OptionalHeader.AddressOfEntryPoint;
    if (ep_rva == 0) {
        log.fatal("No entry point found in '{s}'.", .{exe_name});
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

    loader.protectRsrc(main_module.parser.sections, &cpu.memory, preferred_base, image_size);

    // Wire up guest heap for all stubs (VirtualAlloc, HeapAlloc, malloc, etc.)
    // (stub_common was already imported above for the pre-resolveAllImports setup)
    x86_memory.guest_memory = &cpu.memory;

    // Register spawn handler so _spawnvp can load child PEs in-process
    stub_common.spawn_handler = &wasmSpawnHandler;

    // Stack occupies the region between the PE image and the thunk area.
    // ESP starts near the top of the stack region (just below thunks).
    cpu.esp = thunk_base_addr -% 16;
    cpu.ebp = cpu.esp;

    // Point FS at the TEB for interpreter FS-relative accesses
    cpu.fs_base = @truncate(@intFromPtr(thread_env));
    // Record the TEB base so host stubs (e.g. RaiseException's SEH walk) can
    // read the guest's FS:[0] exception chain via guest memory.
    teb.teb_base_addr = @intFromPtr(thread_env);

    log.info("wasm: starting x86 interpreter at EIP=0x{X}, ESP=0x{X}, FS_BASE=0x{X}", .{
        cpu.eip,
        cpu.esp,
        cpu.fs_base,
    });

    if (profiler.enabled) profiler.start();

    if (use_jit) {
        if (comptime build_options.enable_jit_host) {
            log.info("JIT mode: compiling and executing x86 blocks via host runtime", .{});
            runWithJitHost(&cpu, allocator, jit_max_eip);
        } else {
            log.info("JIT mode: compiling x86 blocks to WASM (compile-only, no host)", .{});
            runner.runWithJit(&cpu, allocator);
        }
    } else {
        x86_execute.run(&cpu);
    }

    profiler.dump();
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
    const posix_len = path_utils.win32ToPosix(cmdname, &posix_buf) catch 0;
    var exe_path: []const u8 = if (posix_len > 0) posix_buf[0..posix_len] else cmdname;

    // If cmdname is empty, extract the intended command from argv[0].
    // CL.EXE passes empty cmdname when it can't construct the C1.DLL path,
    // but argv[0] still contains the bare name (e.g. "c1").
    var argv_name_buf: [256]u8 = undefined;
    log.info("wasmSpawnHandler: initial exe_path '{s}', argv_ptr=0x{X}", .{ exe_path, argv_ptr });
    if (exe_path.len == 0 and argv_ptr != 0) {
        if (argv_ptr >= 0x10000) {
            const host_argv = trace.addr(argv_ptr);
            var i: usize = 0;
            while (true) {
                const arg_va = @as(*const u32, @ptrFromInt(host_argv + i * 4)).*;
                if (arg_va == 0) break;
                const arg_str = trace.c_span(arg_va);
                log.info("wasmSpawnHandler: argv[{d}] = '{s}'", .{ i, arg_str });
                if (exe_path.len == 0 and arg_str.len > 0) {
                    if (arg_str.len < argv_name_buf.len) {
                        @memcpy(argv_name_buf[0..arg_str.len], arg_str);
                        exe_path = argv_name_buf[0..arg_str.len];
                        log.info("wasmSpawnHandler: extracted exe_path from argv[{d}]: '{s}'", .{ i, exe_path });
                    }
                }
                i += 1;
            }
        } else {
            log.info("wasmSpawnHandler: argv_ptr 0x{X} is < 0x10000! Why?", .{argv_ptr});
        }
    }

    var resolved_buf: [1024]u8 = undefined;

    // If cmdname is a bare name without path separators, try to
    // find it in the main PE's directory (e.g. CL.EXE spawning "c1").
    if (exe_path.len > 0 and std.mem.indexOfScalar(u8, exe_path, '/') == null and
        std.mem.indexOfScalar(u8, exe_path, '\\') == null)
    {
        if (runtime.main_exe_dir_len > 0) {
            const dir = runtime.main_exe_dir[0..runtime.main_exe_dir_len];
            const dir_posix_len = path_utils.win32ToPosix(dir, &resolved_buf) catch 0;
            if (dir_posix_len > 0) {
                // The name is guest-supplied and reaches here unbounded when
                // win32ToPosix could not convert it, so the joined path is
                // refused rather than written past the end of the buffer.
                if (dir_posix_len + exe_path.len >= resolved_buf.len) {
                    log.err("wasm: spawn handler: child path does not fit in {d} bytes", .{resolved_buf.len});
                    return -1;
                }
                @memcpy(resolved_buf[dir_posix_len..][0..exe_path.len], exe_path);
                exe_path = resolved_buf[0 .. dir_posix_len + exe_path.len];
            }
        }
    }

    log.info("wasm: spawn handler loading child PE '{s}'", .{exe_path});

    // Collect argv strings from parent's guest memory (translate guest VAs).
    // argv_ptr is a guest VA pointing to a null-terminated array of guest VA
    // string pointers. Each must be translated through the parent's GuestMemory.
    var arg_strings: std.ArrayListUnmanaged([]const u8) = .empty;
    if (argv_ptr != 0) {
        if (argv_ptr >= 0x10000) {
            const host_argv_addr = trace.addr(argv_ptr);
            const argv = @as([*]const u32, @ptrFromInt(host_argv_addr));
            var i: usize = 0;
            while (argv[i] != 0) : (i += 1) {
                var s = trace.c_span(argv[i]);
                // Strip surrounding quotes (DUMPBIN/LIB wrap args in quotes for _spawnvp)
                if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
                    s = s[1 .. s.len - 1];
                }
                arg_strings.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, s) catch "") catch break;
            }
        }
    }

    // Save parent state
    const shared = @import("win32/shared.zig");
    const msvcrt_process = @import("win32/msvcrt/process.zig");
    const kernel32_process = @import("win32/kernel32/process.zig");
    const saved_guest_memory = x86_memory.guest_memory;
    const saved_argc = stubs_msvcrt.global_argc;
    const saved_argv = stubs_msvcrt.global_argv;
    const saved_thunk = loader.saveThunkState();
    const child_alloc = std.heap.page_allocator;
    var child_env = Environment.init(child_alloc);
    var child_buf: ?[]u8 = null;
    var child_argv_ptrs: std.ArrayListUnmanaged(?[*:0]u8) = .empty;

    // The argv copies live in the parent's address space and must outlive
    // the defer that restores it; the child only reads them.
    defer {
        for (arg_strings.items) |s| std.heap.page_allocator.free(s);
        arg_strings.deinit(std.heap.page_allocator);
    }

    defer {
        // Restore parent state
        x86_memory.guest_memory = saved_guest_memory;
        stubs_msvcrt.global_argc = saved_argc;
        stubs_msvcrt.global_argv = saved_argv;
        loader.restoreThunkState(saved_thunk);
        // The child resolved exports into its own thunk memory; those
        // addresses are gone now, so the parent must resolve them again
        // rather than reuse a cache entry pointing into the child image.
        kernel32_process.resetProcCache();
        kernel32_process.resetCommandLine();
        msvcrt_process.resetGuestArgs();
        // Free the child environment last: its module mappings and the
        // child's linear memory (128 MB of it) are the bulk of what a
        // spawning guest would otherwise strand per call.
        for (child_argv_ptrs.items) |p| {
            if (p) |s| std.heap.page_allocator.free(std.mem.span(s));
        }
        child_argv_ptrs.deinit(std.heap.page_allocator);
        if (child_buf) |b| child_alloc.free(b);
        child_env.deinit();
    }

    // Load the child PE
    // Register all stub DLLs (same as main)
    runner.registerAllStubs(&child_env, @intFromPtr(&not_implemented)) catch return -1;
    var child_host_dirs = runner.getHostPathDirs(child_alloc) catch return -1;
    defer runner.freeHostPathDirs(child_alloc, &child_host_dirs);
    runner.setupSearchPaths(&child_env, child_alloc, exe_path, child_host_dirs.items) catch return -1;

    const exe_name = std.fs.path.basename(exe_path);
    const child_module = child_env.registry.loadModule(exe_name) catch |err| {
        log.err("wasm: spawn handler failed to load '{s}': {}", .{ exe_name, err });
        return -1;
    };

    const child_image_size: u32 = @truncate(child_module.mapped_memory.len);
    const CHILD_STACK: u32 = 64 * 1024;
    const CHILD_THUNK: u32 = 32 * 1024;
    // LINK.EXE (spawned by CL.EXE) needs tens of MB for symbol tables and the
    // output image; a 16MB child heap produced LNK1102 "out of memory". 128MB
    // keeps the combined linear memory (main heap + child heap) within the
    // 2GB module max.
    const CHILD_HEAP: u32 = 128 * 1024 * 1024;
    const child_combined_size = child_image_size + CHILD_STACK + CHILD_THUNK + CHILD_HEAP;

    const pe_preferred: u32 = child_module.parser.getNtHeaders().OptionalHeader.ImageBase;
    const has_relocs = child_module.parser.getNtHeaders().OptionalHeader.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC].Size > 0;

    // For fixed-base PEs (no relocation table), we need the buffer at the PE's
    // preferred base so hardcoded addresses match host memory. But we can only
    // do this if the parent's combined_buf doesn't overlap. If both PEs have the
    // same preferred base, fall back to a separate buffer (child won't get correct
    // pointer dereferences in stubs, but at least won't crash the parent).
    child_buf = child_alloc.alloc(u8, child_combined_size) catch return -1;
    const child_mem = child_buf.?;
    // For relocatable PEs, use buffer host address as base.
    // For fixed-base PEs, use preferred ImageBase (interpreter translates correctly,
    // but raw @ptrFromInt in stubs may not work for file paths — trace.addr() handles this).
    const child_preferred: u32 = if (has_relocs)
        @intCast(@intFromPtr(child_mem.ptr))
    else
        pe_preferred;

    @memset(child_mem[child_image_size .. child_image_size + CHILD_STACK], 0);
    @memset(child_mem[child_image_size + CHILD_STACK ..], 0xCC);

    const child_thunk_base = child_preferred +% child_image_size +% CHILD_STACK;
    var child_guest_mem = x86_memory.GuestMemory{
        .base = child_mem,
        .base_addr = child_preferred,
    };
    loader.setThunkMemory(&child_guest_mem, child_thunk_base);

    child_guest_mem.heap_start = child_image_size + CHILD_STACK + CHILD_THUNK;
    child_guest_mem.heap_cursor = child_guest_mem.heap_start;
    child_env.relocateDataExports(&child_guest_mem, child_mem, child_preferred);

    runner.resolveAllImports(&child_env, child_alloc) catch return -1;

    @memcpy(child_mem[0..child_image_size], child_module.mapped_memory[0..child_image_size]);

    loader.applyReverseRelocations(child_mem, &child_module.parser, child_image_size, @truncate(child_module.image_base), child_preferred);
    loader.zeroFillBss(child_mem, child_module.parser.sections);

    // Build argv as host-allocated null-terminated strings.
    // ensureGuestArgs() reads these via std.mem.span() and copies them
    // into the child's guest memory for the interpreter.
    for (arg_strings.items) |s| {
        child_argv_ptrs.append(std.heap.page_allocator, std.heap.page_allocator.dupeZ(u8, s) catch null) catch return -1;
    }
    child_argv_ptrs.append(std.heap.page_allocator, null) catch return -1;

    stubs_msvcrt.global_argc = @intCast(arg_strings.items.len);
    stubs_msvcrt.global_argv = child_argv_ptrs.items.ptr;
    @import("win32/kernel32/process.zig").resetCommandLine();
    @import("win32/msvcrt/process.zig").resetGuestArgs();

    // Set up child CPU
    const ep_rva = child_module.parser.getNtHeaders().OptionalHeader.AddressOfEntryPoint;
    if (ep_rva == 0) return -1;

    var child_cpu = x86_cpu.Cpu{};
    child_cpu.memory = x86_memory.GuestMemory{
        .base = child_mem,
        .base_addr = child_preferred,
        .heap_start = child_image_size + CHILD_STACK + CHILD_THUNK,
        .heap_cursor = child_guest_mem.heap_cursor,
    };
    child_cpu.eip = child_preferred +% ep_rva;
    child_cpu.esp = child_thunk_base -% 16;
    child_cpu.ebp = child_cpu.esp;

    // Reuse parent's TEB
    child_cpu.fs_base = @truncate(teb.teb_base_addr);

    x86_memory.guest_memory = &child_cpu.memory;

    loader.protectRsrc(child_module.parser.sections, &child_cpu.memory, child_preferred, child_image_size);

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

const build_options = @import("build_options");

var global_jit_ptr: ?*jit_compiler.JitCompiler = null;
var global_block_index_ptr: ?*jit_compiler.BlockIndex = null;

fn flushJitCache() callconv(.c) void {
    if (global_block_index_ptr) |index| {
        index.invalidateAll();
    }
    if (global_jit_ptr) |j| {
        @memset(&j.block_cache_keys, jit_compiler.EMPTY_KEY);
    }
}

/// Runs the guest to completion without the JIT. Used when the block cache
/// cannot be allocated.
fn runInterpretedOnly(cpu: *x86_cpu.Cpu) void {
    while (!cpu.halted) x86_execute.step(cpu);
}

/// JIT-integrated execution loop with host execution support.
/// When enable_jit_host is true (build option), compiled WASM blocks are
/// sent to the host runtime (browser/zine-host) for actual execution.
/// CPU state is transferred via JitCpuState in shared linear memory.
fn runWithJitHost(cpu: *x86_cpu.Cpu, allocator: std.mem.Allocator, jit_max_eip: u32) void {
    const host_wasm = @import("jit/host_wasm.zig");

    // Allocate the JitCpuState in the arena — its WASM linear memory
    // address is used by the generated code for state transfer.
    var jit_state = jit_host_mod.JitCpuState{};
    const state_addr: u32 = @intFromPtr(&jit_state);

    // mem_base = wasm_linear_addr_of_buffer - guest_va_base
    // This allows JIT'd code to translate guest VAs to WASM linear memory offsets.
    jit_state.mem_base = @as(i32, @bitCast(@as(u32, @intFromPtr(cpu.memory.base.ptr)) -% cpu.memory.base_addr));

    var jit = jit_compiler.JitCompiler.init(allocator, state_addr);
    defer jit.deinit();

    // Cache: guest_eip → host block id, validated against the x86 bytes the
    // block was compiled from. Fixed 4096-entry direct-mapped table to bound
    // memory; a hit requires the guest bytes to be unchanged.
    var block_index = jit_compiler.BlockIndex.init(allocator) catch {
        log.err("JIT: block index allocation failed, running interpreted", .{});
        runInterpretedOnly(cpu);
        return;
    };
    defer block_index.deinit();
    // Per-block execution counters (hot-block detection): how many times each
    // cached block ran. Mirrors the ring buffer layout.
    var block_counts = [_]u32{0} ** jit_compiler.BLOCK_CACHE_SLOTS;

    // Register SMC invalidation hook globally
    global_jit_ptr = &jit;
    global_block_index_ptr = &block_index;
    stub_common.smc_invalidate_cache = flushJitCache;
    defer {
        global_jit_ptr = null;
        global_block_index_ptr = null;
        stub_common.smc_invalidate_cache = null;
    }

    var blocks_compiled: u32 = 0;
    var blocks_executed: u32 = 0;
    // Linear continuation: the EIP the interpreter would land on after a
    // straight-line instruction (start + length). A branch/call/ret changes
    // EIP to something else, marking that target as a basic-block entry.
    var expected_next_eip: u32 = 0;

    while (!cpu.halted) {
        const eip = cpu.eip;

        // Only attempt JIT at basic block entries (discontinuous EIP changes)
        if (eip != expected_next_eip and eip < jit_max_eip) {
            const cache_idx = eip & jit_compiler.BLOCK_CACHE_MASK;
            var block_id: ?jit_host_mod.BlockId = null;
            if (cpu.memory.readSlice(eip, @intCast(jit_compiler.MAX_JIT_BLOCK_BYTES))) |code| {
                // A hit means these exact bytes are what produced the block.
                // Guest code patched in place, or a region remapped at the
                // same address, misses and recompiles below.
                if (block_index.lookup(eip, code)) |cached| {
                    block_id = cached;
                } else {
                    // The slot is empty, evicted, or holds stale bytes. Drop
                    // the compile mark too, or a mark left by an earlier visit
                    // would suppress the recompile.
                    block_index.invalidateEip(eip);
                    jit.invalidateEip(eip);
                    const block_len = runner.scanBlock(code);
                    if (block_len > 0) {
                        jit.module.deinit();
                        jit.module = @import("jit/emitter.zig").WasmModule.init(allocator);

                        if (jit.compile(eip, code[0..block_len])) |wasm_bin| {
                            // Send to host for compilation
                            if (host_wasm.compile(wasm_bin)) |new_block_id| {
                                block_index.store(eip, code[0..block_len], new_block_id);
                                blocks_compiled += 1;
                                if (blocks_compiled <= 10) {
                                    log.info("JIT: compiled+loaded block at EIP=0x{X} ({d} x86 bytes -> {d} WASM bytes)", .{
                                        eip, block_len, wasm_bin.len,
                                    });
                                } else if (blocks_compiled == 11) {
                                    log.info("JIT: (suppressing further compilation logs)", .{});
                                }
                                block_id = new_block_id;
                            }
                            allocator.free(wasm_bin);
                        } else |_| {}
                    }
                }
            }

            if (block_id) |bid| {
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
                jit_state.fs_base = cpu.fs_base;

                // Execute the compiled block via the host
                host_wasm.call(bid);

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
                cpu.fs_base = jit_state.fs_base;

                blocks_executed += 1;
                block_counts[cache_idx] +|= 1;
                // Live hot-block detection: log when a block crosses each
                // order-of-magnitude execution milestone. The end-of-run
                // report never fires for apps that call exit() (proc_exit
                // unwinds WASM before runWithJitHost returns), so emit hot
                // blocks as they warm up.
                const c = block_counts[cache_idx];
                if (c == 10 or c == 100 or c == 1000 or c == 10000) {
                    log.info("JIT: hot block EIP=0x{X} reached {d} executions", .{ eip, c });
                }
                // The compiled block ends at the first control-flow
                // instruction; the interpreter must handle it, and its target
                // will be the next block entry.
                expected_next_eip = cpu.eip;
                continue;
            }
        }

        // Fall back to interpreter for one instruction. Track the linear
        // continuation so a branch (discontinuous EIP change) marks its target
        // as a block entry on the next iteration.
        const start_eip = cpu.eip;
        var insn_len: u8 = 1;
        if (cpu.memory.readSlice(start_eip, 16)) |code| {
            if (cpu.decode_cache.lookup(start_eip, code)) |insn| {
                insn_len = insn.length;
            } else {
                const decoded = x86_decoder.decode(code);
                if (decoded.length > 0) insn_len = decoded.length;
            }
        }
        x86_execute.step(cpu);
        expected_next_eip = start_eip +% insn_len;
    }

    log.info("JIT: compiled {d} blocks, executed {d} block calls", .{ blocks_compiled, blocks_executed });

    // Hot-block report: find the most-executed cached blocks (top 8).
    // These are the blocks worth pinning/pre-warming for future runs.
    var hot_idx: [8]u32 = .{0} ** 8;
    for (0..4096) |i| {
        const cnt = block_counts[i];
        if (cnt == 0) continue;
        for (0..8) |j| {
            if (cnt > block_counts[hot_idx[j]]) {
                var k: usize = 7;
                while (k > j) : (k -= 1) hot_idx[k] = hot_idx[k - 1];
                hot_idx[j] = @intCast(i);
                break;
            }
        }
    }
    for (hot_idx, 0..) |idx, j| {
        if (block_counts[idx] == 0) break;
        log.info("JIT: hot block #{d}: EIP=0x{X} executed {d} times ({d}% of block calls)", .{
            j + 1,
            block_index.keyAt(idx),
            block_counts[idx],
            @as(u32, @intCast((@as(u64, block_counts[idx]) * 100) / @max(blocks_executed, 1))),
        });
    }
}
