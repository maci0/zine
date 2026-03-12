/// Structured diagnostic logging with colored level prefixes.
///
/// Provides five log levels — fatal, err, warn, info, trace — each
/// emitting a colored `[FATAL]`, `[ERROR]`, `[WARN]`, `[INFO]`, `[TRACE]`
/// prefix to stderr.  Colors are auto-detected via TTY check and disabled
/// on WASM or when stderr is piped to a file.
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

// ── Level definitions ───────────────────────────────────────────────

pub const Level = enum {
    fatal,
    err,
    warn,
    info,
    trace,
};

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

var log_buf: [16384]u8 = undefined;

pub fn emit(level: Level, comptime fmt: []const u8, args: anytype) void {
    const prefix = levelPrefix(level);
    const tag = if (getUseColor()) prefix.color else prefix.plain;

    // Write prefix
    const stderr = std.fs.File.stderr();
    stderr.writeAll(tag) catch {};

    // Format and write the message body
    const s = std.fmt.bufPrint(&log_buf, fmt, args) catch {
        stderr.writeAll("LOG BUFFER OVERFLOW\n") catch {};
        return;
    };
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
