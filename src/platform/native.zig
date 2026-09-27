//! Platform backend: Native Linux (x86 / x86_64).
//!
//! Uses POSIX syscalls (mmap, sigaction, /proc/self/maps), inline asm for
//! FS-segment setup, and std.Thread.  Compiled only when targeting a native
//! CPU architecture.  Architecture-specific code is gated on is_x86/is_x86_64.

const linux = std.os.linux;

const std = @import("std");
const runtime = @import("../runtime.zig");
const builtin = @import("builtin");
const log = @import("../log.zig");
const teb = @import("../win32/teb.zig");
const trace = @import("../trace.zig");
const kernel32_error = @import("../win32/kernel32/error.zig");
const compat_thunks = @import("../x86/compat_thunks.zig");

// -------------------------------------------------------------------------
// Architecture constants
// -------------------------------------------------------------------------

pub const is_wasm = false;
pub const is_native = true;
pub const is_x86 = builtin.target.cpu.arch == .x86;
pub const is_x86_64 = builtin.target.cpu.arch == .x86_64;

// -------------------------------------------------------------------------
// Threading
// -------------------------------------------------------------------------

/// Yields execution to the host environment.
pub fn yield() void {
    // A host that refuses to yield is not an error the guest can act on.
    std.Thread.yield() catch {};
}

/// Suspends execution for the specified number of nanoseconds. Covers the full
/// interval: zine installs its own signal handlers, so a guest Sleep() is
/// routinely cut short by SIGSEGV/SIGALRM delivery and must resume from the
/// unslept remainder instead of returning early.
pub fn sleep(ns: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: linux.timespec = undefined;
    while (linux.nanosleep(&req, &rem) == @intFromEnum(linux.E.INTR)) {
        if (rem.sec == 0 and rem.nsec == 0) break;
        req = rem;
    }
}

pub const Mutex = runtime.Mutex;

// -------------------------------------------------------------------------
// FS segment swap for libc calls from stub contexts
// -------------------------------------------------------------------------

/// Host TLS base of the main thread, captured before setupFS switches FS to
/// the guest TEB. libc (pthread_create, malloc, ...) reads per-thread state
/// via %fs; inside a compat-mode stub the FS selector points at the guest
/// TEB, so libc sees garbage. useHostFs() temporarily restores the host TLS
/// so such calls work, and restoreFs() puts the guest selector back.
var host_fs_base: usize = 0;

/// Capture the host FS base (call once from main, before setupFS).
pub fn saveHostFsBase() void {
    if (comptime is_x86_64) {
        var base: usize = 0;
        _ = std.os.linux.syscall2(std.os.linux.SYS.arch_prctl, 0x1003, @intFromPtr(&base)); // ARCH_GET_FS
        host_fs_base = base;
    }
}

/// Switch the current thread to host TLS (selector 0 + MSR host base).
/// Returns the FS selector to restore with restoreFs().
pub fn useHostFs() u16 {
    if (comptime is_x86_64) {
        var sel: u16 = undefined;
        asm volatile ("mov %%fs, %[s]"
            : [s] "=r" (sel),
        );
        asm volatile ("mov %[z], %%fs"
            :
            : [z] "r" (@as(u16, 0)),
        );
        _ = std.os.linux.syscall2(std.os.linux.SYS.arch_prctl, 0x1002, host_fs_base); // ARCH_SET_FS
        return sel;
    }
    return 0;
}

/// Restore the guest FS selector captured by useHostFs().
pub fn restoreFs(sel: u16) void {
    if (comptime is_x86_64) {
        if (sel != 0) {
            asm volatile ("mov %[s], %%fs"
                :
                : [s] "r" (sel),
            );
        }
    }
}

/// Spawns a new thread. Returns true on success.
pub fn spawnThread(func: anytype, args: anytype) bool {
    _ = std.Thread.spawn(.{}, func, args) catch return false;
    return true;
}

/// Read the SEH exception list head. On x86 this is FS:0.
/// On other native architectures, SEH is not supported.
pub fn readExceptionList() u32 {
    if (comptime is_x86) {
        return asm volatile ("movl %%fs:0, %[out]"
            : [out] "=r" (-> u32),
        );
    } else {
        return 0xFFFFFFFF; // No SEH on this architecture
    }
}

// -------------------------------------------------------------------------
// Memory Mapping
// -------------------------------------------------------------------------

/// Allocates or maps a memory region.
pub fn mmap(
    hint: ?*anyopaque,
    size: usize,
    executable: bool,
    file_fd: i32,
    file_offset: u64,
    shared: bool,
    fixed: bool,
) ![]align(4096) u8 {
    var prot: std.posix.PROT = .{ .READ = true, .WRITE = true };
    if (executable) prot.EXEC = true;

    var flags: std.posix.MAP = if (shared) .{ .TYPE = .SHARED } else .{ .TYPE = .PRIVATE };
    if (comptime is_x86_64 and builtin.os.tag == .linux) {
        // MAP_32BIT constrains anonymous allocations to the low 4GB.
        // Don't set it for fixed-address mappings (the address is already
        // known) — it can interfere with MAP_FIXED_NOREPLACE.
        if (!fixed) {
            flags.@"32BIT" = true;
        }
    }
    if (file_fd == -1) {
        flags.ANONYMOUS = true;
    }
    if (fixed) {
        // Use MAP_FIXED_NOREPLACE to avoid silently destroying existing
        // mappings (including the Zig host process itself).  If the
        // requested address is already occupied, the kernel returns
        // EEXIST and we fall back to a non-fixed mapping.
        flags.FIXED_NOREPLACE = true;
    }

    const ptr_hint: ?[*]align(4096) u8 = @ptrCast(@alignCast(hint));
    const result = std.posix.mmap(ptr_hint, size, prot, flags, file_fd, file_offset);

    if (result) |slice| {
        return slice;
    } else |err| {
        if (fixed and (err == error.MappingAlreadyExists or err == error.OutOfMemory)) {
            // The fixed address is occupied. Fall back to a non-fixed mapping.
            log.warn("MAP_FIXED_NOREPLACE failed at 0x{X}, falling back to any address", .{@intFromPtr(hint)});
            var fallback_flags = flags;
            fallback_flags.FIXED_NOREPLACE = false;
            if (comptime is_x86_64 and builtin.os.tag == .linux) {
                fallback_flags.@"32BIT" = true; // ensure fallback stays in low 4GB
            }
            return std.posix.mmap(null, size, prot, fallback_flags, file_fd, file_offset);
        }
        return err;
    }
}

/// Unmaps a memory region.
pub fn munmap(slice: []align(4096) u8) void {
    std.posix.munmap(slice);
}

// -------------------------------------------------------------------------
// Process
// -------------------------------------------------------------------------

/// Returns the process ID of the current process.
pub fn getProcessId() u32 {
    // Linux-specific — no cross-platform Zig std equivalent
    return @intCast(std.os.linux.getpid());
}

/// Terminates the current process with the given exit code.
/// On x86_64, use a raw syscall to avoid Zig's TLS-dependent cleanup
/// (FS segment is set to TEB, not Zig's TLS, so cleanup would crash).
pub fn exitProcess(code: u8) noreturn {
    if (comptime is_x86_64) {
        asm volatile ("syscall"
            :
            : [num] "{rax}" (@as(usize, 231)), // __NR_exit_group
              [arg1] "{rdi}" (@as(usize, code)),
            : .{ .rcx = true, .r11 = true });
        unreachable;
    }
    std.process.exit(code);
}

fn readClock(clock_id: linux.clockid_t) linux.timespec {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(clock_id, &ts);
    return ts;
}

/// Returns the current timestamp as a Unix epoch value (seconds).
pub fn timestamp() i64 {
    return readClock(.REALTIME).sec;
}

/// Returns the current timestamp in milliseconds since Unix epoch.
pub fn milliTimestamp() i64 {
    const ts = readClock(.REALTIME);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

/// Returns the current timestamp in nanoseconds since Unix epoch.
pub fn nanoTimestamp() i128 {
    const ts = readClock(.REALTIME);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// -------------------------------------------------------------------------
// Stack bounds (from /proc/self/maps)
// -------------------------------------------------------------------------

pub const StackBounds = struct {
    stack_base: u32,
    stack_limit: u32,
};

/// Guest stack size probed below the detected stack base. MSVC's _chkstk
/// guard pages abort (C1063) once the guest touches this boundary.
const guest_stack_bytes: usize = 8 * 1024 * 1024;

/// A `/proc/self/maps` line is "start-end perms offset dev inode path"; the
/// path may contain spaces, so only the first two fields are parsed.
fn parseStackMapping(line: []const u8, result: *StackBounds) bool {
    if (std.mem.indexOf(u8, line, "[stack]") == null) return false;
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const range = fields.next() orelse return false;
    var range_it = std.mem.splitScalar(u8, range, '-');
    const start_str = range_it.next() orelse return false;
    const end_str = range_it.next() orelse return false;

    const stack_limit = std.fmt.parseInt(usize, start_str, 16) catch return false;
    const stack_base = std.fmt.parseInt(usize, end_str, 16) catch return false;

    result.stack_base = @truncate(stack_base);
    result.stack_limit = if (stack_base > guest_stack_bytes)
        @truncate(stack_base - guest_stack_bytes)
    else
        @truncate(stack_limit);

    log.info("Detected stack: 0x{X} - 0x{X} (limit set to 0x{X})", .{ stack_limit, stack_base, result.stack_limit });
    return true;
}

/// Chunk size for streaming `/proc/self/maps`. The file grows past any single
/// read buffer on hosts with many mappings, and `[stack]` is one of the last
/// entries, so a short read silently loses the whole stack mapping.
const maps_chunk_size: usize = 4096;
/// Longest line carried across a chunk boundary. Real mappings lines are
/// well under this; a longer line is dropped rather than buffered.
const maps_line_carry: usize = 512;

/// Scan a chunked `/proc/self/maps` stream for the `[stack]` mapping.
/// `reader.next(buf)` fills `buf` with the next chunk and returns its
/// length, or 0 at end of input. `buf` must be at least
/// `maps_line_carry + maps_chunk_size` bytes; a line split across a chunk
/// boundary is rejoined from the carried tail.
fn findStackMapping(reader: anytype, buf: []u8) ?StackBounds {
    var carry: [maps_line_carry]u8 = undefined;
    var carry_len: usize = 0;
    const window: []u8 = buf[0 .. carry.len + maps_chunk_size];

    while (true) {
        const n = reader.next(window[carry_len..]);
        if (n == 0) break;
        const total = carry_len + n;

        var lines = std.mem.splitScalar(u8, window[0..total], '\n');
        while (lines.next()) |line| {
            var bounds: StackBounds = undefined;
            if (parseStackMapping(line, &bounds)) return bounds;
        }

        // Keep the trailing partial line for the next chunk.
        const last_nl = std.mem.lastIndexOfScalar(u8, window[0..total], '\n') orelse {
            carry_len = @min(total, carry.len);
            @memcpy(carry[0..carry_len], window[0..carry_len]);
            continue;
        };
        const rest = window[last_nl + 1 .. total];
        carry_len = @min(rest.len, carry.len);
        @memcpy(carry[0..carry_len], rest[0..carry_len]);
    }
    return null;
}

/// Feeds `findStackMapping` from a byte slice, one `maps_chunk_size` at a time.
const SliceReader = struct {
    content: []const u8,
    offset: usize = 0,

    fn next(self: *@This(), buf: []u8) usize {
        const n = @min(buf.len, self.content.len - self.offset);
        @memcpy(buf[0..n], self.content[self.offset..][0..n]);
        self.offset += n;
        return n;
    }
};

/// Returns the bounds of the current thread's stack.
pub fn getStackBounds(frame_addr: usize) StackBounds {
    // Defaults based on frame address
    var result = StackBounds{
        .stack_base = @truncate((frame_addr +% 0x100000) & 0xFFFFF000),
        .stack_limit = @truncate((frame_addr -% 0x700000) & 0xFFFFF000),
    };

    if (std.Io.Dir.openFileAbsolute(runtime.io(), "/proc/self/maps", .{})) |file| {
        defer file.close(runtime.io());
        var offset: u64 = 0;
        const FileReader = struct {
            file: std.Io.File,
            offset: *u64,

            fn next(self: *@This(), buf: []u8) usize {
                const n = self.file.readPositionalAll(runtime.io(), buf, self.offset.*) catch 0;
                self.offset.* += n;
                return n;
            }
        };
        var reader = FileReader{ .file = file, .offset = &offset };
        var buf: [maps_line_carry + maps_chunk_size]u8 = undefined;
        if (findStackMapping(&reader, &buf)) |found| result = found;
    } else |_| {}

    return result;
}

test "parseStackMapping reads the [stack] range and clamps the guest limit" {
    var bounds = StackBounds{ .stack_base = 0, .stack_limit = 0 };
    const line = "7ffe0000-7ffff000 rw-p 00000000 00:00 0                          [stack]";
    try std.testing.expect(parseStackMapping(line, &bounds));
    try std.testing.expectEqual(@as(u32, 0x7ffff000), bounds.stack_base);
    try std.testing.expectEqual(@as(u32, 0x7ffff000 - guest_stack_bytes), bounds.stack_limit);
}

test "parseStackMapping ignores unrelated and malformed lines" {
    var bounds = StackBounds{ .stack_base = 0, .stack_limit = 0 };
    try std.testing.expect(!parseStackMapping("55a1b2000-55a1b3000 rw-p 00000000 00:00 0    /usr/lib/libc.so.6", &bounds));
    try std.testing.expect(!parseStackMapping("7ffc1b1fe000-7ffc1b3fe000 rw-p 00000000 00:00 0", &bounds));
    try std.testing.expect(!parseStackMapping("not-a-range rw-p 00000000 00:00 0           [stack]", &bounds));
    try std.testing.expectEqual(@as(u32, 0), bounds.stack_base);
}

test "parseStackMapping keeps the range when the base is below the probe size" {
    var bounds = StackBounds{ .stack_base = 0, .stack_limit = 0 };
    const line = "00100000-00300000 rw-p 00000000 00:00 0                          [stack]";
    try std.testing.expect(parseStackMapping(line, &bounds));
    try std.testing.expectEqual(@as(u32, 0x00300000), bounds.stack_base);
    try std.testing.expectEqual(@as(u32, 0x00100000), bounds.stack_limit);
}

test "getStackBounds finds the host [stack] mapping" {
    var probe: u8 = 0;
    const bounds = getStackBounds(@intFromPtr(&probe));
    try std.testing.expect(bounds.stack_base != 0);
    try std.testing.expect(bounds.stack_limit < bounds.stack_base);
}

test "findStackMapping finds a [stack] line past the first chunk" {
    // Real hosts list thousands of mappings before [stack]; a scan that reads
    // one buffer and stops misses the stack entirely.
    const filler = "7f0000000000-7f0000001000 rw-p 00000000 00:00 0 /usr/lib/libc.so.6\n";
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    while (content.items.len < maps_chunk_size * 2) {
        try content.appendSlice(std.testing.allocator, filler);
    }
    try content.appendSlice(std.testing.allocator, "7ffe0000-7ffff000 rw-p 00000000 00:00 0 [stack]\n");

    var buf: [maps_line_carry + maps_chunk_size]u8 = undefined;
    var reader = SliceReader{ .content = content.items };
    const bounds = findStackMapping(&reader, &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x7ffff000), bounds.stack_base);
}

test "findStackMapping rejoins a [stack] line split across chunks" {
    const filler = "7f0000000000-7f0000001000 rw-p 00000000 00:00 0 /usr/lib/libc.so.6\n";
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    while (content.items.len < maps_chunk_size - 10) {
        try content.appendSlice(std.testing.allocator, filler);
    }
    // Ends mid-line, so the [stack] entry can only be parsed after the carry
    // from the previous chunk is prepended.
    try content.appendSlice(std.testing.allocator, "7ffe0000-7ff");
    try content.appendSlice(std.testing.allocator, "e0000 rw-p 00000000 00:00 0 [stack]\n");

    var buf: [maps_line_carry + maps_chunk_size]u8 = undefined;
    var reader = SliceReader{ .content = content.items };
    const bounds = findStackMapping(&reader, &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x7ffe0000), bounds.stack_base);
}

test "findStackMapping returns null when no [stack] line exists" {
    var buf: [maps_line_carry + maps_chunk_size]u8 = undefined;
    var reader = SliceReader{ .content = "7f0000000000-7f0000001000 rw-p 00000000 00:00 0 [heap]\n" };
    try std.testing.expect(findStackMapping(&reader, &buf) == null);
}

// -------------------------------------------------------------------------
// FS Segment Setup (TEB)
// -------------------------------------------------------------------------

/// Configures the FS segment for the current thread.
pub fn setupFS(teb_ptr: *anyopaque) !void {
    const arch = builtin.target.cpu.arch;

    if (arch == .x86) {
        // x86: use set_thread_area syscall via int $0x80
        // No Zig std equivalent — this is a Linux-specific syscall for
        // configuring x86 segment descriptors (needed for Win32 FS: TEB access).
        const SYS_set_thread_area: usize = 243;

        var desc: [4]u32 = [_]u32{
            0xFFFFFFFF, // entry_number = -1
            @truncate(@intFromPtr(teb_ptr)), // base_addr
            0xfffff, // limit
            0 | (1 << 0) | (0 << 1) | (0 << 3) | (1 << 4) | (0 << 5) | (1 << 6),
        };

        var rc: usize = undefined;
        asm volatile ("int $0x80"
            : [ret] "={eax}" (rc),
            : [num] "{eax}" (SYS_set_thread_area),
              [arg1] "{ebx}" (@intFromPtr(&desc)),
            : .{ .memory = true, .cc = true });

        if (rc > 0xfffff000) {
            log.err("set_thread_area failed: {d}", .{rc});
            return error.SetThreadAreaFailed;
        }

        const entry_number = desc[0];
        const selector: u16 = @intCast((entry_number << 3) | 3); // RPL 3

        asm volatile ("mov %[sel], %%fs"
            :
            : [sel] "r" (selector),
        );

        // Save selector globally for timer threads that need to set FS for game callbacks
        teb.teb_fs_selector = selector;

        log.info("FS segment initialized with selector 0x{X}, TEB at 0x{X}", .{ selector, @intFromPtr(teb_ptr) });
    } else if (arch == .x86_64) {
        // x86_64: use arch_prctl(ARCH_SET_FS) for 64-bit mode FS base,
        // AND set_thread_area for 32-bit compat mode FS access.
        // 32-bit compat mode (CS=0x23) uses GDT-based FS, not the MSR-based
        // FS base from arch_prctl. Both are needed.
        const SYS_arch_prctl: usize = 158;
        const ARCH_SET_FS: usize = 0x1002;
        var rc: usize = undefined;
        asm volatile ("syscall"
            : [ret] "={rax}" (rc),
            : [num] "{rax}" (SYS_arch_prctl),
              [arg1] "{rdi}" (ARCH_SET_FS),
              [arg2] "{rsi}" (@intFromPtr(teb_ptr)),
            : .{ .rcx = true, .r11 = true, .memory = true });

        if (rc > 0xfffffffffffff000) {
            log.err("arch_prctl(ARCH_SET_FS) failed: {d}", .{rc});
            return error.SetThreadAreaFailed;
        }

        // Also set up a LDT entry for FS so 32-bit compat mode code can use
        // fs: prefix (e.g. `mov eax, fs:[0]` for SEH chain).
        // set_thread_area is not available on x86_64, but modify_ldt is.
        const SYS_modify_ldt: usize = 154;
        const teb_addr_32: u32 = @truncate(@intFromPtr(teb_ptr));
        const ldt_entry = extern struct {
            entry_number: u32,
            base_addr: u32,
            limit: u32,
            flags: u32,
        }{
            .entry_number = 0, // LDT entry 0
            .base_addr = teb_addr_32,
            .limit = 0xFFFFF, // 4GB (granularity=page)
            .flags = (1 << 0) | // seg_32bit
                (0 << 3) | // contents = data
                (0 << 1) | // read_exec_only = 0 (writable)
                (1 << 4) | // limit_in_pages = 1 (4K granularity)
                (0 << 5) | // seg_not_present = 0 (present)
                (1 << 6), // useable = 1
        };
        var rc2: usize = undefined;
        asm volatile ("syscall"
            : [ret] "={rax}" (rc2),
            : [num] "{rax}" (SYS_modify_ldt),
              [arg1] "{rdi}" (@as(usize, 1)), // write
              [arg2] "{rsi}" (@intFromPtr(&ldt_entry)),
              [arg3] "{rdx}" (@as(usize, @sizeOf(@TypeOf(ldt_entry)))),
            : .{ .rcx = true, .r11 = true, .memory = true });

        if (rc2 > 0xfffffffffffff000) {
            log.warn("modify_ldt failed on x86_64: {d} (compat mode FS won't work)", .{rc2});
        } else {
            // LDT selector: (entry_number << 3) | 0x4 (LDT bit) | 0x3 (RPL 3)
            const selector: u16 = (0 << 3) | 0x4 | 0x3; // = 0x07
            asm volatile ("movw %[sel], %%fs"
                :
                : [sel] "r" (selector),
            );
            teb.teb_fs_selector = selector;
            log.info("FS LDT entry set for compat mode: selector=0x{X}, TEB at 0x{X}", .{ selector, teb_addr_32 });
        }

        log.info("FS base set via arch_prctl, TEB at 0x{X}", .{@intFromPtr(teb_ptr)});
    } else {
        return; // Unsupported architecture
    }
}

// -------------------------------------------------------------------------
// Memory Protection
// -------------------------------------------------------------------------

/// Changes the protection of a memory region.
pub fn mprotect(addr: usize, len: usize, readable: bool, writable: bool, executable: bool) void {
    var prot: std.posix.PROT = .{};
    if (readable) prot.READ = true;
    if (writable) prot.WRITE = true;
    if (executable) prot.EXEC = true;
    _ = std.os.linux.mprotect(@ptrFromInt(addr), len, prot);
}

/// Mark a memory region as read-write-execute. Used when VirtualAlloc
/// re-commits a region with PAGE_EXECUTE_* protection.
pub fn mprotectExec(addr: *anyopaque, len: usize) !void {
    const aligned_addr = @intFromPtr(addr) & ~@as(usize, 4095);
    const aligned_len = ((@intFromPtr(addr) + len + 4095) & ~@as(usize, 4095)) - aligned_addr;
    const prot: std.posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = true };
    _ = std.os.linux.mprotect(@ptrFromInt(aligned_addr), aligned_len, prot);
}

// -------------------------------------------------------------------------
// Pipe / Dup
// -------------------------------------------------------------------------

/// 32/64-bit lseek wrapper. Returns the new file position, or -1 on error.
pub fn lseek(fd: i32, offset: i64, whence: u32) i64 {
    if (comptime builtin.target.cpu.arch.isWasm()) return -1;
    if (@sizeOf(usize) == 8) {
        const rc = std.os.linux.lseek(fd, offset, whence);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return -1;
        return signed;
    } else {
        var result: u64 = 0;
        const rc = std.os.linux.llseek(fd, @bitCast(offset), &result, whence);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return -1;
        return @bitCast(result);
    }
}

test "lseek normalizes native errors and preserves file positions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(runtime.io(), "seek.bin", .{});
    defer file.close(runtime.io());

    try std.testing.expectEqual(@as(i64, 7), lseek(file.handle, 7, 0));
    try std.testing.expectEqual(@as(i64, -1), lseek(file.handle, -1, 0));
    try std.testing.expectEqual(@as(i64, 7), lseek(file.handle, 0, 1));
    try std.testing.expectEqual(@as(i64, -1), lseek(-1, 0, 0));
    try std.testing.expectEqual(@as(i64, -1), lseek(file.handle, 0, 3));

    const large_offset: i64 = 0x1_0000_0001;
    try std.testing.expectEqual(large_offset, lseek(file.handle, large_offset, 0));
    try std.testing.expectEqual(large_offset - 1, lseek(file.handle, -1, 1));
}

/// Creates a unidirectional data channel.
pub fn pipe() ![2]std.posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe(&fds);
    if (rc != 0) return error.PipeFailed;
    return fds;
}

/// Duplicates a file descriptor.
pub fn dup(fd: std.posix.fd_t) !std.posix.fd_t {
    const rc = std.os.linux.dup(fd);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.DupFailed;
    return @intCast(rc);
}

// -------------------------------------------------------------------------
// Signal Handler Setup
// -------------------------------------------------------------------------

const native_arch = builtin.target.cpu.arch;

// glibc-compatible REG indices into mcontext_t.gregs (see sys/ucontext.h).
// Kept in-tree because std.os.linux dropped these constants in 0.16.
pub const REG = if (native_arch == .x86) struct {
    pub const GS = 0;
    pub const FS = 1;
    pub const ES = 2;
    pub const DS = 3;
    pub const EDI = 4;
    pub const ESI = 5;
    pub const EBP = 6;
    pub const ESP = 7;
    pub const EBX = 8;
    pub const EDX = 9;
    pub const ECX = 10;
    pub const EAX = 11;
    pub const TRAPNO = 12;
    pub const ERR = 13;
    pub const EIP = 14;
    pub const CS = 15;
    pub const EFL = 16;
    pub const UESP = 17;
    pub const SS = 18;
} else struct {
    pub const R8 = 0;
    pub const R9 = 1;
    pub const R10 = 2;
    pub const R11 = 3;
    pub const R12 = 4;
    pub const R13 = 5;
    pub const R14 = 6;
    pub const R15 = 7;
    pub const RDI = 8;
    pub const RSI = 9;
    pub const RBP = 10;
    pub const RBX = 11;
    pub const RDX = 12;
    pub const RAX = 13;
    pub const RCX = 14;
    pub const RSP = 15;
    pub const RIP = 16;
    pub const EFL = 17;
    pub const CSGSFS = 18;
    pub const ERR = 19;
    pub const TRAPNO = 20;
    pub const OLDMASK = 21;
    pub const CR2 = 22;
};

// glibc-compatible ucontext_t as delivered by the kernel to signal handlers
// with SA_SIGINFO. Std removed the built-in wrapper in 0.16.
const greg_t = if (native_arch == .x86) u32 else usize;
const gregset_t = if (native_arch == .x86) [19]greg_t else [23]greg_t;

const fpregset_t_x86 = extern struct {
    cw: u32,
    sw: u32,
    tag: u32,
    ipoff: u32,
    cssel: u32,
    dataoff: u32,
    datasel: u32,
    st: [8]extern struct { significand: [4]u16, exponent: u16 },
    status: u32,
};

const fpregset_t_x86_64 = extern struct {
    cwd: u16,
    swd: u16,
    ftw: u16,
    fop: u16,
    rip: u64,
    rdp: u64,
    mxcsr: u32,
    mxcr_mask: u32,
    st: [8]extern struct { significand: [4]u16, exponent: u16, padding: [3]u16 },
    xmm: [16]extern struct { element: [4]u32 },
    padding: [24]u32,
};

pub const mcontext_t = if (native_arch == .x86) extern struct {
    gregs: gregset_t,
    fpregs: *fpregset_t_x86,
    oldmask: u32,
    cr2: u32,
} else extern struct {
    gregs: gregset_t,
    fpregs: *fpregset_t_x86_64,
    __reserved1: [8]u64,
};

pub const ucontext_t = extern struct {
    flags: usize,
    link: ?*ucontext_t,
    stack: std.posix.stack_t,
    mcontext: mcontext_t,
    sigmask: std.posix.sigset_t,
    fpregs_mem: if (native_arch == .x86) fpregset_t_x86 else fpregset_t_x86_64,
};

const reg_ip = if (native_arch == .x86) REG.EIP else @as(usize, REG.RIP);
const reg_sp = if (native_arch == .x86) REG.ESP else @as(usize, REG.RSP);
const reg_ax = if (native_arch == .x86) REG.EAX else @as(usize, REG.RAX);
const reg_cx = if (native_arch == .x86) REG.ECX else @as(usize, REG.RCX);
const reg_dx = if (native_arch == .x86) REG.EDX else @as(usize, REG.RDX);
const reg_bx = if (native_arch == .x86) REG.EBX else @as(usize, REG.RBX);
const reg_si = if (native_arch == .x86) REG.ESI else @as(usize, REG.RSI);
const reg_di = if (native_arch == .x86) REG.EDI else @as(usize, REG.RDI);
const reg_bp = if (native_arch == .x86) REG.EBP else @as(usize, REG.RBP);
const reg_fl = if (native_arch == .x86) REG.EFL else @as(usize, REG.EFL);

/// Central signal handler for memory faults (SIGSEGV/SIGBUS), illegal instructions (SIGILL),
/// and floating-point exceptions (SIGFPE) occurring during natively executed guest code.
///
/// This function translates Linux signals into Windows `EXCEPTION_RECORD` structures,
/// identifies whether the fault occurred in guest 32-bit code (CS=0x23) or host 64-bit code
/// (CS=0x33), and dispatches the exception to the guest's SEH chain (via INT 0xFE emulation)
/// or fatally crashes if the fault occurred within the emulator's host code.
fn sigsegvHandler(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    const uctx = @as(*ucontext_t, @ptrCast(@alignCast(ctx_ptr.?)));
    const fault_addr = @intFromPtr(info.fields.sigfault.addr);
    const ip: usize = @bitCast(uctx.mcontext.gregs[reg_ip]);

    // x86_64: check CS to determine if the fault is in guest (32-bit) or host (64-bit) code.
    // Guest faults (CS=0x23) need INT 0xFE dispatch and AppCompat/SEH handling.
    // Host faults (CS=0x33) should exit — they indicate bugs in Zig stubs.
    if (comptime is_x86_64) {
        const cs = @as(usize, @bitCast(uctx.mcontext.gregs[REG.CSGSFS])) & 0xFFFF;

        // INT 0xFE thunk detection or CPUID trap — works in both compat and 64-bit mode
        if (sig == std.posix.SIG.SEGV and ip != 0) {
            // Only read instruction bytes if IP is in a mapped code range
            const in_pool = if (compat_thunks.getPoolRange()) |r|
                (ip >= r[0] and ip < r[1])
            else
                false;
            if (in_pool or cs == 0x23) {
                const code = @as([*]const u8, @ptrFromInt(ip));
                if (code[0] == 0xCD and code[1] == 0xFE) {
                    const thunk_id = @as(*align(1) const u32, @ptrCast(code + 2)).*;
                    compat_thunks.dispatchFromSignal(uctx, thunk_id);
                    return;
                } else if (code[0] == 0x0F and code[1] == 0xA2) {
                    if (trace.enable_tracing) trace.print("CPUID TRAPPED!\n", .{});
                    // CPUID trapped! Emulate a basic Pentium Pro to appease MSVC6 heuristics
                    const leaf = @as(u32, @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_ax]))));
                    var eax: u32 = 0;
                    var ebx: u32 = 0;
                    var ecx: u32 = 0;
                    var edx: u32 = 0;
                    switch (leaf) {
                        0 => {
                            eax = 2;
                            ebx = 0x756E6547;
                            edx = 0x49656E69;
                            ecx = 0x6C65746E;
                        },
                        1 => {
                            eax = 0x00000633;
                            ebx = 0x00010800;
                            ecx = 0;
                            edx = (1 << 0) | (1 << 4) | (1 << 5) | (1 << 8) | (1 << 11) | (1 << 15) | (1 << 23) | (1 << 24) | (1 << 25) | (1 << 26);
                        },
                        else => {},
                    }
                    uctx.mcontext.gregs[reg_ax] = @bitCast(@as(usize, eax));
                    uctx.mcontext.gregs[reg_bx] = @bitCast(@as(usize, ebx));
                    uctx.mcontext.gregs[reg_cx] = @bitCast(@as(usize, ecx));
                    uctx.mcontext.gregs[reg_dx] = @bitCast(@as(usize, edx));
                    uctx.mcontext.gregs[reg_ip] = @bitCast(ip + 2);
                    return;
                }
            }
        }

        // 64-bit host code fault — not guest code.
        // Only exit for faults in the Zig binary itself (above 0x70000000).
        // Faults in the 0-0x70000000 range with CS=0x33 can happen during
        // callCompat32 nested signal handling — let them fall through to
        // AppCompat/SEH handlers which handle compat mode guest faults.
        if (cs != 0x23 and ip >= 0x70000000) {
            log.fatal("Segfault in host code at IP=0x{X}, fault_addr=0x{X}", .{ ip, fault_addr });
            exitProcess(1);
        }
    }

    // Handle SIGILL — dispatch through SEH like Wine does.
    // cpuidsdk's SEH handler catches EXCEPTION_ILLEGAL_INSTRUCTION and sets
    // EIP/registers appropriately. Only skip directly if no SEH handler exists.
    if (sig == std.posix.SIG.ILL) {
        var has_seh = false;
        if (teb.teb_base_addr != 0) {
            const seh_head = @as(*const u32, @ptrFromInt(teb.teb_base_addr)).*;
            if (seh_head != 0 and seh_head != 0xFFFFFFFF) has_seh = true;
        }
        if (!has_seh) {
            const seh_fs = readExceptionList();
            if (seh_fs != 0 and seh_fs != 0xFFFFFFFF) has_seh = true;
        }
        if (has_seh) {
            // Fall through to SEH dispatch below with EXCEPTION_ILLEGAL_INSTRUCTION
            log.info("AppCompat: SIGILL at 0x{X}, dispatching to SEH", .{ip});
        } else {
            // No SEH handler — skip the instruction directly
            const code = @as([*]const u8, @ptrFromInt(ip));
            var inst_len: usize = 2;
            if (code[0] == 0x0F) {
                if (code[1] == 0x3F) inst_len = 4 else if (code[1] == 0x37) inst_len = 2 else if (code[1] == 0x01) inst_len = 3;
            }
            log.info("AppCompat: SIGILL at 0x{X}, no SEH, skipping {d} bytes", .{ ip, inst_len });
            uctx.mcontext.gregs[reg_ip] = @bitCast(ip + inst_len);
            uctx.mcontext.gregs[reg_ax] = 0;
            uctx.mcontext.gregs[reg_dx] = 0;
            return;
        }
    }

    // Handle SIGFPE (divide by zero) in game or native DLL code — skip the instruction
    if (sig == std.posix.SIG.FPE) {
        const code = @as([*]const u8, @ptrFromInt(ip));
        // Determine instruction length: div/idiv are 2 bytes (F7 /6 or F7 /7 with modrm)
        var inst_len: usize = 2;
        if (code[0] == 0xF7) {
            const modrm = code[1];
            const mod = (modrm >> 6) & 3;
            const rm = modrm & 7;
            if (mod == 0 and rm == 5) inst_len += 4 // [disp32]
            else if (mod == 1) inst_len += 1 // [reg+disp8]
            else if (mod == 2) inst_len += 4; // [reg+disp32]
            if (rm == 4 and mod != 3) inst_len += 1; // SIB byte
        }
        log.info("AppCompat: SIGFPE at 0x{X}, skipping {d} bytes", .{ ip, inst_len });
        uctx.mcontext.gregs[reg_ip] = @bitCast(ip + inst_len);
        uctx.mcontext.gregs[reg_ax] = 0;
        uctx.mcontext.gregs[reg_dx] = 0;
        return;
    }

    const is_app_code = (ip >= runtime.app_code_start and ip < runtime.app_code_end);
    // Detect execution in PE data/BSS sections — this means a bad jump
    // (e.g., NULL function pointer from corrupt data). These should be
    // treated as crashes, not valid code.
    const is_pe_data = (ip >= runtime.app_code_end and ip < runtime.app_code_end + 0x200000 and ip >= 0x400000);
    // VirtualAlloc'd code (Delphi runtime, JIT trampolines) lives in the
    // low address space outside the main PE. Treat any mapped memory in
    // the 0x10000–0x70000000 range as potentially valid guest code.
    const is_guest_alloc = (ip >= 0x10000 and ip < 0x70000000 and !is_app_code and !is_pe_data);
    const is_native_dll = (ip >= 0x10000000 and ip < 0x30000000) or
        (ip >= 0xF0000000); // loaded DLLs (may be relocated)

    // Handle privileged I/O port instructions (IN/OUT) — skip directly.
    // These cause #GP on Linux (SIGSEGV). cpuidsdk.dll uses VMware's backdoor
    // I/O port for detection. Skipping with EAX=0 indicates "not VMware".
    // Only check for I/O instructions if IP is in known mapped memory.
    // IP might contain a corrupt value (e.g., path string "LER\") that
    // would crash when we try to read instruction bytes from it.
    const ip_in_known_range = (ip >= 0x400000 and ip < 0x900000) or // PE image
        (ip >= 0x20140000 and ip < 0x20200000) or // VirtualAlloc executable (trampolines)
        (ip >= 0x70000000 and ip < 0x80000000) or // Zig binary
        is_native_dll; // Loaded DLLs (e.g. at 0x10000000)
    if (sig == std.posix.SIG.SEGV and ip != 0 and ip_in_known_range) {
        const code = @as([*]const u8, @ptrFromInt(ip));
        const is_io = switch (code[0]) {
            0xEC, 0xED, 0xEE, 0xEF => true,
            0xE4, 0xE5, 0xE6, 0xE7 => true,
            else => false,
        };
        if (is_io) {
            const ilen: usize = switch (code[0]) {
                0xE4, 0xE5, 0xE6, 0xE7 => 2,
                else => 1,
            };
            log.info("AppCompat: I/O port at 0x{X}, skipping {d} bytes", .{ ip, ilen });
            uctx.mcontext.gregs[reg_ip] = @bitCast(ip + ilen);
            uctx.mcontext.gregs[reg_ax] = 0;
            return;
        }
    }
    const is_priv_instruction = false;
    // Check if IP is within the zine binary's code segment. We use the address
    // of this handler function as a reference point — all Zig-compiled stubs
    // (COM vtable methods, Win32 API stubs) are in the same binary and within
    // a ±64MB window. We can't use isNativeImport() because that only matches
    // exact function entry points, not instructions within functions.
    const zine_code_ref = @intFromPtr(&sigsegvHandler);
    const is_zine_code = (ip >= zine_code_ref -| (64 * 1024 * 1024)) and
        (ip < zine_code_ref + (64 * 1024 * 1024));
    // Handle clearly invalid IPs (null pointer, corrupt addresses like 0xAAAAAAAA).
    // Invalid IP (null, corrupt pointer, freed memory, etc.)
    // Try to recover by scanning the stack for a valid return address.
    // If recovery fails after a few tries, halt the thread.
    if (!ip_in_known_range and sig == std.posix.SIG.SEGV) {
        const InvalidIPState = struct {
            var recover_count: u32 = 0;
        };
        InvalidIPState.recover_count += 1;

        // Log full register state for debugging
        if (trace.enable_tracing) {
            const esp_dbg: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
            trace.print("AppCompat: Invalid IP=0x{X} (attempt {d})\n", .{ ip, InvalidIPState.recover_count });
            trace.print("  EAX=0x{X} EBX=0x{X} ECX=0x{X} EDX=0x{X}\n", .{
                @as(usize, @bitCast(uctx.mcontext.gregs[reg_ax])),
                @as(usize, @bitCast(uctx.mcontext.gregs[reg_bx])),
                @as(usize, @bitCast(uctx.mcontext.gregs[reg_cx])),
                @as(usize, @bitCast(uctx.mcontext.gregs[reg_dx])),
            });
            trace.print("  ESP=0x{X} EBP=0x{X} ESI=0x{X} EDI=0x{X}\n", .{
                esp_dbg,
                @as(usize, @bitCast(uctx.mcontext.gregs[reg_bp])),
                @as(usize, @bitCast(uctx.mcontext.gregs[reg_si])),
                @as(usize, @bitCast(uctx.mcontext.gregs[reg_di])),
            });
            // Dump top of stack
            if (esp_dbg > 0x10000 and esp_dbg < 0xFFFFF000) {
                var si: usize = 0;
                while (si < 16) : (si += 1) {
                    const sv = @as(*align(1) const u32, @ptrFromInt(esp_dbg + si * 4)).*;
                    trace.print("  stack[{d}] = 0x{X}\n", .{ si, sv });
                }
            }
        }

        if (InvalidIPState.recover_count <= 3) {
            const esp_r: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
            if (esp_r > 0x10000 and esp_r < 0xFFFFF000) {
                // Pop the return address (pushed by the CALL instruction)
                const ret_addr = @as(*align(1) const u32, @ptrFromInt(esp_r)).*;
                if (trace.enable_tracing) trace.print("  [ESP] = 0x{X}, app_code={d}\n", .{ ret_addr, @as(u8, if (ret_addr >= runtime.app_code_start and ret_addr < runtime.app_code_end) 1 else 0) });
                if (ret_addr >= runtime.app_code_start and ret_addr < runtime.app_code_end) {
                    uctx.mcontext.gregs[reg_sp] = @bitCast(esp_r + 4);
                    uctx.mcontext.gregs[reg_ax] = 0;
                    uctx.mcontext.gregs[reg_bx] = 0; // Clear corrupt EBX
                    uctx.mcontext.gregs[reg_ip] = ret_addr;
                    if (trace.enable_tracing) trace.print("AppCompat: Invalid IP=0x{X}, returning to caller 0x{X}\n", .{ ip, ret_addr });
                    return;
                }
            }
        }
        // Recovery exhausted — halt the thread but keep web server alive
        if (trace.enable_tracing) trace.print("AppCompat: Invalid IP=0x{X} — halting main thread\n", .{ip});
        while (true) {
            const req = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
            _ = std.os.linux.nanosleep(&req, null);
        }
    }

    if (ip != 0 and !is_app_code and !is_guest_alloc and !is_native_dll and !is_zine_code and sig != std.posix.SIG.ILL) {
        // Bad function pointer call from game code — try to recover
        const BadIPState = struct {
            var last_recover_addr: u32 = 0;
            var recover_count: u32 = 0;
        };
        const esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
        if (esp > 0x1000) {
            const stack = @as([*]const u32, @ptrFromInt(esp & ~@as(usize, 3)));
            // Find a return address, skipping addresses we've already tried
            var found_ret: ?u32 = null;
            var found_idx: usize = 0;
            for (0..200) |si| {
                const val = stack[si];
                if (val >= runtime.app_code_start and val < runtime.app_code_end) {
                    // Skip addresses in the same function we keep recovering to
                    if (BadIPState.last_recover_addr != 0 and
                        BadIPState.recover_count > 3)
                    {
                        // Skip addresses within ±1024 of previous recovery
                        const last = BadIPState.last_recover_addr;
                        if (val >= last -| 1024 and val <= last + 1024) continue;
                    }
                    if (found_ret == null) {
                        found_ret = val;
                        found_idx = si;
                    }
                    break; // Use first matching
                }
            }
            if (found_ret) |ret| {
                if (ret == BadIPState.last_recover_addr) {
                    BadIPState.recover_count += 1;
                } else {
                    BadIPState.last_recover_addr = ret;
                    BadIPState.recover_count = 1;
                }
                if (BadIPState.recover_count <= 20) {
                    if (trace.enable_tracing) trace.print("AppCompat: Bad IP=0x{X}, recovering to 0x{X} (count={d})\n", .{ ip, ret, BadIPState.recover_count });
                    uctx.mcontext.gregs[reg_ip] = ret;
                    uctx.mcontext.gregs[reg_sp] = @bitCast(esp + (found_idx + 1) * 4);
                    uctx.mcontext.gregs[reg_ax] = 0;
                    return;
                }
                // Too many recoveries — stop trying
                if (trace.enable_tracing) trace.print("AppCompat: Too many recoveries, giving up\n", .{});
            }
        }
        // True emulator crash — print diagnostics and exit
        log.fatal("Segfault in emulator code at IP=0x{X}, fault_addr=0x{X}", .{ ip, fault_addr });
        log.fatal("  EAX=0x{X} ECX=0x{X} EDX=0x{X} EBX=0x{X}", .{
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_ax])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_cx])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_dx])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_bx])),
        });
        log.fatal("  ESP=0x{X} EBP=0x{X} ESI=0x{X} EDI=0x{X}", .{
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_bp])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_si])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_di])),
        });
        const fatal_esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
        if (fatal_esp > 0x1000) {
            const stack = @as([*]const u32, @ptrFromInt(fatal_esp));
            log.fatal("  Stack (first 16):", .{});
            for (0..16) |si| {
                log.fatal("    [{d}] = 0x{X}", .{ si, stack[si] });
            }
        }
        exitProcess(1);
    }

    // AppCompat: Handle EIP=0 (null function pointer call or corrupted ret)
    if (ip == 0) {
        const esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
        if (esp > 0x1000) {
            // Walk the stack to find the first valid code address
            // App code is in 0x401000-0x6B0000, zine code is in 0x100000-0x300000
            // App code is in .text section (bounds from PE loader)
            // (.rdata starts at 0x662000 — must NOT jump there, it's data)
            const stack = @as([*]const u32, @ptrFromInt(esp & ~@as(usize, 3)));
            log.warn("AppCompat: EIP=0 fault. Stack walk:", .{});
            var found_ret: ?u32 = null;
            var found_idx: usize = 0;
            for (0..200) |si| {
                const val = stack[si];
                if (val >= runtime.app_code_start and val < runtime.app_code_end) {
                    if (found_ret == null) {
                        found_ret = val;
                        found_idx = si;
                    }
                    if (si < 10 or found_ret != null) {
                        log.warn("  stack[{d}] = 0x{X} <app>", .{ si, val });
                    }
                } else if (si < 10) {
                    log.warn("  stack[{d}] = 0x{X}", .{ si, val });
                }
            }
            if (found_ret) |ret| {
                log.info("AppCompat: Recovering to app code 0x{X} (stack[{d}])", .{ ret, found_idx });
                uctx.mcontext.gregs[reg_ip] = ret;
                uctx.mcontext.gregs[reg_sp] = @bitCast(esp + (found_idx + 1) * 4);
                uctx.mcontext.gregs[reg_ax] = 0;
                return;
            }
        }
    }

    // Early re-entrancy check: if we're already inside RaiseException's SEH
    // dispatch and the handler itself faults, signal the fault and skip the
    // instruction. Do NOT go through the NULL loop detector or AppCompat shims.
    {
        if (kernel32_error.raise_exception_depth > 0) {
            kernel32_error.handler_faulted = true;
            // Skip the faulting instruction to let the handler return
            if (ip != 0 and ip < 0x70000000) {
                const ptr2 = @as([*]const u8, @ptrFromInt(ip));
                const skip2: usize = if (ptr2[0] == 0x89 or ptr2[0] == 0x8B) blk2: {
                    const modrm2 = ptr2[1];
                    const mod2 = (modrm2 >> 6) & 3;
                    const rm2 = modrm2 & 7;
                    var s: usize = 2;
                    if (rm2 == 4 and mod2 != 3) s += 1;
                    if (mod2 == 1) s += 1 else if (mod2 == 2 or (mod2 == 0 and rm2 == 5)) s += 4;
                    break :blk2 s;
                } else 2;
                uctx.mcontext.gregs[reg_ip] += @intCast(skip2);
                if (ptr2[0] == 0x8B) uctx.mcontext.gregs[@as(usize, (ptr2[1] >> 3) & 7)] = 0;
            }
            return;
        }
    }

    // AppCompat: skip Delphi @LStrCmp reads from corrupt string pointers.
    // When a Delphi object has an uninitialized string field pointing to
    // unmapped memory, the string comparison crashes. Skip the length read
    // and return 0 (empty string) so the comparison fails gracefully.
    if (fault_addr >= 0x1000 and is_app_code and sig == std.posix.SIG.SEGV) {
        const ptr3 = @as([*]const u8, @ptrFromInt(ip));
        // MOV EAX, [ESI-4]  (8B 46 FC) — Delphi @LStrCmp string length
        // MOV EDX, [EDI-4]  (8B 57 FC) — second string length
        if (ptr3[0] == 0x8B and (ptr3[2] == 0xFC) and
            ((ptr3[1] == 0x46) or (ptr3[1] == 0x57)))
        {
            const reg3 = (ptr3[1] >> 3) & 7;
            const dest: usize = switch (reg3) {
                0 => reg_ax,
                2 => reg_dx,
                else => reg_ax,
            };
            uctx.mcontext.gregs[dest] = 0;
            uctx.mcontext.gregs[reg_ip] += 3;
            return;
        }

        // AppCompat: Auto-commit pages within known VirtualAlloc reservations.
        // Only commit pages in the legitimate VirtualAlloc range (0x20000000+).
        if (fault_addr >= 0x20000000 and fault_addr < 0x50000000) {
            const page_addr = fault_addr & ~@as(usize, 0xFFF);
            const result = std.posix.mmap(
                @ptrFromInt(page_addr),
                4096,
                .{ .READ = true, .WRITE = true, .EXEC = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
                -1,
                0,
            ) catch null;
            if (result != null) {
                if (trace.enable_tracing) trace.print("AppCompat: Auto-committed page at 0x{X} for fault at IP=0x{X}\n", .{ page_addr, ip });
                return;
            }
        }
    }

    // Track repeated faults at the same IP to detect infinite loops.
    const S = struct {
        var last_null_ip: usize = 0;
        var null_repeat_count: u32 = 0;
    };

    const skip_appcompat_null = blk: {
        if (fault_addr < 0x1000 and ip != 0 and is_app_code) {
            // For null+offset faults (e.g., [NULL+0x74]), always use AppCompat handler
            // rather than deferring to SEH. Games often have null struct pointers with
            // field offsets that their SEH handlers don't handle properly. Skipping the
            // instruction and zeroing the destination register is the safer recovery.
            if (fault_addr > 0) break :blk false;
            if (ip == S.last_null_ip) {
                S.null_repeat_count += 1;
                if (S.null_repeat_count > 3) break :blk false;
            } else {
                S.last_null_ip = ip;
                S.null_repeat_count = 1;
            }
            const seh_check = readExceptionList();
            break :blk (seh_check != 0 and seh_check != 0xFFFFFFFF);
        }
        break :blk false;
    };

    if (!skip_appcompat_null) {
        if (fault_addr < 0x1000 and ip != 0) {
            if (S.null_repeat_count > 50) {
                const msg = "NULL read loop, aborting.\n";
                _ = std.os.linux.write(2, msg.ptr, msg.len);
                exitProcess(1);
            }
        }
        if (fault_addr < 0x1000 and ip != 0) {
            const ptr = @as([*]u8, @ptrFromInt(ip));

            // F2 AE = repnz scasb (strlen pattern: ecx=-1, al=0, scan es:[edi])
            // When EDI is in the NULL page, simulate scanning an empty string:
            // one iteration finds the null terminator, so ecx goes -1 → -2.
            if (ptr[0] == 0xF2 and ptr[1] == 0xAE) {
                log.info("AppCompat: Skipped NULL repnz scasb at 0x{X} (edi=0x{X})", .{ ip, @as(usize, @bitCast(uctx.mcontext.gregs[reg_di])) });
                uctx.mcontext.gregs[reg_cx] = @bitCast(@as(isize, -2)); // as if one byte scanned
                uctx.mcontext.gregs[reg_di] = 1; // edi advanced past the "null terminator"
                uctx.mcontext.gregs[reg_ip] += 2; // skip F2 AE
                return;
            }

            // ff 51 XX (call [ecx+disp8]) or ff 52 XX (call [edx+disp8])
            if ((ptr[0] == 0xFF and (ptr[1] & 0xF8) == 0x50)) {
                log.info("AppCompat: Skipped NULL pointer call at 0x{X} ({X} {X} {X})", .{ ip, ptr[0], ptr[1], ptr[2] });
                uctx.mcontext.gregs[reg_ip] += 3;
                uctx.mcontext.gregs[reg_sp] += if (native_arch == .x86) 4 else 8;
                return;
            }

            // Generic x86 NULL-pointer read/write skip.  We decode the ModR/M
            // (and optional SIB) byte to figure out how many bytes to skip.
            //
            // Reads:  8A (mov r8, [r/m])   8B (mov r32, [r/m])
            //         3B (cmp r32, [r/m])
            // Writes: 88/89 (mov [r/m], reg)  C6/C7 (mov [r/m], imm)
            //         01/09/21/29/31 (alu [r/m], reg)
            const maybe_opcode = ptr[0];

            const is_read = switch (maybe_opcode) {
                0x8A, 0x8B => true, // mov reg, [r/m] (8/32 bit)
                0x3B => true, // cmp reg, [r/m]
                else => false,
            };
            const is_store = switch (maybe_opcode) {
                0x88, 0x89 => true, // mov [r/m], reg8/32
                0xC6, 0xC7 => true, // mov [r/m], imm8/imm32
                0x01 => true, // add [r/m], reg
                0x29 => true, // sub [r/m], reg
                0x09 => true, // or  [r/m], reg
                0x21 => true, // and [r/m], reg
                0x31 => true, // xor [r/m], reg
                else => false,
            };

            if ((is_read or is_store) and ptr[1] & 0xC0 != 0xC0) { // Not reg-to-reg (mod != 11)
                const modrm = ptr[1];
                const mod_field = (modrm >> 6) & 3;
                const rm_field = modrm & 7;
                const reg_field = (modrm >> 3) & 7;
                // Base instruction length: opcode(1) + modrm(1)
                var skip: usize = 2;
                // SIB byte present when rm == 4 and mod != 3
                if (rm_field == 4 and mod_field != 3) skip += 1;
                // Displacement
                if (mod_field == 0 and rm_field == 5) {
                    skip += 4; // [disp32]
                } else if (mod_field == 1) {
                    skip += 1; // [reg+disp8]
                } else if (mod_field == 2) {
                    skip += 4; // [reg+disp32]
                }
                // Immediate (for C6/C7)
                if (maybe_opcode == 0xC6) skip += 1;
                if (maybe_opcode == 0xC7) skip += 4;

                if (is_read) {
                    // Zero the destination register (from reg field of ModR/M)
                    const dest_reg_idx: usize = switch (reg_field) {
                        0 => reg_ax,
                        1 => reg_cx,
                        2 => reg_dx,
                        3 => reg_bx,
                        4 => reg_sp,
                        5 => reg_bp,
                        6 => reg_si,
                        7 => reg_di,
                        else => unreachable,
                    };
                    uctx.mcontext.gregs[dest_reg_idx] = 0;
                    log.info("AppCompat: Skipped NULL pointer read at 0x{X} (reg={d})", .{ ip, reg_field });
                } else {
                    log.info("AppCompat: Skipped NULL pointer write at 0x{X}", .{ip});
                }
                uctx.mcontext.gregs[reg_ip] += @intCast(skip);
                return;
            }
        }
    } // end if (!skip_appcompat_null)

    const exc_code: u32 = if (sig == std.posix.SIG.ILL)
        0xC000001D // EXCEPTION_ILLEGAL_INSTRUCTION
    else if (is_priv_instruction)
        0xC0000096 // EXCEPTION_PRIV_INSTRUCTION
    else
        0xC0000005; // EXCEPTION_ACCESS_VIOLATION

    // Save hardware context for RaiseException's SEH dispatch
    const raise_addr = @intFromPtr(&kernel32_error.RaiseException);

    // Fill a static CONTEXT with the faulting register state
    const hw_ctx = &(struct {
        var ctx: teb.CONTEXT = undefined;
    }).ctx;
    @memset(std.mem.asBytes(hw_ctx), 0);
    hw_ctx.ContextFlags = 0x10007;
    hw_ctx.Eax = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_ax])));
    hw_ctx.Ecx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_cx])));
    hw_ctx.Edx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_dx])));
    hw_ctx.Ebx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_bx])));
    hw_ctx.Esi = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_si])));
    hw_ctx.Edi = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_di])));
    hw_ctx.Ebp = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_bp])));
    hw_ctx.Esp = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])));
    hw_ctx.Eip = @truncate(ip);
    hw_ctx.EFlags = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_fl])));
    kernel32_error.saved_hw_context = hw_ctx;

    // Push RaiseException args on the guest stack (stdcall: right-to-left).
    // Verify ESP is in a plausible mapped range before writing to avoid
    // crashing the signal handler itself.
    var esp: u32 = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])));
    if (esp < 0x10000) {
        log.fatal("SEH dispatch: ESP=0x{X} out of range at IP=0x{X}", .{ esp, ip });
        exitProcess(1);
    }
    // Align ESP to 4 bytes (compat mode may have misaligned ESP)
    esp &= ~@as(u32, 3);
    esp -= 4;
    @as(*align(1) u32, @ptrFromInt(esp)).* = 0; // lpArguments = NULL
    esp -= 4;
    @as(*align(1) u32, @ptrFromInt(esp)).* = 0; // nNumberOfArguments = 0
    esp -= 4;
    @as(*align(1) u32, @ptrFromInt(esp)).* = 0; // dwExceptionFlags = 0
    esp -= 4;
    @as(*align(1) u32, @ptrFromInt(esp)).* = exc_code; // dwExceptionCode
    esp -= 4;
    @as(*align(1) u32, @ptrFromInt(esp)).* = @truncate(ip); // fake return address

    // Set signal context to call RaiseException when signal handler returns.
    // On x86_64, set CS=0x33 since RaiseException is 64-bit Zig code and
    // the fault may have been in 32-bit compat mode (CS=0x23).
    uctx.mcontext.gregs[reg_sp] = esp;
    uctx.mcontext.gregs[reg_ip] = @truncate(raise_addr);
    if (comptime is_x86_64) {
        const csgsfs: usize = @bitCast(uctx.mcontext.gregs[REG.CSGSFS]);
        uctx.mcontext.gregs[REG.CSGSFS] = @bitCast((csgsfs & ~@as(usize, 0xFFFF)) | 0x33);
    }

    if (trace.enable_tracing) trace.print("SEH: Redirecting to RaiseException(code={x}) for exception at 0x{X}, fault_addr=0x{X}, EAX=0x{X} EBX=0x{X} ECX=0x{X} EDX=0x{X} ESI=0x{X} EDI=0x{X} ESP=0x{X} EBP=0x{X}\n", .{
        exc_code,                                          ip,                                                fault_addr,
        @as(usize, @bitCast(uctx.mcontext.gregs[reg_ax])), @as(usize, @bitCast(uctx.mcontext.gregs[reg_bx])), @as(usize, @bitCast(uctx.mcontext.gregs[reg_cx])),
        @as(usize, @bitCast(uctx.mcontext.gregs[reg_dx])), @as(usize, @bitCast(uctx.mcontext.gregs[reg_si])), @as(usize, @bitCast(uctx.mcontext.gregs[reg_di])),
        @as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])), @as(usize, @bitCast(uctx.mcontext.gregs[reg_bp])),
    });
    return;
}

/// Install the SIGSEGV/SIGFPE handler.
pub fn installSegfaultHandler() void {
    // SA_NODEFER allows the signal to be delivered while its handler is running.
    // This is required for x86_64 compat mode: callCompat32 enters compat mode
    // via iretq, and nested INT 0xFE signals must be delivered within the
    // handler context (e.g., DllMain -> _initterm -> callCompat32 -> init func).
    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = &sigsegvHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.NODEFER,
    };
    std.posix.sigaction(std.posix.SIG.SEGV, &act, null);
    std.posix.sigaction(std.posix.SIG.FPE, &act, null);
    std.posix.sigaction(std.posix.SIG.ILL, &act, null);

    if (comptime is_x86_64 and builtin.os.tag == .linux) {
        _ = std.os.linux.prctl(38, 1, 0, 0, 0); // PR_SET_NO_NEW_PRIVS
        _ = std.os.linux.syscall2(std.os.linux.SYS.arch_prctl, 0x1012, 0); // ARCH_SET_CPUID
    }
}

/// Map the null page for compatibility (may fail due to mmap_min_addr).
pub fn mapNullPage() void {
    _ = std.posix.mmap(
        @ptrFromInt(0),
        4096,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1,
        0,
    ) catch |e| {
        // Non-fatal: some programs work without NULL page mapping, but
        // Delphi apps that read NULL pointers will segfault without it.
        log.warn("failed to map null page (mmap_min_addr?): {} — Delphi NULL reads may crash", .{e});
    };
}

/// Increase the stack rlimit to avoid C1063.
pub fn raiseStackLimit() void {
    if (@hasDecl(std.posix, "getrlimit")) {
        if (std.posix.getrlimit(.STACK)) |rlim| {
            var new_rlim = rlim;
            new_rlim.cur = rlim.max;
            _ = std.posix.setrlimit(.STACK, new_rlim) catch |e| {
                log.warn("failed to raise stack limit: {} — deep recursion (MSVC _chkstk) may fail", .{e});
            };
        } else |_| {}
    }
}
