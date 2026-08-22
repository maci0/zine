const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");

/// Miscellaneous MSVCRT stubs: rand/srand, qsort, bsearch, errno,
/// setlocale, _strupr, abs, and generic no-op/ignore stubs.
/// Implementation status: Partially implemented
pub fn log_call(comptime name: []const u8) void {
    if (trace.enable_tracing) trace.print("MSVCRT: {s}\n", .{name});
}

var rand_seed: u32 = 1;

/// --- rand / srand (MSVC LCG) ---
/// Implementation status: Partially implemented
pub fn srand(seed: u32) callconv(.c) void {
    rand_seed = seed;
    if (trace.enable_tracing) trace.print("MSVCRT: srand({d})\n", .{seed});
}

/// rand
/// Implementation status: Partially implemented
pub fn rand() callconv(.c) i32 {
    rand_seed = rand_seed *% 214013 +% 2531011;
    const result = @as(i32, @intCast((rand_seed >> 16) & 0x7fff));
    if (trace.enable_tracing) trace.print("MSVCRT: rand() -> {d}\n", .{result});
    return result;
}

/// stub_ignore_i32
/// Implementation status: Stub
pub fn stub_ignore_i32() callconv(.c) i32 {
    if (trace.enable_tracing) {
        trace.print("MSVCRT: ignored call (i32) from 0x{X}\n", .{@returnAddress()});
    }
    return 0;
}

/// stub_ignore_ptr
/// Implementation status: No-op fallback
pub fn stub_ignore_ptr() callconv(.c) ?*anyopaque {
    const ra = @returnAddress();
    if (trace.enable_tracing) trace.print("MSVCRT: ignored call (ptr) from 0x{X}\n", .{ra});
    return null;
}

/// --- qsort / bsearch ---
/// Implementation status: Partially implemented

/// Call a guest comparator function (int (*)(const void*, const void*)).
/// On native x86 the guest code lives at the host address and can be called
/// directly; on x86_64 it runs via the compat dispatcher; on WASM it must be
/// executed by the x86 interpreter (a guest function pointer is not a valid
/// WASM indirect-call index — calling it directly traps with "out of bounds
/// table access").
// Reused guest stack for the nested comparator interpreter runs. The runs are
// strictly sequential (the comparator returns before the next call), so a single
// 64KB stack region is safe. Allocating a fresh 64KB stack per call made LINK's
// qsort/bsearch (thousands of comparisons) exhaust the guest heap → LNK1102.
var comparator_stack_va: u32 = 0;
var comparator_stack_owner: ?*const anyopaque = null;

fn callComparator(compare_ptr: usize, a: usize, b: usize) i32 {
    // Direct call only on native 32-bit x86 (guest code IS host code there).
    // On native x86_64 the 32-bit guest function MUST run via the compat
    // dispatcher (CS=0x23) — a direct 64-bit call executes the 32-bit
    // machine code in long mode, misdecoding `mov (%eax),%esi` as a 64-bit
    // `mov (%rax),%rsi` and reading garbage (LINK "ReadSymbolTable" crash).
    if (comptime @import("../../platform.zig").is_x86) {
        const compare = @as(*const fn (usize, usize) callconv(.c) i32, @ptrFromInt(compare_ptr));
        return compare(a, b);
    }
    if (comptime @import("../../platform.zig").is_x86_64) {
        return @bitCast(@import("../../x86/compat_thunks.zig").callCompat32_4(@truncate(compare_ptr), @truncate(a), @truncate(b), 0, 0));
    }
    // WASM: run the comparator on a fresh interpreter CPU sharing guest memory.
    const x86_cpu = @import("../../x86/cpu.zig");
    const x86_execute = @import("../../x86/execute.zig");
    const shared = @import("../shared.zig");
    const teb_mod = @import("../teb.zig");
    const stack_size: u32 = 64 * 1024;
    // Lazily allocate the stack from the GLOBAL guest memory (once per guest
    // memory instance), then copy the (now advanced) GuestMemory state into the
    // temp CPU. Copying first and allocating on the copy would bump a stale
    // heap cursor, so the comparator's own mallocs (which use the global) could
    // collide with this stack.
    const owner = @as(?*const anyopaque, @ptrCast(shared.guest_memory));
    if (comparator_stack_owner != owner) {
        comparator_stack_va = if (shared.guest_memory) |gm| gm.guestAlloc(stack_size) else 0;
        comparator_stack_owner = owner;
    }
    if (comparator_stack_va == 0) return 0;
    var cpu = x86_cpu.Cpu{};
    if (shared.guest_memory) |gm| cpu.memory = gm.*;
    if (teb_mod.teb_base_addr != 0) cpu.fs_base = @intCast(teb_mod.teb_base_addr);
    // Use a HLT byte as the return address so the interpreter halts cleanly
    // (EIP 0 logs a spurious "out of bounds" error and is noisier).
    const halt_va = cpu.memory.guestAlloc(1);
    if (halt_va == 0) return 0;
    cpu.memory.write8(halt_va, 0xF4); // HLT
    cpu.esp = comparator_stack_va + stack_size - 16;
    // cdecl: push args right-to-left, then the return address (halts).
    cpu.push32(@intCast(b));
    cpu.push32(@intCast(a));
    cpu.push32(@intCast(halt_va));
    cpu.eip = @intCast(compare_ptr);
    x86_execute.run(&cpu);
    return @bitCast(cpu.eax);
}

pub fn qsort(base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) void {
    if (base == 0 or num == 0 or width == 0 or compare_ptr == 0) return;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        var j: usize = i + 1;
        while (j < num) : (j += 1) {
            const ap = base + i * width;
            const bp = base + j * width;
            const cmp = callComparator(compare_ptr, ap, bp);
            if (cmp > 0) {
                var k: usize = 0;
                while (k < width) : (k += 1) {
                    const a = @as(*u8, @ptrFromInt(trace.addr(ap + k)));
                    const b = @as(*u8, @ptrFromInt(trace.addr(bp + k)));
                    const t = a.*;
                    a.* = b.*;
                    b.* = t;
                }
            }
        }
    }
}

/// bsearch
/// Implementation status: Partially implemented
pub fn bsearch(key: usize, base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) usize {
    if (key == 0 or base == 0 or num == 0 or width == 0 or compare_ptr == 0) return 0;
    const trace_mod = @import("../../trace.zig");
    if (trace_mod.enable_tracing) trace_mod.print("MSVCRT: bsearch(key={x}, base={x}, num={d}, width={d}, cmp={x})\n", .{ key, base, num, width, compare_ptr });
    var lo: usize = 0;
    var hi: usize = num;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const item = base + mid * width;
        const cmp = callComparator(compare_ptr, key, item);
        if (cmp == 0) return item;
        if (cmp < 0) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return 0;
}

/// --- errno ---
/// Returns a pointer to the errno value. On WASM, returns a guest VA
/// so the x86 interpreter can dereference it.
pub fn errno() callconv(.c) *i32 {
    // On WASM, use guest globals slot so x86 code can dereference
    const process = @import("process.zig");
    const g = process.ensureGuestGlobals();
    if (g != 0) {
        const shared = @import("../shared.zig");
        if (shared.guest_memory) |gmem| {
            // Sync host errno into guest slot
            const off = g + process.g_errno - gmem.base_addr;
            @as(*align(1) i32, @ptrCast(gmem.base[off..][0..4].ptr)).* = msvcrt.msvcrt_errno_val;
            return @ptrCast(@alignCast(gmem.base[off..][0..4].ptr));
        }
    }
    return &msvcrt.msvcrt_errno_val;
}

var setlocale_buf: [2]u8 = .{ 'C', 0 };

/// --- Locale ---
/// Returns a pointer to the locale string. On WASM, returns a guest VA.
pub fn setlocale(category: i32, locale: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (trace.enable_tracing) {
        if (locale) |loc| {
            trace.print("MSVCRT: setlocale({d}, '{s}')\n", .{ category, std.mem.span(loc) });
        } else {
            trace.print("MSVCRT: setlocale({d}, NULL)\n", .{category});
        }
    }
    // On WASM, return from guest globals slot
    const process = @import("process.zig");
    const g = process.ensureGuestGlobals();
    if (g != 0) {
        const shared = @import("../shared.zig");
        if (shared.guest_memory) |gmem| {
            const off = g + process.g_setlocale - gmem.base_addr;
            return @ptrCast(gmem.base[off..].ptr);
        }
    }
    return @ptrCast(&setlocale_buf);
}

/// strupr
/// Implementation status: Partially implemented
pub fn strupr(s: [*]u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (s[i] != 0 and i < 0x100000) : (i += 1) {
        if (s[i] >= 'a' and s[i] <= 'z') s[i] -= 32;
    }
    return s;
}

/// Converts a multibyte character to a wide character (ANSI/ASCII subset).
/// c1.dll uses this to encode wide string literals — a no-op returning 0 made
/// every `L"..."` literal decode as an empty/garbage string in the .obj.
///
/// Returns the number of bytes consumed (1 for single-byte), 0 for the null
/// character, -1 on invalid input. With `s == NULL`, reports whether the
/// encoding has shift state (0 for single-byte encodings).
pub fn mbtowc(pwc: ?[*]u16, s: ?[*]const u8, n: usize) callconv(.c) i32 {
    if (trace.enable_tracing) {
        const pwc_addr: usize = if (pwc) |p| @intFromPtr(p) else 0;
        const s_addr: usize = if (s) |p| @intFromPtr(p) else 0;
        trace.print("MSVCRT: mbtowc(pwc={x}, s={x}, n={d})\n", .{ pwc_addr, s_addr, n });
    }
    if (s == null) return 0; // Single-byte encoding: no shift state
    if (n == 0) return -1;
    const ch = s.?[0];
    if (ch == 0) {
        if (pwc) |wc| wc[0] = 0;
        return 0;
    }
    if (pwc) |wc| wc[0] = ch;
    return 1;
}

/// --- Simple stubs ---
/// Implementation status: Partially implemented
pub fn abs(n: i32) callconv(.c) i32 {
    return if (n < 0) -n else n;
}

/// stub_noop0
/// Implementation status: Stub
pub fn stub_noop0() callconv(.c) void {}
/// stub_noop1
/// Implementation status: Stub
pub fn stub_noop1(_: usize) callconv(.c) void {}
/// stub_noop3
/// Implementation status: Stub
pub fn stub_noop3(_: usize, _: usize, _: usize) callconv(.c) void {}
