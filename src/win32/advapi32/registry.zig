const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

var next_reg_handle: u32 = 0xDE000001;

pub fn RegOpenKeyExA(hKey: usize, lpSubKey: usize, ulOptions: u32, samDesired: u32, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = ulOptions;
    _ = samDesired;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegOpenKeyExA(0x{X}, '{s}') -> ERROR_FILE_NOT_FOUND\n", .{ hKey, key });
    }
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = 0;
    }
    return 2; // ERROR_FILE_NOT_FOUND
}

pub fn RegQueryValueExA(hKey: usize, lpValueName: usize, lpReserved: usize, lpType: usize, lpData: usize, lpcbData: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpReserved;
    _ = lpType;
    _ = lpData;
    _ = lpcbData;
    if (trace.enable_tracing) {
        const name = if (lpValueName != 0) trace.c_span(lpValueName) else "(null)";
        trace.print("ADVAPI32: RegQueryValueExA('{s}') -> ERROR_FILE_NOT_FOUND\n", .{name});
    }
    return 2; // ERROR_FILE_NOT_FOUND
}

pub fn RegCreateKeyExA(hKey: usize, lpSubKey: usize, reserved: u32, lpClass: usize, dwOptions: u32, samDesired: u32, lpSecurityAttributes: usize, phkResult: usize, lpdwDisposition: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = reserved;
    _ = lpClass;
    _ = dwOptions;
    _ = samDesired;
    _ = lpSecurityAttributes;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegCreateKeyExA('{s}')\n", .{key});
    }
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    if (lpdwDisposition != 0) {
        @as(*u32, @ptrFromInt(lpdwDisposition)).* = 1; // REG_CREATED_NEW_KEY (no persisted values)
    }
    return 0; // ERROR_SUCCESS
}

pub fn RegSetValueExA(hKey: usize, lpValueName: usize, reserved: u32, dwType: u32, lpData: usize, cbData: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = reserved;
    _ = dwType;
    _ = lpData;
    _ = cbData;
    if (trace.enable_tracing) {
        const name = if (lpValueName != 0) trace.c_span(lpValueName) else "(null)";
        trace.print("ADVAPI32: RegSetValueExA('{s}')\n", .{name});
    }
    return 0;
}

pub fn RegDeleteKeyA(hKey: usize, lpSubKey: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteKeyA\n", .{});
    return 0;
}

pub fn stub_RegDeleteValueA(hKey: usize, lpValueName: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpValueName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteValueA\n", .{});
    return 0;
}

pub fn stub_RegEnumKeyExA(hKey: usize, dwIndex: u32, lpName: usize, lpcchName: usize, lpReserved: usize, lpClass: usize, lpcchClass: usize, lpftLastWriteTime: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = lpcchName;
    _ = lpReserved;
    _ = lpClass;
    _ = lpcchClass;
    _ = lpftLastWriteTime;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyExA -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259; // ERROR_NO_MORE_ITEMS
}

pub fn RegEnumKeyA(hKey: usize, dwIndex: u32, lpName: usize, cchName: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = cchName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyA -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259;
}

pub fn RegQueryInfoKeyA(hKey: usize, lpClass: usize, lpcchClass: usize, lpReserved: usize, lpcSubKeys: usize, lpcbMaxSubKeyLen: usize, lpcbMaxClassLen: usize, lpcValues: usize, lpcbMaxValueNameLen: usize, lpcbMaxValueLen: usize, lpcbSecurityDescriptor: usize, lpftLastWriteTime: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpClass;
    _ = lpcchClass;
    _ = lpReserved;
    _ = lpftLastWriteTime;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryInfoKeyA\n", .{});
    // Fill counts with 0
    if (lpcSubKeys != 0) @as(*u32, @ptrFromInt(lpcSubKeys)).* = 0;
    if (lpcbMaxSubKeyLen != 0) @as(*u32, @ptrFromInt(lpcbMaxSubKeyLen)).* = 0;
    if (lpcbMaxClassLen != 0) @as(*u32, @ptrFromInt(lpcbMaxClassLen)).* = 0;
    if (lpcValues != 0) @as(*u32, @ptrFromInt(lpcValues)).* = 0;
    if (lpcbMaxValueNameLen != 0) @as(*u32, @ptrFromInt(lpcbMaxValueNameLen)).* = 0;
    if (lpcbMaxValueLen != 0) @as(*u32, @ptrFromInt(lpcbMaxValueLen)).* = 0;
    if (lpcbSecurityDescriptor != 0) @as(*u32, @ptrFromInt(lpcbSecurityDescriptor)).* = 0;
    return 0;
}

pub fn stub_RegFlushKey(hKey: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegFlushKey\n", .{});
    return 0;
}

pub fn stub_RegOpenKeyA(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = phkResult;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegOpenKeyA('{s}') -> ERROR_FILE_NOT_FOUND\n", .{key});
    }
    return 2; // ERROR_FILE_NOT_FOUND
}

pub fn RegQueryValueExW(hKey: usize, lpValueName: usize, lpReserved: usize, lpType: usize, lpData: usize, lpcbData: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpValueName;
    _ = lpReserved;
    _ = lpType;
    _ = lpData;
    _ = lpcbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueExW -> ERROR_FILE_NOT_FOUND\n", .{});
    return 2; // ERROR_FILE_NOT_FOUND
}

pub fn RegSetValueExW(hKey: usize, lpValueName: usize, reserved: u32, dwType: u32, lpData: usize, cbData: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpValueName;
    _ = reserved;
    _ = dwType;
    _ = lpData;
    _ = cbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegSetValueExW\n", .{});
    return 0;
}

pub fn stub_RegCreateKeyA(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegCreateKeyA('{s}')\n", .{key});
    }
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    return 0; // ERROR_SUCCESS
}

pub fn stub_RegCreateKeyW(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegCreateKeyW\n", .{});
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    return 0; // ERROR_SUCCESS
}

// --- W variant stubs for win2k apps ---

pub fn RegOpenKeyExW(hKey: usize, lpSubKey: usize, ulOptions: u32, samDesired: u32, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = ulOptions;
    _ = samDesired;
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyExW -> ERROR_FILE_NOT_FOUND\n", .{});
    if (phkResult != 0) @as(*u32, @ptrFromInt(phkResult)).* = 0;
    return 2; // ERROR_FILE_NOT_FOUND
}

pub fn RegCreateKeyExW(hKey: usize, lpSubKey: usize, reserved: u32, lpClass: usize, dwOptions: u32, samDesired: u32, lpSecurityAttributes: usize, phkResult: usize, lpdwDisposition: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = reserved;
    _ = lpClass;
    _ = dwOptions;
    _ = samDesired;
    _ = lpSecurityAttributes;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegCreateKeyExW\n", .{});
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    if (lpdwDisposition != 0) {
        @as(*u32, @ptrFromInt(lpdwDisposition)).* = 1; // REG_CREATED_NEW_KEY (no persisted values)
    }
    return 0;
}

pub fn stub_RegOpenKeyW(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyW -> ERROR_FILE_NOT_FOUND\n", .{});
    if (phkResult != 0) @as(*u32, @ptrFromInt(phkResult)).* = 0;
    return 2;
}

pub fn RegDeleteKeyW(hKey: usize, lpSubKey: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteKeyW\n", .{});
    return 0;
}

pub fn stub_RegDeleteValueW(hKey: usize, lpValueName: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpValueName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteValueW\n", .{});
    return 0;
}

pub fn stub_RegSetValueW(hKey: usize, lpSubKey: usize, dwType: u32, lpData: usize, cbData: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = dwType;
    _ = lpData;
    _ = cbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegSetValueW\n", .{});
    return 0;
}

pub fn RegEnumKeyW(hKey: usize, dwIndex: u32, lpName: usize, cchName: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = cchName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyW -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259;
}

pub fn stub_RegQueryValueW(hKey: usize, lpSubKey: usize, lpData: usize, lpcbData: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = lpData;
    _ = lpcbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueW -> ERROR_FILE_NOT_FOUND\n", .{});
    return 2;
}
