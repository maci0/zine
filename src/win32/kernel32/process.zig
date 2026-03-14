const std = @import("std");
const env = @import("../../loader/env.zig");
const trace = @import("../../trace.zig");
const log = @import("../../log.zig");
const kernel32 = @import("../kernel32.zig");
const loader = @import("../../loader/loader.zig");
const kernel32_mem = @import("mem.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../../win32_constants.zig");
const x86_thunks = @import("../../x86/thunks.zig");
const w32cc = @import("../../calling_convention.zig");

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
    ExceptionRecord: *const @import("../../teb.zig").EXCEPTION_RECORD,
    ContextRecord: *const @import("../../teb.zig").CONTEXT,
};

pub fn UnhandledExceptionFilter(ExceptionInfo: usize) callconv(w32cc.WINAPI) u32 {
    if (ExceptionInfo != 0) {
        const ptrs = @as(*EXCEPTION_POINTERS, @ptrFromInt(ExceptionInfo));
        const code = ptrs.ExceptionRecord.ExceptionCode;
        const addr = ptrs.ExceptionRecord.ExceptionAddress;

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

pub fn ExitProcess(exitCode: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: ExitProcess({d})\n", .{exitCode});
    platform.exitProcess(@intCast(exitCode & 0xFF));
}

pub fn stub_SetConsoleCtrlHandler(handler: *const anyopaque, add: i32) callconv(w32cc.WINAPI) i32 {
    _ = handler;
    _ = add;
    return 1;
}

pub fn stub_DisableThreadLibraryCalls(hLibModule: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hLibModule;
    return 1;
}

pub fn LoadLibraryA(lpFileName_ptr: usize) callconv(w32cc.WINAPI) usize {
    if (lpFileName_ptr == 0) return 0;
    const name = trace.c_span(lpFileName_ptr);

    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA('{s}')\n", .{name});

    if (kernel32.global_env) |genv| {
        // Convert Win32 path (e.g. C:\Desktop\Guild\MP3DEC.ASI) to POSIX
        const path_utils = @import("../../path_utils.zig");
        var posix_buf: [1024]u8 = undefined;
        const posix_len = path_utils.win32ToPosix(name, &posix_buf);
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

            if (!mod.attached) {
                mod.attached = true;
                const opt_header = &mod.parser.getNtHeaders().OptionalHeader;
                if (opt_header.AddressOfEntryPoint != 0) {
                    const entry_point_addr = @intFromPtr(mod.mapped_memory.ptr) + opt_header.AddressOfEntryPoint;
                    const DllMain = @as(*const fn (usize, u32, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(entry_point_addr));
                    if (trace.enable_tracing) trace.print("KERNEL32: Executing DllMain for {s} at {x}\n", .{ load_name, entry_point_addr });
                    const ret = DllMain(@intFromPtr(mod.mapped_memory.ptr), 1, 0);
                    if (trace.enable_tracing) trace.print("KERNEL32: DllMain returned {d}\n", .{ret});
                }
            }

            return @intFromPtr(mod.mapped_memory.ptr);
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
                if (c == '.') { has_dot = true; break; }
            }
            if (!has_dot and basename.len < 250) {
                var ext_buf: [256]u8 = undefined;
                @memcpy(ext_buf[0..basename.len], basename);
                @memcpy(ext_buf[basename.len..basename.len + 4], ".dll");
                ext_buf[basename.len + 4] = 0;
                if (genv.getBuiltinHandle(ext_buf[0..basename.len + 4])) |handle| {
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

pub fn GetProcAddress(hModule: usize, lpProcName_ptr: usize) callconv(w32cc.WINAPI) usize {
    if (hModule == 0 or lpProcName_ptr == 0) return 0;

    var is_ordinal = false;
    if (lpProcName_ptr < 0x10000) {
        is_ordinal = true;
    }

    if (kernel32.global_env) |genv| {
        if (!is_ordinal) {
            const name = trace.c_span(lpProcName_ptr);
            var it = genv.builtins.iterator();
            while (it.next()) |entry| {
                const builtin = entry.value_ptr.*;
                if (builtin.handle == hModule) {
                    if (builtin.exports.get(name)) |exp| {
                        if (trace.enable_tracing) trace.print("KERNEL32: GetProcAddress('{s}') -> {x} (from builtin)\n", .{ name, exp.addr });
                        // Register the resolved address as a native import so the
                        // interpreter can dispatch calls to it (GetProcAddress results
                        // bypass the normal IAT-based import registration).
                        x86_thunks.registerNativeImport(@intCast(exp.addr), entry.key_ptr.*, name, exp.param_bytes);
                        return exp.addr;
                    }
                }
            }
        }

        var target_mod: ?*env.Module = null;
        var it = genv.registry.modules.iterator();
        while (it.next()) |entry| {
            const mod = entry.value_ptr.*;
            if (@intFromPtr(mod.mapped_memory.ptr) == hModule) {
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
    return 0;
}

pub fn GetStartupInfoA(lpStartupInfo_ptr: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetStartupInfoA({x})\n", .{lpStartupInfo_ptr});
    if (lpStartupInfo_ptr == 0) return;
    const si = @as(*w32.STARTUPINFOA, @ptrFromInt(lpStartupInfo_ptr));
    si.* = .{}; // zero all, cb defaults to 68
}

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
        var it = genv.registry.modules.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                return @intFromPtr(entry.value_ptr.*.mapped_memory.ptr);
            }
        }

        if (genv.getBuiltinHandle(name)) |handle| {
            if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA -> {x}\n", .{handle});
            return handle;
        }

        // Try with ".dll" suffix appended (games often pass "KERNEL32" without extension)
        if (name.len < 248 and !std.ascii.endsWithIgnoreCase(name, ".dll")) {
            var ext_buf: [256]u8 = undefined;
            @memcpy(ext_buf[0..name.len], name);
            @memcpy(ext_buf[name.len..name.len + 4], ".dll");
            if (genv.getBuiltinHandle(ext_buf[0..name.len + 4])) |handle| {
                if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA('{s}' + .dll) -> {x}\n", .{name, handle});
                return handle;
            }
        }
    }
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleHandleA -> 0 (not found)\n", .{});
    return 0;
}

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


var cmdline_buf: [4096]u8 = undefined;
var cmdline_initialized: bool = false;
var cmdline_result_addr: usize = 0; // Final address to return (host or guest)

pub fn GetCommandLineA() callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineA\n", .{});

    if (!cmdline_initialized) {
        // Determine working buffer: guest memory if available, else host static buf.
        const kernel32_mem_mod = @import("mem.zig");
        var buf: []u8 = &cmdline_buf;
        if (kernel32_mem_mod.guest_memory()) |gmem| {
            const guest_va = gmem.guestAlloc(4096);
            if (guest_va != 0) {
                const host_ptr = @as([*]u8, @ptrFromInt(trace.addr(guest_va)));
                buf = host_ptr[0..4096];
                cmdline_result_addr = guest_va;
            }
        }
        if (cmdline_result_addr == 0) {
            cmdline_result_addr = @intFromPtr(&cmdline_buf);
        }

        const msvcrt = @import("../msvcrt.zig");
        var pos: usize = 0;
        if (msvcrt.global_argc > 0) {
            // Use the actual argv[0] (already has Win32-style path from posixToWin32)
            if (msvcrt.global_argv[0]) |argv0| {
                const span = trace.c_span(@intFromPtr(argv0));
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
                    const arg = trace.c_span(@intFromPtr(arg_ptr));

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

    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineA -> '{s}'\n", .{trace.c_span(cmdline_result_addr)});
    return cmdline_result_addr;
}

pub fn GetCurrentProcess() callconv(w32cc.WINAPI) usize {
    return 0xFFFFFFFF; // Pseudo-handle for current process
}

pub fn GetCurrentProcessId() callconv(w32cc.WINAPI) u32 {
    return platform.getProcessId();
}

pub fn GetCurrentThreadId() callconv(w32cc.WINAPI) u32 {
    return @intCast(std.Thread.getCurrentId());
}

pub fn SetEnvironmentVariableA(lpName: usize, lpValue: usize) callconv(w32cc.WINAPI) i32 {
    if (lpName != 0 and lpValue != 0) {
        const name = trace.c_span(lpName);
        const value = trace.c_span(lpValue);
        if (trace.enable_tracing) trace.print("KERNEL32: SetEnvironmentVariableA('{s}', '{s}')\n", .{ name, value });

        const msvcrt = @import("../msvcrt.zig");
        const key_dupe = std.heap.page_allocator.dupe(u8, name) catch return 0;
        const val_dupe = std.heap.page_allocator.dupe(u8, value) catch return 0;

        for (msvcrt.msvcrt_env_vars.items) |*v| {
            if (std.mem.eql(u8, v.key, key_dupe)) {
                v.val = val_dupe;
                return 1;
            }
        }
        msvcrt.msvcrt_env_vars.append(std.heap.page_allocator, .{ .key = key_dupe, .val = val_dupe }) catch return 0;

        return 1;
    }
    return 0; // FALSE
}

pub fn GetEnvironmentVariableA(lpName: usize, lpBuffer: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    const name = trace.c_span(lpName);
    if (trace.enable_tracing) trace.print("KERNEL32: GetEnvironmentVariableA('{s}')\n", .{name});

    const msvcrt = @import("../msvcrt.zig");
    var value: ?[]const u8 = null;

    // First check overridden vars
    for (msvcrt.msvcrt_env_vars.items) |v| {
        if (std.ascii.eqlIgnoreCase(v.key, name)) {
            value = v.val;
            break;
        }
    }

    // Then check global_envp
    if (value == null) {
        var env_i: usize = 0;
        while (msvcrt.global_envp[env_i]) |e_ptr| : (env_i += 1) {
            const e_str = trace.c_span(@intFromPtr(e_ptr));
            if (std.ascii.startsWithIgnoreCase(e_str, name) and e_str.len > name.len and e_str[name.len] == '=') {
                value = e_str[name.len + 1 ..];
                break;
            }
        }
    }

    if (value) |v| {
        if (lpBuffer != 0 and nSize > v.len) {
            const buf = @as([*]u8, @ptrFromInt(lpBuffer));
            @memcpy(buf[0..v.len], v);
            buf[v.len] = 0;
            return @intCast(v.len);
        }
        return @intCast(v.len + 1); // Return required size
    }

    return 0; // Not found
}

pub fn GetModuleFileNameA(hModule: usize, lpFilename: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    _ = hModule;
    if (lpFilename != 0 and nSize > 0) {
        if (kernel32.global_env) |genv| {
            _ = genv;
            const msvcrt = @import("../msvcrt.zig");
            if (msvcrt.global_argc > 0 and msvcrt.global_argv[0] != null) {
                const exe_path = trace.c_span(@intFromPtr(msvcrt.global_argv[0].?));
                const buf = @as([*]u8, @ptrFromInt(lpFilename));
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
    for (&child_procs) |*cp| {
        if (cp.handle == 0) {
            const h = next_process_handle;
            next_process_handle += 1;
            cp.handle = h;
            cp.child = child;
            cp.exit_code = null;
            return h;
        }
    }
    return null;
}

pub fn getChildProc(handle: usize) ?*ChildProc {
    for (&child_procs) |*cp| {
        if (cp.handle == handle) return cp;
    }
    return null;
}

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

    // Convert Win32 path to POSIX
    const path_utils = @import("../../path_utils.zig");
    var posix_buf: [1024]u8 = undefined;
    const posix_len = path_utils.win32ToPosix(target_path_buf[0..target_path_len], &posix_buf);

    if (trace.enable_tracing) trace.print("KERNEL32: CreateProcessA -> spawning '{s}'\n", .{posix_buf[0..posix_len]});

    // Get our own executable path to re-invoke zine
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.readLinkAbsolute("/proc/self/exe", &self_exe_buf) catch {
        log.warn("CreateProcessA: failed to read /proc/self/exe", .{});
        if (lpProcessInformation != 0) {
            const pi = @as(*align(1) w32.PROCESS_INFORMATION, @ptrFromInt(lpProcessInformation));
            pi.hProcess = 0x1234;
            pi.hThread = 0x5678;
            pi.dwProcessId = 1337;
            pi.dwThreadId = 1338;
        }
        return 1;
    };

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
            if (arg_start < cmd_line.len) arg_start += 1; // skip closing quote
        } else {
            while (arg_start < cmd_line.len and cmd_line[arg_start] != ' ') : (arg_start += 1) {}
        }
        // Skip whitespace
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
                arg_end += 1; // skip closing quote
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

    // Spawn the child process
    var child = std.process.Child.init(argv_buf[0..argc], std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |err| {
        log.warn("CreateProcessA: spawn failed: {}", .{err});
        return 0; // FALSE
    };

    const proc_handle = allocChildProc(child) orelse {
        // No room, but process is running. Store handle anyway.
        if (lpProcessInformation != 0) {
            const pi = @as(*align(1) w32.PROCESS_INFORMATION, @ptrFromInt(lpProcessInformation));
            pi.hProcess = 0x1234;
            pi.hThread = 0x5678;
            pi.dwProcessId = @intCast(child.id);
            pi.dwThreadId = @intCast(child.id);
        }
        return 1;
    };

    if (lpProcessInformation != 0) {
        const pi = @as(*align(1) w32.PROCESS_INFORMATION, @ptrFromInt(lpProcessInformation));
        pi.hProcess = proc_handle;
        pi.hThread = proc_handle + 0x10000; // fake thread handle
        pi.dwProcessId = @intCast(child.id);
        pi.dwThreadId = @intCast(child.id);
    }

    log.info("Spawned child process (pid={d}, handle=0x{X})", .{ child.id, proc_handle });
    return 1; // TRUE
}

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

pub fn GetEnvironmentStringsA() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetEnvironmentStringsA()\n", .{});
    const msvcrt = @import("../msvcrt.zig");
    var total_len: usize = 1; // Final null
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            total_len += trace.c_span(@intFromPtr(env_ptr)).len + 1;
        }
    }

    const ptr = kernel32_mem.raw_alloc(total_len) orelse return null;
    const buf = @as([*]u8, @ptrCast(ptr));
    var pos: usize = 0;
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.c_span(@intFromPtr(env_ptr));
            @memcpy(buf[pos .. pos + span.len], span);
            pos += span.len;
            buf[pos] = 0;
            pos += 1;
        }
    }
    buf[pos] = 0;
    return ptr;
}

pub fn FreeEnvironmentStringsA(penv: usize) callconv(w32cc.WINAPI) i32 {
    _ = penv;
    return 1;
}

pub fn FreeEnvironmentStringsW(penv: usize) callconv(w32cc.WINAPI) i32 {
    _ = penv;
    return 1;
}

pub fn GetEnvironmentStringsW() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetEnvironmentStringsW()\n", .{});
    const msvcrt = @import("../msvcrt.zig");
    var total_chars: usize = 1; // Final null
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            total_chars += trace.c_span(@intFromPtr(env_ptr)).len + 1;
        }
    }

    const ptr = kernel32_mem.raw_alloc(total_chars * 2) orelse return null;
    const buf = @as([*]u16, @ptrCast(@alignCast(ptr)));
    var pos: usize = 0;
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const span = trace.c_span(@intFromPtr(env_ptr));
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
var next_thread_handle: usize = 0xA0000001;

fn threadWrapper(start_address: usize, parameter: usize) void {
    const func = @as(ThreadStartFn, @ptrFromInt(start_address));
    _ = func(parameter);
}

pub fn CreateThread(lpThreadAttributes: usize, dwStackSize: usize, lpStartAddress: usize, lpParameter: usize, dwCreationFlags: u32, lpThreadId: usize) callconv(w32cc.WINAPI) usize {
    _ = lpThreadAttributes;
    _ = dwStackSize;
    _ = dwCreationFlags;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateThread(start={x}, param={x})\n", .{ lpStartAddress, lpParameter });

    const handle = next_thread_handle;
    next_thread_handle += 1;

    if (lpThreadId != 0) {
        @as(*u32, @ptrFromInt(lpThreadId)).* = @intCast(handle & 0xFFFF);
    }

    if (!platform.spawnThread(threadWrapper, .{ lpStartAddress, lpParameter })) {
        if (trace.enable_tracing) trace.print("KERNEL32: CreateThread spawn failed\n", .{});
        return 0;
    }

    return handle;
}

pub fn stub_ExitThread(dwExitCode: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: ExitThread({d})\n", .{dwExitCode});
}

var cmdline_w_buf: [8192]u8 = undefined;
var cmdline_w_initialized: bool = false;

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

pub fn GetCommandLineW() callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineW\n", .{});
    if (!cmdline_w_initialized) {
        // Get narrow command line and widen it
        const narrow_ptr = GetCommandLineA();
        const narrow = trace.c_span(narrow_ptr);
        const wbuf = @as([*]u16, @ptrCast(@alignCast(&cmdline_w_buf)));
        const copy_len = @min(narrow.len, 4095);
        for (0..copy_len) |i| {
            wbuf[i] = narrow[i];
        }
        wbuf[copy_len] = 0;
        cmdline_w_initialized = true;
    }
    return @intFromPtr(&cmdline_w_buf);
}

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

pub fn stub_OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(w32cc.WINAPI) usize {
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    _ = dwProcessId;
    if (trace.enable_tracing) trace.print("KERNEL32: OpenProcess -> 0 (fail)\n", .{});
    return 0;
}

pub fn stub_SetHandleInformation(hObject: usize, dwMask: u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = hObject;
    _ = dwMask;
    _ = dwFlags;
    return 1;
}

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

// GetPriorityClass: returns priority class of a process
// NORMAL_PRIORITY_CLASS = 0x00000020
pub fn stub_GetPriorityClass(hProcess: usize) callconv(w32cc.WINAPI) u32 {
    _ = hProcess;
    return 0x20; // NORMAL_PRIORITY_CLASS
}

// --- DxWrapper / MSVC CRT stubs ---

pub fn LoadLibraryExW(lpLibFileName: usize, hFile: usize, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryExW(hFile={X}, flags=0x{X})\n", .{ hFile, dwFlags });
    // Delegate to LoadLibraryW which handles wide-to-narrow conversion
    return LoadLibraryW(lpLibFileName);
}

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
        @as(*usize, @ptrFromInt(phModule)).* = handle;
    }
    return if (handle != 0) 1 else 0;
}

pub fn IsDebuggerPresent() callconv(w32cc.WINAPI) i32 {
    return 0; // Not being debugged
}

// --- Additional process stubs ---

pub fn GetCurrentThread() callconv(w32cc.WINAPI) usize {
    return 0xFFFFFFFE; // Pseudo-handle for current thread
}

pub fn stub_FreeLibrary(hLibModule: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: FreeLibrary({x})\n", .{hLibModule});
    return 1; // TRUE = success (no-op, we don't unload)
}

pub fn stub_SetPriorityClass(hProcess: usize, dwPriorityClass: u32) callconv(w32cc.WINAPI) i32 {
    _ = hProcess;
    _ = dwPriorityClass;
    return 1; // TRUE
}

pub fn stub_SetThreadPriority(hThread: usize, nPriority: i32) callconv(w32cc.WINAPI) i32 {
    _ = hThread;
    _ = nPriority;
    return 1; // TRUE
}

pub fn stub_ResumeThread(hThread: usize) callconv(w32cc.WINAPI) u32 {
    _ = hThread;
    return 1; // Previous suspend count = 1
}

pub fn stub_TerminateProcess(hProcess: usize, uExitCode: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: TerminateProcess({x}, {d})\n", .{ hProcess, uExitCode });
    return 1; // TRUE
}

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


pub fn stub_SuspendThread(hThread: usize) callconv(w32cc.WINAPI) u32 {
    _ = hThread;
    return 0; // Previous suspend count = 0
}

pub fn stub_GetThreadPriority(hThread: usize) callconv(w32cc.WINAPI) i32 {
    _ = hThread;
    return 0; // THREAD_PRIORITY_NORMAL
}
