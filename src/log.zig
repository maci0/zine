/// Structured diagnostic logging with colored level prefixes and timestamps.
///
/// Provides five log levels — fatal, err, warn, info, trace — each
/// emitting a colored `[FATAL]`, `[ERROR]`, `[WARN]`, `[INFO]`, `[TRACE]`
/// prefix to stderr.  Colors are auto-detected via TTY check and disabled
/// on WASM or when stderr is piped to a file.
///
/// Features:
///   - Timestamps: each line is prefixed with elapsed time since startup
///   - Level filtering: only messages at or above `min_level` are emitted
///   - Thread-safe: per-call stack buffer avoids global state races
///
/// Usage:
///   const log = @import("log.zig");
///   log.info("Loaded {s} at 0x{X}", .{ name, addr });
///   log.err("Failed to open '{s}': {}", .{ path, err });
///
/// The `trace` level is gated by the existing `trace.enable_tracing` flag
/// so it only emits output when `--trace` / `--trace-api` is active.

const std = @import("std");
const builtin = @import("builtin");
const trace_mod = @import("trace.zig");

/// Whether to emit ANSI color escape codes.  Lazily detected on first use.
var use_color: ?bool = null;

fn getUseColor() bool {
    if (use_color) |c| return c;
    const result = detectColorImpl();
    use_color = result;
    return result;
}

fn detectColorImpl() bool {
    if (builtin.target.cpu.arch == .wasm32) return false;
    if (std.process.hasEnvVarConstant("NO_COLOR")) return false;
    const handle = std.fs.File.stderr().handle;
    return std.posix.isatty(handle);
}

// ── ANSI escape sequences ───────────────────────────────────────────

const ESC_RESET = "\x1b[0m";
const ESC_RED = "\x1b[1;31m"; // bold red
const ESC_YELLOW = "\x1b[1;33m"; // bold yellow
const ESC_CYAN = "\x1b[1;36m"; // bold cyan
const ESC_DIM = "\x1b[2m"; // dim / faint

// ── Startup timestamp ───────────────────────────────────────────────

/// Nanosecond timestamp captured at first log call (lazy init).
var start_ns: ?i128 = null;

fn getElapsedMs() u64 {
    if (comptime builtin.target.cpu.arch == .wasm32) return 0;
    const now = std.time.nanoTimestamp();
    if (start_ns == null) {
        start_ns = now;
        return 0;
    }
    const delta = now - start_ns.?;
    if (delta < 0) return 0;
    return @intCast(@as(u128, @intCast(delta)) / 1_000_000);
}

// ── Level definitions ───────────────────────────────────────────────

pub const Level = enum(u3) {
    fatal = 0,
    err = 1,
    warn = 2,
    info = 3,
    trace = 4,
};

/// Minimum log level.  Messages below this level are suppressed.
/// Default: .trace (show everything).  Set via ZINE_LOG_LEVEL env var
/// or programmatically.
pub var min_level: Level = .trace;

fn levelPrefix(level: Level) struct { plain: []const u8, color: []const u8 } {
    return switch (level) {
        .fatal => .{ .plain = "[FATAL] ", .color = ESC_RED ++ "[FATAL]" ++ ESC_RESET ++ " " },
        .err => .{ .plain = "[ERROR] ", .color = ESC_RED ++ "[ERROR]" ++ ESC_RESET ++ " " },
        .warn => .{ .plain = "[WARN]  ", .color = ESC_YELLOW ++ "[WARN]" ++ ESC_RESET ++ "  " },
        .info => .{ .plain = "[INFO]  ", .color = ESC_CYAN ++ "[INFO]" ++ ESC_RESET ++ "  " },
        .trace => .{ .plain = "[TRACE] ", .color = ESC_DIM ++ "[TRACE]" ++ ESC_RESET ++ " " },
    };
}

// ── Core emit function ──────────────────────────────────────────────

/// Formats and emits a log message at the specified level.
pub fn emit(level: Level, comptime fmt: []const u8, args: anytype) void {
    // Level filtering: skip messages below min_level (lower enum value = higher severity)
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;

    const prefix = levelPrefix(level);
    const tag = if (getUseColor()) prefix.color else prefix.plain;

    const stderr = std.fs.File.stderr();

    // Format timestamp
    const elapsed_ms = getElapsedMs();
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "[{d:>7}.{d:0>3}] ", .{
        elapsed_ms / 1000,
        elapsed_ms % 1000,
    }) catch "";

    // Thread-local stack buffer avoids global state races from the web UI thread
    var log_buf: [16384]u8 = undefined;

    // Format the message body
    const s = std.fmt.bufPrint(&log_buf, fmt, args) catch {
        stderr.writeAll(ts) catch {};
        stderr.writeAll(tag) catch {};
        stderr.writeAll("LOG BUFFER OVERFLOW\n") catch {};
        return;
    };

    // Write: timestamp + prefix + message + newline (single writeAll where possible)
    stderr.writeAll(ts) catch {};
    stderr.writeAll(tag) catch {};
    stderr.writeAll(s) catch {};

    // Ensure trailing newline
    if (s.len == 0 or s[s.len - 1] != '\n') {
        stderr.writeAll("\n") catch {};
    }
}

// ── Public API ──────────────────────────────────────────────────────

/// Log a fatal error.  Does NOT exit — caller should exit/trap after.
pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    emit(.fatal, fmt, args);
}

/// Log an error condition.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(.err, fmt, args);
}

/// Log a warning.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(.warn, fmt, args);
}

/// Log an informational message.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit(.info, fmt, args);
}

/// Log a trace-level message.  Only emits when tracing is enabled.
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (!trace_mod.enable_tracing) return;
    emit(.trace, fmt, args);
}

/// Initialize log level from ZINE_LOG_LEVEL environment variable.
/// Call during startup, after env vars are available.
pub fn initFromEnv() void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, "ZINE_LOG_LEVEL") catch return;
    defer std.heap.page_allocator.free(val);
    if (std.mem.eql(u8, val, "fatal")) {
        min_level = .fatal;
    } else if (std.mem.eql(u8, val, "error") or std.mem.eql(u8, val, "err")) {
        min_level = .err;
    } else if (std.mem.eql(u8, val, "warn")) {
        min_level = .warn;
    } else if (std.mem.eql(u8, val, "info")) {
        min_level = .info;
    } else if (std.mem.eql(u8, val, "trace")) {
        min_level = .trace;
    }
}
