const std = @import("std");
const x86_memory = @import("../../x86/memory.zig");
const runtime = @import("../../runtime.zig");
const env = @import("../../loader/env.zig");
const trace = @import("../../trace.zig");
const log = @import("../../log.zig");
const kernel32 = @import("../kernel32.zig");
const loader = @import("../../loader/loader.zig");
const kernel32_mem = @import("mem.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../constants.zig");
const x86_thunks = @import("../../x86/thunks.zig");
const w32cc = @import("../calling_convention.zig");

/// Detect if a Win32 path references a system directory.
/// Matches patterns like C:\Windows\System32\*, C:\WINDOWS\system32\*
/// (case-insensitive).
fn isSystemDirPath(path: []const u8) bool {
    // Look for \Windows\System32\ (case-insensitive, handles both \ and /)
    const pattern = "windows";
    const sys32 = "system32";
    var i: usize = 0;
    while (i + pattern.len + 1 + sys32.len < path.len) : (i += 1) {
        const sep1 = (path[i] == '\\' or path[i] == '/');
        if (sep1 and std.ascii.startsWithIgnoreCase(path[i + 1 ..], pattern)) {
            const after_win = i + 1 + pattern.len;
            if (after_win < path.len and (path[after_win] == '\\' or path[after_win] == '/')) {
                if (std.ascii.startsWithIgnoreCase(path[after_win + 1 ..], sys32)) {
                    return true;
                }
            }
        }
    }
    return false;
}

const EXCEPTION_POINTERS = extern struct {
    ExceptionRecord: *const @import("../teb.zig").EXCEPTION_RECORD,
    ContextRecord: *const @import("../teb.zig").CONTEXT,
};

/// Called when an exception occurs that is not handled by any exception handlers.
/// Implementation status: Fully implemented (logs and exits)
pub fn UnhandledExceptionFilter(ExceptionInfo: usize) callconv(w32cc.WINAPI) u32 {
    if (ExceptionInfo != 0) {
        const ptrs = @as(*EXCEPTION_POINTERS, @ptrFromInt(ExceptionInfo));
        const code = ptrs.ExceptionRecord.ExceptionCode;
        const addr = ptrs.ExceptionRecord.ExceptionAddress;

        // STATUS_FATAL_APP_EXIT (0x40000015) from _amsg_exit (R6025 pure virtual, etc.)
        // Suppress and continue — the app may recover.
        if (code == 0x40000015) {
            log.warn("UnhandledExceptionFilter: suppressed STATUS_FATAL_APP_EXIT at 0x{X}", .{addr});
            return 0xFFFFFFFF; // EXCEPTION_CONTINUE_EXECUTION
        }

        log.err("UnhandledExceptionFilter caught code 0x{X} at 0x{X}", .{ code, addr });

        const renderer = @import("../../gui/renderer.zig");
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "This program has performed an illegal operation and will be shut down.\\n\\nException Code: 0x{X}\\nFault Address: 0x{X}", .{ code, addr }) catch "Error";
        renderer.showMessageBox("Application Error", text);
    }

    // Give WebSocket time to flush
    platform.sleep(100 * std.time.ns_per_ms);
    platform.exitProcess(1);
    return 1; // EXCEPTION_EXECUTE_HANDLER (though we never reach here)
}

/// Ends the calling process and all its threads.
/// Implementation status: Fully implemented (exits the WASM/native host)
pub fn ExitProcess(exitCode: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: ExitProcess({d})\n", .{exitCode});
    // In WASM child-process mode, store the exit code and halt the child
    // CPU, rather than killing the whole WASM process.
    const shared = @import("../shared.zig");
    if (shared.child_exit_code) |ptr| {
        ptr.* = @bitCast(exitCode);
        if (shared.child_cpu) |cpu| {
            cpu.halted = true;
        }
        return;
    }
    platform.exitProcess(@intCast(exitCode & 0xFF));
}

/// stub_SetConsoleCtrlHandler
/// Implementation status: No-op fallback
pub fn stub_SetConsoleCtrlHandler(handler: *const anyopaque, add: i32) callconv(w32cc.WINAPI) i32 {
    _ = handler;
    _ = add;
    return 1;
}

/// stub_DisableThreadLibraryCalls
/// Implementation status: No-op fallback
pub fn stub_DisableThreadLibraryCalls(hLibModule: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hLibModule;
    return 1;
}

/// Loads the specified module into the address space of the calling process.
/// Implementation status: Partially implemented (supports DLL loading and builtin stubs)
pub fn LoadLibraryA(lpFileName_ptr: usize) callconv(w32cc.WINAPI) usize {
    if (lpFileName_ptr == 0) return 0;
    const name = trace.c_span(lpFileName_ptr);

    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA('{s}')\n", .{name});

    if (kernel32.global_env) |genv| {
        // Convert Win32 path (e.g. C:\Desktop\Guild\MP3DEC.ASI) to POSIX.
        // toHostPath anchors ".." inside drive_c/ so LoadLibrary cannot point
        // the PE loader at arbitrary host files outside the virtual drive.
        const path_utils = @import("../../path_utils.zig");
        var posix_buf: [1024]u8 = undefined;
        const posix_len = path_utils.toHostPath(name, &posix_buf);
        var load_name = if (posix_len > 0) posix_buf[0..posix_len] else name;

        // Strip "./" or ".\" prefix — Windows apps use ".\foo.dll" meaning "same dir as me"
        // but loadModule will search registered paths, so just use the basename
        if (load_name.len > 2 and load_name[0] == '.' and (load_name[1] == '/' or load_name[1] == '\\')) {
            load_name = load_name[2..];
        }

        // If path references a system directory (e.g. C:\Windows\System32\ddraw.dll),
        // check builtins FIRST. This is critical for proxy DLLs like dxwrapper that
        // try to LoadLibrary the "real" system DLL — they should get our builtin stubs.
        if (isSystemDirPath(name)) {
            var basename = name;
            for (name, 0..) |c, i| {
                if (c == '\\' or c == '/') basename = name[i + 1 ..];
            }
            if (genv.getBuiltinHandle(basename)) |handle| {
                if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA found builtin '{s}' for system path '{s}', returning handle {x}\n", .{ basename, name, handle });
                return handle;
            }
        }

        if (genv.registry.loadModule(load_name)) |mod| {
            if (!mod.imports_resolved) {
                loader.resolveImports(genv, mod) catch |err| {
                    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA failed to resolve imports: {}\n", .{err});
                    return 0;
                };
            }

            if (comptime platform.is_wasm) {
                loader.copyModuleToGuest(mod);
            }

            if (!mod.attached) {
                mod.attached = true;
                const opt_header = &mod.parser.getNtHeaders().OptionalHeader;
                if (opt_header.AddressOfEntryPoint != 0) {
                    if (comptime !platform.is_wasm) {
                        const entry_point_addr = @intFromPtr(mod.mapped_memory.ptr) + opt_header.AddressOfEntryPoint;
                        if (trace.enable_tracing) trace.print("KERNEL32: Executing DllMain for {s} at {x}\n", .{ load_name, entry_point_addr });
                        if (comptime platform.is_x86_64) {
                            const compat_thunks_mod = @import("../../x86/compat_thunks.zig");
                            _ = compat_thunks_mod.callCompat32(
                                @truncate(entry_point_addr),
                                @truncate(@intFromPtr(mod.mapped_memory.ptr)),
                                1, // DLL_PROCESS_ATTACH
                                0, // lpReserved
                            );
                        } else {
                            const DllMain = @as(*const fn (usize, u32, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(entry_point_addr));
                            const ret = DllMain(@intFromPtr(mod.mapped_memory.ptr), 1, 0);
                            if (trace.enable_tracing) trace.print("KERNEL32: DllMain returned {d}\n", .{ret});
                        }
                    } else {
                        const shared = @import("../shared.zig");
                        if (x86_memory.guest_memory) |gmem| {
                            const stack_base = gmem.guestAlloc(64);
                            if (stack_base != 0) {
                                const x86_cpu = @import("../../x86/cpu.zig");
                                const x86_execute = @import("../../x86/execute.zig");
                                var temp_cpu = x86_cpu.Cpu{};
                                temp_cpu.memory = gmem.*;
                                if (shared.child_cpu) |child| {
                                    temp_cpu.fs_base = child.fs_base;
                                }

                                temp_cpu.memory.write8(stack_base, 0xF4); // HLT

                                temp_cpu.esp = stack_base + 64;
                                temp_cpu.esp -= 4;
                                temp_cpu.memory.write32(temp_cpu.esp, 0); // lpReserved
                                temp_cpu.esp -= 4;
                                temp_cpu.memory.write32(temp_cpu.esp, 1); // DLL_PROCESS_ATTACH
                                temp_cpu.esp -= 4;
                                temp_cpu.memory.write32(temp_cpu.esp, @truncate(mod.image_base)); // hModule
                                temp_cpu.esp -= 4;
                                temp_cpu.memory.write32(temp_cpu.esp, stack_base); // Return to HLT

                                temp_cpu.eip = @truncate(mod.image_base + opt_header.AddressOfEntryPoint);

                                if (trace.enable_tracing) trace.print("KERNEL32: Executing DllMain for {s} at guest {x} (WASM emulator)\n", .{ load_name, temp_cpu.eip });

                                x86_execute.run(&temp_cpu);

                                if (trace.enable_tracing) trace.print("KERNEL32: DllMain (WASM) returned {d}\n", .{temp_cpu.eax});
                            }
                        }
                    }
                }
            }

            return mod.image_base;
        } else |err| {
            // Windows API set DLLs (api-ms-win-core-*) redirect to kernel32/ntdll
            if (std.ascii.startsWithIgnoreCase(name, "api-ms-win-")) {
                if (genv.getBuiltinHandle("kernel32.dll")) |handle| {
                    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA redirecting API set '{s}' -> kernel32.dll handle {x}\n", .{ name, handle });
                    return handle;
                }
            }

            // Try full name first
            if (genv.getBuiltinHandle(name)) |handle| {
                if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA found builtin '{s}', returning handle {x}\n", .{ name, handle });
                return handle;
            }

            // Strip path (e.g. "C:\WINDOWS\SYSTEM32\advapi32.dll" -> "advapi32.dll")
            var basename = name;
            for (name, 0..) |c, i| {
                if (c == '\\' or c == '/') basename = name[i + 1 ..];
            }
            if (basename.len != name.len) {
                if (genv.getBuiltinHandle(basename)) |handle| {
                    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA found builtin '{s}' (from '{s}'), returning handle {x}\n", .{ basename, name, handle });
                    return handle;
                }
            }

            // Try with .dll extension appended (e.g. "kernel32" -> "kernel32.dll")
            // MSVC CRT loads DLLs without extension
            var has_dot = false;
            for (basename) |c| {
                if (c == '.') {
                    has_dot = true;
                    break;
                }
            }
            if (!has_dot and basename.len < 250) {
                var ext_buf: [256]u8 = undefined;
                @memcpy(ext_buf[0..basename.len], basename);
                @memcpy(ext_buf[basename.len .. basename.len + 4], ".dll");
                ext_buf[basename.len + 4] = 0;
                if (genv.getBuiltinHandle(ext_buf[0 .. basename.len + 4])) |handle| {
                    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA found builtin '{s}.dll' (from '{s}'), returning handle {x}\n", .{ basename, name, handle });
                    return handle;
                }
            }

            if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA failed with error: {}\n", .{err});
            return 0;
        }
    }
    return 0;
}

/// Cache of resolved builtin-export lookups, keyed by (module handle, name).
/// Win32 returns a stable pointer for a given (module, name) pair; without
/// this cache every lookup allocates a fresh thunk (WASM/x86_64 pool) or
/// import-registry entry, so an app querying the same export repeatedly
/// exhausts those fixed-size tables.
const ProcCacheEntry = struct { hmodule: usize, name: []u8, addr: usize };
var proc_cache: std.ArrayListUnmanaged(ProcCacheEntry) = .empty;

fn lookupCachedProcAddress(hModule: usize, name: []const u8) ?usize {
    for (proc_cache.items) |*entry| {
        if (entry.hmodule == hModule and std.mem.eql(u8, entry.name, name)) return entry.addr;
    }
    return null;
}

/// Retrieves the address of an exported function or variable from the specified DLL.
/// Implementation status: Partially implemented (supports builtin exports and mapped modules)
pub fn GetProcAddress(hModule: usize, lpProcName_ptr: usize) callconv(w32cc.WINAPI) usize {
    if (hModule == 0 or lpProcName_ptr == 0) return 0;

    var is_ordinal = false;
    if (lpProcName_ptr < 0x10000) {
        is_ordinal = true;
    }

    if (kernel32.global_env) |genv| {
        if (!is_ordinal) {
            const name = trace.c_span(lpProcName_ptr);
            if (lookupCachedProcAddress(hModule, name)) |cached| {
                if (trace.enable_tracing) trace.print("KERNEL32: GetProcAddress('{s}') -> {x} (cached)\n", .{ name, cached });
                return cached;
            }
            var it = genv.builtins.iterator();
            while (it.next()) |entry| {
                const builtin = entry.value_ptr.*;
                if (builtin.handle == hModule) {
                    if (builtin.exports.get(name)) |exp| {
                        const loader_mod = @import("../../loader/loader.zig");
                        const result = loader_mod.allocThunkForExport(exp, entry.key_ptr.*, name);
                        // Cache successful results; names must be duped because
                        // c_span points into mutable guest memory.
                        if (result != 0) {
                            if (genv.allocator.dupe(u8, name)) |owned| {
                                proc_cache.append(genv.allocator, .{ .hmodule = hModule, .name = owned, .addr = result }) catch genv.allocator.free(owned);
                            } else |_| {}
                        }
                        if (trace.enable_tracing) trace.print("KERNEL32: GetProcAddress('{s}') -> {x} (from builtin)\n", .{ name, result });
                        return result;
                    }
                }
            }
        }

        var target_mod: ?*env.Module = null;
        var it = genv.registry.modules.iterator();
        while (it.next()) |entry| {
            const mod = entry.value_ptr.*;
            if (mod.image_base == hModule) {
                target_mod = mod;
                break;
            }
        }

        if (target_mod) |mod| {
            if (is_ordinal) {
                if (trace.enable_tracing) trace.print("KERNEL32: GetProcAddress(ordinal={d})\n", .{lpProcName_ptr});
                return 0;
            } else {
                const name = trace.c_span(lpProcName_ptr);
                if (trace.enable_tracing) trace.print("KERNEL32: GetProcAddress('{s}')\n", .{name});
                if (mod.getExport(name)) |addr| {
                    if (trace.enable_tracing) trace.print("KERNEL32: GetProcAddress -> {x}\n", .{addr});
                    return addr;
                }
            }
        }
    }
    if (trace.enable_tracing and !is_ordinal) {
        const name = trace.c_span(lpProcName_ptr);
        trace.print("KERNEL32: GetProcAddress('{s}') -> NOT FOUND\n", .{name});
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn GetStartupInfoA(si: *w32.STARTUPINFOA) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetStartupInfoA\n", .{});
    si.* = .{}; // zero all, cb defaults to 68
}

/// Implementation status: Partially implemented
pub fn GetModuleHandleA(lpModuleName_ptr: usize) callconv(w32cc.WINAPI) usize {
    @setRuntimeSafety(false);
    const frame_addr = @frameAddress();
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA esp={x}\n", .{frame_addr});

    if (lpModuleName_ptr == 0) {
        return kernel32.main_module_handle;
    }
    const name = trace.c_span(lpModuleName_ptr);

    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA('{s}')\n", .{name});

    if (kernel32.global_env) |genv| {
        // Extract basename for comparison (strip directory path)
        var basename = name;
        for (name, 0..) |c, i| {
            if (c == '\\' or c == '/') basename = name[i + 1 ..];
        }

        var it = genv.registry.modules.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name) or
                std.ascii.eqlIgnoreCase(entry.key_ptr.*, basename))
            {
                const handle = @intFromPtr(entry.value_ptr.*.mapped_memory.ptr);
                if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA -> {x}\n", .{handle});
                return handle;
            }
        }

        if (genv.getBuiltinHandle(name)) |handle| {
            if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA -> {x}\n", .{handle});
            return handle;
        }

        if (genv.getBuiltinHandle(basename)) |handle| {
            if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA('{s}' basename) -> {x}\n", .{ basename, handle });
            return handle;
        }

        // Try with ".dll" suffix appended (games often pass "KERNEL32" without extension)
        if (basename.len < 248 and !std.ascii.endsWithIgnoreCase(basename, ".dll")) {
            var ext_buf: [256]u8 = undefined;
            @memcpy(ext_buf[0..basename.len], basename);
            @memcpy(ext_buf[basename.len .. basename.len + 4], ".dll");
            if (genv.getBuiltinHandle(ext_buf[0 .. basename.len + 4])) |handle| {
                if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA('{s}' + .dll) -> {x}\n", .{ basename, handle });
                return handle;
            }
        }
    }
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA -> 0 (not found)\n", .{});
    return 0;
}

/// Implementation status: Partially implemented
pub fn GetModuleHandleW(lpModuleName_ptr: usize) callconv(w32cc.WINAPI) usize {
    if (lpModuleName_ptr == 0) {
        return kernel32.main_module_handle;
    }
    // Convert wide string to narrow, then delegate to the A version
    const wstr = trace.c_span_w(lpModuleName_ptr);
    var narrow_buf: [256]u8 = undefined;
    const copy_len = @min(wstr.len, 255);
    for (0..copy_len) |i| {
        narrow_buf[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow_buf[copy_len] = 0;
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleW('{s}')\n", .{narrow_buf[0..copy_len]});
    return GetModuleHandleA(@intFromPtr(&narrow_buf));
}

var cmdline_initialized: bool = false;
var cmdline_host_addr: usize = 0; // Host pointer to the command-line buffer
var cmdline_guest_addr: usize = 0; // Guest VA handed back to the x86 code

var cmdline_w_initialized: bool = false;
var cmdline_w_host_addr: usize = 0; // Host pointer to the wide command-line buffer
var cmdline_w_guest_addr: usize = 0; // Guest VA handed back to the x86 code

/// Reset command line state so the next GetCommandLineA rebuilds from current argv.
/// Called by the WASM spawn handler before executing a child PE.
pub fn resetCommandLine() void {
    cmdline_initialized = false;
    cmdline_host_addr = 0;
    cmdline_guest_addr = 0;
    cmdline_w_initialized = false;
    cmdline_w_host_addr = 0;
    cmdline_w_guest_addr = 0;
}

/// Retrieves the command-line string for the current process.
/// Implementation status: Partially implemented (constructs command line from guest arguments)
pub fn GetCommandLineA() callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineA\n", .{});

    if (!cmdline_initialized) {
        // Determine working buffer: allocate from shared guest heap.
        // raw_alloc returns a HOST pointer; writes below use it directly and
        // hostToGuest() derives the guest VA that x86 code sees in EAX.
        const kernel32_mem_mod = @import("mem.zig");
        if (cmdline_host_addr == 0) {
            const raw = kernel32_mem_mod.raw_alloc(4096) orelse return 0;
            cmdline_host_addr = @intFromPtr(raw);
            cmdline_guest_addr = @import("../shared.zig").hostToGuest(cmdline_host_addr);
        }

        const host_ptr = @as([*]u8, @ptrFromInt(cmdline_host_addr));
        var buf: []u8 = host_ptr[0..4096];

        const msvcrt = @import("../msvcrt.zig");
        var pos: usize = 0;
        if (msvcrt.global_argc > 0) {
            // Use the actual argv[0] (already has Win32-style path from posixToWin32).
            // global_argv entries are HOST pointers — read without translation.
            if (msvcrt.global_argv[0]) |argv0| {
                const span = trace.host_c_span(@intFromPtr(argv0));
                const copy_len = @min(span.len, 4094);
                @memcpy(buf[0..copy_len], span[0..copy_len]);
                pos = copy_len;
            } else {
                const exe_stub = "C:\\program.exe";
                @memcpy(buf[0..exe_stub.len], exe_stub);
                pos = exe_stub.len;
            }

            var i: usize = 1;
            while (i < msvcrt.global_argc) : (i += 1) {
                if (msvcrt.global_argv[i]) |arg_ptr| {
                    const arg = trace.host_c_span(@intFromPtr(arg_ptr));

                    if (pos < 4094) {
                        buf[pos] = ' ';
                        pos += 1;
                    }

                    var write_arg = arg;
                    var needs_quotes = false;
                    for (write_arg) |c| {
                        if (c == ' ' or c == '\t') needs_quotes = true;
                    }

                    if (write_arg.len >= 2 and write_arg[0] == '"' and write_arg[write_arg.len - 1] == '"') {
                        write_arg = write_arg[1 .. write_arg.len - 1];
                        needs_quotes = true;
                    }

                    if (needs_quotes and pos < 4094) {
                        buf[pos] = '"';
                        pos += 1;
                    }

                    const copy_len = @min(write_arg.len, 4094 - pos);
                    @memcpy(buf[pos .. pos + copy_len], write_arg[0..copy_len]);
                    pos += copy_len;

                    if (needs_quotes and pos < 4094) {
                        buf[pos] = '"';
                        pos += 1;
                    }
                }
            }
        } else {
            const dummy = "C:\\program.exe";
            @memcpy(buf[0..dummy.len], dummy);
            pos = dummy.len;
        }
        buf[pos] = 0;

        cmdline_initialized = true;
    }

    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineA -> '{s}'\n", .{trace.c_span(cmdline_guest_addr)});
    return cmdline_guest_addr;
}

/// Retrieves a pseudo-handle for the current process.
/// Implementation status: Fully implemented
pub fn GetCurrentProcess() callconv(w32cc.WINAPI) usize {
    return 0xFFFFFFFF; // Pseudo-handle for current process
}

pub fn GetCurrentProcessId() callconv(w32cc.WINAPI) u32 {
    return platform.getProcessId();
}

pub fn GetCurrentThreadId() callconv(w32cc.WINAPI) u32 {
    return @intCast(std.Thread.getCurrentId());
}

/// Implementation status: Partially implemented
pub fn SetEnvironmentVariableA(lpName: usize, lpValue: usize) callconv(w32cc.WINAPI) i32 {
    if (lpName == 0) return 0;
    const name = trace.c_span(lpName);
    // Win32 contract: lpValue == NULL deletes the variable.
    if (lpValue != 0) {
        const value = trace.c_span(lpValue);
        if (trace.enable_tracing) trace.print("KERNEL32: SetEnvironmentVariableA('{s}', '{s}')\n", .{ name, value });

        const msvcrt = @import("../msvcrt.zig");

        // Update any existing override in place. Lookups elsewhere are
        // case-insensitive, so matching by exact bytes only would let a
        // differently-cased name coexist with the inherited entry and
        // children would then see the stale inherited value first.
        for (msvcrt.msvcrt_env_vars.items) |*v| {
            if (std.ascii.eqlIgnoreCase(v.key, name)) {
                if (v.deleted) {
                    v.deleted = false;
                    const val_dupe = std.heap.page_allocator.dupe(u8, value) catch return 0;
                    v.val = val_dupe;
                } else {
                    const val_dupe = std.heap.page_allocator.dupe(u8, value) catch return 0;
                    std.heap.page_allocator.free(v.val);
                    v.val = val_dupe;
                }
                return 1;
            }
        }

        const key_dupe = std.heap.page_allocator.dupe(u8, name) catch return 0;
        const val_dupe = std.heap.page_allocator.dupe(u8, value) catch return 0;
        msvcrt.msvcrt_env_vars.append(std.heap.page_allocator, .{ .key = key_dupe, .val = val_dupe }) catch return 0;

        return 1;
    }

    // Delete: record a tombstone so reads stop resolving to the inherited
    // value and spawned children no longer receive the variable.
    if (trace.enable_tracing) trace.print("KERNEL32: SetEnvironmentVariableA('{s}', DELETE)\n", .{name});
    const msvcrt = @import("../msvcrt.zig");
    for (msvcrt.msvcrt_env_vars.items) |*v| {
        if (!v.deleted and std.ascii.eqlIgnoreCase(v.key, name)) {
            std.heap.page_allocator.free(v.val);
            std.heap.page_allocator.free(v.key);
            v.key = "";
            v.val = "";
            v.deleted = true;
            return 1;
        }
    }
    const key_dupe = std.heap.page_allocator.dupe(u8, name) catch return 0;
    msvcrt.msvcrt_env_vars.append(std.heap.page_allocator, .{ .key = key_dupe, .val = "", .deleted = true }) catch return 0;
    return 1;
}

/// Look up an environment variable by narrow name, returning a slice into the
/// host-side env storage (overridden vars first, then global_envp).
fn getEnvValue(name: []const u8) ?[]const u8 {
    const msvcrt = @import("../msvcrt.zig");
    // First check overridden vars. A tombstone means the guest deleted the
    // name: it must not fall through to the inherited value.
    for (msvcrt.msvcrt_env_vars.items) |v| {
        if (std.ascii.eqlIgnoreCase(v.key, name)) {
            if (v.deleted) return null;
            return v.val;
        }
    }
    // Then check global_envp (entries are HOST pointers — no translation)
    var env_i: usize = 0;
    while (msvcrt.global_envp[env_i]) |e_ptr| : (env_i += 1) {
        const e_str = trace.host_c_span(@intFromPtr(e_ptr));
        if (std.ascii.startsWithIgnoreCase(e_str, name) and e_str.len > name.len and e_str[name.len] == '=') {
            return e_str[name.len + 1 ..];
        }
    }
    return null;
}

/// Implementation status: Partially implemented
pub fn GetEnvironmentVariableA(lpName: usize, lpBuffer: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    const name = trace.c_span(lpName);
    if (trace.enable_tracing) trace.print("KERNEL32: GetEnvironmentVariableA('{s}')\n", .{name});

    const value = getEnvValue(name) orelse return 0; // Not found

    if (lpBuffer != 0 and nSize > value.len) {
        // lpBuffer is a guest VA (usize param — not auto-translated)
        const buf = @as([*]u8, @ptrFromInt(trace.addr(lpBuffer)));
        @memcpy(buf[0..value.len], value);
        buf[value.len] = 0;
        return @intCast(value.len);
    }
    return @intCast(value.len + 1); // Return required size
}

/// GetEnvironmentVariableW — retrieves the value of an environment variable (wide).
pub fn GetEnvironmentVariableW(lpName: usize, lpBuffer: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    const name_w = trace.c_span_w(lpName);
    if (name_w.len == 0) return 0;
    if (trace.enable_tracing) trace.print("KERNEL32: GetEnvironmentVariableW(len={d})\n", .{name_w.len});

    // Narrow the name (ASCII subset) and look up through the shared helper.
    var narrow_buf: [512]u8 = undefined;
    if (name_w.len >= narrow_buf.len) return 0;
    for (name_w, 0..) |c, i| {
        narrow_buf[i] = @intCast(c & 0xFF);
    }
    narrow_buf[name_w.len] = 0;

    const value = getEnvValue(narrow_buf[0..name_w.len]) orelse return 0;

    if (lpBuffer != 0 and @as(usize, nSize) > value.len) {
        // lpBuffer is a guest VA (usize param — not auto-translated).
        const buf = @as([*]u16, @ptrFromInt(trace.addr(lpBuffer)));
        for (value, 0..) |c, i| {
            buf[i] = c;
        }
        buf[value.len] = 0;
        return @intCast(value.len);
    }
    return @intCast(value.len + 1); // Required size in WCHARs (incl. NUL)
}

/// Implementation status: Partially implemented
pub fn GetModuleFileNameA(hModule: usize, lpFilename: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    _ = hModule;
    if (lpFilename != 0 and nSize > 0) {
        if (kernel32.global_env) |genv| {
            _ = genv;
            const msvcrt = @import("../msvcrt.zig");
            if (msvcrt.global_argc > 0 and msvcrt.global_argv[0] != null) {
                const exe_path = std.mem.span(msvcrt.global_argv[0].?);
                const host_buf_addr = trace.addr(lpFilename);
                const buf = @as([*]u8, @ptrFromInt(host_buf_addr));
                const copy_len = @min(exe_path.len, nSize - 1);
                const buf_slice = buf[0..copy_len];
                @memcpy(buf_slice, exe_path[0..copy_len]);
                buf[copy_len] = 0;

                std.mem.replaceScalar(u8, buf_slice, '/', '\\');

                if (trace.enable_tracing) trace.print("KERNEL32: GetModuleFileNameA -> '{s}'\n", .{buf[0..copy_len]});
                return @intCast(copy_len);
            }
        }
    }
    return 0;
}

// --- Child process tracking ---
const max_child_procs = 16;
pub const ChildProc = struct {
    handle: usize = 0,
    child: if (platform.is_native) ?std.process.Child else ?void = null,
    exit_code: ?u32 = null,
};
var child_procs: [max_child_procs]ChildProc = [_]ChildProc{.{}} ** max_child_procs;
var next_process_handle: usize = 0xCA000001;

fn allocChildProc(child: if (platform.is_native) std.process.Child else void) ?usize {
    const cp = reserveChildSlot() orelse return null;
    return adoptReservedChild(cp, child);
}

/// Find a free or evictable table slot without recording a child in it.
/// Callers must fill the slot via adoptReservedChild (or leave it untouched,
/// where handle == 0 keeps it free).
fn reserveChildSlot() ?*ChildProc {
    for (&child_procs) |*cp| {
        if (cp.handle == 0) {
            return cp;
        }
    }
    // Evict an already-reaped child so repeated spawn/wait cycles don't
    // exhaust the table with finished entries.
    for (&child_procs) |*cp| {
        if (cp.exit_code != null) {
            return cp;
        }
    }
    return null;
}

fn adoptReservedChild(cp: *ChildProc, child: if (platform.is_native) std.process.Child else void) usize {
    const h = next_process_handle;
    next_process_handle += 1;
    cp.handle = h;
    cp.child = child;
    cp.exit_code = null;
    return h;
}

/// Poll every tracked-but-unwaited child with waitpid(WNOHANG), recording the
/// exit code of finished ones. Without this, a guest that spawns short-lived
/// processes without waiting on them accumulates one zombie per spawn until
/// the table fills and spawns start failing.
pub fn reapExitedChildren() void {
    if (comptime !platform.is_native) return;
    if (comptime @import("builtin").os.tag != .linux) return;
    for (&child_procs) |*cp| {
        if (cp.handle == 0 or cp.exit_code != null) continue;
        const child = &(cp.child orelse continue);
        const id = child.id orelse continue;
        var status: u32 = 0;
        const wrc = std.os.linux.waitpid(@intCast(id), &status, std.os.linux.W.NOHANG);
        const waited: isize = @bitCast(wrc);
        if (waited != id) continue; // still running (0) or error (<0)
        cp.exit_code = if (std.posix.W.IFEXITED(status)) @as(u32, std.posix.W.EXITSTATUS(status)) else 1;
    }
}

/// getChildProc
/// Implementation status: Partially implemented
pub fn getChildProc(handle: usize) ?*ChildProc {
    for (&child_procs) |*cp| {
        if (cp.handle == handle) return cp;
    }
    return null;
}

/// Creates a new process and its primary thread.
/// Implementation status: Partially implemented (spawns a new instance of zine with the target PE)
pub fn CreateProcessA(
    lpApplicationName: usize,
    lpCommandLine: usize,
    lpProcessAttributes: usize,
    lpThreadAttributes: usize,
    bInheritHandles: i32,
    dwCreationFlags: u32,
    lpEnvironment: usize,
    lpCurrentDirectory: usize,
    lpStartupInfo: usize,
    lpProcessInformation: usize,
) callconv(w32cc.WINAPI) i32 {
    _ = lpProcessAttributes;
    _ = lpThreadAttributes;
    _ = bInheritHandles;
    _ = dwCreationFlags;
    _ = lpEnvironment;
    _ = lpCurrentDirectory;
    _ = lpStartupInfo;

    const app_name: []const u8 = if (lpApplicationName != 0) trace.c_span(lpApplicationName) else "";
    const cmd_line: []const u8 = if (lpCommandLine != 0) trace.c_span(lpCommandLine) else "";

    if (trace.enable_tracing) trace.print("KERNEL32: CreateProcessA(app='{s}', cmd='{s}')\n", .{ app_name, cmd_line });

    if (comptime !platform.is_native) {
        // WASM: can't spawn processes, return fake handles
        if (lpProcessInformation != 0) {
            const pi = @as(*align(1) w32.PROCESS_INFORMATION, @ptrFromInt(lpProcessInformation));
            pi.hProcess = 0x1234;
            pi.hThread = 0x5678;
            pi.dwProcessId = 1337;
            pi.dwThreadId = 1338;
        }
        return 1;
    }

    // Determine the target PE path from either app_name or cmd_line
    var target_path_buf: [1024]u8 = undefined;
    var target_path_len: usize = 0;

    if (app_name.len > 0) {
        target_path_len = @min(app_name.len, 1023);
        @memcpy(target_path_buf[0..target_path_len], app_name[0..target_path_len]);
    } else if (cmd_line.len > 0) {
        // Parse the executable from the command line (may be quoted)
        var start: usize = 0;
        var end: usize = 0;
        if (cmd_line[0] == '"') {
            start = 1;
            end = start;
            while (end < cmd_line.len and cmd_line[end] != '"') : (end += 1) {}
        } else {
            while (end < cmd_line.len and cmd_line[end] != ' ') : (end += 1) {}
        }
        target_path_len = @min(end - start, 1023);
        @memcpy(target_path_buf[0..target_path_len], cmd_line[start .. start + target_path_len]);
    }

    if (target_path_len == 0) {
        log.warn("CreateProcessA: no target executable specified", .{});
        return 0;
    }

    // Convert Win32 path to POSIX. toHostPath anchors ".." inside drive_c/
    // (win32ToPosix does not normalize), keeping child launches inside the
    // virtual drive.
    const path_utils = @import("../../path_utils.zig");
    var posix_buf: [1024]u8 = undefined;
    const posix_len = path_utils.toHostPath(target_path_buf[0..target_path_len], &posix_buf);
    if (posix_len == 0) return 0;

    if (trace.enable_tracing) trace.print("KERNEL32: CreateProcessA -> spawning '{s}'\n", .{posix_buf[0..posix_len]});

    // Get our own executable path to re-invoke zine
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rt_io = runtime.io();
    const self_exe_len = std.process.executablePath(rt_io, &self_exe_buf) catch 0;
    if (self_exe_len == 0) {
        log.warn("CreateProcessA: failed to read /proc/self/exe", .{});
        if (lpProcessInformation != 0) {
            const pi = @as(*align(1) w32.PROCESS_INFORMATION, @ptrFromInt(lpProcessInformation));
            pi.hProcess = 0x1234;
            pi.hThread = 0x5678;
            pi.dwProcessId = 1337;
            pi.dwThreadId = 1338;
        }
        return 1;
    }
    const self_exe = self_exe_buf[0..self_exe_len];

    // Build argv: [zine, "--", <posix_path>]
    // Also pass through any additional command-line args from cmd_line
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = self_exe;
    argc += 1;
    argv_buf[argc] = "--";
    argc += 1;
    argv_buf[argc] = posix_buf[0..posix_len];
    argc += 1;

    // Parse additional args from cmd_line (after the executable)
    if (cmd_line.len > 0) {
        var arg_start: usize = 0;
        // Skip past the executable in cmd_line
        if (cmd_line[0] == '"') {
            arg_start = 1;
            while (arg_start < cmd_line.len and cmd_line[arg_start] != '"') : (arg_start += 1) {}
            if (arg_start < cmd_line.len) arg_start += 1;
        } else {
            while (arg_start < cmd_line.len and cmd_line[arg_start] != ' ') : (arg_start += 1) {}
        }
        while (arg_start < cmd_line.len and cmd_line[arg_start] == ' ') : (arg_start += 1) {}
        // Add remaining args (split by spaces, respecting quotes)
        while (arg_start < cmd_line.len and argc < argv_buf.len - 1) {
            var arg_end = arg_start;
            if (cmd_line[arg_start] == '"') {
                arg_start += 1;
                arg_end = arg_start;
                while (arg_end < cmd_line.len and cmd_line[arg_end] != '"') : (arg_end += 1) {}
                argv_buf[argc] = cmd_line[arg_start..arg_end];
                argc += 1;
                arg_end += 1;
            } else {
                while (arg_end < cmd_line.len and cmd_line[arg_end] != ' ') : (arg_end += 1) {}
                if (arg_end > arg_start) {
                    argv_buf[argc] = cmd_line[arg_start..arg_end];
                    argc += 1;
                }
            }
            arg_start = arg_end;
            while (arg_start < cmd_line.len and cmd_line[arg_start] == ' ') : (arg_start += 1) {}
        }
    }

    if (trace.enable_tracing) {
        trace.print("KERNEL32: CreateProcessA -> exec:", .{});
        for (argv_buf[0..argc]) |arg| {
            trace.print(" '{s}'", .{arg});
        }
        trace.print("\n", .{});
    }

    // Reclaim slots of children that already exited un-waited, then reserve
    // a table slot BEFORE spawning: spawning a child we cannot track would
    // leave it permanently unreaped (zombie) and unwaitable.
    reapExitedChildren();
    const reserved_slot = reserveChildSlot() orelse {
        log.warn("CreateProcessA: child process table full ({d} live children)", .{max_child_procs});
        return 0; // FALSE
    };

    // Spawn the child process
    const child = std.process.spawn(rt_io, .{ .argv = argv_buf[0..argc] }) catch |err| {
        log.warn("CreateProcessA: spawn failed: {}", .{err});
        return 0; // FALSE: reservation had no handle set, so the slot stays free
    };

    const proc_handle = adoptReservedChild(reserved_slot, child);

    if (lpProcessInformation != 0) {
        const pi = @as(*align(1) w32.PROCESS_INFORMATION, @ptrFromInt(lpProcessInformation));
        pi.hProcess = @truncate(proc_handle);
        pi.hThread = @truncate(proc_handle + 0x10000); // fake thread handle
        pi.dwProcessId = @intCast(child.id orelse 0);
        pi.dwThreadId = @intCast(child.id orelse 0);
    }

    log.info("Spawned child process (pid={d}, handle=0x{X})", .{ child.id orelse 0, proc_handle });
    return 1; // TRUE
}

/// Implementation status: Partially implemented
pub fn CreateProcessW(
    lpApplicationName: usize,
    lpCommandLine: usize,
    lpProcessAttributes: usize,
    lpThreadAttributes: usize,
    bInheritHandles: i32,
    dwCreationFlags: u32,
    lpEnvironment: usize,
    lpCurrentDirectory: usize,
    lpStartupInfo: usize,
    lpProcessInformation: usize,
) callconv(w32cc.WINAPI) i32 {
    // Convert wide strings to narrow, then delegate to CreateProcessA
    var narrow_app: [1024]u8 = undefined;
    var narrow_app_addr: usize = 0;
    if (lpApplicationName != 0) {
        const wstr = trace.c_span_w(lpApplicationName);
        const copy_len = @min(wstr.len, 1023);
        for (0..copy_len) |i| {
            narrow_app[i] = @intCast(wstr[i] & 0xFF);
        }
        narrow_app[copy_len] = 0;
        narrow_app_addr = @intFromPtr(&narrow_app);
        if (trace.enable_tracing) trace.print("KERNEL32: CreateProcessW(app='{s}')\n", .{narrow_app[0..copy_len]});
    }

    var narrow_cmd: [4096]u8 = undefined;
    var narrow_cmd_addr: usize = 0;
    if (lpCommandLine != 0) {
        const wstr = trace.c_span_w(lpCommandLine);
        const copy_len = @min(wstr.len, 4095);
        for (0..copy_len) |i| {
            narrow_cmd[i] = @intCast(wstr[i] & 0xFF);
        }
        narrow_cmd[copy_len] = 0;
        narrow_cmd_addr = @intFromPtr(&narrow_cmd);
        if (trace.enable_tracing) trace.print("KERNEL32: CreateProcessW(cmd='{s}')\n", .{narrow_cmd[0..copy_len]});
    }

    return CreateProcessA(
        narrow_app_addr,
        narrow_cmd_addr,
        lpProcessAttributes,
        lpThreadAttributes,
        bInheritHandles,
        dwCreationFlags,
        lpEnvironment,
        lpCurrentDirectory,
        lpStartupInfo,
        lpProcessInformation,
    );
}

/// Implementation status: Partially implemented
pub fn GetEnvironmentStringsA() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetEnvironmentStringsA()\n", .{});
    const msvcrt = @import("../msvcrt.zig");
    var total_len: usize = 1; // Final null
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            total_len += trace.host_c_span(@intFromPtr(env_ptr)).len + 1;
        }
    }

    const ptr = kernel32_mem.raw_alloc(total_len) orelse return null;
    const buf = @as([*]u8, @ptrCast(ptr));
    var pos: usize = 0;
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.host_c_span(@intFromPtr(env_ptr));
            @memcpy(buf[pos .. pos + span.len], span);
            pos += span.len;
            buf[pos] = 0;
            pos += 1;
        }
    }
    buf[pos] = 0;
    return ptr;
}

/// Implementation status: Partially implemented
pub fn FreeEnvironmentStringsA(penv: usize) callconv(w32cc.WINAPI) i32 {
    _ = penv;
    return 1;
}

/// Implementation status: Partially implemented
pub fn FreeEnvironmentStringsW(penv: usize) callconv(w32cc.WINAPI) i32 {
    _ = penv;
    return 1;
}

/// Implementation status: Partially implemented
pub fn GetEnvironmentStringsW() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetEnvironmentStringsW()\n", .{});
    const msvcrt = @import("../msvcrt.zig");
    var total_chars: usize = 1; // Final null
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            total_chars += trace.host_c_span(@intFromPtr(env_ptr)).len + 1;
        }
    }

    const ptr = kernel32_mem.raw_alloc(total_chars * 2) orelse return null;
    const buf = @as([*]u16, @ptrCast(@alignCast(ptr)));
    var pos: usize = 0;
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.host_c_span(@intFromPtr(env_ptr));
            for (span) |c| {
                buf[pos] = c;
                pos += 1;
            }
            buf[pos] = 0;
            pos += 1;
        }
    }
    buf[pos] = 0;
    return ptr;
}

const ThreadStartFn = *const fn (usize) callconv(w32cc.WINAPI) u32;
var next_thread_handle: usize = 0xA0010001;

// --- Thread Handle Registry ---
// Tracks guest threads for lifecycle management (WaitForSingleObject, ExitThread).
const MAX_GUEST_THREADS = 32;

const ThreadInfo = struct {
    handle: usize = 0,
    thread: if (platform.is_native) ?std.Thread else void = if (platform.is_native) null else {},
    running: bool = false,
    exit_code: u32 = 0,
    /// TEB copy owned by this slot and reused by every guest thread created
    /// on it. Allocating a fresh one per CreateThread cycle and never freeing
    /// it leaked one page-allocator block per finished thread; slots are
    /// bounded (MAX_GUEST_THREADS) so reuse bounds total TEB memory too.
    teb_mem: ?[]u8 = null,
};

var thread_registry: [MAX_GUEST_THREADS]ThreadInfo = [_]ThreadInfo{.{}} ** MAX_GUEST_THREADS;
var thread_registry_mutex: if (platform.is_native) runtime.Mutex else struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
} = .{};

fn allocThreadInfo() ?*ThreadInfo {
    thread_registry_mutex.lock();
    defer thread_registry_mutex.unlock();
    for (&thread_registry) |*ti| {
        if (ti.handle == 0) return ti;
    }
    // Recycle a finished thread's slot so sequential CreateThread cycles
    // don't exhaust the registry with exited entries.
    for (&thread_registry) |*ti| {
        if (!ti.running) {
            if (comptime platform.is_native) {
                if (ti.thread) |t| t.detach();
                ti.thread = null;
            }
            ti.handle = 0;
            return ti;
        }
    }
    return null;
}

/// Release a thread handle via CloseHandle.
/// Returns true when the handle belonged to this registry.
pub fn closeThreadHandle(handle: usize) bool {
    thread_registry_mutex.lock();
    defer thread_registry_mutex.unlock();
    for (&thread_registry) |*ti| {
        if (ti.handle == handle) {
            if (comptime platform.is_native) {
                // Detach any unjoined OS thread so its resources are freed at
                // exit. A still-running thread keeps its slot reserved until
                // threadWrapper clears running, so the slot is never reused
                // while the detached thread still writes it.
                if (ti.thread) |t| t.detach();
                ti.thread = null;
                if (ti.running) return true;
            }
            ti.handle = 0;
            return true;
        }
    }
    return false;
}

/// Release a child-process handle via CloseHandle.
/// Returns true when the handle belonged to this registry. A live child keeps
/// its slot so WaitForSingleObject can still reap it later; only reaped
/// children free their slot immediately.
pub fn closeChildProcHandle(handle: usize) bool {
    for (&child_procs) |*cp| {
        if (cp.handle == handle) {
            if (cp.exit_code != null) cp.handle = 0;
            return true;
        }
    }
    return false;
}

/// Look up a ThreadInfo entry by its Win32 handle.
/// Used by WaitForSingleObject in sync.zig.
pub fn getThreadInfo(handle: usize) ?*ThreadInfo {
    for (&thread_registry) |*ti| {
        if (ti.handle == handle) return ti;
    }
    return null;
}

const ThreadWrapperCtx = struct {
    start_address: usize,
    parameter: usize,
    thread_info: *ThreadInfo,
};

fn threadWrapper(ctx: ThreadWrapperCtx) void {
    const start_address = ctx.start_address;
    const parameter = ctx.parameter;
    const thread_info = ctx.thread_info;

    // Allocate a per-thread TEB so each thread has its own SEH chain and TLS.
    // Copy the main thread's TEB as a template. The allocation belongs to the
    // registry slot (thread_info.teb_mem) and is reused across CreateThread
    // cycles on that slot, so repeated thread create/exit stays bounded.
    const teb_mod = @import("../teb.zig");
    const builtin_mod = @import("builtin");

    // This OS thread's own TLS location, captured before setupFS points FS
    // at the guest TEB. Restored in the defer below: past this function the
    // spawned thread still runs its own exit path (std.Thread/pthread
    // teardown reads per-thread libc state via %fs), and with the slot-owned
    // TEB now reusable by the next CreateThread, leaving FS aimed at it would
    // let a dying thread corrupt its successor's TLS. It also stops every
    // finished thread from reading TLS out of leaked TEB memory forever.
    var saved_fs_base: usize = 0;
    var saved_fs_sel: u16 = 0;
    defer {
        if (comptime builtin_mod.os.tag == .linux and platform.is_native) {
            if (comptime builtin_mod.target.cpu.arch == .x86_64) {
                if (saved_fs_base != 0) {
                    asm volatile ("syscall"
                        :
                        : [num] "{rax}" (@as(usize, 158)), // __NR_arch_prctl
                          [arg1] "{rdi}" (@as(usize, 0x1002)), // ARCH_SET_FS
                          [arg2] "{rsi}" (saved_fs_base),
                        : .{ .rax = true, .rcx = true, .r11 = true, .memory = true });
                }
            } else if (comptime builtin_mod.target.cpu.arch == .x86) {
                if (saved_fs_sel != 0) {
                    asm volatile ("mov %[sel], %%fs"
                        :
                        : [sel] "r" (saved_fs_sel),
                    );
                }
            }
        }
        // Clear running only after FS is back on host TLS: allocThreadInfo
        // recycles any slot whose thread is !running, and the recycled TEB
        // must not be repopulated while this thread can still reach it.
        thread_info.running = false;
    }

    if (teb_mod.teb_base_addr != 0) {
        const teb_size = @sizeOf(teb_mod.TEB);
        const thread_teb_mem = blk: {
            if (thread_info.teb_mem) |m| break :blk m;
            const m = std.heap.page_allocator.alloc(u8, teb_size) catch {
                // Fallback: share main thread's TEB
                teb_mod.setupFS(@ptrFromInt(teb_mod.teb_base_addr)) catch {};
                if (start_address != 0) {
                    const func = @as(ThreadStartFn, @ptrFromInt(start_address));
                    thread_info.exit_code = func(parameter);
                }
                return;
            };
            thread_info.teb_mem = m;
            break :blk m;
        };

        // Capture the pre-swap TLS base/selector for the defer above.
        if (comptime builtin_mod.os.tag == .linux and platform.is_native) {
            if (comptime builtin_mod.target.cpu.arch == .x86_64) {
                // ARCH_GET_FS writes through arg2; rax return (0 or -errno) unused.
                _ = asm volatile ("syscall"
                    : [ret] "={rax}" (-> usize),
                    : [num] "{rax}" (@as(usize, 158)), // __NR_arch_prctl
                      [arg1] "{rdi}" (@as(usize, 0x1003)), // ARCH_GET_FS
                      [arg2] "{rsi}" (@intFromPtr(&saved_fs_base)),
                    : .{ .rax = true, .rcx = true, .r11 = true, .memory = true });
            } else if (comptime builtin_mod.target.cpu.arch == .x86) {
                asm volatile ("mov %%fs, %[out]"
                    : [out] "=r" (saved_fs_sel),
                );
            }
        }

        // Copy main thread's TEB
        const main_teb = @as([*]const u8, @ptrFromInt(teb_mod.teb_base_addr));
        @memcpy(thread_teb_mem[0..teb_size], main_teb[0..teb_size]);
        // Initialize per-thread fields
        const thread_teb = @as(*teb_mod.TEB, @ptrCast(@alignCast(thread_teb_mem.ptr)));
        thread_teb.NtTib.ExceptionList = 0xFFFFFFFF; // Empty SEH chain
        thread_teb.NtTib.Self = @truncate(@intFromPtr(thread_teb_mem.ptr) + 0x18); // Self pointer
        // Set up FS to point to this thread's TEB
        teb_mod.setupFS(@ptrCast(@alignCast(thread_teb_mem.ptr))) catch {};
    }

    if (start_address == 0) {
        return;
    }

    // On native x86, guest code runs natively — call directly as before.
    // On x86_64, guest code runs in compat mode via signal-based dispatcher.
    // On WASM, guest code runs through the x86 interpreter.
    if (comptime !platform.is_native) {
        // WASM: use x86 interpreter for guest code
        const x86_cpu = @import("../../x86/cpu.zig");
        const x86_execute = @import("../../x86/execute.zig");
        const shared = @import("../shared.zig");

        var cpu = x86_cpu.Cpu{};
        // Share the same guest memory
        if (x86_memory.guest_memory) |gm| {
            cpu.memory = gm.*;
        }
        cpu.eip = @intCast(start_address);
        // Allocate 8MB guest stack (standard Linux thread stack size, Windows default is 1MB but compilers are hungry)
        const stack_size: u32 = 8 * 1024 * 1024;
        if (shared.raw_alloc(stack_size)) |stack_ptr| {
            cpu.esp = @intCast(@intFromPtr(stack_ptr) + stack_size - 16);
        }
        // Win32 LPTHREAD_START_ROUTINE: push parameter, push return address (0 = halt)
        cpu.push32(@intCast(parameter));
        cpu.push32(0); // Return to address 0 causes halt

        if (teb_mod.teb_base_addr != 0) {
            cpu.fs_base = @intCast(teb_mod.teb_base_addr);
        }

        x86_execute.run(&cpu);
        thread_info.exit_code = cpu.eax;
    } else if (comptime platform.is_x86_64) {
        // x86_64: use compat mode (signal-based CS=0x23 execution)
        const compat_thunks = @import("../../x86/compat_thunks.zig");
        thread_info.exit_code = compat_thunks.callCompat32(@intCast(start_address), @intCast(parameter), 0, 0);
    } else {
        // Native x86: call directly — guest code runs natively on host CPU
        const func = @as(ThreadStartFn, @ptrFromInt(start_address));
        thread_info.exit_code = func(parameter);
    }
}

/// CreateThread: Creates a thread to execute within the virtual address space of the calling process.
/// Implementation status: Partially implemented
pub fn CreateThread(lpThreadAttributes: usize, dwStackSize: usize, lpStartAddress: usize, lpParameter: usize, dwCreationFlags: u32, lpThreadId: usize) callconv(w32cc.WINAPI) usize {
    _ = lpThreadAttributes;
    _ = dwStackSize;
    _ = dwCreationFlags;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateThread(start={x}, param={x})\n", .{ lpStartAddress, lpParameter });

    const ti = allocThreadInfo() orelse {
        if (trace.enable_tracing) trace.print("KERNEL32: CreateThread failed — thread registry full\n", .{});
        return 0;
    };

    const handle = next_thread_handle;
    next_thread_handle += 1;

    ti.handle = handle;
    ti.running = true;
    ti.exit_code = 0;

    if (lpThreadId != 0) {
        @as(*u32, @ptrFromInt(lpThreadId)).* = @intCast(handle & 0xFFFF);
    }

    if (comptime platform.is_native) {
        ti.thread = std.Thread.spawn(.{}, threadWrapper, .{ThreadWrapperCtx{
            .start_address = lpStartAddress,
            .parameter = lpParameter,
            .thread_info = ti,
        }}) catch {
            if (trace.enable_tracing) trace.print("KERNEL32: CreateThread spawn failed\n", .{});
            ti.handle = 0;
            ti.running = false;
            return 0;
        };
    } else {
        // WASM: run synchronously (no real threading)
        threadWrapper(ThreadWrapperCtx{
            .start_address = lpStartAddress,
            .parameter = lpParameter,
            .thread_info = ti,
        });
    }

    return handle;
}

/// ExitThread: Ends the calling thread.
/// Implementation status: Partially implemented
pub fn ExitThread(dwExitCode: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: ExitThread({d})\n", .{dwExitCode});
    // Store exit code for whichever thread we are
    if (comptime platform.is_native) {
        const tid = std.Thread.getCurrentId();
        for (&thread_registry) |*ti| {
            if (ti.handle != 0 and ti.running) {
                if (ti.thread) |t| {
                    _ = t;
                    // Match by host thread ID — the ThreadInfo.thread field
                    // has the same thread ID as the currently executing thread
                    _ = tid;
                    ti.exit_code = dwExitCode;
                    break;
                }
            }
        }
    }
    // Note: On native x86, this returns to the caller (threadWrapper) which
    // then sets running=false. On WASM, the interpreter continues until halt.
}

// Deprecated: cmdline_w_buf is removed because pointers to .bss truncate on 64-bit systems.

/// Implementation status: Partially implemented
pub fn GetModuleFileNameW(hModule: usize, lpFilename: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    _ = hModule;
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleFileNameW\n", .{});
    if (lpFilename == 0 or nSize == 0) return 0;

    const msvcrt = @import("../msvcrt.zig");
    if (msvcrt.global_argc > 0 and msvcrt.global_argv[0] != null) {
        const exe_path = trace.c_span(@intFromPtr(msvcrt.global_argv[0].?));
        const wbuf = @as([*]u16, @ptrFromInt(lpFilename));
        const copy_len = @min(exe_path.len, nSize - 1);
        for (0..copy_len) |i| {
            const c = exe_path[i];
            wbuf[i] = if (c == '/') '\\' else c;
        }
        wbuf[copy_len] = 0;
        return @intCast(copy_len);
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn GetCommandLineW() callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineW\n", .{});
    if (!cmdline_w_initialized) {
        // Get narrow command line and widen it
        const narrow_ptr = GetCommandLineA();
        const narrow = trace.c_span(narrow_ptr);

        const kernel32_mem_mod = @import("mem.zig");
        if (cmdline_w_host_addr == 0) {
            const raw = kernel32_mem_mod.raw_alloc(8192) orelse return 0;
            cmdline_w_host_addr = @intFromPtr(raw);
            cmdline_w_guest_addr = @import("../shared.zig").hostToGuest(cmdline_w_host_addr);
        }

        const wbuf = @as([*]u16, @ptrFromInt(cmdline_w_host_addr));
        const copy_len = @min(narrow.len, 4095);
        for (0..copy_len) |i| {
            wbuf[i] = narrow[i];
        }
        wbuf[copy_len] = 0;
        cmdline_w_initialized = true;
    }
    return cmdline_w_guest_addr;
}

/// Implementation status: Partially implemented
pub fn LoadLibraryW(lpFileName_ptr: usize) callconv(w32cc.WINAPI) usize {
    if (lpFileName_ptr == 0) return 0;
    const wstr = trace.c_span_w(lpFileName_ptr);
    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryW (len={d})\n", .{wstr.len});
    // Convert wide to narrow
    var narrow_buf: [1024]u8 = undefined;
    const copy_len = @min(wstr.len, 1023);
    for (0..copy_len) |i| {
        narrow_buf[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow_buf[copy_len] = 0;
    // Delegate to LoadLibraryA
    return LoadLibraryA(@intFromPtr(&narrow_buf));
}

/// stub_OpenProcess
/// Implementation status: Stub
pub fn stub_OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(w32cc.WINAPI) usize {
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    _ = dwProcessId;
    if (trace.enable_tracing) trace.print("KERNEL32: OpenProcess -> 0 (fail)\n", .{});
    return 0;
}

/// stub_SetHandleInformation
/// Implementation status: No-op fallback
pub fn stub_SetHandleInformation(hObject: usize, dwMask: u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = hObject;
    _ = dwMask;
    _ = dwFlags;
    return 1;
}

/// Implementation status: Partially implemented
pub fn CreatePipe(hReadPipe: usize, hWritePipe: usize, lpPipeAttributes: usize, nSize: u32) callconv(w32cc.WINAPI) i32 {
    _ = lpPipeAttributes;
    _ = nSize;
    if (trace.enable_tracing) trace.print("KERNEL32: CreatePipe()\n", .{});

    if (hReadPipe == 0 or hWritePipe == 0) return 0;

    if (comptime !platform.is_native) {
        // WASM: can't create pipes
        return 0;
    }

    const fds = platform.pipe() catch return 0;
    @as(*u32, @ptrFromInt(hReadPipe)).* = @bitCast(fds[0]);
    @as(*u32, @ptrFromInt(hWritePipe)).* = @bitCast(fds[1]);
    if (trace.enable_tracing) trace.print("KERNEL32: CreatePipe -> read={d}, write={d}\n", .{ fds[0], fds[1] });
    return 1; // TRUE
}

/// GetPriorityClass: returns priority class of a process
/// NORMAL_PRIORITY_CLASS = 0x00000020
/// Implementation status: Stub
pub fn stub_GetPriorityClass(hProcess: usize) callconv(w32cc.WINAPI) u32 {
    _ = hProcess;
    return 0x20; // NORMAL_PRIORITY_CLASS
}

/// --- DxWrapper / MSVC CRT stubs ---
/// Implementation status: Partially implemented
pub fn LoadLibraryExA(lpLibFileName: usize, hFile: usize, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = hFile;
    _ = dwFlags;
    return LoadLibraryA(lpLibFileName);
}

/// Implementation status: Partially implemented
pub fn LoadLibraryExW(lpLibFileName: usize, hFile: usize, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryExW(hFile={X}, flags=0x{X})\n", .{ hFile, dwFlags });
    // Delegate to LoadLibraryW which handles wide-to-narrow conversion
    return LoadLibraryW(lpLibFileName);
}

/// Implementation status: Partially implemented
pub fn GetModuleHandleExW(dwFlags: u32, lpModuleName: usize, phModule: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleExW(flags=0x{X})\n", .{dwFlags});

    var handle: usize = 0;

    if (lpModuleName == 0) {
        // NULL module name = main exe
        handle = kernel32.main_module_handle;
    } else {
        // Convert wide to narrow and use existing GetModuleHandleA
        const wstr = trace.c_span_w(lpModuleName);
        var narrow_buf: [1024]u8 = undefined;
        const copy_len = @min(wstr.len, 1023);
        for (0..copy_len) |i| {
            narrow_buf[i] = @intCast(wstr[i] & 0xFF);
        }
        narrow_buf[copy_len] = 0;
        handle = GetModuleHandleA(@intFromPtr(&narrow_buf));
    }

    if (phModule != 0) {
        @as(*u32, @ptrFromInt(phModule)).* = @truncate(handle);
    }
    return if (handle != 0) 1 else 0;
}

/// Implementation status: Partially implemented
pub fn IsDebuggerPresent() callconv(w32cc.WINAPI) i32 {
    return 0; // Not being debugged
}

/// --- Additional process stubs ---
/// Implementation status: Partially implemented
pub fn GetCurrentThread() callconv(w32cc.WINAPI) usize {
    return 0xFFFFFFFE; // Pseudo-handle for current thread
}

/// stub_FreeLibrary
/// Implementation status: No-op fallback
pub fn stub_FreeLibrary(hLibModule: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: FreeLibrary({x})\n", .{hLibModule});
    return 1; // TRUE = success (no-op, we don't unload)
}

/// stub_SetPriorityClass
/// Implementation status: No-op fallback
pub fn stub_SetPriorityClass(hProcess: usize, dwPriorityClass: u32) callconv(w32cc.WINAPI) i32 {
    _ = hProcess;
    _ = dwPriorityClass;
    return 1; // TRUE
}

/// stub_SetThreadPriority
/// Implementation status: No-op fallback
pub fn stub_SetThreadPriority(hThread: usize, nPriority: i32) callconv(w32cc.WINAPI) i32 {
    _ = hThread;
    _ = nPriority;
    return 1; // TRUE
}

/// stub_ResumeThread
/// Implementation status: No-op fallback
pub fn stub_ResumeThread(hThread: usize) callconv(w32cc.WINAPI) u32 {
    _ = hThread;
    return 1; // Previous suspend count = 1
}

/// stub_TerminateProcess
/// Implementation status: No-op fallback
pub fn stub_TerminateProcess(hProcess: usize, uExitCode: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: TerminateProcess({x}, {d})\n", .{ hProcess, uExitCode });
    return 1; // TRUE
}

/// Implementation status: Partially implemented
pub fn GetExitCodeProcess(hProcess: usize, lpExitCode: usize) callconv(w32cc.WINAPI) i32 {
    if (lpExitCode == 0) return 1;

    // Check if this is a tracked child process
    if (getChildProc(hProcess)) |cp| {
        if (cp.exit_code) |code| {
            @as(*u32, @ptrFromInt(lpExitCode)).* = code;
        } else {
            @as(*u32, @ptrFromInt(lpExitCode)).* = 259; // STILL_ACTIVE
        }
        return 1;
    }

    @as(*u32, @ptrFromInt(lpExitCode)).* = 0;
    return 1; // TRUE
}

/// stub_SuspendThread
/// Implementation status: Stub
pub fn stub_SuspendThread(hThread: usize) callconv(w32cc.WINAPI) u32 {
    _ = hThread;
    return 0; // Previous suspend count = 0
}

/// stub_GetThreadPriority
/// Implementation status: Stub
pub fn stub_GetThreadPriority(hThread: usize) callconv(w32cc.WINAPI) i32 {
    _ = hThread;
    return 0; // THREAD_PRIORITY_NORMAL
}

// -------------------------------------------------------------------------
// Module / atom / env-string functions (moved from misc.zig)
// -------------------------------------------------------------------------

/// Returns the path of the executable file of the current process.
pub fn GetModuleFileNameA_Full(hModule: usize, lpFilename: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleFileNameA(hModule={x})\n", .{hModule});
    if (lpFilename == 0 or nSize == 0) return 0;
    const buf = @as([*]u8, @ptrFromInt(lpFilename));

    // For the main module (hModule == 0 or matches main_module_handle), return real exe path
    if (hModule == 0 or hModule == kernel32.main_module_handle) {
        const result = GetModuleFileNameA(hModule, lpFilename, nSize);
        if (result > 0) return result;

        // Fallback to exe dir + generic name
        const dir = runtime.main_exe_dir[0..runtime.main_exe_dir_len];
        const exe_name = "program.exe";
        const total = dir.len + exe_name.len;
        if (total < nSize) {
            @memcpy(buf[0..dir.len], dir);
            @memcpy(buf[dir.len..total], exe_name);
            buf[total] = 0;
            return @intCast(total);
        }
    }

    // Fallback: try to find module name from registry
    if (kernel32.global_env) |genv| {
        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == hModule) {
                const dir = runtime.main_exe_dir[0..runtime.main_exe_dir_len];
                const mname = m.*.name;
                const total = dir.len + mname.len;
                if (total < nSize) {
                    @memcpy(buf[0..dir.len], dir);
                    @memcpy(buf[dir.len..total], mname);
                    buf[total] = 0;
                    return @intCast(total);
                }
            }
        }
    }

    // Last resort fallback: use main_exe_dir if available
    if (runtime.main_exe_dir_len > 0) {
        const dir = runtime.main_exe_dir[0..runtime.main_exe_dir_len];
        const exe_name = "program.exe";
        const total = dir.len + exe_name.len;
        if (total < nSize) {
            @memcpy(buf[0..dir.len], dir);
            @memcpy(buf[dir.len..total], exe_name);
            buf[total] = 0;
            return @intCast(total);
        }
    }
    const name = "C:\\program.exe";
    const copy_len = @min(name.len, @as(usize, nSize) - 1);
    @memcpy(buf[0..copy_len], name[0..copy_len]);
    buf[copy_len] = 0;
    return @intCast(copy_len);
}

/// Adds a character string to the global atom table and returns a unique value (an atom).
pub fn GlobalAddAtomA(lpString: usize) callconv(w32cc.WINAPI) u16 {
    const state = struct {
        var next_atom: u16 = 0xC000;
    };
    const atom = state.next_atom;
    if (state.next_atom < 0xFFFF) state.next_atom += 1;
    if (trace.enable_tracing) {
        const name = if (lpString != 0) trace.c_span(lpString) else "(null)";
        trace.print("KERNEL32: GlobalAddAtomA('{s}') -> 0x{X}\n", .{ name, atom });
    }
    return atom;
}

/// ExpandEnvironmentStringsA — expands %VARIABLE% references in a string.
pub fn ExpandEnvironmentStringsA(lpSrc: usize, lpDst: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    if (lpSrc == 0) return 0;
    const src = trace.c_span(lpSrc);
    if (trace.enable_tracing) trace.print("KERNEL32: ExpandEnvironmentStringsA('{s}')\n", .{src});

    // Simple passthrough — copy src to dst without expansion
    const copy_len = @min(src.len, if (nSize > 0) nSize - 1 else 0);
    if (lpDst != 0 and copy_len > 0) {
        const dst = @as([*]u8, @ptrFromInt(lpDst));
        for (0..copy_len) |i| dst[i] = src[i];
        dst[copy_len] = 0;
    }
    return @intCast(src.len + 1);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn testDummyChild() if (platform.is_native) std.process.Child else void {
    if (comptime platform.is_native) {
        return .{
            .id = null,
            .thread_handle = {},
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        };
    } else {
        return {};
    }
}

test "child proc table recycles reaped slots" {
    const saved_procs = child_procs;
    defer child_procs = saved_procs;
    child_procs = [_]ChildProc{.{}} ** max_child_procs;

    const dummy = testDummyChild();
    var first_handle: usize = 0;
    for (0..max_child_procs) |i| {
        const h = allocChildProc(dummy) orelse return error.TestUnexpectedResult;
        if (i == 0) first_handle = h;
    }
    // Table full of live children — no free slot.
    try std.testing.expect(allocChildProc(dummy) == null);

    // Once the first child is reaped, its slot is evictable.
    getChildProc(first_handle).?.exit_code = 0;
    try std.testing.expect(allocChildProc(dummy) != null);
}

test "closeChildProcHandle frees reaped slots only" {
    const saved_procs = child_procs;
    defer child_procs = saved_procs;
    child_procs = [_]ChildProc{.{}} ** max_child_procs;

    const dummy = testDummyChild();
    const h_live = allocChildProc(dummy) orelse return error.TestUnexpectedResult;
    const h_done = allocChildProc(dummy) orelse return error.TestUnexpectedResult;
    getChildProc(h_done).?.exit_code = 7;

    try std.testing.expect(closeChildProcHandle(h_done));
    try std.testing.expect(getChildProc(h_done) == null);
    // Live children keep their slot so they can still be waited on.
    try std.testing.expect(closeChildProcHandle(h_live));
    try std.testing.expect(getChildProc(h_live) != null);
}

test "thread registry recycles finished slots" {
    // No lock here: allocThreadInfo() takes thread_registry_mutex itself and
    // the mutex is a non-reentrant spinlock — locking first would deadlock.
    const saved_registry = thread_registry;
    defer thread_registry = saved_registry;
    for (&thread_registry) |*ti| ti.* = .{};
    for (&thread_registry, 0..) |*ti, i| {
        ti.handle = 0xA0010000 + i;
        ti.running = false;
    }

    // Every slot holds a finished thread — allocation must recycle, not fail.
    try std.testing.expect(allocThreadInfo() != null);
}

test "reapExitedChildren records exit codes of finished children" {
    if (comptime !platform.is_native) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const saved_procs = child_procs;
    defer child_procs = saved_procs;
    child_procs = [_]ChildProc{.{}} ** max_child_procs;

    const fork_rc = std.os.linux.fork();
    const pid_signed: isize = @bitCast(fork_rc);
    if (pid_signed < 0) return error.SkipZigTest;
    if (pid_signed == 0) {
        // Child: exit immediately with a known code (raw exit, no atexit).
        std.os.linux.exit(7);
    }

    child_procs[0] = .{
        .handle = 0xCA000001,
        .child = .{
            .id = @intCast(pid_signed),
            .thread_handle = {},
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        },
        .exit_code = null,
    };

    // The child may need a moment to terminate; reapExitedChildren only
    // collects children that have already exited.
    var spins: usize = 0;
    while (spins < 1000 and child_procs[0].exit_code == null) : (spins += 1) {
        reapExitedChildren();
        if (child_procs[0].exit_code == null) platform.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(child_procs[0].exit_code != null);
    try std.testing.expectEqual(@as(u32, 7), child_procs[0].exit_code.?);

    // A reaped entry is evictable again.
    try std.testing.expect(allocChildProc(testDummyChild()) != null);
}

test "closeThreadHandle releases finished entries and reserves running ones" {
    // No outer lock: closeThreadHandle()/allocThreadInfo() lock internally.
    const saved_registry = thread_registry;
    defer thread_registry = saved_registry;
    for (&thread_registry) |*ti| ti.* = .{};

    const done = allocThreadInfo() orelse return error.TestUnexpectedResult;
    done.handle = 0xA0010042;
    done.running = false;

    const live = allocThreadInfo() orelse return error.TestUnexpectedResult;
    live.handle = 0xA0010043;
    live.running = true;
    live.thread = if (platform.is_native) null else {};

    try std.testing.expect(closeThreadHandle(0xA0010042));
    try std.testing.expect(getThreadInfo(0xA0010042) == null);

    try std.testing.expect(closeThreadHandle(0xA0010043));
    // A running (detached) thread keeps its slot until it finishes.
    try std.testing.expect(getThreadInfo(0xA0010043) != null);
}

test "GetProcAddress returns a stable cached address per module+name" {
    const saved_env = kernel32.global_env;
    defer kernel32.global_env = saved_env;

    const alloc = std.heap.page_allocator;
    var environment = env.Environment.init(alloc);
    defer {
        // Cache entries own their (page_allocator) name copies.
        for (proc_cache.items) |*e| alloc.free(e.name);
        proc_cache.clearRetainingCapacity();
        environment.deinit();
    }
    try environment.addBuiltinExport("TESTDLL.dll", "FakeApi", 0x00F00D00);
    kernel32.global_env = &environment;

    const hmod = environment.getBuiltinHandle("TESTDLL.dll") orelse return error.TestUnexpectedResult;
    const name_z: [*:0]const u8 = "FakeApi";

    const first = GetProcAddress(hmod, @intFromPtr(name_z));
    try std.testing.expect(first != 0);
    // Second lookup must return the SAME address (Win32 semantics), not
    // allocate another thunk.
    const second = GetProcAddress(hmod, @intFromPtr(name_z));
    try std.testing.expectEqual(first, second);

    // A miss is not cached and must not disturb cached entries.
    const missing = GetProcAddress(hmod, @intFromPtr(@as([*:0]const u8, "NoSuchApi")));
    try std.testing.expectEqual(@as(usize, 0), missing);
    const third = GetProcAddress(hmod, @intFromPtr(name_z));
    try std.testing.expectEqual(first, third);
}

test "SetEnvironmentVariableA NULL value deletes and shadows inherited vars" {
    const msvcrt = @import("../msvcrt.zig");
    const saved_vars = msvcrt.msvcrt_env_vars;
    const saved_envp = msvcrt.global_envp;
    var empty_envp: [1]?[*:0]const u8 = .{null};
    msvcrt.msvcrt_env_vars = .empty;
    msvcrt.global_envp = &empty_envp;
    defer {
        for (msvcrt.msvcrt_env_vars.items) |v| {
            if (!v.deleted) {
                std.heap.page_allocator.free(v.key);
                std.heap.page_allocator.free(v.val);
            } else if (v.key.len > 0) {
                std.heap.page_allocator.free(v.key);
            }
        }
        msvcrt.msvcrt_env_vars.deinit(std.heap.page_allocator);
        msvcrt.msvcrt_env_vars = saved_vars;
        msvcrt.global_envp = saved_envp;
    }

    var name_buf: [8]u8 = undefined;
    @memcpy(name_buf[0..4], "PATH");
    name_buf[4] = 0;
    var val_buf: [16]u8 = undefined;
    @memcpy(val_buf[0..7], "newdir/");
    val_buf[7] = 0;

    // Set an override (different case than a typical inherited "PATH").
    try std.testing.expectEqual(@as(i32, 1), SetEnvironmentVariableA(@intFromPtr(&name_buf), @intFromPtr(&val_buf)));
    try std.testing.expectEqualStrings("newdir/", getEnvValue("path").?);

    // Delete via lpValue == NULL (Win32 contract).
    try std.testing.expectEqual(@as(i32, 1), SetEnvironmentVariableA(@intFromPtr(&name_buf), 0));
    try std.testing.expect(getEnvValue("PATH") == null);
}
