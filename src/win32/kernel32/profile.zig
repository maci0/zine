const std = @import("std");
const trace = @import("../../trace.zig");
const kernel32_mem = @import("mem.zig");
const w32cc = @import("../calling_convention.zig");

// --- INI file support ---

fn readIniValue(lpFileName: usize, lpAppName: usize, lpKeyName: usize) ?[]const u8 {
    if (lpFileName == 0 or lpAppName == 0 or lpKeyName == 0) return null;

    const file_path_raw = trace.c_span(lpFileName);
    const section_name = trace.c_span(lpAppName);
    const key_name = trace.c_span(lpKeyName);

    // Use host_io for path conversion + case-insensitive resolution
    const host_io = @import("../host_io.zig");
    const fd = host_io.open(file_path_raw, 0, 0); // O_RDONLY
    if (fd < 0) return null;
    const file = @import("../host_io.zig").fileFromFd(@intCast(fd));
    defer file.close();

    var content_buf: [16384]u8 = undefined;
    const bytes_read = file.readAll(&content_buf) catch return null;
    const content = content_buf[0..bytes_read];

    // Parse INI: find [section] then key=value
    var in_section = false;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        var line = std.mem.trimRight(u8, raw_line, "\r \t");
        line = std.mem.trimLeft(u8, line, " \t");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                const sec = line[1..end];
                in_section = std.ascii.eqlIgnoreCase(sec, section_name);
            }
            continue;
        }

        if (in_section) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const k = std.mem.trimRight(u8, line[0..eq], " \t");
                if (std.ascii.eqlIgnoreCase(k, key_name)) {
                    return std.mem.trimLeft(u8, line[eq + 1 ..], " \t");
                }
            }
        }
    }
    return null;
}

/// Retrieves a string from the specified section in an initialization file.
/// Implementation status: Partially implemented (supports basic key-value parsing from INI files)
pub fn GetPrivateProfileStringA(lpAppName: usize, lpKeyName: usize, lpDefault: usize, lpReturnedString: usize, nSize: u32, lpFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const app = if (lpAppName != 0) trace.c_span(lpAppName) else "(null)";
        const key = if (lpKeyName != 0) trace.c_span(lpKeyName) else "(null)";
        const fname = if (lpFileName != 0) trace.c_span(lpFileName) else "(null)";
        trace.print("KERNEL32: GetPrivateProfileStringA('{s}', '{s}', file='{s}')\n", .{ app, key, fname });
    }
    if (lpReturnedString == 0 or nSize == 0) return 0;
    const buf = @as([*]u8, @ptrFromInt(lpReturnedString));

    if (readIniValue(lpFileName, lpAppName, lpKeyName)) |value| {
        const copy_len = @min(value.len, @as(usize, nSize) - 1);
        @memcpy(buf[0..copy_len], value[0..copy_len]);
        buf[copy_len] = 0;
        if (trace.enable_tracing) trace.print("  -> '{s}'\n", .{buf[0..copy_len]});
        return @intCast(copy_len);
    }

    if (lpDefault != 0) {
        const def = trace.c_span(lpDefault);
        const copy_len = @min(def.len, @as(usize, nSize) - 1);
        @memcpy(buf[0..copy_len], def[0..copy_len]);
        buf[copy_len] = 0;
        return @intCast(copy_len);
    }
    buf[0] = 0;
    return 0;
}

/// Retrieves an integer associated with a key in the specified section of an initialization file.
/// Implementation status: Partially implemented (supports basic key-value parsing from INI files)
pub fn GetPrivateProfileIntA(lpAppName: usize, lpKeyName: usize, nDefault: i32, lpFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const app = if (lpAppName != 0) trace.c_span(lpAppName) else "(null)";
        const key = if (lpKeyName != 0) trace.c_span(lpKeyName) else "(null)";
        trace.print("KERNEL32: GetPrivateProfileIntA('{s}', '{s}', default={d})\n", .{ app, key, nDefault });
    }
    if (readIniValue(lpFileName, lpAppName, lpKeyName)) |value| {
        const result = std.fmt.parseInt(i32, value, 10) catch return @bitCast(nDefault);
        if (trace.enable_tracing) trace.print("  -> {d}\n", .{result});
        return @bitCast(result);
    }
    return @bitCast(nDefault);
}

/// Retrieves all keys and values for the specified section of an INI file.
/// Returns key=value pairs as null-terminated strings, followed by an extra null.
pub fn GetPrivateProfileSectionA(lpAppName: usize, lpReturnedString: usize, nSize: u32, lpFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (lpReturnedString == 0 or nSize < 2) return 0;

    const buf = @as([*]u8, @ptrFromInt(lpReturnedString));
    buf[0] = 0;
    buf[1] = 0; // Double-null terminator for empty result

    if (lpAppName == 0 or lpFileName == 0) return 0;

    const section_name = trace.c_span(lpAppName);
    const file_path_raw = trace.c_span(lpFileName);

    if (trace.enable_tracing) trace.print("KERNEL32: GetPrivateProfileSectionA('{s}', buf=0x{X}, size={d}, file='{s}')\n", .{ section_name, lpReturnedString, nSize, file_path_raw });

    const host_io = @import("../host_io.zig");
    const fd = host_io.open(file_path_raw, 0, 0);
    if (fd < 0) return 0;
    const file = host_io.fileFromFd(@intCast(fd));
    defer file.close();

    var content_buf: [16384]u8 = undefined;
    const bytes_read = file.readAll(&content_buf) catch return 0;
    const content = content_buf[0..bytes_read];

    var out_pos: u32 = 0;
    const max_pos = nSize - 2; // Reserve space for double-null
    var in_section = false;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        var line = std.mem.trimRight(u8, raw_line, "\r \t");
        line = std.mem.trimLeft(u8, line, " \t");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (in_section) break; // End of our section
            if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                const sec = line[1..end];
                in_section = std.ascii.eqlIgnoreCase(sec, section_name);
            }
            continue;
        }

        if (in_section and line.len > 0) {
            const needed: u32 = @intCast(line.len + 1); // line + null terminator
            if (out_pos + needed > max_pos) break;
            @memcpy(buf[out_pos .. out_pos + @as(u32, @intCast(line.len))], line);
            out_pos += @intCast(line.len);
            buf[out_pos] = 0; // null-terminate this entry
            out_pos += 1;
        }
    }
    buf[out_pos] = 0; // Final null terminator (double-null)

    if (trace.enable_tracing) trace.print("  -> {d} bytes\n", .{out_pos});
    return out_pos;
}

/// Copies a string into the specified section of an initialization file.
/// Implementation status: No-op fallback
pub fn stub_WritePrivateProfileStringA(lpAppName: usize, lpKeyName: usize, lpString: usize, lpFileName: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpAppName;
    _ = lpKeyName;
    _ = lpString;
    _ = lpFileName;
    return 1; // Success
}

/// Copies a string into the specified section of an initialization file (Unicode version).
/// Implementation status: No-op fallback
pub fn stub_WritePrivateProfileStringW(lpAppName: usize, lpKeyName: usize, lpString: usize, lpFileName: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpAppName;
    _ = lpKeyName;
    _ = lpString;
    _ = lpFileName;
    if (trace.enable_tracing) trace.print("KERNEL32: WritePrivateProfileStringW\n", .{});
    return 1; // Success
}

fn wideToNarrow(wide_ptr: usize, buf: []u8) []const u8 {
    if (wide_ptr == 0) return "";
    const wide = @as([*]const u16, @ptrFromInt(wide_ptr));
    var i: usize = 0;
    while (i < buf.len - 1 and wide[i] != 0) : (i += 1) {
        buf[i] = @intCast(wide[i] & 0xFF);
    }
    buf[i] = 0;
    return buf[0..i];
}

/// Retrieves a string from the specified section in an initialization file (Unicode version).
/// Implementation status: Partially implemented (wraps the ANSI version)
pub fn GetPrivateProfileStringW(lpAppName: usize, lpKeyName: usize, lpDefault: usize, lpReturnedString: usize, nSize: u32, lpFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        var app_buf: [256]u8 = undefined;
        var key_buf: [256]u8 = undefined;
        const app = wideToNarrow(lpAppName, &app_buf);
        const key = wideToNarrow(lpKeyName, &key_buf);
        trace.print("KERNEL32: GetPrivateProfileStringW('{s}', '{s}')\n", .{ app, key });
    }
    if (lpReturnedString == 0 or nSize == 0) return 0;

    const out = @as([*]u16, @ptrFromInt(lpReturnedString));

    var app_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;
    var fname_buf: [512]u8 = undefined;
    _ = wideToNarrow(lpAppName, &app_buf);
    _ = wideToNarrow(lpKeyName, &key_buf);
    _ = wideToNarrow(lpFileName, &fname_buf);

    var narrow_result: [1024]u8 = undefined;
    const a_result = GetPrivateProfileStringA(
        @intFromPtr(&app_buf),
        @intFromPtr(&key_buf),
        0, // no default for A version, handle W default below
        @intFromPtr(&narrow_result),
        @min(nSize, 1024),
        @intFromPtr(&fname_buf),
    );

    if (a_result > 0) {
        const len = @min(@as(usize, a_result), @as(usize, nSize) - 1);
        for (0..len) |i| out[i] = narrow_result[i];
        out[len] = 0;
        return @intCast(len);
    }

    if (lpDefault != 0) {
        const def = @as([*]const u16, @ptrFromInt(lpDefault));
        var i: usize = 0;
        while (i < nSize - 1 and def[i] != 0) : (i += 1) {
            out[i] = def[i];
        }
        out[i] = 0;
        return @intCast(i);
    }

    out[0] = 0;
    return 0;
}

/// Retrieves a string from the specified section in the Win.ini file.
/// Implementation status: Stub (returns the default value)
pub fn stub_GetProfileStringA(lpAppName: usize, lpKeyName: usize, lpDefault: usize, lpReturnedString: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    if (lpReturnedString == 0 or nSize == 0) return 0;
    const buf = @as([*]u8, @ptrFromInt(lpReturnedString));
    if (lpDefault != 0) {
        const def = trace.c_span(lpDefault);
        const copy_len = @min(def.len, @as(usize, nSize) - 1);
        @memcpy(buf[0..copy_len], def[0..copy_len]);
        buf[copy_len] = 0;
        if (trace.enable_tracing) {
            const app = if (lpAppName != 0) trace.c_span(lpAppName) else "(null)";
            const key = if (lpKeyName != 0) trace.c_span(lpKeyName) else "(null)";
            trace.print("KERNEL32: GetProfileStringA('{s}', '{s}') -> default\n", .{ app, key });
        }
        return @intCast(copy_len);
    }
    buf[0] = 0;
    return 0;
}
