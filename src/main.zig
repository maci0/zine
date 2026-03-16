//! Main entry point for the Zine x86 interpreter (Native CLI).
//!
//! This module provides the standard `main()` function for the native Linux
//! build. It parses command-line arguments, loads a Win32 PE executable,
//! initializes the guest environment (memory, stack, TEB), and starts the
//! x86 interpreter loop.
//!
//! It supports both direct native execution (using the host CPU) and
//! software interpretation.
//!
//! Usage:
//!   zine [options] [--] <target.exe> [args...]

const std = @import("std");
const pe = @import("pe.zig");
const teb = @import("win32/teb.zig");
const Module = @import("loader/module.zig").Module;
const Environment = @import("loader/env.zig").Environment;
const loader = @import("loader/loader.zig");
const stubs_msvcrt = @import("win32/msvcrt.zig");
const stubs_advapi32 = @import("win32/advapi32.zig");
const stubs_imagehlp = @import("win32/imagehlp.zig");
const stubs_kernel32 = @import("win32/kernel32.zig");
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
const stubs_setupapi = @import("win32/setupapi.zig");
const stubs_shlwapi = @import("win32/shlwapi.zig");
const stubs_msvcp60 = @import("win32/msvcp60.zig");
const BatEnv = @import("bat.zig").BatEnv;
const renderer = @import("gui/renderer.zig");
const platform = @import("platform.zig");
const x86_cpu = @import("x86/cpu.zig");
const x86_execute = @import("x86/execute.zig");
const x86_thunks = @import("x86/thunks.zig");
const x86_memory = @import("x86/memory.zig");

const trace = @import("trace.zig");
const log = @import("log.zig");
const profiler = @import("profiler.zig");

/// Fallback function for unimplemented Win32 APIs.
/// It attempts to resolve the name of the missing API and logs a fatal error.
fn not_implemented() callconv(.c) void {
    const ra = @returnAddress();
    const name = x86_thunks.lookupUnresolvedName(ra);
    if (name) |func_name| {
        log.fatal("Unimplemented Win32 API: {s} (called from 0x{X})", .{ func_name, ra });
    } else {
        // Also try to identify via E8→FF25 thunk chain: the caller did
        // E8 rel32 → jmp [IAT], so RA-5 has `E8 rel32`. Resolve the E8
        // target and check if that's a `FF 25 addr32` (jmp thunk).
        var found_name: ?[]const u8 = null;
        if (ra >= 5) {
            const call_site: [*]const u8 = @ptrFromInt(ra - 5);
            if (call_site[0] == 0xE8) {
                const rel = @as(*align(1) const i32, @ptrCast(call_site + 1)).*;
                const target: usize = @intCast(@as(isize, @intCast(ra)) + rel);
                const thunk_ptr: [*]const u8 = @ptrFromInt(target);
                if (thunk_ptr[0] == 0xFF and thunk_ptr[1] == 0x25) {
                    const iat_slot = @as(*align(1) const u32, @ptrCast(thunk_ptr + 2)).*;
                    found_name = x86_thunks.lookupUnresolvedName_bySlot(iat_slot);
                }
            }
        }
        if (found_name) |func_name| {
            log.fatal("Unimplemented Win32 API: {s} (called from 0x{X})", .{ func_name, ra });
        } else {
            log.fatal("Unimplemented Win32 API called from 0x{X}", .{ra});
            // Dump stack for diagnostics
            const esp: usize = @frameAddress();
            if (esp > 0x1000) {
                const stack = @as([*]const u32, @ptrFromInt(esp));
                log.fatal("  Stack context:", .{});
                for (0..8) |i| {
                    log.fatal("    [{d}] = 0x{X}", .{ i, stack[i] });
                }
            }
        }
    }
    std.process.exit(1);
}

/// The entry point for the native Zine executable.
/// It handles CLI argument parsing, environment setup, and starts the emulation.
pub fn main() !void {
    // Pre-initialize vDSO for time functions so they don't crash when FS is changed
    _ = std.time.timestamp();

    platform.installSegfaultHandler();
    platform.mapNullPage();
    platform.raiseStackLimit();

    // Windows processes essentially never cleanly free all memory before ExitProcess or exit()
    // Using GPA will always report thousands of leaks because the process terminates.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // deliberately not deferring deinit to match OS behavior on process exit
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    var target_exe_opt: ?[]const u8 = null;
    var argv0_opt: ?[]const u8 = null;
    var app_args: std.ArrayListUnmanaged(?[*:0]u8) = .{};
    var use_interpreter = false;
    var use_jit = false;
    var no_gui = false;

    if (std.process.hasEnvVarConstant("ZINE_TRACE")) {
        trace.enable_tracing = true;
    }
    if (std.process.hasEnvVarConstant("ZINE_TRACE_INSN")) {
        trace.enable_instructions = true;
    }
    if (std.process.hasEnvVarConstant("ZINE_PROFILE")) {
        profiler.enabled = true;
    }
    
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
        if (!end_of_options and (std.mem.eql(u8, arg, "--interpret") or std.mem.eql(u8, arg, "-i"))) {
            use_interpreter = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--jit")) {
            use_jit = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--profile")) {
            profiler.enabled = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--fltk")) {
            renderer.active_backend = .fltk;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--no-gui")) {
            no_gui = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            std.fs.File.stdout().writeAll(
                \\Usage: zine [options] [--] <target.exe> [args...]
                \\
                \\Run a Win32 PE executable on Linux.
                \\
                \\Options:
                \\  -t, --trace         Enable all tracing output (API + instructions)
                \\      --trace-api     Enable API tracing only
                \\      --trace-insn    Enable x86 instruction tracing only
                \\      --profile       Enable profiling (hot code, opcodes, stubs)
                \\  -i, --interpret     Use x86 software interpreter instead of native execution
                \\      --jit           Use JIT compiler (x86-to-WASM translation)
                \\      --fltk          Use native FLTK GUI instead of web UI
                \\      --no-gui        Disable GUI (no web server), even for GUI apps
                \\      --argv0 <name>  Override argv[0] passed to the target
                \\  -h, --help          Show this help message
                \\  -v, --version       Show version information
                \\  --                  Stop processing options
                \\
                \\Environment:
                \\  ZINE_TRACE          Set to any value to enable API tracing
                \\  ZINE_TRACE_INSN     Set to any value to enable instruction tracing
                \\  ZINE_PROFILE        Set to any value to enable profiling
                \\
                \\Examples:
                \\  zine myapp.exe
                \\  zine --trace myapp.exe input.txt
                \\  zine --argv0 editor notepad.exe file.txt
                \\  zine -- -weird-name.exe
                \\
            ) catch {};
            std.process.exit(0);
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            std.fs.File.stdout().writeAll("zine 0.1.0\n") catch {};
            std.process.exit(0);
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--argv0") or std.mem.startsWith(u8, arg, "--argv0="))) {
            if (std.mem.startsWith(u8, arg, "--argv0=")) {
                argv0_opt = arg["--argv0=".len..];
            } else if (args.next()) |val| {
                argv0_opt = val;
            } else {
                std.fs.File.stderr().writeAll("Error: --argv0 requires a value.\nTry 'zine --help' for more information.\n") catch {};
                std.process.exit(2);
            }
            continue;
        }
        if (!end_of_options and target_exe_opt == null and arg.len > 1 and arg[0] == '-') {
            var err_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "Error: unknown option '{s}'.\nTry 'zine --help' for more information.\n", .{arg}) catch "Error: unknown option.\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            std.process.exit(2);
        }

        if (target_exe_opt == null) {
            target_exe_opt = arg;

            // Push argv0 if provided, otherwise the target_exe
            var first_arg = if (argv0_opt) |a0| a0 else arg;

            // Strip ALL surrounding quotes from first_arg
            while (first_arg.len >= 2 and first_arg[0] == '"' and first_arg[first_arg.len - 1] == '"') {
                first_arg = first_arg[1 .. first_arg.len - 1];
            }

            first_arg = std.mem.trim(u8, first_arg, " \t\r\n\"");

            // Convert to proper Win32 path (drive_c/... -> C:\..., /abs -> Z:\...)
            const path_utils = @import("path_utils.zig");
            var win_path_buf: [1024]u8 = undefined;
            const win_len = path_utils.posixToWin32(first_arg, &win_path_buf);
            const win_arg = try allocator.dupeZ(u8, win_path_buf[0..win_len]);

            try app_args.append(allocator, win_arg);
        } else {
            // Convert args that reference our virtual filesystem to Win32 format.
            // Only convert if the arg starts with "drive_c/" → C:\...
            // Other args (flags like /nologo, relative names, numbers) are passed as-is.
            const path_utils = @import("path_utils.zig");
            if (path_utils.isInsideDriveC(arg)) {
                var win_path_buf: [1024]u8 = undefined;
                const win_len = path_utils.posixToWin32(arg, &win_path_buf);
                try app_args.append(allocator, try allocator.dupeZ(u8, win_path_buf[0..win_len]));
            } else {
                try app_args.append(allocator, try allocator.dupeZ(u8, arg));
            }
        }
    }

    if (target_exe_opt == null) {
        std.fs.File.stderr().writeAll("Error: missing required argument <target.exe>.\nTry 'zine --help' for more information.\n") catch {};
        std.process.exit(2);
    }
    var target_exe = target_exe_opt.?;
    var final_envp: ?[*]?[*:0]u8 = null;
    var bat_env_opt: ?BatEnv = null;

    if (std.mem.endsWith(u8, target_exe, ".bat") or std.mem.endsWith(u8, target_exe, ".BAT") or
        std.mem.endsWith(u8, target_exe, ".cmd") or std.mem.endsWith(u8, target_exe, ".CMD"))
    {
        bat_env_opt = try BatEnv.init(allocator);
        var bat_env = &bat_env_opt.?;

        var bat_args: std.ArrayListUnmanaged([]const u8) = .{};
        for (app_args.items) |arg| {
            if (arg) |a| try bat_args.append(allocator, std.mem.span(a));
        }

        if (try bat_env.parseFile(target_exe, bat_args.items)) |parsed_args| {
            target_exe = parsed_args[0];
            app_args.clearRetainingCapacity();
            for (parsed_args) |arg| {
                const win_arg = try allocator.dupeZ(u8, arg);
                try app_args.append(allocator, win_arg);
            }
            final_envp = try bat_env.buildEnvp();
        } else {
            std.fs.File.stderr().writeAll("Error: failed to parse bat file or no final command found.\n") catch {};
            std.process.exit(1);
        }
    }

    var environment = Environment.init(allocator);
    defer environment.deinit();

    // Setup base fallback export for unresolved symbols
    try environment.addBuiltinExport("builtin", "not_implemented", @intFromPtr(&not_implemented));

    try stubs_msvcrt.register(&environment);
    try stubs_kernel32.register(&environment);
    try stubs_advapi32.register(&environment);
    @import("win32/advapi32/registry.zig").initConfig(allocator);
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
    try stubs_dinput8.register(&environment);
    try stubs_dsound.register(&environment);
    try stubs_d3d8.register(&environment);
    try stubs_mss32.register(&environment);
    try stubs_shell32.register(&environment);
    try stubs_comctl32.register(&environment);
    try stubs_ole32.register(&environment);
    try stubs_oleaut32.register(&environment);
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
    try stubs_shlwapi.register(&environment);
    try stubs_msvcp60.register(&environment);
    try stubs_setupapi.register(&environment);

    // Allow loader to search current dir and the target exe's directory
    try environment.registry.addSearchPath(".");
    // Convert backslashes to forward slashes for dirname extraction on Linux
    const fixed_target = try allocator.dupe(u8, target_exe);
    defer allocator.free(fixed_target);
    std.mem.replaceScalar(u8, fixed_target, '\\', '/');
    if (std.fs.path.dirname(fixed_target)) |dir| {
        try environment.registry.addSearchPath(dir);
    }

    // Add paths from the system PATH environment variable
    if (bat_env_opt) |*be| {
        var bat_path_opt = be.env.get("PATH");
        if (bat_path_opt == null) bat_path_opt = be.env.get("Path");
        
        if (bat_path_opt) |bat_path| {
            trace.print("ZINE BAT PATH: {s}\n", .{bat_path});
            var it = std.mem.tokenizeAny(u8, bat_path, ";:");
            while (it.next()) |p| {
                // Strip quotes
                var clean_p = p;
                if (clean_p.len >= 2 and clean_p[0] == '"' and clean_p[clean_p.len - 1] == '"') {
                    clean_p = clean_p[1 .. clean_p.len - 1];
                }
                const unix_p = try allocator.dupe(u8, clean_p);
                std.mem.replaceScalar(u8, unix_p, '\\', '/');
                try environment.registry.addSearchPath(unix_p);
            }
        }
    }

    // When no BAT environment was loaded, fall back to the host PATH.
    // This is needed when the test harness exports PATH=.../VC98/Bin:...
    // so that LoadLibraryA can find DLLs like MSDIS110.DLL at runtime.
    if (bat_env_opt == null) {
        if (std.process.getEnvVarOwned(allocator, "PATH")) |host_path| {
            defer allocator.free(host_path);
            var it = std.mem.tokenizeScalar(u8, host_path, ':');
            while (it.next()) |p| {
                if (p.len == 0) continue;
                try environment.registry.addSearchPath(try allocator.dupe(u8, p));
            }
        } else |_| {}
    }

    const exe_name = std.fs.path.basename(target_exe);
    const main_module = try environment.registry.loadModule(exe_name);
    stubs_kernel32.main_module_handle = @intFromPtr(main_module.mapped_memory.ptr);

    // Set app code bounds from the PE's .text section for SIGSEGV recovery
    {
        const pe_base = @intFromPtr(main_module.mapped_memory.ptr);
        {
            const sections = main_module.parser.sections;
            for (sections) |sec| {
                if (sec.Characteristics & 0x20 != 0) { // IMAGE_SCN_CNT_CODE
                    stubs_kernel32.app_code_start = pe_base + sec.VirtualAddress;
                    stubs_kernel32.app_code_end = pe_base + sec.VirtualAddress + sec.Misc.VirtualSize;
                    break;
                }
            }
        }
    }

    // Store the exe's directory as a Windows-style path for GetModuleFileNameA
    {
        const path_utils = @import("path_utils.zig");
        const kernel32_path = @import("win32/kernel32/path.zig");
        const fixed_exe = try allocator.dupe(u8, target_exe);
        defer allocator.free(fixed_exe);
        std.mem.replaceScalar(u8, fixed_exe, '\\', '/');
        if (std.fs.path.dirname(fixed_exe)) |dir| {
            // Convert the exe directory to Win32 path
            var win_dir_buf: [1024]u8 = undefined;
            const win_dir_len = path_utils.posixToWin32(dir, &win_dir_buf);
            const copy_len = @min(win_dir_len, stubs_kernel32.main_exe_dir.len - 2);
            @memcpy(stubs_kernel32.main_exe_dir[0..copy_len], win_dir_buf[0..copy_len]);
            var pos = copy_len;
            // Ensure trailing backslash
            if (pos > 0 and stubs_kernel32.main_exe_dir[pos - 1] != '\\') {
                stubs_kernel32.main_exe_dir[pos] = '\\';
                pos += 1;
            }
            stubs_kernel32.main_exe_dir_len = pos;

            // Set virtual CWD to the actual host process CWD (not exe dir)
            // This ensures relative file opens (e.g. "hello.c") resolve against where the user invoked zine
            if (std.fs.cwd().realpathAlloc(allocator, ".")) |real_cwd| {
                var cwd_win_buf: [1024]u8 = undefined;
                const cwd_win_len = path_utils.posixToWin32(real_cwd, &cwd_win_buf);
                const cwd_copy_len = @min(cwd_win_len, kernel32_path.current_directory.len - 1);
                @memcpy(kernel32_path.current_directory[0..cwd_copy_len], cwd_win_buf[0..cwd_copy_len]);
                kernel32_path.current_directory_len = cwd_copy_len;
            } else |_| {
                // Fallback: use exe dir if we can't get the real cwd
                @memcpy(kernel32_path.current_directory[0..win_dir_len], win_dir_buf[0..win_dir_len]);
                kernel32_path.current_directory_len = win_dir_len;
            }
        }
    }

    // Check PE subsystem: IMAGE_SUBSYSTEM_WINDOWS_GUI = 2
    const subsystem = main_module.parser.getNtHeaders().OptionalHeader.Subsystem;
    const is_gui = (subsystem == 2);
    if (is_gui) {
        if (trace.enable_tracing) trace.print("Detected GUI application (subsystem={d})\n", .{subsystem});
    } else {
        if (trace.enable_tracing) trace.print("Detected console application (subsystem={d})\n", .{subsystem});
        renderer.active_backend = .none;
    }

    // --no-gui overrides the subsystem check
    if (no_gui) {
        renderer.active_backend = .none;
    }

    // Initialize Web GUI early so allocator is ready before we extract resources like menus.
    if (renderer.active_backend != .none) {
        try renderer.init(allocator);
    }

    // Extract dynamic menu (GUI apps only)
    if (is_gui) {
        if (main_module.getFirstResource(4)) |menu_data| { // RT_MENU = 4
            const menu_parser = @import("loader/menu_parser.zig");
            if (menu_parser.parseMenuResource(allocator, menu_data)) |json_str| {
                renderer.setMenu(json_str);
            } else |err| {
                log.warn("Failed to parse RT_MENU resource: {}", .{err});
            }
        }
    }

    // Resolve imports iteratively until all modules are processed
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

    try app_args.append(allocator, null);

    stubs_msvcrt.global_argc = @intCast(app_args.items.len - 1);
    stubs_msvcrt.global_argv = app_args.items.ptr;

    // Build _acmdln string from argv for MSVCRT data export
    {
        var cmdline_buf = try allocator.alloc(u8, 4096);
        @memset(cmdline_buf, 0);
        var pos: usize = 0;
        for (app_args.items) |arg_opt| {
            if (arg_opt) |arg| {
                const span = std.mem.span(arg);
                if (pos > 0 and pos < 4095) {
                    cmdline_buf[pos] = ' ';
                    pos += 1;
                }
                const copy_len = @min(span.len, 4095 - pos);
                @memcpy(cmdline_buf[pos .. pos + copy_len], span[0..copy_len]);
                pos += copy_len;
            }
        }
        stubs_msvcrt.msvcrt_acmdln = @intFromPtr(cmdline_buf.ptr);
    }

    // Dump arguments
    if (trace.enable_tracing) {
        trace.print("ZINE ARGS:\n", .{});
        for (app_args.items) |arg_opt| {
            if (arg_opt) |arg| {
                const span = std.mem.span(arg);
                trace.print("  {s}\n", .{span});

                if (span.len > 1 and span[0] == '@') {
                    if (std.fs.cwd().openFile(span[1..], .{})) |f| {
                        var buf: [4096]u8 = undefined;
                        const rb = f.readAll(&buf) catch 0;
                        trace.print("  [RSP FILE CONTENT]:\n{s}\n", .{buf[0..rb]});
                        f.close();
                    } else |_| {}
                }
            }
        }
    }

    log.info("Executing {s}...", .{exe_name});
    if (trace.enable_tracing) {
        log.info("Execution tracing enabled", .{});
    }

    if (final_envp) |envp| {
        stubs_msvcrt.global_envp = @ptrCast(envp);
    } else {
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        const c_envp = try allocator.alloc(?[*:0]u8, env_map.count() + 1);
        var it = env_map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            const env_str = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            c_envp[i] = (try allocator.dupeZ(u8, env_str)).ptr;
            allocator.free(env_str);
            i += 1;
        }
        c_envp[i] = null;
        stubs_msvcrt.global_envp = @ptrCast(c_envp.ptr);
    }

    // Sort environment block (Windows expects sorted env vars)
    var envp_len: usize = 0;
    while (stubs_msvcrt.global_envp[envp_len]) |_| : (envp_len += 1) {}
    const lessThanEnv = struct {
        fn lessThan(context: void, lhs: ?[*:0]const u8, rhs: ?[*:0]const u8) bool {
            _ = context;
            const l = std.mem.span(lhs.?);
            const r = std.mem.span(rhs.?);
            return std.ascii.orderIgnoreCase(l, r) == .lt;
        }
    }.lessThan;
    std.mem.sort(?[*:0]const u8, @as([*]?[*:0]const u8, @ptrCast(@constCast(stubs_msvcrt.global_envp)))[0..envp_len], {}, lessThanEnv);

    stubs_msvcrt.global_env_initialized = true;

    // Initialize TEB/PEB
    const thread_env = try teb.initTEB(allocator);
    teb.teb_base_addr = @intFromPtr(thread_env);
    
    // Build PEB Environment block (Must be UTF-16 on NT)
    var env_total_chars: usize = 1; // Final null
    if (stubs_msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (stubs_msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.c_span(@intFromPtr(env_ptr));
            env_total_chars += span.len + 1;
        }
    }
    // Allocate wide env block.
    // In interpreter mode, must be in low 32-bit memory since the PEB's
    // Environment field is a 32-bit pointer read by guest x86 code.
    const env_byte_size = env_total_chars * 2;
    const env_block: [*]u16 = if (use_interpreter) blk: {
        const kernel32_mem = @import("win32/kernel32/mem.zig");
        const ptr = kernel32_mem.raw_alloc(env_byte_size) orelse {
            log.fatal("Failed to allocate environment block", .{});
            std.process.exit(1);
        };
        break :blk @ptrCast(@alignCast(ptr));
    } else blk: {
        const mem = try allocator.alloc(u16, env_total_chars);
        break :blk mem.ptr;
    };
    var env_pos: usize = 0;
    if (stubs_msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (stubs_msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.c_span(@intFromPtr(env_ptr));
            for (span) |c| {
                env_block[env_pos] = c;
                env_pos += 1;
            }
            env_block[env_pos] = 0;
            env_pos += 1;
        }
    }
    env_block[env_pos] = 0;
    
    const peb = @as(*teb.PEB, @ptrFromInt(thread_env.ProcessEnvironmentBlock));
    const params = @as(*teb.RTL_USER_PROCESS_PARAMETERS, @ptrFromInt(peb.ProcessParameters));
    params.Environment = @truncate(@intFromPtr(env_block));

    try teb.setupFS(thread_env);

    if (use_interpreter or use_jit) {
        // x86 software interpreter path — jump straight to the entry point.
        // The PE entry point calls CRT init and DllMain itself, so we skip
        // the native DllMain dispatch and CRT env logging.
        const ep = main_module.entry_point orelse {
            std.fs.File.stderr().writeAll("Error: no entry point found in executable.\n") catch {};
            std.process.exit(1);
        };
        const base: u32 = @truncate(main_module.image_base);
        // Allocate a dedicated 1MB stack for the interpreter
        const stack_size = 1024 * 1024;
        const stack_mem = try platform.mmap(null, stack_size, true, -1, 0, false, false);

        var cpu = x86_cpu.Cpu{};
        cpu.memory = x86_memory.GuestMemory{
            .base = main_module.mapped_memory,
            .base_addr = base,
            .native_linear = true, // allow any virtual address to pass through to host memory
        };
        cpu.eip = @truncate(ep);
        cpu.esp = @intCast(@intFromPtr(stack_mem.ptr) + stack_size - 16);
        cpu.ebp = cpu.esp;
        cpu.fs_base = @truncate(teb.teb_base_addr);
        trace.print("Interpreter: EIP=0x{X} ESP=0x{X} fs_base=0x{X} (image base=0x{X}, stack base=0x{X})\n", .{ cpu.eip, cpu.esp, cpu.fs_base, base, @intFromPtr(stack_mem.ptr) });

        if (use_jit) {
            log.warn("JIT on native x86: blocks will be compiled to WASM for validation but NOT executed", .{});
            runWithJit(&cpu, allocator);
        } else {
            x86_execute.run(&cpu);
        }
        profiler.dump();
        trace.print("*** Interpreter halted, EAX=0x{X} ***\n", .{cpu.eax});
        std.process.exit(@truncate(cpu.eax));
    }

    if (stubs_msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (stubs_msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const env_str = trace.c_span(@intFromPtr(env_ptr));
            if (std.ascii.startsWithIgnoreCase(env_str, "LIB=")) {
                if (trace.enable_tracing) trace.print("ENV LIB: {s}\n", .{env_str});
            }
        }
    }

    // Call DllMain for all loaded DLL dependencies (after CRT globals are initialized)
    loader.attachLoadedDlls(&environment);

    if (main_module.getExport("_InvokeCompilerPass@12")) |invoke_addr| {
        trace.print("Executing MSVC Compiler Pass...\n", .{});
        const invoke = @as(*const fn (i32, [*]?[*:0]u8, [*]?[*:0]u8) callconv(.winapi) i32, @ptrFromInt(invoke_addr));
        const rc = invoke(stubs_msvcrt.global_argc, stubs_msvcrt.global_argv, @as([*]?[*:0]u8, @ptrCast(@constCast(stubs_msvcrt.global_envp))));
        std.process.exit(@intCast(rc & 0xFF));
    } else if (main_module.entry_point) |ep| {
        // AppCompat: patch known executables that need runtime fixes
        applyAppCompatPatches(main_module);

        const EntryPointFn = *const fn () callconv(.c) void;
        const entry_point = @as(EntryPointFn, @ptrFromInt(ep));
        entry_point();
        profiler.dump();
        trace.print("*** Entry point returned, exiting ***\n", .{});
        std.process.exit(0);
    } else {
        std.fs.File.stderr().writeAll("Error: no entry point found in executable.\n") catch {};
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// AppCompat: runtime patches for known executables
// ---------------------------------------------------------------------------

fn applyAppCompatPatches(module: *@import("loader/module.zig").Module) void {
    const mem = module.mapped_memory;

    _ = mem;
}

fn scanAndPatch(mem: []align(4096) u8, pattern: []const u8, patch_offset: usize, patch: []const u8) bool {
    if (mem.len < pattern.len) return false;
    var i: usize = 0;
    while (i + pattern.len <= mem.len) : (i += 1) {
        if (std.mem.eql(u8, mem[i .. i + pattern.len], pattern)) {
            log.info("AppCompat: Pattern found at mem offset 0x{X} (VA 0x{X})", .{ i, @intFromPtr(mem.ptr) + i });
            log.info("AppCompat: Before patch: {X:0>2} {X:0>2} -> {X:0>2} {X:0>2}", .{
                mem[i + patch_offset],
                mem[i + patch_offset + 1],
                patch[0],
                patch[1],
            });
            const dest = mem[i + patch_offset .. i + patch_offset + patch.len];
            @memcpy(dest, patch);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// JIT-integrated execution loop
// ---------------------------------------------------------------------------

const jit_compiler = @import("jit/compiler.zig");
const jit_emitter = @import("jit/emitter.zig");
const x86_decoder = @import("x86/decoder.zig");

/// JIT-integrated execution loop.
/// Runs the interpreter and compiles basic blocks as they are encountered.
fn runWithJit(cpu: *x86_cpu.Cpu, allocator: std.mem.Allocator) void {
    var jit = jit_compiler.JitCompiler.init(allocator, 0);
    defer jit.deinit();

    var blocks_compiled: u32 = 0;
    var expected_next_eip: u32 = 0;

    while (!cpu.halted) {
        const eip = cpu.eip;

        // Only compile at actual basic block entries — when EIP changes
        // discontinuously (jump, call, ret). Sequential instruction advances
        // (eip == expected_next_eip) are NOT new blocks.
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

        // Execute one instruction and track the expected next EIP
        x86_execute.step(cpu);
        // After step, cpu.eip is the next instruction. If execution was
        // sequential, this will match eip on the next iteration.
        expected_next_eip = cpu.eip;
    }

    log.info("JIT: compiled {d} unique basic blocks", .{blocks_compiled});
}

/// Scans x86 code to find the end of a basic block.
/// Basic blocks are terminated by control flow instructions like JMP or RET.
fn scanBlock(code: []const u8) usize {
    var offset: usize = 0;
    while (offset < code.len) {
        const insn = x86_decoder.decode(code[offset..]);
        if (insn.length == 0) break;
        offset += insn.length;
        switch (insn.opcode) {
            0xC3, 0xC2, 0xCB, 0xCA, 0xE9, 0xEB, 0xF4, 0xCC => break,
            else => {},
        }
    }
    return offset;
}
