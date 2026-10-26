//! Main entry point for the Zine PE emulator (Native CLI).
//!
//! This module provides the standard `main()` function for the native Linux
//! build. It parses command-line arguments, loads a Win32 PE executable,
//! initializes the guest environment (memory, stack, TEB), and starts
//! execution.
//!
//! It supports direct native execution (using the host CPU), software
//! interpretation, and JIT compilation.
//!
//! Usage:
//!   zine [options] [--] <target.exe> [args...]

const std = @import("std");
const teb = @import("win32/teb.zig");
const teb_layout = @import("win32/teb_layout.zig");
const Module = @import("loader/module.zig").Module;
const pe_resources = @import("pe_resources.zig");
const Environment = @import("loader/env.zig").Environment;
const loader = @import("loader/loader.zig");
const stubs_msvcrt = @import("win32/msvcrt.zig");
const stubs_kernel32 = @import("win32/kernel32.zig");
const BatEnv = @import("bat.zig").BatEnv;
const renderer = @import("gui/renderer.zig");
const platform = @import("platform.zig");
const x86_cpu = @import("x86/cpu.zig");
const x86_execute = @import("x86/execute.zig");
const x86_thunks = @import("x86/thunks.zig");
const x86_memory = @import("x86/memory.zig");
const compat_thunks = if (platform.is_x86_64) @import("x86/compat_thunks.zig") else struct {};

const path_utils = @import("path_utils.zig");
const text_utils = @import("text_utils.zig");
const trace = @import("trace.zig");
const config = @import("config.zig");
const log = @import("log.zig");
const profiler = @import("profiler.zig");
const version = @import("version.zig");
const clispec = @import("clispec.zig");
const build_options = @import("build_options");
const pe = @import("pe.zig");
const runtime = @import("runtime.zig");

fn buildCmdLineString(allocator: std.mem.Allocator, app_args_items: []const ?[*:0]u8) !usize {
    var cmdline_buf = try allocator.alloc(u8, 4096);
    @memset(cmdline_buf, 0);
    var pos: usize = 0;
    for (app_args_items) |arg_opt| {
        if (arg_opt) |arg| {
            const span = std.mem.span(arg);
            if (pos > 0 and pos < 4095) {
                cmdline_buf[pos] = ' ';
                pos += 1;
            }
            const copy_len = text_utils.truncateUtf8(span, 4095 - pos).len;
            @memcpy(cmdline_buf[pos .. pos + copy_len], span[0..copy_len]);
            pos += copy_len;
        }
    }
    return @intFromPtr(cmdline_buf.ptr);
}

/// The entry point for the native Zine executable.
/// It handles CLI argument parsing, environment setup, and starts the emulation.
pub fn main(init: std.process.Init) !void {
    runtime.init(init.io, init.gpa, init.minimal.environ);
    // schema and -o must work with no config and no guest. This exits on schema.
    clispec.prepare(init);

    // Warm up the vDSO time path before we rewrite FS segment (TEB).
    // Without this the first clock_gettime after setupFS() faults.
    _ = platform.timestamp();
    log.initFromEnv(init.environ_map) catch {
        std.debug.print("{s}", .{log.levelErrorMessage()});
        clispec.usageExit();
    };
    config.initFromEnv(init.environ_map) catch |err| {
        std.debug.print("{s}", .{config.initErrorMessage(err)});
        clispec.usageExit();
    };
    if (config.clock.start_ns) |start_ns| {
        runtime.installConfiguredClock(start_ns, config.clock.step_ns);
        log.info("virtual clock: first read {d} ns, {d} ns per read", .{ start_ns, config.clock.step_ns });
    }
    if (!config.web_server.isLoopback()) {
        log.warn("Web UI is bound to {s}, reachable from other hosts", .{config.web_server.host()});
    }

    // Windows processes essentially never cleanly free all memory before ExitProcess or exit()
    // Using GPA will always report thousands of leaks because the process terminates.
    const allocator = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    var target_exe_opt: ?[]const u8 = null;
    var argv0_opt: ?[]const u8 = null;
    var app_args: std.ArrayListUnmanaged(?[*:0]u8) = .empty;
    var use_interpreter = false;
    var use_jit = false;
    var no_gui = false;

    if (config.diagnostics.trace) {
        trace.enable_tracing = true;
    }
    if (config.diagnostics.trace_insn) {
        trace.enable_instructions = true;
    }
    if (config.diagnostics.profile) {
        profiler.enabled = true;
    }

    var end_of_options = false;
    while (args.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output") or std.mem.startsWith(u8, arg, "--output="))) {
            const attached = if (std.mem.startsWith(u8, arg, "--output=")) arg["--output=".len..] else null;
            const value = attached orelse args.next() orelse {
                std.debug.print("{s}", .{"Error: --output requires auto, text, or json.\nTry 'zine --help' for more information.\n"});
                clispec.mode = .auto;
                clispec.usageExit();
            };
            clispec.setMode(value);
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
        if (!end_of_options and (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q"))) {
            // A flag wins over ZINE_LOG_LEVEL, so this overrides whatever the
            // environment selected at startup.
            log.min_level = .warn;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--fltk")) {
            if (!build_options.use_fltk) {
                std.debug.print("{s}", .{"Error: --fltk is not available in this build.\nRebuild with: zig build -Dfltk\nTry 'zine --help' for more information.\n"});
                clispec.usageExit();
            }
            renderer.active_backend = .fltk;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--no-gui")) {
            no_gui = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            runtime.writeCliOut(
                \\Usage: zine [options] [--] <target.exe> [args...]
                \\
                \\Run a Win32 PE executable on Linux.
                \\
                \\Options:
                \\  -i, --interpret     Use x86 software interpreter instead of native execution
                \\      --jit           Use JIT compiler (x86-to-WASM translation)
                \\      --argv0 <name>  Override argv[0] passed to the target; also
                \\                      accepted as --argv0=<name>
                \\  -t, --trace         Enable all tracing (API + instructions)
                \\      --trace-api     Enable API tracing only
                \\      --trace-insn    Enable x86 instruction tracing only
                \\      --profile       Enable profiling (hot code, opcodes, stubs)
                \\  -q, --quiet         Only report warnings and errors on stderr
                \\
                \\      --fltk          Use native FLTK GUI instead of web UI
                \\      --no-gui        Disable GUI (no web server), even for GUI apps
                \\
                \\  -h, --help          Show this help message
                \\  -v, --version       Show version information
                \\  -o, --output FMT    auto, text, or json. auto stays text on a pipe
                \\      schema          Print the CLI Spec document and exit
                \\  --                  Stop processing options; zine -- schema runs a file named schema
                \\
                \\Environment:
                \\  ZINE_TRACE          Set to any value to enable API tracing
                \\  ZINE_TRACE_INSN     Set to any value to enable instruction tracing
                \\  ZINE_PROFILE        Set to any value to enable profiling
                \\  ZINE_LOG_LEVEL      fatal, error, err, warn, info, trace (default: trace)
                \\  ZINE_WEB_HOST       Web UI bind address, IP literal (default: 127.0.0.1)
                \\  ZINE_WEB_PORT       Web UI port, 1-65535 (default: 1995)
                \\  ZINE_CWD            Absolute POSIX path validated at startup;
                \\                      the native build resolves relative guest
                \\                      paths against its own working directory,
                \\                      so only the WASI build consults it
                \\  ZINE_VIRTUAL_CLOCK_NS
                \\                      Guest clock start in ns since the Unix
                \\                      epoch; unset uses the host clock
                \\  ZINE_CLOCK_STEP_NS  Guest clock advance per read, ns
                \\                      (default: 1000000; needs ZINE_VIRTUAL_CLOCK_NS)
                \\
                \\Examples:
                \\  zine myapp.exe
                \\  zine --trace myapp.exe input.txt
                \\  zine --argv0 editor notepad.exe file.txt
                \\  zine -- -weird-name.exe
                \\  zine schema
                \\  zine -- schema
                \\
                \\Exit status:
                \\  0  the guest ran and reported success
                \\  1  the target could not be run, or the guest exited with this
                \\     status
                \\  2  usage error: an unknown option, a missing <target.exe>, or a
                \\     rejected ZINE_* setting
                \\
            );
            std.process.exit(0);
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            if (clispec.wantsJson()) {
                runtime.writeCliOut("{\"version\":\"" ++ version.string ++ "\"}\n");
            } else {
                runtime.writeCliOut("zine " ++ version.string ++ "\n");
            }
            std.process.exit(0);
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--argv0") or std.mem.startsWith(u8, arg, "--argv0="))) {
            // Two spellings: a separate argument, or "=".
            const attached = if (std.mem.startsWith(u8, arg, "--argv0=")) arg["--argv0=".len..] else null;
            const val = attached orelse args.next() orelse {
                std.debug.print("{s}", .{"Error: --argv0 requires a value.\nTry 'zine --help' for more information.\n"});
                clispec.usageExit();
            };
            if (val.len == 0) {
                std.debug.print("{s}", .{"Error: --argv0 requires a non-empty value.\nTry 'zine --help' for more information.\n"});
                clispec.usageExit();
            }
            argv0_opt = val;
            continue;
        }
        if (!end_of_options and target_exe_opt == null and arg.len > 1 and arg[0] == '-') {
            var err_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "Error: unknown option '{s}'.\nTry 'zine --help' for more information.\n", .{arg}) catch "Error: unknown option.\n";
            std.debug.print("{s}", .{msg});
            clispec.usageExit();
        }

        if (target_exe_opt == null) {
            target_exe_opt = arg;
            end_of_options = true; // Stop parsing emulator flags once target is found

            // Push argv0 if provided, otherwise the target_exe
            var first_arg = if (argv0_opt) |a0| a0 else arg;

            // Strip ALL surrounding quotes from first_arg
            while (first_arg.len >= 2 and first_arg[0] == '"' and first_arg[first_arg.len - 1] == '"') {
                first_arg = first_arg[1 .. first_arg.len - 1];
            }

            first_arg = std.mem.trim(u8, first_arg, " \t\r\n\"");

            // Convert to proper Win32 path (drive_c/... -> C:\..., /abs -> Z:\...)
            var win_path_buf: [1024]u8 = undefined;
            const win_len = try path_utils.posixToWin32(first_arg, &win_path_buf);
            const win_arg = try allocator.dupeZ(u8, win_path_buf[0..win_len]);

            try app_args.append(allocator, win_arg);
        } else {
            // Convert args that reference our virtual filesystem to Win32 format.
            // Only convert if the arg starts with "drive_c/" → C:\...
            // Other args (flags like /nologo, relative names, numbers) are passed as-is.
            if (path_utils.isInsideDriveC(arg)) {
                var win_path_buf: [1024]u8 = undefined;
                const win_len = try path_utils.posixToWin32(arg, &win_path_buf);
                try app_args.append(allocator, try allocator.dupeZ(u8, win_path_buf[0..win_len]));
            } else {
                try app_args.append(allocator, try allocator.dupeZ(u8, arg));
            }
        }
    }

    if (no_gui and renderer.active_backend == .fltk) {
        std.debug.print("{s}", .{"Error: --fltk and --no-gui are mutually exclusive.\nTry 'zine --help' for more information.\n"});
        clispec.usageExit();
    }
    if (use_interpreter and use_jit) {
        log.warn("--interpret is ignored when --jit is specified", .{});
    }

    if (target_exe_opt == null) {
        std.debug.print("{s}", .{"Error: missing required argument <target.exe>.\nTry 'zine --help' for more information.\n"});
        clispec.usageExit();
    }
    platform.installSegfaultHandler();
    platform.mapNullPage();
    platform.raiseStackLimit();

    var target_exe = target_exe_opt.?;
    var final_envp: ?[*]?[*:0]u8 = null;
    var bat_env_opt: ?BatEnv = null;

    if (std.mem.endsWith(u8, target_exe, ".bat") or std.mem.endsWith(u8, target_exe, ".BAT") or
        std.mem.endsWith(u8, target_exe, ".cmd") or std.mem.endsWith(u8, target_exe, ".CMD"))
    {
        bat_env_opt = try BatEnv.init(allocator);
        var bat_env = &bat_env_opt.?;

        var bat_args: std.ArrayListUnmanaged([]const u8) = .empty;
        for (app_args.items) |arg| {
            if (arg) |a| try bat_args.append(allocator, std.mem.span(a));
        }

        const bat_command = bat_env.parseFile(target_exe, bat_args.items) catch |err| {
            var err_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "Error: cannot open batch file '{s}' ({s}).\n", .{ target_exe, @errorName(err) }) catch "Error: cannot open batch file.\n";
            std.debug.print("{s}", .{msg});
            std.process.exit(1);
        };
        if (bat_command) |parsed_args| {
            target_exe = parsed_args[0];
            app_args.clearRetainingCapacity();
            for (parsed_args) |arg| {
                const win_arg = try allocator.dupeZ(u8, arg);
                try app_args.append(allocator, win_arg);
            }
            final_envp = try bat_env.buildEnvp();
        } else {
            std.debug.print("Error: '{s}' defines no command to run.\n", .{target_exe});
            std.process.exit(1);
        }
    }

    const runner = @import("runner.zig");

    var environment = Environment.init(allocator);
    defer environment.deinit();

    try runner.registerAllStubs(&environment, @intFromPtr(&x86_thunks.not_implemented_stub));

    // On x86_64, initialize the compat thunk pool for 32-bit PE execution
    if (comptime platform.is_x86_64) {
        try compat_thunks.init();
    }

    // Search paths: CWD + the target's directory + BAT PATH or host PATH
    var extra_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (extra_paths.items) |p| allocator.free(p);
        extra_paths.deinit(allocator);
    }
    if (bat_env_opt) |*be| {
        var bat_path_opt = be.env.get("PATH");
        if (bat_path_opt == null) bat_path_opt = be.env.get("Path");
        if (bat_path_opt) |bat_path| {
            trace.print("ZINE BAT PATH: {s}\n", .{bat_path});
            var it = std.mem.tokenizeAny(u8, bat_path, ";:");
            while (it.next()) |p| {
                var clean_p = p;
                if (clean_p.len >= 2 and clean_p[0] == '"' and clean_p[clean_p.len - 1] == '"') {
                    clean_p = clean_p[1 .. clean_p.len - 1];
                }
                const unix_p = try allocator.dupe(u8, clean_p);
                std.mem.replaceScalar(u8, unix_p, '\\', '/');
                try extra_paths.append(allocator, unix_p);
            }
        }
    } else {
        var host_dirs = try runner.getHostPathDirs(allocator);
        defer runner.freeHostPathDirs(allocator, &host_dirs);
        try extra_paths.ensureUnusedCapacity(allocator, host_dirs.items.len);
        for (host_dirs.items) |d| extra_paths.appendAssumeCapacity(try allocator.dupe(u8, d));
    }
    try runner.setupSearchPaths(&environment, allocator, target_exe, extra_paths.items);

    const exe_name = std.fs.path.basename(target_exe);
    const main_module = environment.registry.loadModule(exe_name) catch |err| {
        runner.failTargetLoad(target_exe, err);
    };
    // Per-application registry overrides (app:<MODULE>: sections).
    @import("win32/advapi32/registry.zig").setAppModule(exe_name);
    stubs_kernel32.main_module_handle = @intFromPtr(main_module.mapped_memory.ptr);

    // Set app code bounds from the PE's .text section for SIGSEGV recovery
    {
        const pe_base = @intFromPtr(main_module.mapped_memory.ptr);
        {
            const sections = main_module.parser.sections;
            for (sections) |sec| {
                if (sec.Characteristics & pe.IMAGE_SCN_CNT_CODE != 0) {
                    runtime.app_code_start = pe_base + sec.VirtualAddress;
                    runtime.app_code_end = pe_base + sec.VirtualAddress + sec.Misc.VirtualSize;
                    break;
                }
            }
        }
    }

    // Store the exe's directory as a Windows-style path for GetModuleFileNameA
    {
        const fixed_exe = try allocator.dupe(u8, target_exe);
        defer allocator.free(fixed_exe);
        std.mem.replaceScalar(u8, fixed_exe, '\\', '/');
        if (std.fs.path.dirname(fixed_exe)) |dir| {
            // Convert the exe directory to Win32 path
            var win_dir_buf: [1024]u8 = undefined;
            const win_dir_len = try path_utils.posixToWin32(dir, &win_dir_buf);
            const copy_len = @min(win_dir_len, runtime.main_exe_dir.len - 2);
            @memcpy(runtime.main_exe_dir[0..copy_len], win_dir_buf[0..copy_len]);
            var pos = copy_len;
            // Ensure trailing backslash
            if (pos > 0 and runtime.main_exe_dir[pos - 1] != '\\') {
                runtime.main_exe_dir[pos] = '\\';
                pos += 1;
            }
            runtime.main_exe_dir_len = pos;

            // Set virtual CWD to the actual host process CWD (not exe dir)
            // This ensures relative file opens (e.g. "hello.c") resolve against where the user invoked zine
            if (std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator)) |real_cwd| {
                var cwd_win_buf: [1024]u8 = undefined;
                const cwd_win_len = try path_utils.posixToWin32(real_cwd, &cwd_win_buf);
                const cwd_copy_len = @min(cwd_win_len, path_utils.current_directory.len - 1);
                @memcpy(path_utils.current_directory[0..cwd_copy_len], cwd_win_buf[0..cwd_copy_len]);
                path_utils.current_directory_len = cwd_copy_len;
            } else |err| {
                // Fallback: use exe dir if we can't get the real cwd. The
                // guest resolves relative paths against this, so say which one
                // it got rather than letting relative opens land somewhere the
                // user never named.
                log.warn("Cannot resolve the current directory ({}), relative paths resolve against the target's directory", .{err});
                @memcpy(path_utils.current_directory[0..win_dir_len], win_dir_buf[0..win_dir_len]);
                path_utils.current_directory_len = win_dir_len;
            }
        }
    }

    const subsystem = main_module.parser.getNtHeaders().OptionalHeader.Subsystem;
    const is_gui = (subsystem == pe.IMAGE_SUBSYSTEM_WINDOWS_GUI);
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
        if (main_module.getFirstResource(pe_resources.RT_MENU)) |menu_data| {
            const menu_parser = @import("loader/menu_parser.zig");
            if (menu_parser.parseMenuResource(allocator, menu_data)) |json_str| {
                renderer.setMenu(json_str);
            } else |err| {
                log.warn("Failed to parse RT_MENU resource: {}", .{err});
            }
        }
    }

    try runner.resolveAllImports(&environment, allocator);

    try app_args.append(allocator, null);

    stubs_msvcrt.global_argc = @intCast(app_args.items.len - 1);
    stubs_msvcrt.global_argv = app_args.items.ptr;

    // Build _acmdln string from argv for MSVCRT data export
    stubs_msvcrt.msvcrt_acmdln = try buildCmdLineString(allocator, app_args.items);

    // Dump arguments
    if (trace.enable_tracing) {
        trace.print("ZINE ARGS:\n", .{});
        for (app_args.items) |arg_opt| {
            if (arg_opt) |arg| {
                const span = std.mem.span(arg);
                trace.print("  {s}\n", .{span});

                if (span.len > 1 and span[0] == '@') {
                    if (std.Io.Dir.cwd().openFile(io, span[1..], .{})) |f| {
                        var buf: [4096]u8 = undefined;
                        const rb = f.readPositionalAll(io, &buf, 0) catch 0;
                        trace.responseFile(span[1..], rb);
                        f.close(io);
                    } else |_| {}
                }
            }
        }
    }

    var web_url_buf: [config.max_url_len]u8 = undefined;
    const web_url = config.web_server.url(&web_url_buf);
    // The settings the run resolved, on one line: an operator reads the active
    // configuration here rather than reconstructing it from the environment it
    // exported. The guest working directory is reported for every build, which
    // only the WASI build reads.
    log.info("zine {s} | exe={s} | mode={s} | gui={s} | web={s} | trace={s} | profile={s} | log={s} | cwd={s}", .{
        version.string,
        exe_name,
        if (use_jit) "jit" else if (use_interpreter) "interpret" else if (platform.is_x86_64) "compat64" else "native",
        if (renderer.active_backend == .none) "off" else "web",
        if (renderer.active_backend == .none) "off" else web_url,
        if (trace.enable_tracing and trace.enable_instructions) "all" else if (trace.enable_tracing) "api" else if (trace.enable_instructions) "insn" else "off",
        if (profiler.enabled) "on" else "off",
        @tagName(log.min_level),
        config.guest.cwd() orelse ".",
    });

    if (final_envp) |envp| {
        stubs_msvcrt.global_envp = @ptrCast(envp);
    } else {
        const env_map = init.environ_map;
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
    const thread_env = try teb.initTEB();
    teb_layout.teb_base_addr = @intFromPtr(thread_env);

    // On x86_64, set very wide stack bounds to cover all MAP_32BIT allocations.
    // Multiple stacks are used (callCompat32 shared stack, enterCompatMode guest
    // stack, etc.) and the CRT's _chkstk compares ESP against StackLimit.
    // Setting wide bounds prevents C1063 false positives.
    if (comptime platform.is_x86_64) {
        thread_env.NtTib.StackBase = 0x7FFF0000; // near top of 32-bit range
        thread_env.NtTib.StackLimit = 0x00100000; // 1MB above null page
    }

    // Build PEB Environment block (Must be UTF-16 on NT)
    var env_total_chars: usize = 1; // Final null
    if (stubs_msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (stubs_msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.host_c_span(@intFromPtr(env_ptr));
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
            const span = trace.host_c_span(@intFromPtr(env_ptr));
            for (span) |c| {
                env_block[env_pos] = c;
                env_pos += 1;
            }
            env_block[env_pos] = 0;
            env_pos += 1;
        }
    }
    env_block[env_pos] = 0;

    const peb = @as(*teb_layout.PEB, @ptrFromInt(thread_env.ProcessEnvironmentBlock));
    const params = @as(*teb_layout.RTL_USER_PROCESS_PARAMETERS, @ptrFromInt(peb.ProcessParameters));
    params.Environment = @truncate(@intFromPtr(env_block));

    // Capture the host TLS base before FS is switched to the guest TEB, so
    // stubs that must call libc (e.g. pthread_create for the WM_TIMER thread)
    // can temporarily restore host TLS via platform.useHostFs().
    platform.saveHostFsBase();

    try teb.setupFS(thread_env);

    if (profiler.enabled) profiler.start();

    if (use_interpreter or use_jit) {
        // x86 software interpreter path — jump straight to the entry point.
        // The PE entry point calls CRT init and DllMain itself, so we skip
        // the native DllMain dispatch and CRT env logging.
        const ep = main_module.entry_point orelse {
            log.fatal("No entry point found in '{s}'.", .{exe_name});
            std.process.exit(1);
        };
        const base: u32 = @truncate(main_module.image_base);
        const stack_size = 1 * 1024 * 1024;
        const stack_mem = try platform.mmap(@ptrFromInt(0x05000000), stack_size, true, -1, 0, false, true);

        // Set proper TEB stack bounds for MSVC compiler pass stack checks
        // C1.DLL mathematically verifies the StackBase - StackLimit native span.
        thread_env.NtTib.StackBase = @intCast(@intFromPtr(stack_mem.ptr) + stack_size);
        thread_env.NtTib.StackLimit = @intCast(@intFromPtr(stack_mem.ptr));

        var cpu = x86_cpu.Cpu{};
        cpu.memory = x86_memory.GuestMemory{
            .base = main_module.mapped_memory,
            .base_addr = base,
            .native_linear = true, // allow any virtual address to pass through to host memory
        };
        cpu.eip = @truncate(ep);
        cpu.esp = @intCast(@intFromPtr(stack_mem.ptr) + stack_size - 16);
        cpu.ebp = cpu.esp;
        cpu.fs_base = @truncate(teb_layout.teb_base_addr);

        trace.print("Interpreter: EIP=0x{X} ESP=0x{X} fs_base=0x{X} (image base=0x{X}, stack base=0x{X})\n", .{ cpu.eip, cpu.esp, cpu.fs_base, base, @intFromPtr(stack_mem.ptr) });

        if (use_jit) {
            log.warn("JIT on native x86: blocks will be compiled to WASM for validation but NOT executed", .{});
            runner.runWithJit(&cpu, allocator);
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
            const env_str = trace.host_c_span(@intFromPtr(env_ptr));
            if (std.ascii.startsWithIgnoreCase(env_str, "LIB=")) {
                if (trace.enable_tracing) trace.print("ENV LIB: {s}\n", .{env_str});
            }
        }
    }

    if (trace.enable_tracing) {
        if (main_module.getExport("_InvokeCompilerPass@12")) |addr| {
            trace.print("Found _InvokeCompilerPass@12 at 0x{X}\n", .{addr});
        } else {
            trace.print("_InvokeCompilerPass@12 not found in {s}\n", .{exe_name});
        }
    }
    if (main_module.getExport("_InvokeCompilerPass@12")) |invoke_addr| {
        trace.print("Executing MSVC Compiler Pass...\n", .{});
        if (comptime platform.is_x86_64) {
            // On x86_64, _InvokeCompilerPass is in a 32-bit PE — must use compat mode
            const guest_stack_size = 16 * 1024 * 1024; // 16MB
            const guest_stack_mem = try platform.mmap(@ptrFromInt(0x05000000), guest_stack_size, true, -1, 0, false, true);
            const guest_esp_top: u32 = @intCast(@intFromPtr(guest_stack_mem.ptr) + guest_stack_size - 64);

            // Set proper TEB stack bounds for MSVC compiler pass stack checks
            // C1.DLL mathematically verifies the StackBase - StackLimit native span.
            // If the span exceeds ~1MB, C1.DLL natively panics resulting in C1063 during deep recursion.
            thread_env.NtTib.StackBase = @intCast(@intFromPtr(guest_stack_mem.ptr) + guest_stack_size);
            thread_env.NtTib.StackLimit = @intCast(@intFromPtr(guest_stack_mem.ptr));

            // Push arguments for _InvokeCompilerPass@12 (stdcall: 3 params)
            // Stack layout: [exit_stub] [arg1: argc] [arg2: argv] [arg3: envp]
            const stack = @as([*]u32, @ptrFromInt(@as(usize, guest_esp_top)));
            const exit_stub = compat_thunks.makeExitStub();
            // Use guest-accessible argv/envp (from ensureGuestArgs, in low 4GB)
            const msvcrt_proc = @import("win32/msvcrt/process.zig");
            msvcrt_proc.ensureGuestArgs();
            stack[0] = exit_stub; // return address
            stack[1] = @intCast(stubs_msvcrt.global_argc);
            stack[2] = msvcrt_proc.guest_argv_addr;
            stack[3] = msvcrt_proc.guest_envp_addr;
            trace.print("compat: entering _InvokeCompilerPass at 0x{X} ESP=0x{X}\n", .{ invoke_addr, guest_esp_top });
            compat_thunks.enterCompatMode(@truncate(invoke_addr), guest_esp_top);
        } else {
            const invoke = @as(*const fn (i32, [*]?[*:0]u8, [*]?[*:0]u8) callconv(.winapi) i32, @ptrFromInt(invoke_addr));
            const rc = invoke(stubs_msvcrt.global_argc, stubs_msvcrt.global_argv, @as([*]?[*:0]u8, @ptrCast(@constCast(stubs_msvcrt.global_envp))));
            std.process.exit(@intCast(rc & 0xFF));
        }
    } else if (main_module.entry_point) |ep| {
        if (comptime platform.is_x86_64) {
            // On x86_64, PE entry point is 32-bit code — use compat mode
            const guest_stack_size = 16 * 1024 * 1024; // 16MB
            const guest_stack_mem = try platform.mmap(@ptrFromInt(0x05000000), guest_stack_size, true, -1, 0, false, true);
            const guest_esp: u32 = @intCast(@intFromPtr(guest_stack_mem.ptr) + guest_stack_size - 64);
            // Update TEB stack bounds to match the guest stack
            thread_env.NtTib.StackBase = @intCast(@intFromPtr(guest_stack_mem.ptr) + guest_stack_size);
            thread_env.NtTib.StackLimit = @intCast(@intFromPtr(guest_stack_mem.ptr));

            // Push exit stub as return address
            const exit_stub = compat_thunks.makeExitStub();
            @as(*u32, @ptrFromInt(@as(usize, guest_esp))).* = exit_stub;
            trace.print("compat: entering PE at 0x{X} ESP=0x{X} exit_stub=0x{X}\n", .{ ep, guest_esp, exit_stub });
            compat_thunks.enterCompatMode(@truncate(ep), guest_esp);
        } else {
            const EntryPointFn = *const fn () callconv(.c) void;
            const entry_point = @as(EntryPointFn, @ptrFromInt(ep));
            entry_point();
            profiler.dump();
            trace.print("*** Entry point returned, exiting ***\n", .{});
            std.process.exit(0);
        }
    } else {
        log.fatal("No entry point found in '{s}'.", .{exe_name});
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// JIT-integrated execution loop
// ---------------------------------------------------------------------------
