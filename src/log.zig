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
/// The `trace` level is emitted through `src/trace.zig` (`trace.print`),
/// which owns the `--trace` / `--trace-api` gating flag and calls back into
/// `log.emit` at this level.
const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");

/// Whether to emit ANSI color escape codes.  Lazily detected on first use.
var use_color: ?bool = null;

fn getUseColor() bool {
    if (use_color) |c| return c;
    const result = detectColorImpl();
    use_color = result;
    return result;
}

fn detectColorImpl() bool {
    if (builtin.target.cpu.arch.isWasm()) return false;
    // TODO(windows): stdlib bug — `Environ.GlobalBlock` has no `view()` on Windows,
    // which makes `Environ.getPosix` fail to compile. Re-enable color + NO_COLOR
    // honoring once stdlib lands the fix, and wire up SetConsoleMode for VT.
    if (builtin.target.os.tag == .windows) return false;
    if (runtime.environ().getPosix("NO_COLOR") != null) return false;
    // `tcgetattr` succeeds iff `handle` is a terminal — stand-in for the
    // `std.posix.isatty` that was dropped in Zig 0.16.
    const handle = std.Io.File.stderr().handle;
    _ = std.posix.tcgetattr(handle) catch return false;
    return true;
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
    if (comptime builtin.target.cpu.arch.isWasm()) return 0;
    // Elapsed-since-start is a duration: monotonic clock, immune to
    // wall-clock steps that would skew or negate log timestamps.
    const now: i128 = runtime.hostMonoNanoTimestamp();
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

// ── Home path redaction ─────────────────────────────────────────────

/// Diagnostics carry host paths: module paths, the command line, every file
/// the guest opens. A home path names the local account, so it is replaced
/// with `~` in every record before the record reaches stderr. Nothing else
/// about the path changes, and a run with no `HOME` in the environment
/// redacts nothing.
const redacted_home = "~";
const max_home_forms = 2;
const max_home_len = 512;

/// `home` in its POSIX form and with separators flipped, each without the
/// leading separator so both `/home/u/f` and `Z:\home\u\f` match. Empty
/// until `initFromEnv` runs.
var home_forms: [max_home_forms][max_home_len]u8 = undefined;
var home_forms_len: [max_home_forms]usize = [_]usize{0} ** max_home_forms;

fn initHomeRedaction(env: *const std.process.Environ.Map) void {
    home_forms_len = [_]usize{0} ** max_home_forms;
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return;
    // A bare separator or an implausibly long value would match everywhere.
    if (home.len < 2 or home.len >= max_home_len) return;

    var rel = home;
    if (rel[0] == '/' or rel[0] == '\\') rel = rel[1..];
    while (rel.len > 0 and (rel[rel.len - 1] == '/' or rel[rel.len - 1] == '\\')) rel = rel[0 .. rel.len - 1];
    if (rel.len == 0) return;

    @memcpy(home_forms[0][0..rel.len], rel);
    for (rel, 0..) |c, i| home_forms[1][i] = if (c == '/') '\\' else c;
    home_forms_len = .{ rel.len, rel.len };
}

/// Replaces home path occurrences in `body` in place. Every replacement is one
/// byte and every match is at least one byte, so the write cursor never
/// overtakes the read cursor.
fn redactHome(body: []u8) []const u8 {
    if (home_forms_len[0] == 0) return body;
    var read: usize = 0;
    var write: usize = 0;
    while (read < body.len) {
        var matched = false;
        for (0..max_home_forms) |i| {
            const len = home_forms_len[i];
            if (len == 0) continue;
            if (read + len <= body.len and std.mem.eql(u8, body[read..][0..len], home_forms[i][0..len])) {
                body[write] = redacted_home[0];
                write += 1;
                read += len;
                matched = true;
                break;
            }
        }
        if (matched) continue;
        body[write] = body[read];
        write += 1;
        read += 1;
    }
    return body[0..write];
}

// ── Control character neutralization ────────────────────────────────

/// Every record quotes guest-controlled text: file names, window titles,
/// registry values, module paths. A guest that puts an escape sequence in any
/// of them drives the terminal that renders the log (OSC 52 rewrites the
/// clipboard, OSC 0/2 rewrites the window title, CSI erases earlier output),
/// and a carriage return replays a line over an earlier one. Both hide records
/// from whoever reads the log. Newline and tab survive: multi-line records are
/// legitimate and callers end their format string with one.
/// Each byte becomes at most `\xNN`, so a body of `n` bytes needs 4n of
/// room and never truncates.
fn neutralizeControlChars(src: []const u8, dst: []u8) []const u8 {
    std.debug.assert(src.len * 4 <= dst.len);
    var read: usize = 0;
    var write: usize = 0;
    while (read < src.len) : (read += 1) {
        const c = src[read];
        if (c < 0x20 and c != '\n' and c != '\t') {
            const digits = "0123456789abcdef";
            dst[write] = '\\';
            dst[write + 1] = 'x';
            dst[write + 2] = digits[c >> 4];
            dst[write + 3] = digits[c & 0xf];
            write += 4;
        } else {
            dst[write] = c;
            write += 1;
        }
    }
    return dst[0..write];
}

// ── Core emit function ──────────────────────────────────────────────

/// Formats and emits a log message at the specified level.
pub fn emit(level: Level, comptime fmt: []const u8, args: anytype) void {
    // Level filtering: skip messages below min_level (lower enum value = higher severity)
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;

    const prefix = levelPrefix(level);
    const tag = if (getUseColor()) prefix.color else prefix.plain;

    const elapsed_ms = getElapsedMs();
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "[{d:>7}.{d:0>3}] ", .{
        elapsed_ms / 1000,
        elapsed_ms % 1000,
    }) catch "";

    // Compose the whole record into one buffer, then emit once.
    // `std.debug.print` acquires the stderr lock per call, so batching matters
    // especially on traced runs where `trace.print` lands here per instruction.
    var log_buf: [16384]u8 = undefined;

    const body = std.fmt.bufPrint(&log_buf, fmt, args) catch {
        std.debug.print("{s}{s}LOG BUFFER OVERFLOW\n", .{ ts, tag });
        return;
    };

    var clean_buf: [log_buf.len * 4]u8 = undefined;
    const redacted = neutralizeControlChars(redactHome(body), &clean_buf);
    const needs_nl = redacted.len == 0 or redacted[redacted.len - 1] != '\n';
    if (builtin.target.os.tag == .linux) {
        // Direct write to fd 2 avoids the locked-stderr vtable in std.debug.print.
        const iovec = [_]std.posix.iovec_const{
            .{ .base = ts.ptr, .len = ts.len },
            .{ .base = tag.ptr, .len = tag.len },
            .{ .base = redacted.ptr, .len = redacted.len },
            .{ .base = "\n", .len = @intFromBool(needs_nl) },
        };
        _ = std.os.linux.writev(2, &iovec, iovec.len);
    } else if (needs_nl) {
        std.debug.print("{s}{s}{s}\n", .{ ts, tag, redacted });
    } else {
        std.debug.print("{s}{s}{s}", .{ ts, tag, redacted });
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

/// Initialize the log level from `ZINE_LOG_LEVEL` and home path redaction
/// from `HOME`. Call during startup, after env vars are available.
pub fn initFromEnv(env: *const std.process.Environ.Map) error{InvalidLogLevel}!void {
    initHomeRedaction(env);
    const val = env.get("ZINE_LOG_LEVEL") orelse {
        min_level = .trace;
        return;
    };
    min_level = if (std.mem.eql(u8, val, "error"))
        .err
    else
        std.meta.stringToEnum(Level, val) orelse return error.InvalidLogLevel;
}

test "log level environment validates values before changing the active level" {
    const saved_level = min_level;
    defer min_level = saved_level;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    min_level = .fatal;
    try initFromEnv(&env);
    try std.testing.expectEqual(Level.trace, min_level);

    const cases = .{
        .{ "fatal", Level.fatal },
        .{ "error", Level.err },
        .{ "err", Level.err },
        .{ "warn", Level.warn },
        .{ "info", Level.info },
        .{ "trace", Level.trace },
    };
    inline for (cases) |case| {
        try env.put("ZINE_LOG_LEVEL", case[0]);
        try initFromEnv(&env);
        try std.testing.expectEqual(case[1], min_level);
    }

    min_level = .warn;
    for ([_][]const u8{ "", "debug", "INFO", " warn", "trace ", "0" }) |val| {
        try env.put("ZINE_LOG_LEVEL", val);
        try std.testing.expectError(error.InvalidLogLevel, initFromEnv(&env));
        try std.testing.expectEqual(Level.warn, min_level);
    }
}

test "diagnostics redact the host home path in both path forms" {
    const saved_forms = home_forms;
    const saved_lens = home_forms_len;
    defer {
        home_forms = saved_forms;
        home_forms_len = saved_lens;
    }

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/jane/");
    try initFromEnv(&env);

    const cases = .{
        .{ "KERNEL32: CreateFileA('/home/jane/notes.txt')", "KERNEL32: CreateFileA('/~/notes.txt')" },
        .{ "USER32: SetWindowTextA('Z:\\home\\jane\\tax.doc')", "USER32: SetWindowTextA('Z:\\~\\tax.doc')" },
        .{ "KERNEL32: CreateFileA('C:\\Program Files\\app.exe')", "KERNEL32: CreateFileA('C:\\Program Files\\app.exe')" },
        .{ "no path here", "no path here" },
    };
    inline for (cases) |case| {
        var buf: [128]u8 = undefined;
        @memcpy(buf[0..case[0].len], case[0]);
        try std.testing.expectEqualStrings(case[1], redactHome(buf[0..case[0].len]));
    }
}

test "control characters from guest text cannot drive the terminal" {
    const cases = .{
        .{ "CreateFileA(\"a\x1b[2J\rb.txt\")", "CreateFileA(\"a\\x1b[2J\\x0db.txt\")" },
        .{ "title\x07", "title\\x07" },
        .{ "line one\nline two\ttabbed", "line one\nline two\ttabbed" },
    };
    inline for (cases) |case| {
        var dst: [case[0].len * 4]u8 = undefined;
        const got = neutralizeControlChars(case[0], &dst);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "home redaction stays off without a usable HOME" {
    const saved_lens = home_forms_len;
    defer home_forms_len = saved_lens;

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try initFromEnv(&env);
    try std.testing.expectEqual(@as(usize, 0), home_forms_len[0]);

    for ([_][]const u8{ "/", "//" }) |home| {
        try env.put("HOME", home);
        try initFromEnv(&env);
        try std.testing.expectEqual(@as(usize, 0), home_forms_len[0]);
    }

    var buf: [32]u8 = undefined;
    const body = "/home/jane/file";
    @memcpy(buf[0..body.len], body);
    try std.testing.expectEqualStrings(body, redactHome(buf[0..body.len]));
}
