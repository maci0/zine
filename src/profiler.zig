//! Lightweight profiling infrastructure for the x86 interpreter and JIT.
//!
//! Three counters, all behind a runtime `enabled` flag (zero overhead when off):
//!
//!   1. EIP Heat Map   — per-4KB-page instruction execution counts
//!   2. Opcode Table   — per-opcode execution frequency
//!   3. Stub Counters  — per-thunk-ID call counts
//!
//! Enable via CLI (--profile) or env (ZINE_PROFILE).
//! Reports top-N entries to stderr on dump().

const std = @import("std");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");
const log = @import("log.zig");

pub var enabled: bool = false;

// -----------------------------------------------------------------------
// Monotonic elapsed time
// -----------------------------------------------------------------------

var start_ns: ?i128 = null;

/// Record the profiling start time. Called when profiling begins.
pub fn start() void {
    if (comptime builtin.target.cpu.arch.isWasm()) return;
    start_ns = runtime.monoNanoTimestamp();
}

fn getElapsedMs() u64 {
    if (comptime builtin.target.cpu.arch.isWasm()) return 0;
    const s = start_ns orelse return 0;
    const now = runtime.monoNanoTimestamp();
    const delta = now - s;
    if (delta < 0) return 0;
    return @intCast(@as(u128, @intCast(delta)) / 1_000_000);
}

// -----------------------------------------------------------------------
// 1. EIP Heat Map — 4KB page granularity over the 32-bit address space
// -----------------------------------------------------------------------
// Only the bottom 1 GB (pages 0 – 262143) is tracked to keep the array
// size reasonable (~2 MB).  Guest code typically lives at 0x00400000+.
const PAGE_SHIFT = 12; // 4 KB pages
const MAX_PAGES = 256 * 1024; // 1 GB coverage → 256K pages

var eip_pages: [MAX_PAGES]u64 = .{0} ** MAX_PAGES;
var total_insns: u64 = 0;

/// Tick the heat map for a given EIP.  Called once per interpreted instruction.
pub inline fn tickEip(eip: u32) void {
    if (!enabled) return;
    total_insns += 1;
    const page = eip >> PAGE_SHIFT;
    if (page < MAX_PAGES) {
        eip_pages[page] += 1;
    }
}

// -----------------------------------------------------------------------
// 2. Opcode Frequency Table
// -----------------------------------------------------------------------
// Supports 1-byte opcodes (0x00-0xFF) and 0F-prefixed 2-byte opcodes
// stored as 0x0F00-0x0FFF.  Total: 4096 entries.
const MAX_OPCODES = 4096;

var opcode_counts: [MAX_OPCODES]u64 = .{0} ** MAX_OPCODES;

/// Tick the opcode counter.  `opcode` uses the same encoding as decoder:
/// single-byte opcodes are 0x00-0xFF, two-byte are 0x0F00-0x0FFF.
pub inline fn tickOpcode(opcode: u16) void {
    if (!enabled) return;
    const idx: usize = if (opcode >= 0x0F00)
        @as(usize, 0x100) + (opcode & 0xFF) // 0x100..0x1FF
    else
        opcode; // 0x00..0xFF
    if (idx < MAX_OPCODES) {
        opcode_counts[idx] += 1;
    }
}

// -----------------------------------------------------------------------
// 3. Stub / Thunk Call Counter
// -----------------------------------------------------------------------
const MAX_THUNKS = 512;

var thunk_counts: [MAX_THUNKS]u64 = .{0} ** MAX_THUNKS;

/// Names registered alongside thunks — points into thunks.zig entries.
var thunk_names: [MAX_THUNKS]?[]const u8 = .{null} ** MAX_THUNKS;

pub inline fn tickThunk(thunk_id: u32) void {
    if (!enabled) return;
    if (thunk_id < MAX_THUNKS) {
        thunk_counts[thunk_id] += 1;
    }
}

/// Registers a human-readable name for a thunk ID.
pub fn registerThunkName(thunk_id: u32, name: []const u8) void {
    if (thunk_id < MAX_THUNKS) {
        thunk_names[thunk_id] = name;
    }
}

// -----------------------------------------------------------------------
// Report
// -----------------------------------------------------------------------

const TOP_N = 20;

/// Dump a profiling report to stderr via the log module.
pub fn dump() void {
    if (!enabled) return;

    const elapsed_ms = getElapsedMs();
    const elapsed_s = elapsed_ms / 1000;
    const elapsed_frac = elapsed_ms % 1000;

    log.info("=== Profiling Report: {d} insns in {d}.{d:0>3}s ({d} insns/ms) ===", .{
        total_insns,
        elapsed_s,
        elapsed_frac,
        if (elapsed_ms > 0) total_insns / elapsed_ms else total_insns,
    });

    // — Hot pages —
    log.info("--- Top {d} Hot Pages (4KB) ---", .{TOP_N});
    {
        var indices: [MAX_PAGES]u32 = undefined;
        var n: usize = 0;
        for (0..MAX_PAGES) |i| {
            if (eip_pages[i] > 0) {
                if (n < MAX_PAGES) {
                    indices[n] = @intCast(i);
                    n += 1;
                }
            }
        }
        // Partial selection sort for top-N
        const show = @min(n, TOP_N);
        for (0..show) |i| {
            var max_idx = i;
            for (i + 1..n) |j| {
                if (eip_pages[indices[j]] > eip_pages[indices[max_idx]]) {
                    max_idx = j;
                }
            }
            const tmp = indices[i];
            indices[i] = indices[max_idx];
            indices[max_idx] = tmp;
        }
        for (0..show) |i| {
            const page = indices[i];
            const addr = @as(u32, page) << PAGE_SHIFT;
            const pct = @as(f64, @floatFromInt(eip_pages[page])) / @as(f64, @floatFromInt(@max(total_insns, 1))) * 100.0;
            log.info("  0x{X:0>8}: {d:>12} insns ({d:.1}%)", .{ addr, eip_pages[page], pct });
        }
    }

    // — Top opcodes —
    log.info("--- Top {d} Opcodes ---", .{TOP_N});
    {
        var indices: [MAX_OPCODES]u16 = undefined;
        var n: usize = 0;
        for (0..MAX_OPCODES) |i| {
            if (opcode_counts[i] > 0) {
                indices[n] = @intCast(i);
                n += 1;
            }
        }
        const show = @min(n, TOP_N);
        for (0..show) |i| {
            var max_idx = i;
            for (i + 1..n) |j| {
                if (opcode_counts[indices[j]] > opcode_counts[indices[max_idx]]) {
                    max_idx = j;
                }
            }
            const tmp = indices[i];
            indices[i] = indices[max_idx];
            indices[max_idx] = tmp;
        }
        for (0..show) |i| {
            const idx = indices[i];
            const opcode: u16 = if (idx >= 0x100)
                0x0F00 | (idx - 0x100)
            else
                idx;
            log.info("  0x{X:0>4}: {d:>12}", .{ opcode, opcode_counts[idx] });
        }
    }

    // — Top stubs —
    log.info("--- Top {d} Stub Calls ---", .{TOP_N});
    {
        var indices: [MAX_THUNKS]u16 = undefined;
        var n: usize = 0;
        for (0..MAX_THUNKS) |i| {
            if (thunk_counts[i] > 0) {
                indices[n] = @intCast(i);
                n += 1;
            }
        }
        const show = @min(n, TOP_N);
        for (0..show) |i| {
            var max_idx = i;
            for (i + 1..n) |j| {
                if (thunk_counts[indices[j]] > thunk_counts[indices[max_idx]]) {
                    max_idx = j;
                }
            }
            const tmp = indices[i];
            indices[i] = indices[max_idx];
            indices[max_idx] = tmp;
        }
        for (0..show) |i| {
            const id = indices[i];
            const name = thunk_names[id] orelse "<unknown>";
            log.info("  [{d:>3}] {s}: {d:>12}", .{ id, name, thunk_counts[id] });
        }
    }
}

/// Reset all counters (for testing).
pub fn reset() void {
    // Use std.mem on byte slices to avoid Zig 0.15 codegen bug with
    // @memset on large typed arrays (InvalidInstruction: mov m64 m64).
    const eip_bytes = std.mem.asBytes(&eip_pages);
    @memset(eip_bytes, 0);
    const opc_bytes = std.mem.asBytes(&opcode_counts);
    @memset(opc_bytes, 0);
    const thk_bytes = std.mem.asBytes(&thunk_counts);
    @memset(thk_bytes, 0);
    for (&thunk_names) |*name| name.* = null;
    total_insns = 0;
    start_ns = null;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "profiler: tick and dump" {
    // Reset global state for a clean test — avoids contamination from
    // other tests (e.g. execute.zig) that may have ticked counters.
    reset();
    enabled = true;
    defer {
        enabled = false;
        reset();
    }

    start();

    const page_idx = 0x00401000 >> PAGE_SHIFT;

    tickEip(0x00401000);
    tickEip(0x00402000); // different page
    tickEip(0x00401000);
    try std.testing.expectEqual(@as(u64, 3), total_insns);
    try std.testing.expectEqual(@as(u64, 2), eip_pages[page_idx]);

    tickOpcode(0x89); // MOV
    tickOpcode(0x89);
    tickOpcode(0x0F84); // JE near
    try std.testing.expectEqual(@as(u64, 2), opcode_counts[0x89]);
    try std.testing.expectEqual(@as(u64, 1), opcode_counts[0x100 + 0x84]);

    registerThunkName(0, "GetMessage");
    tickThunk(0);
    tickThunk(0);
    tickThunk(0);
    try std.testing.expectEqual(@as(u64, 3), thunk_counts[0]);
}

test "profiler: disabled does not tick" {
    reset();
    enabled = false;

    tickEip(0x00401000);
    tickOpcode(0x89);
    tickThunk(0);

    try std.testing.expectEqual(@as(u64, 0), total_insns);
    try std.testing.expectEqual(@as(u64, 0), opcode_counts[0x89]);
    try std.testing.expectEqual(@as(u64, 0), thunk_counts[0]);
}

test "profiler: out of range indices are safe" {
    reset();
    enabled = true;
    defer {
        enabled = false;
        reset();
    }

    // EIP beyond tracked range (>1GB)
    tickEip(0x40000000);
    try std.testing.expectEqual(@as(u64, 1), total_insns); // counted
    // But no page entry updated beyond MAX_PAGES

    // Thunk ID beyond MAX_THUNKS
    tickThunk(MAX_THUNKS + 1);
    try std.testing.expectEqual(@as(u64, 0), thunk_counts[0]); // not corrupted
}
