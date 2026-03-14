const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");
const platform = @import("../../platform.zig");

/// WS2_32.dll — Winsock 2 (primary implementation on Win2K)
///
/// These stubs provide REAL networking on native targets via std.net / std.posix,
/// falling back to no-op stubs on WASM/freestanding.

const INVALID_SOCKET: usize = @as(usize, @bitCast(@as(isize, -1)));
const SOCKET_ERROR: i32 = -1;

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
inline fn socketToFd(s: usize) if (platform.is_native) std.posix.socket_t else void {
    if (comptime !platform.is_native) return {};
    return @intCast(@as(isize, @bitCast(s)));
}

inline fn fdToSocket(fd: if (platform.is_native) std.posix.socket_t else void) usize {
    if (comptime !platform.is_native) return 0;
    return @as(usize, @bitCast(@as(isize, fd)));
}

/// Convert a guest sockaddr pointer + length into a std.net.Address.
fn sockaddrToAddress(name: usize, namelen: i32) ?std.net.Address {
    if (name == 0 or namelen < @sizeOf(WinSockAddrIn)) return null;
    const sa = @as(*const WinSockAddrIn, @ptrFromInt(name));
    if (sa.sin_family != AF_INET) return null; // only IPv4 for Win2K era
    return std.net.Address.initIp4(
        @bitCast(sa.sin_addr),
        @byteSwap(sa.sin_port),
    );
}

/// Write a std.net.Address back into a guest sockaddr buffer.
fn addressToSockaddr(addr: std.net.Address, name: usize, addrlen: usize) void {
    if (name == 0) return;
    const sa = @as(*WinSockAddrIn, @ptrFromInt(name));
    switch (addr.any.family) {
        std.posix.AF.INET => {
            sa.sin_family = AF_INET;
            sa.sin_port = @byteSwap(addr.getPort());
            sa.sin_addr = @bitCast(addr.in.sa.addr);
            sa.sin_zero = [_]u8{0} ** 8;
        },
        else => {},
    }
    if (addrlen != 0) {
        const lenp = @as(*i32, @ptrFromInt(addrlen));
        lenp.* = @sizeOf(WinSockAddrIn);
    }
}

// ============================================================
// Winsock stub implementations (all pub, shared with wsock32)
// ============================================================

pub fn stub_WSAStartup(wVersionRequired: u16, lpWSAData: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn stub_WSACleanup() callconv(w32cc.WINAPI) i32 {
    return 0;
}

pub fn stub_WSAGetLastError() callconv(w32cc.WINAPI) i32 {
    return 0;
}

pub fn stub_WSASetLastError(iError: i32) callconv(w32cc.WINAPI) void {
    _ = iError;
}

pub fn stub_socket(af: i32, sock_type: i32, protocol: i32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("WS2_32: socket(af={d}, type={d}, proto={d})\n", .{ af, sock_type, protocol });
    if (comptime platform.is_native) {
        const fd = std.posix.socket(
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

pub fn stub_bind(s: usize, name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: bind(s={d})\n", .{s});
    if (comptime platform.is_native) {
        const addr = sockaddrToAddress(name, namelen) orelse return SOCKET_ERROR;
        std.posix.bind(socketToFd(s), &addr.any, @intCast(@as(u32, @bitCast(namelen)))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: bind failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return SOCKET_ERROR;
}

pub fn stub_listen(s: usize, backlog: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: listen(s={d}, backlog={d})\n", .{ s, backlog });
    if (comptime platform.is_native) {
        std.posix.listen(socketToFd(s), @intCast(@as(u32, @bitCast(backlog)))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: listen failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return SOCKET_ERROR;
}

pub fn stub_accept(s: usize, addr: usize, addrlen: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("WS2_32: accept(s={d})\n", .{s});
    if (comptime platform.is_native) {
        var address: std.net.Address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: std.posix.socklen_t = 16; // sizeof(sockaddr_in)
        const new_fd = std.posix.accept(socketToFd(s), &address.any, &addr_len, 0) catch |err| {
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

pub fn stub_connect(s: usize, name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: connect(s={d})\n", .{s});
    if (comptime platform.is_native) {
        const addr = sockaddrToAddress(name, namelen) orelse return SOCKET_ERROR;
        std.posix.connect(socketToFd(s), &addr.any, @intCast(@as(u32, @bitCast(namelen)))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: connect failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return SOCKET_ERROR;
}

pub fn stub_send(s: usize, buf: usize, len: i32, flags: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const data = @as([*]const u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        const sent = std.posix.send(
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

pub fn stub_sendto(s: usize, buf: usize, len: i32, flags: i32, to: usize, tolen: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const data = @as([*]const u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        const dest_addr: ?*const std.posix.sockaddr = if (to != 0)
            @ptrCast(@alignCast(@as(*const std.posix.sockaddr, @ptrFromInt(to))))
        else
            null;
        const dest_len: std.posix.socklen_t = if (to != 0) @intCast(@as(u32, @bitCast(tolen))) else 0;
        const sent = std.posix.sendto(
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

pub fn stub_recv(s: usize, buf: usize, len: i32, flags: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const buffer = @as([*]u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        const received = std.posix.recv(
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

pub fn stub_recvfrom(s: usize, buf: usize, len: i32, flags: i32, from: usize, fromlen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (buf == 0 or len <= 0) return SOCKET_ERROR;
        const buffer = @as([*]u8, @ptrFromInt(buf))[0..@intCast(@as(u32, @bitCast(len)))];
        var src_addr: std.net.Address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: std.posix.socklen_t = 16; // sizeof(sockaddr_in)
        const received = std.posix.recvfrom(
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

pub fn stub_closesocket(s: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("WS2_32: closesocket(s={d})\n", .{s});
    if (comptime platform.is_native) {
        std.posix.close(socketToFd(s));
        return 0;
    }
    return 0;
}

pub fn stub_shutdown(s: usize, how: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        // Win32 SD_RECEIVE=0, SD_SEND=1, SD_BOTH=2 — same as POSIX SHUT_*
        std.posix.shutdown(socketToFd(s), @enumFromInt(@as(u32, @bitCast(how)))) catch |err| {
            if (trace.enable_tracing) trace.print("WS2_32: shutdown failed: {}\n", .{err});
            return SOCKET_ERROR;
        };
        return 0;
    }
    return 0;
}

pub fn stub_select(nfds: i32, readfds: usize, writefds: usize, exceptfds: usize, timeout: usize) callconv(w32cc.WINAPI) i32 {
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
                const tv = @as(*const extern struct { tv_sec: i32, tv_usec: i32 }, @ptrFromInt(timeout));
                const ns = @as(u64, @intCast(tv.tv_sec)) * std.time.ns_per_s +
                    @as(u64, @intCast(@divTrunc(tv.tv_usec, 1000))) * std.time.ns_per_ms;
                if (ns > 0) std.Thread.sleep(ns);
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
            const tv = @as(*const extern struct { tv_sec: i32, tv_usec: i32 }, @ptrFromInt(timeout));
            timeout_ms = @intCast(@as(i64, tv.tv_sec) * 1000 + @divTrunc(@as(i64, tv.tv_usec), 1000));
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

pub fn stub_setsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: i32) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        const val_ptr: ?[*]const u8 = if (optval != 0 and optlen > 0)
            @ptrFromInt(optval)
        else
            null;
        const val_len: usize = if (optlen > 0) @intCast(@as(u32, @bitCast(optlen))) else 0;
        // Translate Win32 SOL_SOCKET (0xFFFF) to POSIX SOL.SOCKET
        const native_level: i32 = if (level == @as(i32, @bitCast(@as(u32, 0xFFFF))))
            @intCast(std.posix.SOL.SOCKET)
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

pub fn stub_getsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        if (optval == 0 or optlen == 0) return SOCKET_ERROR;
        const lenp = @as(*std.posix.socklen_t, @ptrFromInt(optlen));
        const native_level: i32 = if (level == @as(i32, @bitCast(@as(u32, 0xFFFF))))
            @intCast(std.posix.SOL.SOCKET)
        else
            level;
        const native_optname = translateSockOpt(@intCast(@as(u32, @bitCast(native_level))), optname);
        const val_ptr = @as([*]u8, @ptrFromInt(optval));
        _ = std.posix.getsockopt(
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

pub fn stub_ioctlsocket(s: usize, cmd: i32, argp: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        // FIONBIO = 0x8004667E on Windows → set non-blocking via fcntl F_SETFL
        const FIONBIO_WIN32: i32 = @bitCast(@as(u32, 0x8004667E));
        if (cmd == FIONBIO_WIN32) {
            if (argp != 0) {
                const flag = @as(*const u32, @ptrFromInt(argp)).*;
                const cur = std.posix.fcntl(socketToFd(s), std.os.linux.F.GETFL, 0) catch return SOCKET_ERROR;
                const O_NONBLOCK: u32 = 0o4000;
                const new_flags = if (flag != 0) cur | O_NONBLOCK else cur & ~O_NONBLOCK;
                _ = std.posix.fcntl(socketToFd(s), std.os.linux.F.SETFL, new_flags) catch return SOCKET_ERROR;
            }
        }
        return 0;
    }
    // WASM fallback: no-op
    return 0;
}

pub fn stub_getpeername(s: usize, name: usize, namelen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        var addr: std.net.Address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: std.posix.socklen_t = 16; // sizeof(sockaddr_in)
        std.posix.getpeername(socketToFd(s), &addr.any, &addr_len) catch {
            return SOCKET_ERROR;
        };
        addressToSockaddr(addr, name, namelen);
        return 0;
    }
    return SOCKET_ERROR;
}

pub fn stub_getsockname(s: usize, name: usize, namelen: usize) callconv(w32cc.WINAPI) i32 {
    if (comptime platform.is_native) {
        var addr: std.net.Address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: std.posix.socklen_t = 16; // sizeof(sockaddr_in)
        std.posix.getsockname(socketToFd(s), &addr.any, &addr_len) catch {
            return SOCKET_ERROR;
        };
        addressToSockaddr(addr, name, namelen);
        return 0;
    }
    return SOCKET_ERROR;
}

// ============================================================
// Byte-order conversion (pure Zig, works everywhere)
// ============================================================

pub fn stub_htonl(hostlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(hostlong);
}

pub fn stub_htons(hostshort: u16) callconv(w32cc.WINAPI) u16 {
    return @byteSwap(hostshort);
}

pub fn stub_ntohl(netlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(netlong);
}

pub fn stub_ntohs(netshort: u16) callconv(w32cc.WINAPI) u16 {
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

pub fn stub_inet_addr(cp: usize) callconv(w32cc.WINAPI) u32 {
    if (cp == 0) return 0xFFFFFFFF;
    const str = @as([*]const u8, @ptrFromInt(cp));
    const len = std.mem.indexOfScalar(u8, str[0..256], 0) orelse return 0xFFFFFFFF;
    const ip_str = str[0..len];
    const octets = parseIp4Manual(ip_str) orelse return 0xFFFFFFFF;
    return @bitCast(octets);
}

var inet_ntoa_buf: [16]u8 = undefined;
pub fn stub_inet_ntoa(in_addr: u32) callconv(w32cc.WINAPI) usize {
    const bytes: [4]u8 = @bitCast(in_addr);
    const result = std.fmt.bufPrint(&inet_ntoa_buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch {
        @memcpy(inet_ntoa_buf[0..7], "0.0.0.0");
        inet_ntoa_buf[7] = 0;
        return @intFromPtr(&inet_ntoa_buf);
    };
    inet_ntoa_buf[result.len] = 0;
    return @intFromPtr(&inet_ntoa_buf);
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

fn fillHostent(name_str: []const u8, addr_bytes: [4]u8) usize {
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

pub fn stub_gethostbyname(name: usize) callconv(w32cc.WINAPI) usize {
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

    // Real DNS resolution (native only)
    if (comptime platform.is_native) {
        // std.net.Address.resolveIp returns a single Address on success
        if (std.net.Address.resolveIp(name_str, 0)) |addr| {
            if (addr.any.family == std.posix.AF.INET) {
                return fillHostent(name_str, @bitCast(addr.in.sa.addr));
            }
        } else |err| {
            if (trace.enable_tracing) trace.print("WS2_32: gethostbyname resolve failed: {}\n", .{err});
        }
        return 0;
    }
    return 0;
}

pub fn stub_gethostbyaddr(addr: usize, len: i32, atype: i32) callconv(w32cc.WINAPI) usize {
    _ = atype;
    if (trace.enable_tracing) trace.print("WS2_32: gethostbyaddr\n", .{});
    if (addr == 0 or len < 4) return 0;
    const ip_bytes = @as(*const [4]u8, @ptrFromInt(addr));
    return fillHostent("unknown", ip_bytes.*);
}

pub fn stub_gethostname(name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
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
    if (level == std.posix.SOL.SOCKET) {
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
