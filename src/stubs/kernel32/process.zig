const std = @import("std");
const env = @import("../../loader/env.zig");
const trace = @import("../../trace.zig");
const kernel32 = @import("../kernel32.zig");
const loader = @import("../../loader/loader.zig");
const kernel32_mem = @import("mem.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../win32_constants.zig");

const EXCEPTION_POINTERS = extern struct {
    ExceptionRecord: *const @import("../../teb.zig").EXCEPTION_RECORD,
    ContextRecord: *const @import("../../teb.zig").CONTEXT,
};

pub fn stub_UnhandledExceptionFilter(ExceptionInfo: usize) callconv(.winapi) u32 {
    if (ExceptionInfo != 0) {
        const ptrs = @as(*EXCEPTION_POINTERS, @ptrFromInt(ExceptionInfo));
        const code = ptrs.ExceptionRecord.ExceptionCode;
        const addr = ptrs.ExceptionRecord.ExceptionAddress;

        std.log.err("UnhandledExceptionFilter caught code 0x{X} at 0x{X}", .{code, addr});

        const renderer = @import("../../gui/renderer.zig");
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "This program has performed an illegal operation and will be shut down.\\n\\nException Code: 0x{X}\\nFault Address: 0x{X}", .{code, addr}) catch "Error";
        renderer.showMessageBox("Application Error", text);
    }

    // Give WebSocket time to flush
    std.Thread.sleep(100 * std.time.ns_per_ms);
    std.process.exit(1);
    return 1; // EXCEPTION_EXECUTE_HANDLER (though we never reach here)
}

pub fn stub_ExitProcess(exitCode: u32) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("KERNEL32: ExitProcess({d})\n", .{exitCode});
    std.process.exit(@intCast(exitCode & 0xFF));
}

pub fn stub_SetConsoleCtrlHandler(handler: *const anyopaque, add: i32) callconv(.winapi) i32 {
    _ = handler;
    _ = add;
    return 1;
}

pub fn stub_DisableThreadLibraryCalls(hLibModule: ?*anyopaque) callconv(.winapi) i32 {
    _ = hLibModule;
    return 1;
}

pub fn stub_LoadLibraryA(lpFileName_ptr: usize) callconv(.winapi) usize {
    if (lpFileName_ptr == 0) return 0;
    const name = trace.c_span(lpFileName_ptr);

    if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA('{s}')\n", .{name});

    if (kernel32.global_env) |genv| {
        if (genv.registry.loadModule(name)) |mod| {
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
                    const DllMain = @as(*const fn (usize, u32, usize) callconv(.winapi) i32, @ptrFromInt(entry_point_addr));
                    if (trace.enable_tracing) trace.print("KERNEL32: Executing DllMain for {s} at {x}\n", .{ name, entry_point_addr });
                    const ret = DllMain(@intFromPtr(mod.mapped_memory.ptr), 1, 0);
                    if (trace.enable_tracing) trace.print("KERNEL32: DllMain returned {d}\n", .{ret});
                }
            }

            return @intFromPtr(mod.mapped_memory.ptr);
        } else |err| {
            // Try full name first
            if (genv.getBuiltinHandle(name)) |handle| {
                if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA found builtin '{s}', returning handle {x}\n", .{ name, handle });
                return handle;
            }

            // Strip path (e.g. "Z:\WINDOWS\SYSTEM32\advapi32.dll" -> "advapi32.dll")
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

            if (trace.enable_tracing) trace.print("KERNEL32: LoadLibraryA failed with error: {}\n", .{err});
            return 0;
        }
    }
    return 0;
}

pub fn stub_GetProcAddress(hModule: usize, lpProcName_ptr: usize) callconv(.winapi) usize {
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
                    if (builtin.exports.get(name)) |addr| {
                        if (trace.enable_tracing) trace.print("KERNEL32: GetProcAddress('{s}') -> {x} (from builtin)\n", .{ name, addr });
                        return addr;
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

pub fn stub_GetStartupInfoA(lpStartupInfo_ptr: usize) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetStartupInfoA({x})\n", .{lpStartupInfo_ptr});
    if (lpStartupInfo_ptr == 0) return;
    const si = @as(*w32.STARTUPINFOA, @ptrFromInt(lpStartupInfo_ptr));
    si.* = .{}; // zero all, cb defaults to 68
}

pub fn stub_GetModuleHandleA(lpModuleName_ptr: usize) callconv(.winapi) usize {
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
            return handle;
        }
    }
    return 0;
}

var cmdline_buf: [4096]u8 = undefined;
var cmdline_initialized: bool = false;

pub fn stub_GetCommandLineA() callconv(.winapi) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineA\n", .{});

    if (!cmdline_initialized) {
        if (kernel32.global_env) |genv| {
            _ = genv;
            var i: usize = 0;
            var pos: usize = 0;
            const msvcrt = @import("../msvcrt.zig");
            if (msvcrt.global_argc > 0) {
                // Hardcode the executable name to avoid path parsing bugs in legacy apps
                const exe_stub = "C:\\program.exe";
                @memcpy(cmdline_buf[0..exe_stub.len], exe_stub);
                pos = exe_stub.len;

                if (msvcrt.global_argc > 1) {
                    cmdline_buf[pos] = ' ';
                    pos += 1;
                }

                i = 1; // Skip actual argv[0]
                while (i < msvcrt.global_argc) : (i += 1) {
                    if (msvcrt.global_argv[i]) |arg_ptr| {
                        const arg = trace.c_span(@intFromPtr(arg_ptr));

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
                            cmdline_buf[pos] = '"';
                            pos += 1;
                        }

                        const copy_len = @min(write_arg.len, 4094 - pos);
                        @memcpy(cmdline_buf[pos .. pos + copy_len], write_arg[0..copy_len]);
                        pos += copy_len;

                        if (needs_quotes and pos < 4094) {
                            cmdline_buf[pos] = '"';
                            pos += 1;
                        }

                        if (i < msvcrt.global_argc - 1 and pos < 4094) {
                            cmdline_buf[pos] = ' ';
                            pos += 1;
                        }
                    }
                }            } else {
                const dummy = "C:\\program.exe";
                @memcpy(cmdline_buf[0..dummy.len], dummy);
                pos = dummy.len;
            }
            cmdline_buf[pos] = 0;
        }
        cmdline_initialized = true;
    }

    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineA -> '{s}'\n", .{trace.c_span(@intFromPtr(@as([*:0]const u8, @ptrCast(&cmdline_buf))))});
    return @intFromPtr(&cmdline_buf);
}

pub fn stub_GetCurrentProcess() callconv(.winapi) usize {
    return 0xFFFFFFFF; // Pseudo-handle for current process
}

pub fn stub_GetCurrentProcessId() callconv(.winapi) u32 {
    return platform.getProcessId();
}

pub fn stub_GetCurrentThreadId() callconv(.winapi) u32 {
    return @intCast(std.Thread.getCurrentId());
}

pub fn stub_SetEnvironmentVariableA(lpName: usize, lpValue: usize) callconv(.winapi) i32 {
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

pub fn stub_GetEnvironmentVariableA(lpName: usize, lpBuffer: usize, nSize: u32) callconv(.winapi) u32 {
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

pub fn stub_GetModuleFileNameA(hModule: usize, lpFilename: usize, nSize: u32) callconv(.winapi) u32 {
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

pub fn stub_CreateProcessA(
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
) callconv(.winapi) i32 {
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

    if (lpProcessInformation != 0) {
        const pi = @as(*w32.PROCESS_INFORMATION, @ptrFromInt(lpProcessInformation));
        pi.hProcess = 0x1234;
        pi.hThread = 0x5678;
        pi.dwProcessId = 1337;
        pi.dwThreadId = 1338;
    }

    return 1; // TRUE
}

pub fn stub_GetEnvironmentStringsA() callconv(.winapi) ?*anyopaque {
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

pub fn stub_FreeEnvironmentStringsA(penv: usize) callconv(.winapi) i32 {
    _ = penv;
    return 1;
}

pub fn stub_FreeEnvironmentStringsW(penv: usize) callconv(.winapi) i32 {
    _ = penv;
    return 1;
}

pub fn stub_GetEnvironmentStringsW() callconv(.winapi) ?*anyopaque {
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

const ThreadStartFn = *const fn (usize) callconv(.winapi) u32;
var next_thread_handle: usize = 0xA0000001;

fn threadWrapper(start_address: usize, parameter: usize) void {
    const func = @as(ThreadStartFn, @ptrFromInt(start_address));
    _ = func(parameter);
}

pub fn stub_CreateThread(lpThreadAttributes: usize, dwStackSize: usize, lpStartAddress: usize, lpParameter: usize, dwCreationFlags: u32, lpThreadId: usize) callconv(.winapi) usize {
    _ = lpThreadAttributes;
    _ = dwStackSize;
    _ = dwCreationFlags;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateThread(start={x}, param={x})\n", .{ lpStartAddress, lpParameter });

    const handle = next_thread_handle;
    next_thread_handle += 1;

    if (lpThreadId != 0) {
        @as(*u32, @ptrFromInt(lpThreadId)).* = @intCast(handle & 0xFFFF);
    }

    if (comptime platform.is_wasm) {
        // Threading not supported on WASM yet
        if (trace.enable_tracing) trace.print("KERNEL32: CreateThread not supported on WASM\n", .{});
        return 0;
    } else {
        _ = std.Thread.spawn(.{}, threadWrapper, .{ lpStartAddress, lpParameter }) catch |err| {
            if (trace.enable_tracing) trace.print("KERNEL32: CreateThread spawn failed: {}\n", .{err});
            return 0;
        };
    }

    return handle;
}

pub fn stub_ExitThread(dwExitCode: u32) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("KERNEL32: ExitThread({d})\n", .{dwExitCode});
}

var cmdline_w_buf: [8192]u8 = undefined;
var cmdline_w_initialized: bool = false;

pub fn stub_GetModuleFileNameW(hModule: usize, lpFilename: usize, nSize: u32) callconv(.winapi) u32 {
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

pub fn stub_GetCommandLineW() callconv(.winapi) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCommandLineW\n", .{});
    if (!cmdline_w_initialized) {
        // Get narrow command line and widen it
        const narrow_ptr = stub_GetCommandLineA();
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

pub fn stub_LoadLibraryW(lpFileName_ptr: usize) callconv(.winapi) usize {
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
    return stub_LoadLibraryA(@intFromPtr(&narrow_buf));
}

pub fn stub_FindFirstFileW(lpFileName: usize, lpFindFileData: usize) callconv(.winapi) usize {
    if (lpFileName == 0 or lpFindFileData == 0) return 0xFFFFFFFF;

    // Convert wide filename to narrow
    const wstr = trace.c_span_w(lpFileName);
    var narrow_buf: [1024]u8 = undefined;
    const copy_len = @min(wstr.len, 1023);
    for (0..copy_len) |i| {
        narrow_buf[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow_buf[copy_len] = 0;

    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileW('{s}')\\n", .{narrow_buf[0..copy_len]});

    // Use a temporary narrow find data buffer
    const file_zig = @import("file.zig");
    var narrow_find_data: [318]u8 = undefined; // sizeof WIN32_FIND_DATAA = 318
    @memset(&narrow_find_data, 0);
    const result = file_zig.stub_FindFirstFileA(@intFromPtr(&narrow_buf), @intFromPtr(&narrow_find_data));

    if (result == 0xFFFFFFFF) {
        if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileW -> INVALID_HANDLE_VALUE\n", .{});
        return 0xFFFFFFFF;
    }

    // Copy narrow find data to wide find data
    // WIN32_FIND_DATAW: same layout but cFileName is [260]u16 and cAlternateFileName is [14]u16
    const out = @as([*]u8, @ptrFromInt(lpFindFileData));
    // Copy the fixed fields (dwFileAttributes through dwReserved1 = 44 bytes)
    @memcpy(out[0..44], narrow_find_data[0..44]);

    // Widen cFileName (260 bytes narrow -> 260 u16 = 520 bytes wide)
    const narrow_name = narrow_find_data[44..304]; // 260 bytes
    const wide_name = @as([*]u16, @ptrCast(@alignCast(out + 44)));
    for (0..260) |i| {
        wide_name[i] = narrow_name[i];
    }

    // Widen cAlternateFileName (14 bytes narrow -> 14 u16 = 28 bytes wide)
    const narrow_alt = narrow_find_data[304..318];
    const wide_alt = @as([*]u16, @ptrCast(@alignCast(out + 44 + 520)));
    for (0..14) |i| {
        wide_alt[i] = narrow_alt[i];
    }

    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileW -> {d}\n", .{result});
    return result;
}

pub fn stub_FindNextFileW(hFindFile: usize, lpFindFileData: usize) callconv(.winapi) i32 {
    _ = hFindFile;
    _ = lpFindFileData;
    return 0; // No more files
}

pub fn stub_OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) usize {
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    _ = dwProcessId;
    if (trace.enable_tracing) trace.print("KERNEL32: OpenProcess -> 0 (fail)\n", .{});
    return 0;
}

pub fn stub_SetHandleInformation(hObject: usize, dwMask: u32, dwFlags: u32) callconv(.winapi) i32 {
    _ = hObject;
    _ = dwMask;
    _ = dwFlags;
    return 1;
}

pub fn stub_CreatePipe(hReadPipe: usize, hWritePipe: usize, lpPipeAttributes: usize, nSize: u32) callconv(.winapi) i32 {
    _ = hReadPipe;
    _ = hWritePipe;
    _ = lpPipeAttributes;
    _ = nSize;
    return 0; // fail
}

// GetPriorityClass: returns priority class of a process
// NORMAL_PRIORITY_CLASS = 0x00000020
pub fn stub_GetPriorityClass(hProcess: usize) callconv(.winapi) u32 {
    _ = hProcess;
    return 0x20; // NORMAL_PRIORITY_CLASS
}
