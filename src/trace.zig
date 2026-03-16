const std = @import("std");
const platform = @import("platform.zig");
const log = @import("log.zig");

/// Enables globally visible trace messages.
pub var enable_tracing: bool = false;
/// Enables printing every x86 instruction as it is executed (very verbose).
pub var enable_instructions: bool = false;

var trace_buf: [16384]u8 = undefined;

/// Emits a trace-level message if tracing is enabled.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!enable_tracing) return;
    // Emit through the log module to gain the colored [TRACE] prefix.
    // We format into our own buffer first to strip trailing newlines
    // (log.trace auto-appends one).
    const s = std.fmt.bufPrint(&trace_buf, fmt, args) catch {
        std.fs.File.stderr().writeAll("TRACE BUFFER TOO SMALL OR ERROR\n") catch {};
        return;
    };
    // Strip trailing newline if present (log.trace adds its own)
    const trimmed = std.mem.trimRight(u8, s, "\n");
    log.emit(.trace, "{s}", .{trimmed});
}

// Scan up to 1MB for null terminator to bound reads on potentially unmapped memory.
/// Returns a slice of the guest memory containing a null-terminated C string.
pub fn c_span(ptr: usize) []const u8 {
    if (ptr < 0x10000) return ""; // NULL or near-NULL pointer guard
    const p = @as([*]const u8, @ptrFromInt(addr(ptr)));
    const len = std.mem.indexOfScalar(u8, p[0..1000000], 0) orelse 1000000;
    return p[0..len];
}

/// Returns a slice of the guest memory containing a null-terminated UTF-16 C string.
pub fn c_span_w(ptr: usize) []const u16 {
    if (ptr < 0x10000) return &[_]u16{};
    const p = @as([*]const u16, @ptrFromInt(addr(ptr)));
    const len = std.mem.indexOfScalar(u16, p[0..1000000], 0) orelse 1000000;
    return p[0..len];
}

/// Translate a guest virtual address to a host address.
/// On native x86, this is a no-op (guest addresses ARE host addresses).
/// On WASM, translates through the GuestMemory buffer.
pub fn addr(guest_addr: usize) usize {
    if (comptime !platform.is_native) {
        if (guest_addr == 0) return 0;
        const stub_common = @import("win32/shared.zig");
        if (stub_common.guest_memory) |gmem| {
            const base_addr: usize = gmem.base_addr;
            const base_end = base_addr + gmem.base.len;
            if (guest_addr >= base_addr and guest_addr < base_end) {
                const offset = guest_addr - base_addr;
                return @intFromPtr(gmem.base.ptr) + offset;
            }
        }
    }
    return guest_addr;
}
