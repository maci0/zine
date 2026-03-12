const std = @import("std");
const platform = @import("platform.zig");
const log = @import("log.zig");

pub var enable_tracing: bool = false;
pub var enable_instructions: bool = false;

var trace_buf: [16384]u8 = undefined;

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
pub fn c_span(ptr: usize) []const u8 {
    if (ptr < 0x10000) return ""; // NULL or near-NULL pointer guard
    const p = @as([*]const u8, @ptrFromInt(ptr));
    const len = std.mem.indexOfScalar(u8, p[0..1000000], 0) orelse 1000000;
    return p[0..len];
}

pub fn c_span_w(ptr: usize) []const u16 {
    if (ptr < 0x10000) return &[_]u16{};
    const p = @as([*]const u16, @ptrFromInt(ptr));
    const len = std.mem.indexOfScalar(u16, p[0..1000000], 0) orelse 1000000;
    return p[0..len];
}
