const trace = @import("../../trace.zig");
const kernel32 = @import("../kernel32.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn GetModuleFileNameA(hModule: usize, lpFilename: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleFileNameA(hModule={x})\n", .{hModule});
    if (lpFilename == 0 or nSize == 0) return 0;
    const buf = @as([*]u8, @ptrFromInt(lpFilename));

    // For the main module (hModule == 0 or matches main_module_handle), return real exe path
    if (hModule == 0 or hModule == kernel32.main_module_handle) {
        // Use actual exe name from argv[0] if available
        const process_mod = @import("process.zig");
        const result = process_mod.GetModuleFileNameA(hModule, lpFilename, nSize);
        if (result > 0) return result;

        // Fallback to exe dir + generic name
        const dir = kernel32.main_exe_dir[0..kernel32.main_exe_dir_len];
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
                const dir = kernel32.main_exe_dir[0..kernel32.main_exe_dir_len];
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
    if (kernel32.main_exe_dir_len > 0) {
        const dir = kernel32.main_exe_dir[0..kernel32.main_exe_dir_len];
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

pub fn stub_OpenFile(lpFileName: usize, lpReOpenBuff: usize, uStyle: u32) callconv(w32cc.WINAPI) i32 {
    _ = lpReOpenBuff;
    _ = uStyle;
    if (trace.enable_tracing) {
        const name = if (lpFileName != 0) trace.c_span(lpFileName) else "(null)";
        trace.print("KERNEL32: OpenFile('{s}')\n", .{name});
    }
    return -1; // HFILE_ERROR
}
