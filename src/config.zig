//! Runtime configuration read from the environment at startup.
//!
//! Every knob here is `ZINE_*` and is validated once, in `main`, before any
//! subsystem is initialized. A bad value stops startup with a message naming
//! the variable and the accepted values; nothing falls back to a default
//! behind the operator's back. The parsed result is the single source of truth
//! for the value (the listen address, the URL printed at startup, the CSP
//! header, the WebSocket origin allowlist), so the values cannot drift apart.

const std = @import("std");

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

/// Active configuration. Set once by `initFromEnv` at startup.
pub var web_server: WebServer = .{};

/// Same lifetime, for the guest clock.
pub var clock: Clock = .{};

pub const InitError = error{
    InvalidWebHost,
    InvalidWebPort,
    InvalidVirtualClock,
    InvalidClockStep,
};

/// Reads `ZINE_WEB_HOST`, `ZINE_WEB_PORT`, and the guest clock settings, and
/// validates them. Leaves `web_server` and `clock` untouched when a value is
/// rejected, so a failed startup never runs on a half-applied configuration.
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
    web_server = parsed;
    clock = parsed_clock;
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
