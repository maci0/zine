const std = @import("std");
const pe = @import("pe.zig");
const teb = @import("teb.zig");
const Module = @import("loader/module.zig").Module;
const Environment = @import("loader/env.zig").Environment;
const loader = @import("loader/loader.zig");
const stubs_msvcrt = @import("stubs/msvcrt.zig");
const stubs_advapi32 = @import("stubs/advapi32.zig");
const stubs_imagehlp = @import("stubs/imagehlp.zig");
const stubs_kernel32 = @import("stubs/kernel32.zig");
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
const BatEnv = @import("bat.zig").BatEnv;
const renderer = @import("gui/renderer.zig");
const platform = @import("platform.zig");

const trace = @import("trace.zig");

fn not_implemented() callconv(.c) void {
    const ra = @returnAddress();
    std.debug.print("\n!!! Unimplemented Win32 API called from 0x{X} !!!\n", .{ra});
    std.debug.print("Run with --trace to identify the unresolved import.\n", .{});
    std.process.exit(1);
}

const native_arch = @import("builtin").target.cpu.arch;

// Architecture-dependent register access helpers
const REG = std.os.linux.REG;
const reg_ip = if (native_arch == .x86) REG.EIP else @as(usize, REG.RIP);
const reg_sp = if (native_arch == .x86) REG.ESP else @as(usize, REG.RSP);
const reg_ax = if (native_arch == .x86) REG.EAX else @as(usize, REG.RAX);
const reg_cx = if (native_arch == .x86) REG.ECX else @as(usize, REG.RCX);
const reg_dx = if (native_arch == .x86) REG.EDX else @as(usize, REG.RDX);
const reg_bx = if (native_arch == .x86) REG.EBX else @as(usize, REG.RBX);
const reg_si = if (native_arch == .x86) REG.ESI else @as(usize, REG.RSI);
const reg_di = if (native_arch == .x86) REG.EDI else @as(usize, REG.RDI);
const reg_bp = if (native_arch == .x86) REG.EBP else @as(usize, REG.RBP);
const reg_fl = if (native_arch == .x86) REG.EFL else @as(usize, REG.EFL);

fn sigsegvHandler(sig: i32, info: *const std.posix.siginfo_t, ctx_ptr: ?*const anyopaque) callconv(.c) void {
    _ = sig;
    const uctx = @as(*std.posix.ucontext_t, @ptrCast(@constCast(@alignCast(ctx_ptr.?))));
    const fault_addr = @intFromPtr(info.fields.sigfault.addr);
    const ip: usize = @bitCast(uctx.mcontext.gregs[reg_ip]);

    // AppCompat: Handle EIP=0 (null function pointer call or corrupted ret)
    if (ip == 0) {
        const esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
        if (esp > 0x1000) {
            // Walk the stack to find the first valid code address
            // App code is in 0x401000-0x6B0000, winloader code is in 0x100000-0x300000
            const stack = @as([*]const u32, @ptrFromInt(esp));
            std.debug.print("AppCompat: EIP=0 fault. Stack walk:\n", .{});
            var found_ret: ?u32 = null;
            var found_idx: usize = 0;
            for (0..200) |si| {
                const val = stack[si];
                if (val >= 0x401000 and val <= 0x6B0000) {
                    if (found_ret == null) {
                        found_ret = val;
                        found_idx = si;
                    }
                    if (si < 10 or found_ret != null) {
                        std.debug.print("  stack[{d}] = 0x{X} <app>\n", .{si, val});
                    }
                } else if (si < 10) {
                    std.debug.print("  stack[{d}] = 0x{X}\n", .{si, val});
                }
            }
            if (found_ret) |ret| {
                std.debug.print("AppCompat: Recovering to app code 0x{X} (stack[{d}])\n", .{ret, found_idx});
                uctx.mcontext.gregs[reg_ip] = ret;
                uctx.mcontext.gregs[reg_sp] = @bitCast(esp + (found_idx + 1) * 4);
                uctx.mcontext.gregs[reg_ax] = 0;
                return;
            }
        }
    }

    // Application Compatibility Shim for NULL pointer dereferences
    if (fault_addr < 0x1000 and ip != 0) {
        const ptr = @as([*]u8, @ptrFromInt(ip));

        // 8b 08 (mov ecx, [eax]) or 8b 10 (mov edx, [eax])
        if ((ptr[0] == 0x8B and ptr[1] == 0x08) or (ptr[0] == 0x8B and ptr[1] == 0x10)) {
            std.log.info("AppCompat: Skipped NULL pointer deref at 0x{X} ({X} {X})", .{ip, ptr[0], ptr[1]});
            uctx.mcontext.gregs[reg_ip] += 2;
            uctx.mcontext.gregs[reg_cx] = 0;
            uctx.mcontext.gregs[reg_dx] = 0;
            return;
        }
        // ff 51 48 (call [ecx+0x48]) or ff 52 08 (call [edx+0x8]) or ff 51 08 (call [ecx+0x8])
        if ((ptr[0] == 0xFF and ptr[1] == 0x51 and ptr[2] == 0x48) or
            (ptr[0] == 0xFF and ptr[1] == 0x52 and ptr[2] == 0x08) or
            (ptr[0] == 0xFF and ptr[1] == 0x51 and ptr[2] == 0x08)) {
            std.log.info("AppCompat: Skipped NULL pointer call at 0x{X} ({X} {X} {X})", .{ip, ptr[0], ptr[1], ptr[2]});
            uctx.mcontext.gregs[reg_ip] += 3;
            uctx.mcontext.gregs[reg_sp] += if (native_arch == .x86) 4 else 8;
            return;
        }
        // Generic x86 NULL-pointer write skip.  We decode just enough of the
        // ModR/M byte to figure out how many bytes to skip.
        //
        // Handles:  88/89/8A/8B (mov r/m↔reg, 8/32 bit)
        //           C6 (mov r/m8, imm8)   C7 (mov r/m32, imm32)
        //           and more via the generic fallback
        const maybe_opcode = ptr[0];
        // Check for common store opcodes (even opcodes = store direction)
        const is_store = switch (maybe_opcode) {
            0x88, 0x89 => true, // mov [r/m], reg8/32
            0xC6, 0xC7 => true, // mov [r/m], imm8/imm32
            0x01 => true,       // add [r/m], reg
            0x29 => true,       // sub [r/m], reg
            0x09 => true,       // or  [r/m], reg
            0x21 => true,       // and [r/m], reg
            0x31 => true,       // xor [r/m], reg
            else => false,
        };
        if (is_store and ptr[1] & 0xC0 != 0xC0) { // Not reg-to-reg (mod != 11)
            const modrm = ptr[1];
            const mod_field = (modrm >> 6) & 3;
            const rm_field = modrm & 7;
            // Base instruction length: opcode(1) + modrm(1)
            var skip: usize = 2;
            // SIB byte present when rm == 4 and mod != 3
            if (rm_field == 4 and mod_field != 3) skip += 1;
            // Displacement
            if (mod_field == 0 and rm_field == 5) {
                skip += 4; // [disp32]
            } else if (mod_field == 1) {
                skip += 1; // [reg+disp8]
            } else if (mod_field == 2) {
                skip += 4; // [reg+disp32]
            }
            // Immediate (for C6/C7)
            if (maybe_opcode == 0xC6) skip += 1;
            if (maybe_opcode == 0xC7) skip += 4;

            std.log.info("AppCompat: Skipped NULL pointer write at 0x{X}", .{ip});
            uctx.mcontext.gregs[reg_ip] += @intCast(skip);
            return;
        }
    }

    // Setup exception record
    var record: teb.EXCEPTION_RECORD = undefined;
    record.ExceptionCode = 0xC0000005; // EXCEPTION_ACCESS_VIOLATION
    record.ExceptionFlags = 0;
    record.ExceptionRecord = null;
    record.ExceptionAddress = @truncate(ip);
    record.NumberParameters = 2;

    // Get ERR register to determine if read or write
    const err_reg = uctx.mcontext.gregs[REG.ERR];
    record.ExceptionInformation[0] = if ((err_reg & 2) != 0) 1 else 0;
    record.ExceptionInformation[1] = @truncate(fault_addr);

    // Setup CONTEXT
    var context: teb.CONTEXT = undefined;
    @memset(std.mem.asBytes(&context), 0);
    context.ContextFlags = 0x10007; // CONTEXT_FULL
    context.Eax = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_ax])));
    context.Ecx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_cx])));
    context.Edx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_dx])));
    context.Ebx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_bx])));
    context.Esi = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_si])));
    context.Edi = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_di])));
    context.Ebp = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_bp])));
    context.Esp = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])));
    context.Eip = @truncate(ip);
    context.EFlags = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_fl])));
    if (native_arch == .x86) {
        context.SegCs = @intCast(uctx.mcontext.gregs[std.os.linux.REG.CS] & 0xFFFF);
        context.SegDs = @intCast(uctx.mcontext.gregs[std.os.linux.REG.DS] & 0xFFFF);
        context.SegEs = @intCast(uctx.mcontext.gregs[std.os.linux.REG.ES] & 0xFFFF);
        context.SegFs = @intCast(uctx.mcontext.gregs[std.os.linux.REG.FS] & 0xFFFF);
        context.SegGs = @intCast(uctx.mcontext.gregs[std.os.linux.REG.GS] & 0xFFFF);
        context.SegSs = @intCast(uctx.mcontext.gregs[std.os.linux.REG.SS] & 0xFFFF);
    }

    // Detect infinite SEH loops
    const seh_loop = struct {
        var last_ip: usize = 0;
        var repeat_count: u32 = 0;
    };
    if (ip == seh_loop.last_ip) {
        seh_loop.repeat_count += 1;
        if (seh_loop.repeat_count > 16) {
            std.debug.print("FATAL: Infinite SEH loop at 0x{X} (fault addr: 0x{X})\n", .{ ip, fault_addr });
            std.process.exit(1);
        }
    } else {
        seh_loop.last_ip = ip;
        seh_loop.repeat_count = 0;
    }

    // Read SEH chain from FS:0
    const fs_base: u32 = asm volatile ("movl %%fs:0, %[ret]" : [ret] "=r" (-> u32));

    var current_node: u32 = fs_base;
    while (current_node != 0 and current_node != 0xFFFFFFFF) {
        const next_ptr = @as(*u32, @ptrFromInt(@as(usize, current_node)));
        const handler_ptr = @as(*u32, @ptrFromInt(@as(usize, current_node) + 4));

        const handler_addr = handler_ptr.*;
        if (handler_addr == 0) {
            current_node = next_ptr.*;
            continue;
        }

        const handler_fn = @as(*const fn (*teb.EXCEPTION_RECORD, u32, *teb.CONTEXT, usize) callconv(.c) u32, @ptrFromInt(@as(usize, handler_addr)));

        if (trace.enable_tracing) trace.print("SEH: Calling handler at 0x{X} for exception at 0x{X}\n", .{handler_addr, ip});

        const disposition = handler_fn(&record, current_node, &context, 0);

        if (disposition == 0) { // ExceptionContinueExecution
            if (trace.enable_tracing) trace.print("SEH: Handler returned ExceptionContinueExecution. Resuming at 0x{X}\n", .{context.Eip});
            uctx.mcontext.gregs[reg_ax] = context.Eax;
            uctx.mcontext.gregs[reg_cx] = context.Ecx;
            uctx.mcontext.gregs[reg_dx] = context.Edx;
            uctx.mcontext.gregs[reg_bx] = context.Ebx;
            uctx.mcontext.gregs[reg_si] = context.Esi;
            uctx.mcontext.gregs[reg_di] = context.Edi;
            uctx.mcontext.gregs[reg_bp] = context.Ebp;
            uctx.mcontext.gregs[reg_sp] = context.Esp;
            uctx.mcontext.gregs[reg_ip] = context.Eip;
            uctx.mcontext.gregs[reg_fl] = context.EFlags;
            return;
        } else if (disposition == 1) { // ExceptionContinueSearch
            current_node = next_ptr.*;
            continue;
        } else {
            std.debug.print("Unhandled SEH disposition {d} from handler 0x{X}\n", .{disposition, handler_ptr.*});
            std.process.exit(1);
        }
    }

    const eax: usize = @bitCast(uctx.mcontext.gregs[reg_ax]);
    const ecx: usize = @bitCast(uctx.mcontext.gregs[reg_cx]);
    const edx: usize = @bitCast(uctx.mcontext.gregs[reg_dx]);
    const ebx: usize = @bitCast(uctx.mcontext.gregs[reg_bx]);
    const esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
    const ebp: usize = @bitCast(uctx.mcontext.gregs[reg_bp]);
    const esi: usize = @bitCast(uctx.mcontext.gregs[reg_si]);
    const edi: usize = @bitCast(uctx.mcontext.gregs[reg_di]);
    std.debug.print("Unhandled SIGSEGV at 0x{X} (fault addr: 0x{X})\n", .{ip, fault_addr});
    std.debug.print("  EAX=0x{X} ECX=0x{X} EDX=0x{X} EBX=0x{X}\n", .{eax, ecx, edx, ebx});
    std.debug.print("  ESP=0x{X} EBP=0x{X} ESI=0x{X} EDI=0x{X}\n", .{esp, ebp, esi, edi});
    // Dump stack (return addresses)
    if (esp > 0x1000) {
        const stack = @as([*]const u32, @ptrFromInt(esp));
        std.debug.print("  Stack: ", .{});
        for (0..16) |si| {
            std.debug.print("{X} ", .{stack[si]});
        }
        std.debug.print("\n", .{});
    }
    std.process.exit(1);
}

pub fn main() !void {
    // Pre-initialize vDSO for time functions so they don't crash when FS is changed
    _ = std.time.timestamp();

    // Platform-specific process setup
    platform.installSegfaultHandler(&sigsegvHandler);
    platform.mapNullPage();
    platform.raiseStackLimit();

    // Windows processes essentially never cleanly free all memory before ExitProcess or exit()
    // Using GPA will always report thousands of leaks because the process terminates.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // deliberately not deferring deinit to match OS behavior on process exit
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable name

    var target_exe_opt: ?[]const u8 = null;
    var argv0_opt: ?[]const u8 = null;
    var app_args: std.ArrayListUnmanaged(?[*:0]u8) = .{};

    if (std.process.hasEnvVarConstant("WINLOADER_TRACE")) {
        trace.enable_tracing = true;
    }
    
    var end_of_options = false;
    while (args.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--trace") or std.mem.eql(u8, arg, "-t"))) {
            trace.enable_tracing = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            const stderr = std.fs.File.stderr();
            stderr.writeAll(
                \\Usage: winloader [options] [--] <target.exe> [args...]
                \\
                \\Run a Win32 PE executable on Linux.
                \\
                \\Options:
                \\  -t, --trace       Enable API tracing output
                \\  --argv0 <name>    Override argv[0] passed to the target
                \\  -h, --help        Show this help message
                \\  --                End of winloader options
                \\
                \\Environment:
                \\  WINLOADER_TRACE   Set to any value to enable tracing
                \\
                \\Examples:
                \\  winloader myapp.exe
                \\  winloader --trace myapp.exe input.txt
                \\  winloader --argv0 editor notepad.exe file.txt
                \\  winloader -- -weird-name.exe
                \\
            ) catch {};
            std.process.exit(0);
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--argv0")) {
            if (args.next()) |val| {
                argv0_opt = val;
            } else {
                std.fs.File.stderr().writeAll("Error: --argv0 requires a value.\nTry 'winloader --help' for more information.\n") catch {};
                std.process.exit(1);
            }
            continue;
        }
        if (!end_of_options and target_exe_opt == null and arg.len > 1 and arg[0] == '-') {
            var err_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "Error: unknown option '{s}'.\nTry 'winloader --help' for more information.\n", .{arg}) catch "Error: unknown option.\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            std.process.exit(1);
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

            // Convert to Windows path separators for the program name
            const win_arg = try allocator.dupeZ(u8, first_arg);
            std.mem.replaceScalar(u8, win_arg, '/', '\\');

            try app_args.append(allocator, win_arg);
        } else {
            try app_args.append(allocator, try allocator.dupeZ(u8, arg));
        }
    }

    if (target_exe_opt == null) {
        std.fs.File.stderr().writeAll("Usage: winloader [options] <target.exe> [args...]\nTry 'winloader --help' for more information.\n") catch {};
        std.process.exit(1);
    }
    var target_exe = target_exe_opt.?;
    var final_envp: ?[*]?[*:0]u8 = null;
    var bat_env_opt: ?BatEnv = null;

    if (std.mem.endsWith(u8, target_exe, ".bat") or std.mem.endsWith(u8, target_exe, ".BAT") or std.mem.endsWith(u8, target_exe, ".cmd")) {
        bat_env_opt = try BatEnv.init(allocator);
        var bat_env = &bat_env_opt.?;

        var bat_args: std.ArrayList([]const u8) = .{};
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

    // Register built-in DLL stubs
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
            if (trace.enable_tracing) std.debug.print("WINLOADER BAT PATH: {s}\n", .{bat_path});
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

    // Note: We intentionally do NOT add the host Unix PATH here.
    // Unix paths like /usr/bin will never contain Windows DLLs and just
    // produce noisy failed searches. Only . , the exe dir, and any
    // BAT-defined PATH entries are useful search locations.

    // Load the main executable
    const exe_name = std.fs.path.basename(target_exe);
    const main_module = try environment.registry.loadModule(exe_name);
    stubs_kernel32.main_module_handle = @intFromPtr(main_module.mapped_memory.ptr);

    // Store the exe's directory as a Windows-style path for GetModuleFileNameA
    {
        // Get the real absolute path of the exe's directory
        const fixed_exe = try allocator.dupe(u8, target_exe);
        defer allocator.free(fixed_exe);
        std.mem.replaceScalar(u8, fixed_exe, '\\', '/');
        if (std.fs.path.dirname(fixed_exe)) |dir| {
            if (std.fs.cwd().realpathAlloc(allocator, dir)) |abs_dir| {
                defer allocator.free(abs_dir);
                // Build "Z:\<abs_dir>\" with backslashes
                stubs_kernel32.main_exe_dir[0] = 'Z';
                stubs_kernel32.main_exe_dir[1] = ':';
                var pos: usize = 2;
                for (abs_dir) |c| {
                    if (pos >= stubs_kernel32.main_exe_dir.len - 2) break;
                    stubs_kernel32.main_exe_dir[pos] = if (c == '/') '\\' else c;
                    pos += 1;
                }
                if (pos > 0 and stubs_kernel32.main_exe_dir[pos - 1] != '\\') {
                    stubs_kernel32.main_exe_dir[pos] = '\\';
                    pos += 1;
                }
                stubs_kernel32.main_exe_dir_len = pos;
            } else |_| {}
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

    // Extract dynamic menu (GUI apps only)
    if (is_gui) {
        if (main_module.getFirstResource(4)) |menu_data| { // RT_MENU = 4
            const menu_parser = @import("loader/menu_parser.zig");
            if (menu_parser.parseMenuResource(allocator, menu_data)) |json_str| {
                renderer.setMenu(json_str);
            } else |err| {
                std.log.warn("Failed to parse RT_MENU resource: {}", .{err});
            }
        }
    }

    // Pre-load all imported DLLs
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

    // Initialize MSVCRT global vars
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

    // Initialize Web GUI (only for GUI applications)
    if (is_gui) {
        try renderer.init(allocator);
    }

    // Dump arguments when tracing is active
    if (trace.enable_tracing) trace.print("WINLOADER ARGS:\n", .{});
    for (app_args.items) |arg_opt| {
        if (arg_opt) |arg| {
            const span = std.mem.span(arg);
            if (trace.enable_tracing) trace.print("  {s}\n", .{span});

            if (span.len > 1 and span[0] == '@') {
                if (std.fs.cwd().openFile(span[1..], .{})) |f| {
                    var buf: [4096]u8 = undefined;
                    const rb = f.readAll(&buf) catch 0;
                    if (trace.enable_tracing) trace.print("  [RSP FILE CONTENT]:\n{s}\n", .{buf[0..rb]});
                    f.close();
                } else |_| {}
            }
        }
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
    
    // Build PEB Environment block (Must be UTF-16 on NT)
    var env_total_chars: usize = 1; // Final null
    if (stubs_msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (stubs_msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.c_span(@intFromPtr(env_ptr));
            env_total_chars += span.len + 1;
        }
    }
    const env_block = try allocator.alloc(u16, env_total_chars);
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
    params.Environment = @truncate(@intFromPtr(env_block.ptr));

    try teb.setupFS(thread_env);

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
        if (trace.enable_tracing) std.debug.print("Executing MSVC Compiler Pass...\n", .{});
        const invoke = @as(*const fn (i32, [*]?[*:0]u8, [*]?[*:0]u8) callconv(.winapi) i32, @ptrFromInt(invoke_addr));
        const rc = invoke(stubs_msvcrt.global_argc, stubs_msvcrt.global_argv, @as([*]?[*:0]u8, @ptrCast(@constCast(stubs_msvcrt.global_envp))));
        std.process.exit(@intCast(rc & 0xFF));
    } else if (main_module.entry_point) |ep| {
        const EntryPointFn = *const fn () callconv(.c) void;
        const entry_point = @as(EntryPointFn, @ptrFromInt(ep));
        entry_point();
        if (trace.enable_tracing) std.debug.print("*** Entry point returned, exiting ***\n", .{});
        std.process.exit(0);
    } else {
        std.fs.File.stderr().writeAll("Error: no entry point found in executable.\n") catch {};
        std.process.exit(1);
    }
}
