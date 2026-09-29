const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");
const reg_config = @import("registry_config.zig");
const runtime = @import("../../runtime.zig");

fn wideEqualsAsciiIgnoreCase(wide: []const u16, ascii: []const u8) bool {
    if (wide.len != ascii.len) return false;
    for (wide, ascii) |wc, ac| {
        if (wc > 0x7f or std.ascii.toLower(@as(u8, @intCast(wc))) != std.ascii.toLower(ac)) return false;
    }
    return true;
}

test "wide registry value names do not alias ASCII through their low byte" {
    const valid = std.unicode.utf8ToUtf16LeStringLiteral("ProcessorNameString");
    const alias = std.unicode.utf8ToUtf16LeStringLiteral("ŐrocessorNameString");
    var size: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0), RegQueryValueExW(CPU_REG_HANDLE, @intFromPtr(valid), 0, 0, 0, @intFromPtr(&size)));
    try std.testing.expectEqual(@as(u32, 36), size);
    try std.testing.expectEqual(@as(u32, 2), RegQueryValueExW(CPU_REG_HANDLE, @intFromPtr(alias), 0, 0, 0, @intFromPtr(&size)));
}

test "wide registry key names preserve non-ASCII code units" {
    const valid = std.unicode.utf8ToUtf16LeStringLiteral("hardware\\description\\system\\centralprocessor\\0");
    const alias = std.unicode.utf8ToUtf16LeStringLiteral("ňardware\\description\\system\\centralprocessor\\0");
    var handle: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0), RegOpenKeyExW(0x80000002, @intFromPtr(valid), 0, 0, @intFromPtr(&handle)));
    try std.testing.expectEqual(CPU_REG_HANDLE, handle);
    try std.testing.expectEqual(@as(u32, 2), RegOpenKeyExW(0x80000002, @intFromPtr(alias), 0, 0, @intFromPtr(&handle)));
    try std.testing.expectEqual(@as(u32, 0), handle);
}

var next_reg_handle: u32 = 0xDE000001;

const CPU_REG_HANDLE: u32 = 0xDE00C000;

/// Initialize the registry from the embedded TOML config.
/// Call once at startup from main.zig / wasm_main.zig.
pub fn initConfig(allocator: std.mem.Allocator) void {
    reg_config.init(allocator);
}

/// Set the current application module so `app:<MODULE>:` overrides apply.
pub fn setAppModule(module_basename: []const u8) void {
    reg_config.setAppModule(module_basename);
}

/// Opens the specified registry key.
/// Implementation status: Stub (always returns ERROR_FILE_NOT_FOUND)
/// Fake registry handle for HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0
pub fn RegOpenKeyExA(hKey: usize, lpSubKey: usize, ulOptions: u32, samDesired: u32, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = ulOptions;
    _ = samDesired;
    const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "";

    // Build full registry path from root key handle + subkey
    const full_path = buildFullPath(hKey, key);

    // Check TOML config first
    if (reg_config.keyExists(full_path)) {
        if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyExA(0x{X}, '{s}') -> OK (config)\n", .{ hKey, key });
        if (phkResult != 0) {
            // phkResult is a guest pointer (usize param — not auto-translated).
            const handle = allocRegHandle();
            @as(*u32, @ptrFromInt(trace.addr(phkResult))).* = handle;
            // Store the path for later RegQueryValueEx lookups
            storeHandlePath(handle, full_path);
        }
        return 0; // ERROR_SUCCESS
    }

    // Legacy: hardcoded CPU registry key
    if (isCpuRegKey(hKey, key)) {
        if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyExA(0x{X}, '{s}') -> OK (CPU)\n", .{ hKey, key });
        if (phkResult != 0) @as(*u32, @ptrFromInt(trace.addr(phkResult))).* = CPU_REG_HANDLE;
        return 0; // ERROR_SUCCESS
    }

    if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyExA(0x{X}, '{s}') -> ERROR_FILE_NOT_FOUND\n", .{ hKey, key });
    if (phkResult != 0) @as(*u32, @ptrFromInt(trace.addr(phkResult))).* = 0;
    return 2; // ERROR_FILE_NOT_FOUND
}

// ---------------------------------------------------------------------------
// Handle → key path mapping (for TOML config lookups)
// ---------------------------------------------------------------------------

const MAX_HANDLES = 256;
const HandleEntry = struct { handle: u32 = 0, path: [512]u8 = undefined, len: u16 = 0 };
var handle_paths: [MAX_HANDLES]HandleEntry = [_]HandleEntry{.{}} ** MAX_HANDLES;
var handle_count: usize = 0;

/// Guards `next_reg_handle` and the handle table below. Any guest thread can
/// open or create a key, and both the counter bump and the append here are
/// read-modify-write: two threads were handed the same handle, and two
/// concurrent appends raced on `handle_count` and overwrote one entry's
/// handle, so a later RegQueryValueEx resolved a path belonging to another
/// key. Each section is a counter bump or a 512-byte copy.
var registry_mutex: runtime.Mutex = .{};

/// Reserves the next key handle. Unique across threads, so a handle paired
/// with its path in a separate section cannot be claimed twice.
fn allocRegHandle() u32 {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const handle = next_reg_handle;
    next_reg_handle +%= 1;
    return handle;
}

fn storeHandlePath(handle: u32, path: []const u8) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (handle_count >= MAX_HANDLES) return;
    var entry = &handle_paths[handle_count];
    entry.handle = handle;
    const copy_len = @min(path.len, entry.path.len);
    @memcpy(entry.path[0..copy_len], path[0..copy_len]);
    entry.len = @intCast(copy_len);
    handle_count += 1;
}

/// Returns a slice into the (static) table, valid after the lock is dropped:
/// appends only ever write past `handle_count`, never over a live entry.
fn lookupHandlePath(handle: u32) ?[]const u8 {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    for (handle_paths[0..handle_count]) |*entry| {
        if (entry.handle == handle) return entry.path[0..entry.len];
    }
    return null;
}

/// Build full registry path from a root key handle + subkey.
/// E.g., (0x80000002, "Software\\Microsoft") → "HKLM\\Software\\Microsoft"
fn buildFullPath(hKey: usize, subkey: []const u8) []const u8 {
    // If hKey is a previously opened handle, prepend its path
    if (lookupHandlePath(@truncate(hKey))) |parent_path| {
        const buf = struct {
            var b: [1024]u8 = undefined;
        };
        if (subkey.len == 0) return parent_path;
        const total = parent_path.len + 1 + subkey.len;
        if (total > buf.b.len) return subkey;
        @memcpy(buf.b[0..parent_path.len], parent_path);
        buf.b[parent_path.len] = '\\';
        @memcpy(buf.b[parent_path.len + 1 ..][0..subkey.len], subkey);
        return buf.b[0..total];
    }

    // Root key handles
    const prefix: []const u8 = switch (hKey) {
        0x80000000 => "HKCR",
        0x80000001 => "HKCU",
        0x80000002 => "HKLM",
        0x80000003 => "HKU",
        0x80000005 => "HKCC",
        else => return subkey,
    };

    const buf = struct {
        var b: [1024]u8 = undefined;
    };
    if (subkey.len == 0) return prefix;
    const total = prefix.len + 1 + subkey.len;
    if (total > buf.b.len) return subkey;
    @memcpy(buf.b[0..prefix.len], prefix);
    buf.b[prefix.len] = '\\';
    @memcpy(buf.b[prefix.len + 1 ..][0..subkey.len], subkey);
    return buf.b[0..total];
}

fn isCpuRegKey(hKey: usize, key: []const u8) bool {
    // HKLM = 0x80000002
    if (hKey == 0x80000002) {
        if (std.ascii.eqlIgnoreCase(key, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0")) return true;
        if (std.ascii.eqlIgnoreCase(key, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor")) return true;
    }
    return false;
}

/// Retrieves the type and data for a specified value name associated with an open registry key.
/// Implementation status: Stub (always returns ERROR_FILE_NOT_FOUND)
pub fn RegQueryValueExA(hKey: usize, lpValueName: ?[*:0]const u8, lpReserved: usize, lpType: ?*u32, lpData: ?[*]u8, lpcbData: ?*u32) callconv(w32cc.WINAPI) u32 {
    _ = lpReserved;
    const name = if (lpValueName) |n| std.mem.span(n) else "";
    const REG_SZ: u32 = 1;
    const REG_DWORD: u32 = 4;

    // Look up by handle → path mapping, then query TOML config
    if (lookupHandlePath(@truncate(hKey))) |key_path| {
        if (reg_config.lookup(key_path, name)) |val| {
            if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueExA('{s}\\{s}') -> config\n", .{ key_path, name });
            return switch (val) {
                .string => |s| writeRegString(lpType, lpData, lpcbData, REG_SZ, s),
                .dword => |d| writeRegDword(lpType, if (lpData) |p| @ptrCast(@alignCast(p)) else null, lpcbData, REG_DWORD, d),
            };
        }
    }

    // Legacy: hardcoded CPU registry values
    if (hKey == CPU_REG_HANDLE) {
        if (std.ascii.eqlIgnoreCase(name, "ProcessorNameString")) {
            return writeRegString(lpType, lpData, lpcbData, REG_SZ, "Intel Pentium III");
        } else if (std.ascii.eqlIgnoreCase(name, "Identifier")) {
            return writeRegString(lpType, lpData, lpcbData, REG_SZ, "x86 Family 6 Model 8 Stepping 3");
        } else if (std.ascii.eqlIgnoreCase(name, "VendorIdentifier")) {
            return writeRegString(lpType, lpData, lpcbData, REG_SZ, "GenuineIntel");
        } else if (std.ascii.eqlIgnoreCase(name, "~MHz")) {
            return writeRegDword(lpType, if (lpData) |p| @ptrCast(@alignCast(p)) else null, lpcbData, REG_DWORD, 1000);
        } else if (std.ascii.eqlIgnoreCase(name, "FeatureSet")) {
            return writeRegDword(lpType, if (lpData) |p| @ptrCast(@alignCast(p)) else null, lpcbData, REG_DWORD, 0x2FFF);
        }
        if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueExA(CPU, '{s}') -> NOT_FOUND\n", .{name});
        return 2;
    }

    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueExA(0x{X}, '{s}') -> ERROR_FILE_NOT_FOUND\n", .{ hKey, name });
    return 2; // ERROR_FILE_NOT_FOUND
}

fn writeRegString(lpType: ?*u32, lpData: ?[*]u8, lpcbData: ?*u32, regType: u32, value: []const u8) u32 {
    const needed: u32 = @intCast(value.len + 1);
    if (lpType) |p| p.* = regType;
    if (lpcbData) |cb| {
        const buf_size = cb.*;
        cb.* = needed;
        if (lpData) |dst| {
            if (buf_size >= needed) {
                @memcpy(dst[0..value.len], value);
                dst[value.len] = 0;
                return 0;
            }
            return 234; // ERROR_MORE_DATA
        }
        return 0; // just querying size
    }
    return 0;
}

fn writeRegDword(lpType: ?*u32, lpData: ?*align(1) u32, lpcbData: ?*u32, regType: u32, value: u32) u32 {
    if (lpType) |p| p.* = regType;
    if (lpcbData) |p| p.* = 4;
    if (lpData) |p| p.* = value;
    return 0;
}

/// Creates the specified registry key.
/// Implementation status: Stub (always returns ERROR_SUCCESS, creates a synthetic handle)
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
        @as(*u32, @ptrFromInt(phkResult)).* = allocRegHandle();
    }
    if (lpdwDisposition != 0) {
        @as(*u32, @ptrFromInt(lpdwDisposition)).* = 1; // REG_CREATED_NEW_KEY (no persisted values)
    }
    return 0; // ERROR_SUCCESS
}

/// Sets the data and type of a specified value under a registry key.
/// Implementation status: Stub (always returns ERROR_SUCCESS)
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

/// Deletes a subkey and its values from the specified platform-specific view of the registry.
/// Implementation status: Stub (always returns ERROR_SUCCESS)
pub fn RegDeleteKeyA(hKey: usize, lpSubKey: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteKeyA\n", .{});
    return 0;
}

/// Removes a named value from the specified registry key.
/// Implementation status: Stub (always returns ERROR_SUCCESS)
pub fn stub_RegDeleteValueA(hKey: usize, lpValueName: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpValueName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteValueA\n", .{});
    return 0;
}

/// Enumerates the subkeys of the specified open registry key.
/// Implementation status: Stub (always returns ERROR_NO_MORE_ITEMS)
pub fn stub_RegEnumKeyExA(hKey: usize, dwIndex: u32, lpName: usize, lpcchName: usize, lpReserved: usize, lpClass: usize, lpcchClass: usize, lpftLastWriteTime: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpReserved;
    _ = lpClass;
    _ = lpcchClass;
    _ = lpftLastWriteTime;
    // For CPU registry key, report one subkey "0" (processor 0)
    if (hKey == CPU_REG_HANDLE and dwIndex == 0) {
        if (lpName != 0 and lpcchName != 0) {
            @as([*]u8, @ptrFromInt(lpName))[0] = '0';
            @as([*]u8, @ptrFromInt(lpName))[1] = 0;
            @as(*u32, @ptrFromInt(lpcchName)).* = 1;
        }
        return 0; // ERROR_SUCCESS
    }
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyExA(idx={d}) -> ERROR_NO_MORE_ITEMS\n", .{dwIndex});
    return 259; // ERROR_NO_MORE_ITEMS
}

/// Enumerates the subkeys of the specified open registry key.
/// Implementation status: Stub (always returns ERROR_NO_MORE_ITEMS)
pub fn RegEnumKeyA(hKey: usize, dwIndex: u32, lpName: usize, cchName: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = cchName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyA -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259; // ERROR_NO_MORE_ITEMS
}

/// Implementation status: Partially implemented
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

/// Implementation status: Stub
pub fn stub_RegFlushKey(hKey: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegFlushKey\n", .{});
    return 0;
}

/// Implementation status: No-op fallback
pub fn stub_RegOpenKeyA(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = phkResult;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegOpenKeyA('{s}') -> ERROR_FILE_NOT_FOUND\n", .{key});
    }
    return 2; // ERROR_FILE_NOT_FOUND
}

/// Implementation status: Partially implemented
pub fn RegQueryValueExW(hKey: usize, lpValueName: usize, lpReserved: usize, lpType: usize, lpData: usize, lpcbData: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpReserved;
    const name = trace.c_span_w(lpValueName);

    if (hKey == CPU_REG_HANDLE) {
        const REG_SZ: u32 = 1;
        const REG_DWORD: u32 = 4;
        if (wideEqualsAsciiIgnoreCase(name, "ProcessorNameString")) {
            return writeRegStringW(lpType, lpData, lpcbData, REG_SZ, "Intel Pentium III");
        } else if (wideEqualsAsciiIgnoreCase(name, "Identifier")) {
            return writeRegStringW(lpType, lpData, lpcbData, REG_SZ, "x86 Family 6 Model 8 Stepping 3");
        } else if (wideEqualsAsciiIgnoreCase(name, "VendorIdentifier")) {
            return writeRegStringW(lpType, lpData, lpcbData, REG_SZ, "GenuineIntel");
        } else if (wideEqualsAsciiIgnoreCase(name, "~MHz")) {
            return writeRegDword(
                if (lpType != 0) @as(?*u32, @ptrFromInt(lpType)) else null,
                if (lpData != 0) @as(?*align(1) u32, @ptrFromInt(lpData)) else null,
                if (lpcbData != 0) @as(?*u32, @ptrFromInt(lpcbData)) else null,
                REG_DWORD,
                1000,
            );
        } else if (wideEqualsAsciiIgnoreCase(name, "FeatureSet")) {
            return writeRegDword(
                if (lpType != 0) @as(?*u32, @ptrFromInt(lpType)) else null,
                if (lpData != 0) @as(?*align(1) u32, @ptrFromInt(lpData)) else null,
                if (lpcbData != 0) @as(?*u32, @ptrFromInt(lpcbData)) else null,
                REG_DWORD,
                0x2FFF,
            );
        }
        if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueExW(CPU, {any}) -> NOT_FOUND\n", .{name});
        return 2;
    }

    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueExW({any}) -> ERROR_FILE_NOT_FOUND\n", .{name});
    return 2; // ERROR_FILE_NOT_FOUND
}

fn writeRegStringW(lpType: usize, lpData: usize, lpcbData: usize, regType: u32, value: []const u8) u32 {
    const needed: u32 = @intCast((value.len + 1) * 2); // UTF-16 bytes
    if (lpType != 0) @as(*u32, @ptrFromInt(lpType)).* = regType;
    if (lpcbData != 0) {
        const buf_size = @as(*u32, @ptrFromInt(lpcbData)).*;
        @as(*u32, @ptrFromInt(lpcbData)).* = needed;
        if (lpData != 0 and buf_size >= needed) {
            const dst = @as([*]u16, @ptrFromInt(lpData));
            for (0..value.len) |i| dst[i] = value[i];
            dst[value.len] = 0;
            return 0;
        }
        if (lpData == 0) return 0;
        return 234; // ERROR_MORE_DATA
    }
    return 0;
}

/// Implementation status: Partially implemented
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

/// Implementation status: Stub
pub fn stub_RegCreateKeyA(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegCreateKeyA('{s}')\n", .{key});
    }
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = allocRegHandle();
    }
    return 0; // ERROR_SUCCESS
}

/// Implementation status: Stub
pub fn stub_RegCreateKeyW(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegCreateKeyW\n", .{});
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = allocRegHandle();
    }
    return 0; // ERROR_SUCCESS
}

/// --- W variant stubs for win2k apps ---
/// Implementation status: Partially implemented
pub fn RegOpenKeyExW(hKey: usize, lpSubKey: usize, ulOptions: u32, samDesired: u32, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = ulOptions;
    _ = samDesired;
    const key = trace.c_span_w(lpSubKey);
    const matches_cpu = isCpuRegKeyWide(hKey, key);

    if (matches_cpu) {
        if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyExW(0x{X}, {any}) -> OK (CPU)\n", .{ hKey, key });
        if (phkResult != 0) @as(*u32, @ptrFromInt(trace.addr(phkResult))).* = CPU_REG_HANDLE;
        return 0;
    }

    if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyExW(0x{X}, {any}) -> ERROR_FILE_NOT_FOUND\n", .{ hKey, key });
    if (phkResult != 0) @as(*u32, @ptrFromInt(trace.addr(phkResult))).* = 0;
    return 2; // ERROR_FILE_NOT_FOUND
}

fn isCpuRegKeyWide(hKey: usize, key: []const u16) bool {
    if (hKey != 0x80000002) return false;
    return wideEqualsAsciiIgnoreCase(key, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0") or
        wideEqualsAsciiIgnoreCase(key, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor");
}

/// Implementation status: Partially implemented
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
        @as(*u32, @ptrFromInt(phkResult)).* = allocRegHandle();
    }
    if (lpdwDisposition != 0) {
        @as(*u32, @ptrFromInt(lpdwDisposition)).* = 1; // REG_CREATED_NEW_KEY (no persisted values)
    }
    return 0;
}

/// Implementation status: No-op fallback
pub fn stub_RegOpenKeyW(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyW -> ERROR_FILE_NOT_FOUND\n", .{});
    if (phkResult != 0) @as(*u32, @ptrFromInt(trace.addr(phkResult))).* = 0;
    return 2;
}

/// Implementation status: Partially implemented
pub fn RegDeleteKeyW(hKey: usize, lpSubKey: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteKeyW\n", .{});
    return 0;
}

/// Implementation status: Stub
pub fn stub_RegDeleteValueW(hKey: usize, lpValueName: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpValueName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteValueW\n", .{});
    return 0;
}

/// Implementation status: Stub
pub fn stub_RegSetValueW(hKey: usize, lpSubKey: usize, dwType: u32, lpData: usize, cbData: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = dwType;
    _ = lpData;
    _ = cbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegSetValueW\n", .{});
    return 0;
}

/// Implementation status: Partially implemented
pub fn RegEnumKeyW(hKey: usize, dwIndex: u32, lpName: usize, cchName: u32) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = cchName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyW -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259;
}

/// Implementation status: No-op fallback
pub fn stub_RegQueryValueW(hKey: usize, lpSubKey: usize, lpData: usize, lpcbData: usize) callconv(w32cc.WINAPI) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = lpData;
    _ = lpcbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueW -> ERROR_FILE_NOT_FOUND\n", .{});
    return 2;
}
