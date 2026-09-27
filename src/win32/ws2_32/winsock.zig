const std = @import("std");
const x86_memory = @import("../../x86/memory.zig");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const platform = @import("../../platform.zig");
const linux = std.os.linux;

/// WS2_32.dll — Winsock 2 (primary implementation on Win2K)
/// These stubs provide REAL networking on native targets via direct Linux syscalls,
/// falling back to no-op stubs on WASM/freestanding.
const INVALID_SOCKET: usize = @as(usize, @bitCast(@as(isize, -1)));
const SOCKET_ERROR: i32 = -1;

/// 0.16 removed std.posix wrappers for sockets; use raw syscalls + local errno check.
inline fn sys_ok(ret: usize) !usize {
    const s: isize = @bitCast(ret);
    if (s < 0) return error.SocketOpFailed;
    return ret;
}

const PosixCompat = struct {
    pub const socket_t = i32;
    pub const socklen_t = u32;
    pub const sockaddr = linux.sockaddr;
    pub const SOL = struct {
        pub const SOCKET = linux.SOL.SOCKET;
    };
    pub const AF = linux.AF;
    pub const F = linux.F;
    pub const O = linux.O;

    pub fn socket(domain: u32, stype: u32, proto: u32) !socket_t {
        const ret = try sys_ok(linux.socket(domain, stype, proto));
        return @intCast(ret);
    }
    pub fn bind(fd: socket_t, addr: *const sockaddr, addrlen: socklen_t) !void {
        _ = try sys_ok(linux.bind(fd, addr, addrlen));
    }
    pub fn listen(fd: socket_t, backlog: u32) !void {
        _ = try sys_ok(linux.listen(fd, backlog));
    }
    pub fn accept(fd: socket_t, addr: *sockaddr, addrlen: *socklen_t, flags: u32) !socket_t {
        const ret = try sys_ok(linux.accept4(fd, addr, addrlen, flags));
        return @intCast(ret);
    }
    pub fn connect(fd: socket_t, addr: *const sockaddr, addrlen: socklen_t) !void {
        _ = try sys_ok(linux.connect(fd, addr, addrlen));
    }
    pub fn send(fd: socket_t, buf: []const u8, flags: u32) !usize {
        return try sys_ok(linux.sendto(fd, buf.ptr, buf.len, flags, null, 0));
    }
    pub fn sendto(fd: socket_t, buf: []const u8, flags: u32, dest: ?*const sockaddr, dest_len: socklen_t) !usize {
        return try sys_ok(linux.sendto(fd, buf.ptr, buf.len, flags, dest, dest_len));
    }
    pub fn recv(fd: socket_t, buf: []u8, flags: u32) !usize {
        return try sys_ok(linux.recvfrom(fd, buf.ptr, buf.len, flags, null, null));
    }
    pub fn recvfrom(fd: socket_t, buf: []u8, flags: u32, addr: *sockaddr, addr_len: *socklen_t) !usize {
        return try sys_ok(linux.recvfrom(fd, buf.ptr, buf.len, flags, addr, addr_len));
    }
    pub fn close(fd: socket_t) void {
        _ = linux.close(fd);
    }
    pub fn shutdown(fd: socket_t, how: u32) !void {
        _ = try sys_ok(linux.shutdown(fd, @intCast(how)));
    }
    pub fn fcntl(fd: socket_t, cmd: i32, arg: usize) !usize {
        return try sys_ok(linux.fcntl(fd, cmd, arg));
    }
    pub fn getsockopt(fd: socket_t, level: i32, optname: u32, opt: []u8) !void {
        var optlen: socklen_t = @intCast(opt.len);
        _ = try sys_ok(linux.getsockopt(fd, level, @intCast(optname), opt.ptr, &optlen));
    }
    pub fn getpeername(fd: socket_t, addr: *sockaddr, addr_len: *socklen_t) !void {
        _ = try sys_ok(linux.getpeername(fd, addr, addr_len));
    }
    pub fn getsockname(fd: socket_t, addr: *sockaddr, addr_len: *socklen_t) !void {
        _ = try sys_ok(linux.getsockname(fd, addr, addr_len));
    }
};

/// Small helper to translate between u32 and i32 bit-cast chains.
const posix_compat = PosixCompat;

/// Minimal AF_INET address used by winsock compat; replaces SockAddrInet.
const SockAddrInet = extern struct {
    any: linux.sockaddr = .{ .family = linux.AF.UNSPEC, .data = [_]u8{0} ** 14 },
    port: u16 = 0,
    addr: u32 = 0,

    pub fn initIp4(octets: [4]u8, p: u16) SockAddrInet {
        var self: SockAddrInet = .{};
        self.port = p;
        self.addr = std.mem.bytesToValue(u32, &octets);
        const sa_in: *linux.sockaddr.in = @ptrCast(@alignCast(&self.any));
        sa_in.* = .{ .family = linux.AF.INET, .port = @byteSwap(p), .addr = self.addr, .zero = [_]u8{0} ** 8 };
        return self;
    }

    pub fn getPort(self: SockAddrInet) u16 {
        const sa_in: *const linux.sockaddr.in = @ptrCast(@alignCast(&self.any));
        return @byteSwap(sa_in.port);
    }
};

// Win32 Winsock address family constants (same as POSIX for AF_INET)
const AF_INET: i32 = 2;

// Win32 sockaddr_in layout (same as POSIX, 16 bytes)
const WinSockAddrIn = extern struct {
    sin_family: u16,
    sin_port: u16, // network byte order
    sin_addr: u32, // network byte order
    sin_zero: [8]u8,
};

// ============================================================
// Helpers: convert between native fd and guest SOCKET handle
// ============================================================

/// On native, SOCKET values are the raw posix fd cast to usize.
inline fn socketToFd(s: usize) if (platform.is_native) PosixCompat.socket_t else void {
    if (comptime !platform.is_native) return {};
    return @intCast(@as(isize, @bitCast(s)));
}

inline fn fdToSocket(fd: if (platform.is_native) PosixCompat.socket_t else void) usize {
    if (comptime !platform.is_native) return 0;
    return @as(usize, @bitCast(@as(isize, fd)));
}

/// Convert a guest sockaddr pointer + length into a SockAddrInet.
fn sockaddrToAddress(name: usize, namelen: i32) ?SockAddrInet {
    if (name == 0 or namelen < @sizeOf(WinSockAddrIn)) return null;
    const sa = @as(*const WinSockAddrIn, @ptrFromInt(name));
    if (sa.sin_family != AF_INET) return null; // only IPv4 for Win2K era
    return SockAddrInet.initIp4(
        @bitCast(sa.sin_addr),
        @byteSwap(sa.sin_port),
    );
}

/// Write a SockAddrInet back into a guest sockaddr buffer.
fn addressToSockaddr(addr: SockAddrInet, name: usize, addrlen: usize) void {
    if (name == 0) return;
    const sa = @as(*WinSockAddrIn, @ptrFromInt(name));
    if (addr.any.family == PosixCompat.AF.INET) {
        sa.sin_family = AF_INET;
        sa.sin_port = @byteSwap(addr.getPort());
        sa.sin_addr = addr.addr;
        sa.sin_zero = [_]u8{0} ** 8;
    }
    if (addrlen != 0) {
        const lenp = @as(*i32, @ptrFromInt(addrlen));
        lenp.* = @sizeOf(WinSockAddrIn);
    }
}

/// ============================================================
/// Winsock stub implementations (all pub, shared with wsock32)
/// ============================================================
/// Implementation status: Partially implemented
pub fn WSAStartup(wVersionRequired: u16, lpWSAData: usize) callconv(w32cc.WINAPI) i32 {
    _ = wVersionRequired;
    if (trace.enable_tracing) trace.print("WS2_32: WSAStartup\n", .{});
    if (lpWSAData != 0) {
        const wsa = @as(*w32.WSADATA, @ptrFromInt(lpWSAData));
        wsa.* = .{};
        wsa.wVersion = 0x0202;
        wsa.wHighVersion = 0x0202;
    }
    return 0; // Success
}

/// Implementation status: Partially implemented
pub fn WSACleanup() callconv(w32cc.WINAPI) i32 {
    return 0;
}

/// stub_WSAGetLastError
/// Implementation status: Stub
pub fn stub_WSAGetLastError() callconv(w32cc.WINAPI) i32 {
    return 0;
}

/// stub_WSASetLastError
/// Implementation status: Stub
pub fn stub_WSASetLastError(iError: i32) callconv(w32cc.WINAPI) void {
    _ = iError;
}

/// socket
/// Implementation status: Partially implemented
pub fn socket(af: i32, sock_type: i32, protocol: i32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("WS2_32: socket(af={d}, type={d}, proto={d})\n", .{ af, sock_type, protocol });
    if (comptime platform.is_native) {
        const fd = PosixCompat.socket(
            @intCast(@as(u32, @bitCast(af))),
            @bitCast(@as(u32, @bitCast(sock_type))),
            @intCast(@as(u32, @bitCast(protocol))),
        ) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: socket failed: {}\n", .{err});
            return INVALID_SOCKET;
        };
        if (trace.enable_tracing) trace.print("WS2_32: socket => fd {d}\n", .{fd});
        return fdToSocket(fd);
    }
    return INVALID_SOCKET;
}

/// bind
/// Implementation status: Partially implemented
pub fn bind(s: usize, name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: bind(s={d})\n", .{s});
    if (comptime platform.is_native) {
        const addr = sockaddrToAddress(name, namelen) orelse return SOCKET_ERROR;
        PosixCompat.bind(socketToFd(s), &addr.any, @intCast(@as(u32, @bitCast(namelen)))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: bind failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return SOCKET_ERROR;
}

/// listen
/// Implementation status: Partially implemented
pub fn listen(s: usize, backlog: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: listen(s={d}, backlog={d})\n", .{ s, backlog });
    if (comptime platform.is_native) {
        PosixCompat.listen(socketToFd(s), @intCast(@as(u32, @bitCast(backlog)))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: listen failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return SOCKET_ERROR;
}

/// accept
/// Implementation status: Partially implemented
pub fn accept(s: usize, addr: usize, addrlen: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("WS2_32: accept(s={d})\n", .{s});
    if (comptime platform.is_native) {
        var address: SockAddrInet = SockAddrInet.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: PosixCompat.socklen_t = 16; // sizeof(sockaddr_in)
        const new_fd = PosixCompat.accept(socketToFd(s), &address.any, &addr_len, 0) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: accept failed: {}\n", .{err});
            return INVALID_SOCKET;
        };
        // Write back the peer address if caller provided a buffer
        if (addr != 0) addressToSockaddr(address, addr, addrlen);
        if (trace.enable_tracing) trace.print("WS2_32: accept => fd {d}\n", .{new_fd});
        return fdToSocket(new_fd);
    }
    return INVALID_SOCKET;
}

/// connect
/// Implementation status: Partially implemented
pub fn connect(s: usize, name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: connect(s={d})\n", .{s});
    if (comptime platform.is_native) {
        const addr = sockaddrToAddress(name, namelen) orelse return SOCKET_ERROR;
        PosixCompat.connect(socketToFd(s), &addr.any, @intCast(@as(u32, @bitCast(namelen)))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: connect failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return SOCKET_ERROR;
}

/// send
/// Implementation status: Partially implemented
pub fn send(s: usize, buf: usize, len: i32, flags: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const data = @as([*]const u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        const sent = PosixCompat.send(
            socketToFd(s),
            data,
            @bitCast(@as(u32, @bitCast(flags))),
        ) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: send failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return @intCast(sent);
    }
    return len; // pretend we sent everything
}

/// sendto
/// Implementation status: Partially implemented
pub fn sendto(s: usize, buf: usize, len: i32, flags: i32, to: usize, tolen: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const data = @as([*]const u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        const dest_addr: ?*const PosixCompat.sockaddr = if (to != 0)
            @ptrCast(@alignCast(@as(*const PosixCompat.sockaddr, @ptrFromInt(to))))
        else
            null;
        const dest_len: PosixCompat.socklen_t = if (to != 0) @intCast(@as(u32, @bitCast(tolen))) else 0;
        const sent = PosixCompat.sendto(
            socketToFd(s),
            data,
            @bitCast(@as(u32, @bitCast(flags))),
            dest_addr,
            dest_len,
        ) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: sendto failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return @intCast(sent);
    }
    return len;
}

/// recv
/// Implementation status: Partially implemented
pub fn recv(s: usize, buf: usize, len: i32, flags: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const buffer = @as([*]u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        const received = PosixCompat.recv(
            socketToFd(s),
            buffer,
            @bitCast(@as(u32, @bitCast(flags))),
        ) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: recv failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return @intCast(received);
    }
    return SOCKET_ERROR;
}

/// recvfrom
/// Implementation status: Partially implemented
pub fn recvfrom(s: usize, buf: usize, len: i32, flags: i32, from: usize, fromlen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const buffer = @as([*]u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        var src_addr: SockAddrInet = SockAddrInet.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: PosixCompat.socklen_t = 16; // sizeof(sockaddr_in)
        const received = PosixCompat.recvfrom(
            socketToFd(s),
            buffer,
            @bitCast(@as(u32, @bitCast(flags))),
            &src_addr.any,
            &addr_len,
        ) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: recvfrom failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        if (from != 0) addressToSockaddr(src_addr, from, fromlen);
        return @intCast(received);
    }
    return SOCKET_ERROR;
}

/// closesocket
/// Implementation status: Partially implemented
pub fn closesocket(s: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: closesocket(s={d})\n", .{s});
    if (comptime platform.is_native) {
        PosixCompat.close(socketToFd(s));
        return 0;
    }
    return 0;
}

/// stub_shutdown
/// Implementation status: Stub
pub fn stub_shutdown(s: usize, how: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        // Win32 SD_RECEIVE=0, SD_SEND=1, SD_BOTH=2 — same as POSIX SHUT_*
        PosixCompat.shutdown(socketToFd(s), @as(u32, @bitCast(how))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: shutdown failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return 0;
}

/// Guest timeval: whole seconds plus a microsecond remainder.
const TimeVal = extern struct { tv_sec: i32, tv_usec: i32 };

const ms_per_second: i64 = 1000;

/// Convert a guest timeval to whole milliseconds for poll(2).
/// poll() takes milliseconds, so a sub-millisecond wait rounds up: truncating
/// would turn a 999us timeout into a non-blocking poll. A negative timeval
/// means "no wait" rather than a wait of negative length. Returns null for a
/// negative tv_sec, the only case that cannot be expressed as a duration.
fn timevalToPollMs(tv_sec: i32, tv_usec: i32) ?i32 {
    if (tv_sec < 0) return 0;
    const usec = @as(i64, tv_usec);
    const ms = @as(i64, tv_sec) * ms_per_second + @divTrunc(usec + std.time.us_per_ms - 1, std.time.us_per_ms);
    if (ms > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(ms);
}

/// Convert a guest timeval to nanoseconds for sleep(). Same rounding up as
/// timevalToPollMs: a wait shorter than a nanosecond still yields at least 1ns
/// so a non-zero timeout is never silently dropped.
fn timevalToNs(tv_sec: i32, tv_usec: i32) u64 {
    const ms = timevalToPollMs(tv_sec, tv_usec) orelse return 0;
    return @as(u64, @intCast(ms)) * std.time.ns_per_ms;
}

/// select
/// Implementation status: Partially implemented
pub fn select(nfds: i32, readfds: usize, writefds: usize, exceptfds: usize, timeout: usize) callconv(w32cc.WINAPI) i32 {
    _ = nfds;
    if (comptime platform.is_native) {
        // Win32 fd_set layout: { u32 fd_count; SOCKET fd_array[64]; }
        // We translate to poll() since Win32 and POSIX fd_set layouts differ.
        const WinFdSet = extern struct {
            fd_count: u32,
            // fd_array follows immediately, each entry is a u32 SOCKET handle
        };

        // Count total fds across all sets
        var total: usize = 0;
        if (readfds != 0) total += @as(*const WinFdSet, @ptrFromInt(readfds)).fd_count;
        if (writefds != 0) total += @as(*const WinFdSet, @ptrFromInt(writefds)).fd_count;
        if (exceptfds != 0) total += @as(*const WinFdSet, @ptrFromInt(exceptfds)).fd_count;

        if (total == 0) {
            // No fds — just sleep for timeout duration if given
            if (timeout != 0) {
                const tv = @as(*const TimeVal, @ptrFromInt(timeout));
                const ns = timevalToNs(tv.tv_sec, tv.tv_usec);
                if (ns > 0) @import("../../platform.zig").sleep(ns);
            }
            return 0;
        }

        // Build poll fd array on stack (max 192 entries = 3 × FD_SETSIZE)
        var pollfds: [192]std.posix.pollfd = undefined;
        var n_poll: usize = 0;
        var read_count: u32 = 0;
        var write_count: u32 = 0;
        var except_count: u32 = 0;

        if (readfds != 0) {
            const fds = @as(*const WinFdSet, @ptrFromInt(readfds));
            read_count = fds.fd_count;
            const arr = @as([*]const u32, @ptrFromInt(readfds + 4));
            for (0..fds.fd_count) |i| {
                if (n_poll >= pollfds.len) break;
                pollfds[n_poll] = .{
                    .fd = @intCast(@as(isize, @bitCast(@as(usize, arr[i])))),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                };
                n_poll += 1;
            }
        }
        if (writefds != 0) {
            const fds = @as(*const WinFdSet, @ptrFromInt(writefds));
            write_count = fds.fd_count;
            const arr = @as([*]const u32, @ptrFromInt(writefds + 4));
            for (0..fds.fd_count) |i| {
                if (n_poll >= pollfds.len) break;
                pollfds[n_poll] = .{
                    .fd = @intCast(@as(isize, @bitCast(@as(usize, arr[i])))),
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                };
                n_poll += 1;
            }
        }
        if (exceptfds != 0) {
            const fds = @as(*const WinFdSet, @ptrFromInt(exceptfds));
            except_count = fds.fd_count;
            const arr = @as([*]const u32, @ptrFromInt(exceptfds + 4));
            for (0..fds.fd_count) |i| {
                if (n_poll >= pollfds.len) break;
                pollfds[n_poll] = .{
                    .fd = @intCast(@as(isize, @bitCast(@as(usize, arr[i])))),
                    .events = std.posix.POLL.ERR | std.posix.POLL.HUP,
                    .revents = 0,
                };
                n_poll += 1;
            }
        }

        // Calculate timeout in ms (-1 = infinite)
        var timeout_ms: i32 = -1;
        if (timeout != 0) {
            const tv = @as(*const TimeVal, @ptrFromInt(timeout));
            timeout_ms = timevalToPollMs(tv.tv_sec, tv.tv_usec) orelse -1;
        }

        const n_ready = std.posix.poll(pollfds[0..n_poll], timeout_ms) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: select/poll failed: {}\n", .{err});
            return SOCKET_ERROR;
        };

        // Write results back into Win32 fd_sets — keep only ready fds
        var poll_idx: usize = 0;
        var result_count: i32 = 0;

        if (readfds != 0) {
            const out = @as(*WinFdSet, @ptrFromInt(readfds));
            const arr = @as([*]u32, @ptrFromInt(readfds + 4));
            var out_count: u32 = 0;
            for (0..read_count) |i| {
                if (poll_idx < n_poll and (pollfds[poll_idx].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                    arr[out_count] = arr[i];
                    out_count += 1;
                    result_count += 1;
                }
                poll_idx += 1;
            }
            out.fd_count = out_count;
        }
        if (writefds != 0) {
            const out = @as(*WinFdSet, @ptrFromInt(writefds));
            const arr = @as([*]u32, @ptrFromInt(writefds + 4));
            var out_count: u32 = 0;
            for (0..write_count) |i| {
                if (poll_idx < n_poll and (pollfds[poll_idx].revents & std.posix.POLL.OUT) != 0) {
                    arr[out_count] = arr[i];
                    out_count += 1;
                    result_count += 1;
                }
                poll_idx += 1;
            }
            out.fd_count = out_count;
        }
        if (exceptfds != 0) {
            const out = @as(*WinFdSet, @ptrFromInt(exceptfds));
            const arr = @as([*]u32, @ptrFromInt(exceptfds + 4));
            var out_count: u32 = 0;
            for (0..except_count) |i| {
                if (poll_idx < n_poll and (pollfds[poll_idx].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
                    arr[out_count] = arr[i];
                    out_count += 1;
                    result_count += 1;
                }
                poll_idx += 1;
            }
            out.fd_count = out_count;
        }

        _ = n_ready;
        return result_count;
    }
    return 0; // no sockets ready
}

/// setsockopt
/// Implementation status: Partially implemented
pub fn setsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        const val_ptr: ?[*]const u8 = if (optval != 0 and optlen > 0)
            @ptrFromInt(optval)
        else
            null;
        const val_len: usize = if (optlen > 0) @intCast(@as(u32, @bitCast(optlen))) else 0;
        // Translate Win32 SOL_SOCKET (0xFFFF) to POSIX SOL.SOCKET
        const native_level: i32 = if (level == @as(i32, @bitCast(@as(u32, 0xFFFF))))
            @intCast(PosixCompat.SOL.SOCKET)
        else
            level;
        const native_optname = translateSockOpt(@intCast(@as(u32, @bitCast(native_level))), optname);
        std.posix.setsockopt(
            socketToFd(s),
            native_level,
            native_optname,
            if (val_ptr) |p| p[0..val_len] else &[_]u8{},
        ) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: setsockopt failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return 0;
}

/// getsockopt
/// Implementation status: Partially implemented
pub fn getsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (optval == 0 or optlen == 0) return SOCKET_ERROR;
        const lenp = @as(*PosixCompat.socklen_t, @ptrFromInt(optlen));
        const native_level: i32 = if (level == @as(i32, @bitCast(@as(u32, 0xFFFF))))
            @intCast(PosixCompat.SOL.SOCKET)
        else
            level;
        const native_optname = translateSockOpt(@intCast(@as(u32, @bitCast(native_level))), optname);
        const val_ptr = @as([*]u8, @ptrFromInt(optval));
        _ = PosixCompat.getsockopt(
            socketToFd(s),
            native_level,
            native_optname,
            val_ptr[0..lenp.*],
        ) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: getsockopt failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return SOCKET_ERROR;
}

/// ioctlsocket
/// Implementation status: Partially implemented
pub fn ioctlsocket(s: usize, cmd: i32, argp: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        // FIONBIO = 0x8004667E on Windows → set non-blocking via fcntl F_SETFL
        const FIONBIO_WIN32: i32 = @bitCast(@as(u32, 0x8004667E));
        if (cmd == FIONBIO_WIN32) {
            if (argp != 0) {
                const flag = @as(*const u32, @ptrFromInt(argp)).*;
                const F = PosixCompat.F;
                const cur = PosixCompat.fcntl(socketToFd(s), F.GETFL, 0) catch return SOCKET_ERROR;
                const nonblock = @as(u32, @bitCast(PosixCompat.O{ .NONBLOCK = true }));
                const new_flags = if (flag != 0) cur | nonblock else cur & ~nonblock;
                _ = PosixCompat.fcntl(socketToFd(s), F.SETFL, new_flags) catch return SOCKET_ERROR;
            }
        }
        return 0;
    }
    // WASM fallback: no-op
    return 0;
}

/// getpeername
/// Implementation status: Partially implemented
pub fn getpeername(s: usize, name: usize, namelen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        var addr: SockAddrInet = SockAddrInet.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: PosixCompat.socklen_t = 16; // sizeof(sockaddr_in)
        PosixCompat.getpeername(socketToFd(s), &addr.any, &addr_len) catch {
            return SOCKET_ERROR;
        };
        addressToSockaddr(addr, name, namelen);
        return 0;
    }
    return SOCKET_ERROR;
}

/// getsockname
/// Implementation status: Partially implemented
pub fn getsockname(s: usize, name: usize, namelen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        var addr: SockAddrInet = SockAddrInet.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: PosixCompat.socklen_t = 16; // sizeof(sockaddr_in)
        PosixCompat.getsockname(socketToFd(s), &addr.any, &addr_len) catch {
            return SOCKET_ERROR;
        };
        addressToSockaddr(addr, name, namelen);
        return 0;
    }
    return SOCKET_ERROR;
}

/// ============================================================
/// Byte-order conversion (pure Zig, works everywhere)
/// ============================================================
/// Implementation status: Partially implemented
pub fn htonl(hostlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(hostlong);
}

/// htons
/// Implementation status: Partially implemented
pub fn htons(hostshort: u16) callconv(w32cc.WINAPI) u16 {
    return @byteSwap(hostshort);
}

/// ntohl
/// Implementation status: Partially implemented
pub fn ntohl(netlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(netlong);
}

/// ntohs
/// Implementation status: Partially implemented
pub fn ntohs(netshort: u16) callconv(w32cc.WINAPI) u16 {
    return @byteSwap(netshort);
}

// ============================================================
// Address conversion (manual parsing to avoid std.net on WASI)
// ============================================================

/// Parse a dotted-decimal IPv4 address string into 4 octets.
/// Returns null if the string is not a valid IPv4 address.
fn parseIp4Manual(ip_str: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var cur: u16 = 0;
    var digit_count: usize = 0;
    for (ip_str) |ch| {
        if (ch == '.') {
            if (digit_count == 0 or octet_idx >= 3 or cur > 255) return null;
            octets[octet_idx] = @intCast(cur);
            octet_idx += 1;
            cur = 0;
            digit_count = 0;
        } else if (ch >= '0' and ch <= '9') {
            cur = cur * 10 + (ch - '0');
            digit_count += 1;
            if (cur > 255) return null;
        } else return null;
    }
    if (digit_count == 0 or octet_idx != 3 or cur > 255) return null;
    octets[3] = @intCast(cur);
    return octets;
}

/// inet_addr
/// Implementation status: Partially implemented
pub fn inet_addr(cp: usize) callconv(w32cc.WINAPI) u32 {
    if (cp == 0) return 0xFFFFFFFF;
    const str = @as([*]const u8, @ptrFromInt(cp));
    const len = std.mem.indexOfScalar(u8, str[0..256], 0) orelse return 0xFFFFFFFF;
    const ip_str = str[0..len];
    const octets = parseIp4Manual(ip_str) orelse return 0xFFFFFFFF;
    return @bitCast(octets);
}

var inet_ntoa_buf: [16]u8 = undefined;
/// Guest-side storage for inet_ntoa results. Win32 returns a pointer to a
/// single static buffer that is overwritten on every call; allocating fresh
/// raw_alloc memory per call made a guest that formats addresses in a loop
/// grow the (free-less) guest heap until allocation started failing.
var inet_ntoa_guest_buf: ?[*]u8 = null;
/// inet_ntoa
/// Implementation status: Partially implemented
pub fn inet_ntoa(in_addr: u32) callconv(w32cc.WINAPI) [*:0]const u8 {
    const bytes: [4]u8 = @bitCast(in_addr);
    const result = std.fmt.bufPrint(&inet_ntoa_buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch {
        @memcpy(inet_ntoa_buf[0..7], "0.0.0.0");
        inet_ntoa_buf[7] = 0;
        return @ptrCast(&inet_ntoa_buf);
    };
    inet_ntoa_buf[result.len] = 0;
    // On WASM, serve from one persistent guest-memory buffer so x86 code can
    // read it and repeated calls don't grow the heap.
    const shared = @import("../shared.zig");
    if (x86_memory.guest_memory != null) {
        if (inet_ntoa_guest_buf == null) {
            if (shared.raw_alloc(16)) |raw| inet_ntoa_guest_buf = @as([*]u8, @ptrCast(raw));
        }
        if (inet_ntoa_guest_buf) |p| {
            @memcpy(p[0..result.len], result);
            p[result.len] = 0;
            return @ptrCast(p);
        }
    }
    return @ptrCast(&inet_ntoa_buf);
}

// ============================================================
// DNS / hostname resolution
// ============================================================

// Static hostent buffer for gethostbyname/gethostbyaddr.
// Win32 hostent layout (32-bit pointers):
const WinHostent = extern struct {
    h_name: u32,
    h_aliases: u32,
    h_addrtype: i16,
    h_length: i16,
    h_addr_list: u32,
};

var hostent_buf: WinHostent = undefined;
var hostent_name_buf: [256]u8 = undefined;
var hostent_addr: u32 = 0;
var hostent_addr_ptr: u32 = 0;
var hostent_addr_list: [2]u32 = undefined;
var hostent_alias_list: [1]u32 = .{0};

/// Guest-side storage for the WASM hostent. Win32's gethostbyname returns a
/// pointer to a static buffer rebuilt per call; allocating fresh raw_alloc
/// memory per lookup grew the (free-less) guest heap by 288 bytes per call.
var hostent_guest_buf: ?[*]u8 = null;

fn fillHostent(name_str: []const u8, addr_bytes: [4]u8) usize {
    // On WASM, build the entire hostent + data in one reused guest block
    const shared = @import("../shared.zig");
    if (x86_memory.guest_memory != null) {
        if (hostent_guest_buf == null) {
            if (shared.raw_alloc(288)) |raw| hostent_guest_buf = @as([*]u8, @ptrCast(raw));
        }
        const base = hostent_guest_buf orelse return 0;
        const base_addr: u32 = @truncate(@intFromPtr(base));

        // Copy name string at offset 16
        const copy_len = @min(name_str.len, 255);
        @memcpy(base[16..][0..copy_len], name_str[0..copy_len]);
        base[16 + copy_len] = 0;

        // addr at offset 272
        @as(*align(1) u32, @ptrCast(base[272..276])).* = @bitCast(addr_bytes);

        // addr_list at offset 276: [ptr_to_addr, 0]
        @as(*align(1) u32, @ptrCast(base[276..280])).* = base_addr + 272;
        @as(*align(1) u32, @ptrCast(base[280..284])).* = 0;

        // alias_list at offset 284: [0]
        @as(*align(1) u32, @ptrCast(base[284..288])).* = 0;

        // hostent struct at offset 0
        const he = @as(*align(1) WinHostent, @ptrCast(base[0..16]));
        he.h_name = base_addr + 16;
        he.h_aliases = base_addr + 284;
        he.h_addrtype = AF_INET;
        he.h_length = 4;
        he.h_addr_list = base_addr + 276;

        return @intFromPtr(base);
    }

    // Native path: use static buffers
    const copy_len = @min(name_str.len, hostent_name_buf.len - 1);
    @memcpy(hostent_name_buf[0..copy_len], name_str[0..copy_len]);
    hostent_name_buf[copy_len] = 0;

    hostent_addr = @bitCast(addr_bytes);
    hostent_addr_ptr = @intCast(@intFromPtr(&hostent_addr));
    hostent_addr_list[0] = @intCast(@intFromPtr(&hostent_addr));
    hostent_addr_list[1] = 0;

    hostent_buf.h_name = @intCast(@intFromPtr(&hostent_name_buf));
    hostent_buf.h_aliases = @intCast(@intFromPtr(&hostent_alias_list));
    hostent_buf.h_addrtype = AF_INET;
    hostent_buf.h_length = 4;
    hostent_buf.h_addr_list = @intCast(@intFromPtr(&hostent_addr_list));

    return @intFromPtr(&hostent_buf);
}

/// gethostbyname
/// Implementation status: Partially implemented
pub fn gethostbyname(name: usize) callconv(w32cc.WINAPI) usize {
    if (name == 0) return 0;
    const name_str = trace.c_span(name);
    if (trace.enable_tracing) trace.print("WS2_32: gethostbyname(\"{s}\")\n", .{name_str});

    // Try parsing as a dotted IP address first (works on all platforms)
    const parsed_ip = parseIp4Manual(name_str);
    if (parsed_ip) |octets| {
        return fillHostent(name_str, octets);
    }

    // Handle "localhost" without DNS
    if (std.mem.eql(u8, name_str, "localhost")) {
        return fillHostent("localhost", .{ 127, 0, 0, 1 });
    }

    // Real DNS resolution (native only) - disabled: std.net.Address.resolveIp gone in 0.16
    // TODO: reimplement via HostName lookup or getaddrinfo
    if (comptime platform.is_native) {
        return 0;
    }
    return 0;
}

/// gethostbyaddr
/// Implementation status: Partially implemented
pub fn gethostbyaddr(addr: usize, len: i32, atype: i32) callconv(w32cc.WINAPI) usize {
    _ = atype;
    if (trace.enable_tracing) trace.print("WS2_32: gethostbyaddr\n", .{});
    if (addr == 0 or len < 4) return 0;
    const ip_bytes = @as(*const [4]u8, @ptrFromInt(addr));
    return fillHostent("unknown", ip_bytes.*);
}

/// gethostname
/// Implementation status: Partially implemented
pub fn gethostname(name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    if (name != 0 and namelen > 0) {
        const hostname = "localhost";
        const buf = @as([*]u8, @ptrFromInt(name));
        const copy_len = @min(hostname.len, @as(usize, @intCast(namelen)) - 1);
        @memcpy(buf[0..copy_len], hostname[0..copy_len]);
        buf[copy_len] = 0;
    }
    return 0;
}

// ============================================================
// Helpers
// ============================================================

/// Translate Win32 socket option names to Linux equivalents.
/// Win32 SOL_SOCKET-level option values differ from Linux x86.
fn translateSockOpt(level: u32, optname: i32) u32 {
    if (level == PosixCompat.SOL.SOCKET) {
        return switch (@as(u32, @bitCast(optname))) {
            0x0004 => std.posix.SO.REUSEADDR,
            0x0008 => std.posix.SO.KEEPALIVE,
            0x0020 => std.posix.SO.BROADCAST,
            0x0080 => std.posix.SO.LINGER,
            0x1001 => std.posix.SO.SNDBUF,
            0x1002 => std.posix.SO.RCVBUF,
            0x1007 => std.posix.SO.ERROR,
            0x1008 => std.posix.SO.TYPE,
            else => @bitCast(optname),
        };
    }
    // IPPROTO_TCP level: TCP_NODELAY = 1 on both platforms
    return @bitCast(optname);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "select timeout rounds microseconds up to whole milliseconds" {
    // poll(2) takes milliseconds: truncating here would turn a sub-millisecond
    // wait into a non-blocking poll and a 1.5s wait into 1s.
    try testing.expectEqual(@as(?i32, 1), timevalToPollMs(0, 1));
    try testing.expectEqual(@as(?i32, 1), timevalToPollMs(0, 999));
    try testing.expectEqual(@as(?i32, 1), timevalToPollMs(0, 1000));
    try testing.expectEqual(@as(?i32, 2), timevalToPollMs(0, 1001));
    try testing.expectEqual(@as(?i32, 1500), timevalToPollMs(1, 500_000));
    try testing.expectEqual(@as(?i32, 60_000), timevalToPollMs(60, 0));
    // A zeroed timeval is a poll, not an infinite wait.
    try testing.expectEqual(@as(?i32, 0), timevalToPollMs(0, 0));
    // Garbage negative fields must not panic or invert the wait.
    try testing.expectEqual(@as(?i32, 0), timevalToPollMs(-1, 0));
    try testing.expectEqual(@as(?i32, 0), timevalToPollMs(0, -5));
    // An out-of-range microsecond field carries into the milliseconds.
    try testing.expectEqual(@as(?i32, 1500), timevalToPollMs(0, 1_500_000));
}

test "select timeout never exceeds what poll(2) can express" {
    try testing.expectEqual(@as(?i32, std.math.maxInt(i32)), timevalToPollMs(std.math.maxInt(i32), 0));
}

test "timeval to nanoseconds conversion matches the millisecond rounding" {
    try testing.expectEqual(@as(u64, 0), timevalToNs(0, 0));
    try testing.expectEqual(@as(u64, std.time.ns_per_ms), timevalToNs(0, 1000));
    try testing.expectEqual(@as(u64, 1500 * std.time.ns_per_ms), timevalToNs(1, 500_000));
    // Sub-millisecond waits keep at least one millisecond instead of vanishing.
    try testing.expectEqual(@as(u64, std.time.ns_per_ms), timevalToNs(0, 1));
    try testing.expectEqual(@as(u64, 0), timevalToNs(-1, 0));
}
