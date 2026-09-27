//! Runtime configuration read from the environment at startup.
//!
//! Every knob here is `ZINE_*` and is validated once, in `main`, before any
//! subsystem is initialized. A bad value stops startup with a message naming
//! the variable and the accepted values; nothing falls back to a default
//! behind the operator's back. A `ZINE_*` variable this module does not know is
//! a typo, and a typo leaves the default in place while the run looks
//! configured, so it is reported at startup too. The parsed result is the
//! single source of truth for the value (the listen address, the URL printed at
//! startup, the CSP header, the WebSocket origin allowlist), so the values
//! cannot drift apart.

const std = @import("std");
const log = @import("log.zig");

/// Loopback-only bind by default: the Web UI serves the emulator's screen and
/// accepts synthetic input, so it must not be reachable from the network.
pub const default_host = "127.0.0.1";
pub const default_port: u16 = 1995;

/// Buffer sizes bound what `ZINE_WEB_HOST` may hold. An IPv6 literal is at
/// most 45 characters, so the stored copy never allocates.
pub const max_host_len = 45;
pub const max_url_len = 64;
pub const max_origin_len = 128;

const default_host_buf = blk: {
    var buf: [max_host_len]u8 = @splat(0);
    @memcpy(buf[0..default_host.len], default_host);
    break :blk buf;
};

pub const WebServer = struct {
    /// IP literal the UI server binds to, without brackets. Copied at startup
    /// so the configuration outlives the environment map it was read from.
    host_buf: [max_host_len]u8 = default_host_buf,
    host_len: u8 = default_host.len,
    port: u16 = default_port,

    fn setHost(self: *WebServer, text: []const u8) void {
        std.debug.assert(text.len <= max_host_len);
        @memcpy(self.host_buf[0..text.len], text);
        self.host_len = @intCast(text.len);
    }

    pub fn host(self: *const WebServer) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    /// True when the bind address is a loopback address, i.e. the UI is only
    /// reachable from this machine.
    pub fn isLoopback(self: *const WebServer) bool {
        const text = self.host();
        if (std.mem.eql(u8, text, "::1")) return true;
        var octets: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, text, '.');
        var n: usize = 0;
        while (it.next()) |part| {
            if (n >= octets.len) return false;
            octets[n] = std.fmt.parseInt(u8, part, 10) catch return false;
            n += 1;
        }
        if (n != octets.len) return false;
        return octets[0] == 127;
    }

    /// Host as it appears in a URL: IPv6 literals are bracketed.
    pub fn urlHost(self: *const WebServer, buf: []u8) []const u8 {
        const text = self.host();
        if (std.mem.indexOfScalar(u8, text, ':') == null) return text;
        return std.fmt.bufPrint(buf, "[{s}]", .{text}) catch text;
    }

    /// e.g. `http://127.0.0.1:1995`
    pub fn url(self: *const WebServer, buf: []u8) []const u8 {
        var host_buf: [max_url_len]u8 = undefined;
        return std.fmt.bufPrint(buf, "http://{s}:{d}", .{ self.urlHost(&host_buf), self.port }) catch "http://" ++ default_host;
    }

    /// e.g. `ws://127.0.0.1:1995/ws`
    pub fn wsUrl(self: *const WebServer, buf: []u8) []const u8 {
        var host_buf: [max_url_len]u8 = undefined;
        return std.fmt.bufPrint(buf, "ws://{s}:{d}/ws", .{ self.urlHost(&host_buf), self.port }) catch "ws://" ++ default_host;
    }

    /// Browsers send `Origin` on WebSocket handshakes. Without this check any
    /// page the user visits could open the UI's socket, read the emulator's
    /// screen frames, and drive the guest with synthetic input (cross-site
    /// WebSocket hijacking / DNS rebinding). Clients that omit `Origin`
    /// (curl, the test suite) are allowed by the caller.
    pub fn originAllowed(self: *const WebServer, origin: []const u8) bool {
        var host_buf: [max_url_len]u8 = undefined;
        const url_host = self.urlHost(&host_buf);
        var buf: [max_origin_len]u8 = undefined;
        if (originEql(origin, "http", url_host, self.port, &buf)) return true;
        // The same loopback server is reachable under every loopback spelling
        // a browser may use for it, so accept those too.
        if (!self.isLoopback()) return false;
        for ([_][]const u8{ "127.0.0.1", "localhost", "::1" }) |alias| {
            var alias_buf: [max_url_len]u8 = undefined;
            const alias_host = if (std.mem.indexOfScalar(u8, alias, ':') == null)
                alias
            else
                std.fmt.bufPrint(&alias_buf, "[{s}]", .{alias}) catch alias;
            if (originEql(origin, "http", alias_host, self.port, &buf)) return true;
        }
        return false;
    }
};

fn originEql(origin: []const u8, scheme: []const u8, host: []const u8, port: u16, buf: []u8) bool {
    const expected = std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ scheme, host, port }) catch return false;
    return std.mem.eql(u8, origin, expected);
}

/// Guest clock. `start_ns` is the nanosecond count the first guest clock read
/// returns; with it set, the wall and monotonic readings both come from a
/// virtual cursor that advances by `step_ns` per read and by the duration of
/// each guest wait, instead of from the host clocks. Two runs that issue the
/// same calls in the same order then see the same time values, which is what
/// makes a guest run replayable. `null` keeps the host clocks.
pub const Clock = struct {
    start_ns: ?i64 = null,
    step_ns: i64 = default_clock_step_ns,
};

/// One millisecond per clock read: enough that a guest loop waiting on
/// GetTickCount deltas terminates, small enough that timestamps stay distinct.
pub const default_clock_step_ns: i64 = std.time.ns_per_ms;

/// Emulator instrumentation. Each toggle is the presence of its variable, not
/// its value: `ZINE_TRACE=`, an empty value, turns tracing on the way
/// `ZINE_TRACE=1` does, and only an unset variable leaves it off.
pub const Diagnostics = struct {
    trace: bool = false,
    trace_insn: bool = false,
    profile: bool = false,
};

/// Upper bound on the guest working directory, excluding the `Z:\` prefix and
/// the terminating NUL that `path_utils` appends.
pub const max_guest_cwd_len = 1021;

/// Guest-side settings that are not the web server's.
pub const Guest = struct {
    /// Working directory the guest resolves relative paths against, as an
    /// absolute POSIX path. WASI has no `realpath`, so the host runtime passes
    /// it in; only the WASI build consults it. Copied at startup, so the value
    /// outlives the environment map it was read from.
    cwd_buf: [max_guest_cwd_len]u8 = @splat(0),
    cwd_len: u16 = 0,

    pub fn cwd(self: *const Guest) ?[]const u8 {
        if (self.cwd_len == 0) return null;
        return self.cwd_buf[0..self.cwd_len];
    }
};

/// Active configuration. Set once by `initFromEnv` at startup.
pub var web_server: WebServer = .{};

/// Same lifetime, for the guest clock.
pub var clock: Clock = .{};

/// Same lifetime, for the instrumentation toggles.
pub var diagnostics: Diagnostics = .{};

/// Same lifetime, for the guest working directory.
pub var guest: Guest = .{};

pub const InitError = error{
    InvalidWebHost,
    InvalidWebPort,
    InvalidVirtualClock,
    InvalidClockStep,
    InvalidGuestCwd,
};

/// The message a rejected value produces, kept next to the check that rejects
/// it so both entry points report the same text.
pub fn errorMessage(err: InitError) []const u8 {
    return switch (err) {
        error.InvalidWebHost => "ZINE_WEB_HOST must be an IPv4 or IPv6 literal, e.g. 127.0.0.1.",
        error.InvalidWebPort => "ZINE_WEB_PORT must be a number from 1 to 65535.",
        error.InvalidVirtualClock => "ZINE_VIRTUAL_CLOCK_NS must be a non-negative nanosecond count since the Unix epoch.",
        error.InvalidClockStep => "ZINE_CLOCK_STEP_NS must be a non-negative nanosecond count and requires ZINE_VIRTUAL_CLOCK_NS.",
        error.InvalidGuestCwd => "ZINE_CWD must be an absolute POSIX path of at most 1021 bytes.",
    };
}

/// Reads and validates every `ZINE_*` setting: the web server address, the
/// guest clock, the instrumentation toggles, and the guest working directory.
/// Leaves the globals untouched when a value is rejected, so a failed startup
/// never runs on a half-applied configuration.
pub fn initFromEnv(env: *const std.process.Environ.Map) InitError!void {
    var parsed = WebServer{};

    if (env.get("ZINE_WEB_HOST")) |host| {
        if (!isValidHost(host)) return error.InvalidWebHost;
        parsed.setHost(host);
    }

    if (env.get("ZINE_WEB_PORT")) |port_text| {
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidWebPort;
        // Port 0 asks the OS for an ephemeral port, which would leave the
        // operator with no address to point a browser at.
        if (port == 0) return error.InvalidWebPort;
        parsed.port = port;
    }

    const parsed_clock = try parseClock(env);
    const parsed_diagnostics: Diagnostics = .{
        .trace = env.get("ZINE_TRACE") != null,
        .trace_insn = env.get("ZINE_TRACE_INSN") != null,
        .profile = env.get("ZINE_PROFILE") != null,
    };
    const parsed_guest: Guest = try parseGuestCwd(env);

    warnUnknownVars(env);

    web_server = parsed;
    clock = parsed_clock;
    diagnostics = parsed_diagnostics;
    guest = parsed_guest;
}

/// The `ZINE_*` variables a run reads. `ZINE_LOG_LEVEL` is validated in
/// `log.zig`, which owns the level names; the rest are parsed here.
const known_env_vars = [_][]const u8{
    "ZINE_LOG_LEVEL",
    "ZINE_TRACE",
    "ZINE_TRACE_INSN",
    "ZINE_PROFILE",
    "ZINE_WEB_HOST",
    "ZINE_WEB_PORT",
    "ZINE_VIRTUAL_CLOCK_NS",
    "ZINE_CLOCK_STEP_NS",
    "ZINE_CWD",
};

/// The `ZINE_*` variables in `env` that name no setting. A misspelled knob is
/// the one misconfiguration the run cannot detect by behaving differently: the
/// value is never read, so the default holds and nothing else goes wrong.
pub fn findUnknownVars(env: *const std.process.Environ.Map, allocator: std.mem.Allocator) ![][]const u8 {
    var unknown: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "ZINE_")) continue;
        if (isKnownVar(key)) continue;
        try unknown.append(allocator, key);
    }
    return unknown.toOwnedSlice(allocator);
}

fn isKnownVar(name: []const u8) bool {
    for (known_env_vars) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

/// Reports each unknown variable once, after the settings are validated.
fn warnUnknownVars(env: *const std.process.Environ.Map) void {
    const unknown = findUnknownVars(env, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(unknown);
    for (unknown) |name| {
        log.warn("ignoring {s}: no such setting, the default stands", .{name});
    }
}

/// Parses `ZINE_CWD`. A relative or empty path is rejected rather than run
/// against the process's own working directory, which on WASI is a preopen the
/// runtime chose and not the host path the operator named.
fn parseGuestCwd(env: *const std.process.Environ.Map) InitError!Guest {
    var parsed = Guest{};
    const cwd = env.get("ZINE_CWD") orelse return parsed;
    if (cwd.len == 0 or cwd.len > max_guest_cwd_len or cwd[0] != '/') {
        return error.InvalidGuestCwd;
    }
    @memcpy(parsed.cwd_buf[0..cwd.len], cwd);
    parsed.cwd_len = @intCast(cwd.len);
    return parsed;
}

/// Parses `ZINE_VIRTUAL_CLOCK_NS` and `ZINE_CLOCK_STEP_NS`. A step without a
/// start is rejected: the operator set a clock no reading would ever consult.
fn parseClock(env: *const std.process.Environ.Map) InitError!Clock {
    var parsed = Clock{};
    var step_given = false;

    if (env.get("ZINE_VIRTUAL_CLOCK_NS")) |start_text| {
        const start = std.fmt.parseInt(i64, start_text, 10) catch return error.InvalidVirtualClock;
        if (start < 0) return error.InvalidVirtualClock;
        parsed.start_ns = start;
    }

    if (env.get("ZINE_CLOCK_STEP_NS")) |step_text| {
        const step = std.fmt.parseInt(i64, step_text, 10) catch return error.InvalidClockStep;
        if (step < 0) return error.InvalidClockStep;
        parsed.step_ns = step;
        step_given = true;
    }

    if (step_given and parsed.start_ns == null) return error.InvalidClockStep;

    return parsed;
}

fn isValidHost(host: []const u8) bool {
    if (host.len == 0 or host.len > max_host_len) return false;
    if (std.mem.indexOfScalar(u8, host, ' ') != null) return false;
    _ = std.Io.net.IpAddress.parse(host, 0) catch return false;
    return true;
}

test "defaults bind loopback only" {
    const saved_server = web_server;
    const saved_clock = clock;
    defer {
        web_server = saved_server;
        clock = saved_clock;
    }
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try initFromEnv(&env);
    try std.testing.expectEqualStrings(default_host, web_server.host());
    try std.testing.expectEqual(default_port, web_server.port);
    try std.testing.expect(web_server.isLoopback());
}

test "host and port override the defaults" {
    const saved = web_server;
    defer web_server = saved;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    try env.put("ZINE_WEB_HOST", "0.0.0.0");
    try env.put("ZINE_WEB_PORT", "8080");

    try initFromEnv(&env);
    // The values are copied: the config outlives the environment map.
    env.deinit();
    try std.testing.expectEqualStrings("0.0.0.0", web_server.host());
    try std.testing.expectEqual(@as(u16, 8080), web_server.port);
    try std.testing.expect(!web_server.isLoopback());
}

test "invalid host and port values are rejected before the config changes" {
    const saved = web_server;
    defer web_server = saved;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZINE_WEB_PORT", "1995");
    try initFromEnv(&env);

    for ([_][]const u8{ "", "localhost", "127.0.0.1:1995", "999.1.1.1", "127.0.0.1 " }) |host| {
        try env.put("ZINE_WEB_HOST", host);
        try std.testing.expectError(error.InvalidWebHost, initFromEnv(&env));
        try std.testing.expectEqual(@as(u16, 1995), web_server.port);
    }
    _ = env.swapRemove("ZINE_WEB_HOST");

    for ([_][]const u8{ "", "0", "-1", "http", "65536", "1995 " }) |port| {
        try env.put("ZINE_WEB_PORT", port);
        try std.testing.expectError(error.InvalidWebPort, initFromEnv(&env));
        try std.testing.expectEqual(@as(u16, 1995), web_server.port);
    }
}

test "urls and origins follow the configured port" {
    var buf: [max_url_len]u8 = undefined;
    var web = WebServer{ .port = 3000 };
    try std.testing.expectEqualStrings("http://127.0.0.1:3000", web.url(&buf));
    try std.testing.expectEqualStrings("ws://127.0.0.1:3000/ws", web.wsUrl(&buf));

    try std.testing.expect(web.originAllowed("http://127.0.0.1:3000"));
    try std.testing.expect(web.originAllowed("http://localhost:3000"));
    try std.testing.expect(web.originAllowed("http://[::1]:3000"));
    try std.testing.expect(!web.originAllowed("http://127.0.0.1:1995"));
    try std.testing.expect(!web.originAllowed("https://127.0.0.1:3000"));
    try std.testing.expect(!web.originAllowed("http://evil.example:3000"));
}

test "a non-loopback bind does not widen the origin allowlist" {
    var buf: [max_url_len]u8 = undefined;
    var web = WebServer{ .port = 3000 };
    web.setHost("0.0.0.0");
    try std.testing.expectEqualStrings("http://0.0.0.0:3000", web.url(&buf));
    try std.testing.expectEqualStrings("ws://0.0.0.0:3000/ws", web.wsUrl(&buf));
    try std.testing.expect(web.originAllowed("http://0.0.0.0:3000"));
    try std.testing.expect(!web.originAllowed("http://127.0.0.1:3000"));
    try std.testing.expect(!web.originAllowed("http://localhost:3000"));
}

test "ipv6 hosts are bracketed in urls" {
    var buf: [max_url_len]u8 = undefined;
    var web = WebServer{};
    web.setHost("::1");
    try std.testing.expectEqualStrings("http://[::1]:1995", web.url(&buf));
    try std.testing.expect(web.originAllowed("http://[::1]:1995"));
}

test "guest clock defaults to the host clocks" {
    const saved = clock;
    defer clock = saved;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try initFromEnv(&env);
    try std.testing.expect(clock.start_ns == null);
    try std.testing.expectEqual(default_clock_step_ns, clock.step_ns);
}

test "guest clock start and step are read from the environment" {
    const saved = clock;
    defer clock = saved;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZINE_VIRTUAL_CLOCK_NS", "1700000000000000000");
    try env.put("ZINE_CLOCK_STEP_NS", "2500000");

    try initFromEnv(&env);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_000_000_000), clock.start_ns);
    try std.testing.expectEqual(@as(i64, 2_500_000), clock.step_ns);
}

test "guest clock rejects a step without a start and leaves the config alone" {
    const saved = clock;
    defer clock = saved;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try initFromEnv(&env);

    try env.put("ZINE_CLOCK_STEP_NS", "1000");
    try std.testing.expectError(error.InvalidClockStep, initFromEnv(&env));
    try std.testing.expect(clock.start_ns == null);

    for ([_][]const u8{ "", "-1", "1e9", "1000ns" }) |bad| {
        try env.put("ZINE_VIRTUAL_CLOCK_NS", bad);
        try std.testing.expectError(error.InvalidVirtualClock, initFromEnv(&env));
        try std.testing.expect(clock.start_ns == null);
    }
    _ = env.swapRemove("ZINE_VIRTUAL_CLOCK_NS");
    try env.put("ZINE_CLOCK_STEP_NS", "-1");
    try std.testing.expectError(error.InvalidClockStep, initFromEnv(&env));
    try std.testing.expectEqual(default_clock_step_ns, clock.step_ns);
}

test "instrumentation toggles are read as the presence of the variable" {
    const saved = diagnostics;
    defer diagnostics = saved;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try initFromEnv(&env);
    try std.testing.expect(!diagnostics.trace);
    try std.testing.expect(!diagnostics.trace_insn);
    try std.testing.expect(!diagnostics.profile);

    // An empty value enables the toggle, the same as any other value.
    try env.put("ZINE_TRACE", "");
    try env.put("ZINE_PROFILE", "0");
    try initFromEnv(&env);
    try std.testing.expect(diagnostics.trace);
    try std.testing.expect(!diagnostics.trace_insn);
    try std.testing.expect(diagnostics.profile);

    try env.put("ZINE_TRACE_INSN", "1");
    try initFromEnv(&env);
    try std.testing.expect(diagnostics.trace_insn);
}

test "guest cwd accepts an absolute path and rejects anything else" {
    const saved = guest;
    defer guest = saved;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try initFromEnv(&env);
    try std.testing.expect(guest.cwd() == null);

    try env.put("ZINE_CWD", "/work/dir");
    try initFromEnv(&env);
    try std.testing.expectEqualStrings("/work/dir", guest.cwd().?);

    try env.put("ZINE_CWD", "/");
    try initFromEnv(&env);
    try std.testing.expectEqualStrings("/", guest.cwd().?);

    for ([_][]const u8{ "", "work/dir", "./work", "C:\\work" }) |bad| {
        try env.put("ZINE_CWD", bad);
        try std.testing.expectError(error.InvalidGuestCwd, initFromEnv(&env));
        try std.testing.expectEqualStrings("/", guest.cwd().?);
    }

    var too_long: [max_guest_cwd_len + 2]u8 = @splat('/');
    try env.put("ZINE_CWD", too_long[0..]);
    try std.testing.expectError(error.InvalidGuestCwd, initFromEnv(&env));
    try std.testing.expectEqualStrings("/", guest.cwd().?);
}

test "every rejected value names its variable in the message" {
    for ([_]struct { InitError, []const u8 }{
        .{ error.InvalidWebHost, "ZINE_WEB_HOST" },
        .{ error.InvalidWebPort, "ZINE_WEB_PORT" },
        .{ error.InvalidVirtualClock, "ZINE_VIRTUAL_CLOCK_NS" },
        .{ error.InvalidClockStep, "ZINE_CLOCK_STEP_NS" },
        .{ error.InvalidGuestCwd, "ZINE_CWD" },
    }) |case| {
        try std.testing.expect(std.mem.indexOf(u8, errorMessage(case[0]), case[1]) != null);
    }
}

test "only unknown ZINE_ variables are collected" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ZINE_WEB_PRT", "3000");
    try env.put("ZINE_TRACE", "");
    try env.put("NO_COLOR", "1");
    for (known_env_vars) |name| try env.put(name, "x");

    const unknown = try findUnknownVars(&env, allocator);
    defer allocator.free(unknown);
    try std.testing.expectEqual(@as(usize, 1), unknown.len);
    try std.testing.expectEqualStrings("ZINE_WEB_PRT", unknown[0]);

    _ = env.swapRemove("ZINE_WEB_PRT");
    const none = try findUnknownVars(&env, allocator);
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
