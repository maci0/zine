//! x86 thunking and Win32 API bridge.
//!
//! This module manages the registration and execution of "thunks" — short
//! x86 code sequences that transition from guest code to native host
//! functions (Win32 API stubs). It provides:
//!   - registerThunk(): registration of stub functions by thunk ID
//!   - dispatch(): called from execute.zig when INT 0xFE is hit
//!   - writeThunkCode(): generate thunk code in guest memory

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const profiler = @import("../profiler.zig");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const runtime = @import("../runtime.zig");
const Cpu = cpu_mod.Cpu;

/// A registered thunk entry.
pub const ThunkEntry = struct {
    /// Name of the import (for logging).
    name: []const u8,
    /// Number of stdcall parameters (for ESP adjustment).
    /// If null, the stub manages ESP itself.
    param_count: ?u8,
    /// The stub function to call.  Receives a pointer to the CPU
    /// so it can read arguments from the guest stack and write
    /// the return value to EAX.
    handler: *const fn (*Cpu) void,
    /// Native function address (WASM function table index or host pointer).
    /// Used by dispatchNativeThunk to call the actual stub.
    native_addr: usize = 0,
    /// Stdcall param bytes (n_params * 4) for native dispatch.
    native_param_bytes: u32 = 0,
    /// Whether the native function uses cdecl (true) or stdcall (false).
    native_is_cdecl: bool = false,
    /// Number of fixed params for variadic functions (0 = not variadic).
    /// For variadic stubs like printf(fmt, ap), this is the number of
    /// guest-visible fixed params (e.g., 1 for printf). The dispatch
    /// passes a pointer to the remaining guest stack args as the last arg.
    native_va_fixed: u8 = 0,
};

/// Maximum number of thunks. Canonical value lives in `runtime.zig`.
pub const MAX_THUNKS = runtime.MAX_THUNKS;

/// Global thunk table (populated during PE loading).
var thunk_entries: [MAX_THUNKS]?ThunkEntry = @splat(null);
var thunk_count: u32 = 0;

/// Capacity of the _initterm callback queue. The queue holds whatever the
/// guest's .CRT init section lists, so its size scales with the number of
/// translation units in the PE, not with anything the emulator controls. The
/// old 64 entries were dropped silently enough to look like a run that just
/// behaved oddly: a dropped entry is a static constructor that never runs. A
/// MSVC 6 CRT section runs to a few hundred entries, so this leaves several
/// times that headroom; the trampoline that consumes the queue emits five
/// bytes per entry, which the guest heap absorbs.
const max_initterm_callbacks = 4096;

/// Shared _initterm callback queue (WASM only).
///
/// On WASM, _initterm collects guest x86 function addresses here.
/// After the stub returns, x86/execute.zig reads them to build a
/// trampoline.
pub var pending_initterm_callbacks: [max_initterm_callbacks]u32 = @as([max_initterm_callbacks]u32, @splat(0));
pub var pending_initterm_count: usize = 0;

pub fn queueInittermCallback(addr: u32) void {
    if (pending_initterm_count < pending_initterm_callbacks.len) {
        pending_initterm_callbacks[pending_initterm_count] = addr;
        pending_initterm_count += 1;
    } else {
        log.warn("x86 thunks: _initterm queue full, dropping callback 0x{X}", .{addr});
    }
}

/// Look up a thunk entry by ID (used by compat_thunks signal dispatcher).
pub fn getEntry(id: u32) ?*const ThunkEntry {
    if (id >= MAX_THUNKS) return null;
    return if (thunk_entries[id]) |*entry| entry else null;
}

/// Register a thunk and return its ID.
pub fn registerThunk(entry: ThunkEntry) u32 {
    if (thunk_count >= MAX_THUNKS) {
        // Returning an ID is mandatory, and 0 is a live thunk: a "full"
        // return of 0 would alias the first registration and silently
        // dispatch every later import to it. Abort instead.
        log.fatal("x86 thunks: thunk table full ({d} entries)", .{MAX_THUNKS});
        std.process.exit(1);
    }
    const id = thunk_count;
    thunk_entries[id] = entry;
    thunk_count += 1;
    profiler.registerThunkName(id, entry.name);
    return id;
}

/// Write thunk code into guest memory at `addr`.
/// Returns the address after the thunk (for chaining).
///
/// Thunk format (6 bytes):
///   CD FE     INT 0xFE
///   xx xx xx xx  (little-endian thunk_id)
pub fn writeThunkCode(memory: *cpu_mod.GuestMemory, addr: u32, thunk_id: u32) u32 {
    memory.write8(addr, 0xCD);
    memory.write8(addr +% 1, 0xFE);
    memory.write32(addr +% 2, thunk_id);
    return addr +% 6;
}

/// Dispatch a thunk call from the interpreter.
/// Called when INT 0xFE is executed.  EIP points past the INT 0xFE
/// opcode (2 bytes) to the 4-byte thunk ID that follows it.
/// We read the thunk ID from EIP and advance past it.
pub fn dispatch(cpu: *Cpu) void {
    // Read thunk_id from code stream (4 bytes after INT 0xFE)
    const thunk_id = cpu.memory.read32(cpu.eip);
    cpu.eip +%= 4;

    if (thunk_id >= MAX_THUNKS) {
        log.err("x86 thunks: invalid thunk ID {d}", .{thunk_id});
        cpu.halted = true;
        return;
    }

    if (thunk_entries[thunk_id]) |entry| {
        profiler.tickThunk(thunk_id);

        if (trace.enable_tracing) {
            trace.print("THUNK EXEC: {s}\n", .{entry.name});
        }

        // Stash the guest ESP/EBP so RaiseException can run WASM SEH handlers
        // on the app's own stack (this thunk path is how WASM imports dispatch).
        if (comptime !@import("../platform.zig").is_native) {
            const except_mod = @import("../win32/msvcrt/except.zig");
            except_mod.seh_current_guest_esp = cpu.esp;
            except_mod.seh_current_guest_ebp = cpu.ebp;
        }

        entry.handler(cpu);

        // On WASM, a host-side _except_handler3 that accepted sets a redirect —
        // apply it to this CPU instead of resuming at the import's return
        // address (the catch block continues the app from there).
        if (comptime !@import("../platform.zig").is_native) {
            const except_mod = @import("../win32/msvcrt/except.zig");
            if (except_mod.wasm_seh_redirect) |rd| {
                except_mod.wasm_seh_redirect = null;
                cpu.eip = rd.eip;
                cpu.esp = rd.esp;
                cpu.ebp = rd.ebp;
                return;
            }
        }

        // For stdcall: callee pops parameters
        if (entry.param_count) |n| {
            cpu.esp +%= @as(u32, n) * 4;
        }

        // On WASM, _initterm collects guest init function addresses.
        // Build an x86 trampoline to execute them before returning
        // to the guest CRT startup code.
        if (comptime !@import("../platform.zig").is_native) {
            if (pending_initterm_count > 0) {
                @import("execute.zig").buildInittermTrampoline(cpu);
            }
        }
    } else {
        log.err("x86 thunks: unregistered thunk ID {d}", .{thunk_id});
        cpu.halted = true;
    }
}

/// Convenience: read a stdcall parameter from the guest stack.
/// Parameter 0 is at [ESP+0] (after the return address has been consumed
/// by CALL → INT 0xFE sequence), parameter 1 at [ESP+4], etc.
pub fn readParam(cpu: *const Cpu, index: u32) u32 {
    return cpu.memory.read32(cpu.esp +% index * 4);
}

/// Reset the thunk tables (for testing). The import registry goes with the
/// thunk table: isNativeImport consults it on every interpreted instruction,
/// so entries a test registered would otherwise outlive it and answer for an
/// address the rest of the run never registered.
pub fn reset() void {
    thunk_entries = @splat(null);
    thunk_count = 0;
    import_count = 0;
    imports_sorted = false;
    import_filter = @as([FILTER_WORDS]u64, @splat(0));
}

// -----------------------------------------------------------------------
// Native thunk dispatch for WASM
// -----------------------------------------------------------------------
// On WASM, we can't jump to native function pointers from guest x86 code.
// Instead, each import gets an INT 0xFE thunk in guest memory. When the
// thunk fires, dispatchNativeThunk reads args from the guest stack and
// calls the native function.

/// Register a native function as a thunk and return the thunk ID.
pub fn registerNativeThunk(name: []const u8, native_addr: usize, param_bytes: u32, is_cdecl: bool) u32 {
    return registerNativeThunkVA(name, native_addr, param_bytes, is_cdecl, 0);
}

/// Register a variadic native function. va_fixed = number of fixed params
/// (e.g. 1 for printf, 2 for sprintf). 0 = not variadic.
pub fn registerNativeThunkVA(name: []const u8, native_addr: usize, param_bytes: u32, is_cdecl: bool, va_fixed: u8) u32 {
    return registerThunk(.{
        .name = name,
        .param_count = null,
        .handler = &dispatchNativeThunk,
        .native_addr = native_addr,
        .native_param_bytes = param_bytes,
        .native_is_cdecl = is_cdecl,
        .native_va_fixed = va_fixed,
    });
}

/// Generic handler for native thunks on WASM.
/// Called when INT 0xFE fires for a thunk registered via registerNativeThunk.
fn dispatchNativeThunk(cpu: *Cpu) void {
    // The thunk_id was already consumed by dispatch(). We need to find
    // which thunk we are — read it back from the code stream.
    // dispatch() advanced EIP past the 4-byte thunk_id, so it's at EIP-4.
    const thunk_id = cpu.memory.read32(cpu.eip -% 4);

    if (thunk_id >= MAX_THUNKS) return;
    const entry = thunk_entries[thunk_id] orelse return;
    const target_addr = entry.native_addr;

    // The CALL instruction pushed a return address.
    const ret_addr = cpu.pop32();

    if (target_addr == 0) {
        log.warn("x86 thunks: null native address for thunk {d} ({s})", .{ thunk_id, entry.name });
        cpu.eax = 0;
        cpu.eip = ret_addr;
        return;
    }

    const platform = @import("../platform.zig");

    // Special case: _ftol reads from x87 FPU stack (ST0). In interpreter
    // mode the FPU state is emulated — the real x87 stack is empty. Match
    // by thunk name instead of target address: on WASM, function pointers
    // have no meaningful integer address, so the address comparison never
    // matches and the generic fallback would return 0. c1.dll uses _ftol
    // when computing its internal heap limits, so a wrong result surfaces
    // as "fatal error C1076/C1063: compiler heap exhausted".
    if (std.mem.eql(u8, entry.name, "_ftol")) {
        const fval = cpu.fpu.pop();
        const ival = @import("fpu.zig").safeFloatToInt(i64, fval);
        const uval = @as(u64, @bitCast(ival));
        cpu.eax = @truncate(uval);
        cpu.edx = @truncate(uval >> 32);
        cpu.eip = ret_addr;
        // _ftol is cdecl (no cleanup needed)
        return;
    }

    if (comptime platform.is_native) {
        // Read up to 16 dword arguments from guest stack
        var args: [16]u32 = undefined;
        for (0..16) |i| {
            args[i] = cpu.memory.read32(cpu.esp +% @as(u32, @intCast(i * 4)));
        }

        if (entry.native_va_fixed > 0) {
            const va_idx = entry.native_va_fixed;
            args[va_idx] = cpu.esp +% @as(u32, va_idx * 4);
        }

        cpu.eax = if (entry.native_is_cdecl)
            callNativeCdecl(target_addr, args)
        else
            callNativeByArity(target_addr, entry.native_param_bytes, args);
    } else {
        // On WASM, we cannot use indirect function calls through computed
        // pointers (WASM enforces type-checked indirect calls). Stubs that
        // need to work on WASM should use addBuiltinExportComptime which
        // generates a proper thunk handler. This fallback just returns 0.
        log.warn("x86 thunks: native dispatch unsupported on WASM for {s} (addr=0x{X})", .{ entry.name, target_addr });
        cpu.eax = 0;
    }

    // For stdcall, callee pops parameters
    if (!entry.native_is_cdecl) {
        cpu.esp +%= entry.native_param_bytes;
    }

    cpu.eip = ret_addr;
}

// -----------------------------------------------------------------------
// Comptime native call dispatch — eliminates hand-written N-arg switches
// -----------------------------------------------------------------------

/// Call a cdecl function at `addr` with 16 u32 args (extras are harmless).
/// On x86_64, args are zero-extended to usize so native stubs (which take
/// usize params like malloc(size: usize)) get correct 64-bit values.
pub fn callNativeCdecl(addr: usize, args: [16]u32) u32 {
    if (comptime @import("../platform.zig").is_x86_64) {
        const GenericFnC = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
        const func: GenericFnC = @ptrFromInt(addr);
        return @truncate(func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15]));
    } else {
        const GenericFnC = *const fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(.c) u32;
        const func: GenericFnC = @ptrFromInt(addr);
        return func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15]);
    }
}

/// Call a stdcall/WINAPI function at `addr` with the correct arity
/// determined by `param_bytes` (0, 4, 8, …, 64). Uses comptime
/// `inline for` to generate all 17 arity variants.
pub fn callNativeByArity(addr: usize, param_bytes: u32, args: [16]u32) u32 {
    inline for (0..17) |n| {
        if (param_bytes == n * 4) {
            return callNativeN(n, addr, args);
        }
    }
    // Fallback for unexpected param_bytes — call as cdecl with 16 args
    log.warn("x86: native call unsupported param_bytes={d}", .{param_bytes});
    return callNativeCdecl(addr, args);
}

/// Comptime-generated call with exactly N arguments using WINAPI convention.
/// On x86_64, uses usize params to match native stub signatures.
fn callNativeN(comptime n: usize, addr: usize, args: [16]u32) u32 {
    const FnType = FnTypeForArity(n);
    const func: *const FnType = @ptrFromInt(addr);
    var call_args: std.meta.ArgsTuple(FnType) = undefined;
    inline for (0..n) |i| {
        call_args[i] = args[i]; // u32 -> u32 on x86, u32 -> usize on x86_64 (auto zero-extend)
    }
    if (comptime @import("../platform.zig").is_x86_64) {
        return @truncate(@call(.auto, func, call_args));
    } else {
        return @call(.auto, func, call_args);
    }
}

/// Generate a function type with N params. On x86, uses u32 params with
/// WINAPI (stdcall). On x86_64, uses usize params with WINAPI (Win64:
/// RCX, RDX, R8, R9) to match the calling convention of the Zig stubs.
fn FnTypeForArity(comptime n: usize) type {
    const is_64 = comptime @import("../platform.zig").is_x86_64;
    const param_type = if (is_64) usize else u32;
    const ret_type = if (is_64) usize else u32;
    const cc = @import("../win32/calling_convention.zig").WINAPI;
    comptime var param_types: [n]type = undefined;
    comptime var param_attrs: [n]std.lang.Type.Fn.ParamAttributes = undefined;
    inline for (0..n) |i| {
        param_types[i] = param_type;
        param_attrs[i] = .{};
    }
    return @Fn(&param_types, &param_attrs, ret_type, .{ .@"callconv" = cc });
}

// -----------------------------------------------------------------------
// Native import registry — maps resolved native addresses to stdcall
// parameter byte counts.  Used by execute.zig's dispatchNativeCall to
// adjust guest ESP after calling native stubs.
//
// Sorted by addr on first lookup for O(log n) binary search.
// -----------------------------------------------------------------------

const MAX_IMPORTS = 2048;

const ImportEntry = struct {
    addr: usize,
    param_bytes: u32, // stdcall bytes to pop (n_params * 4)
    is_cdecl: bool, // true if this is a cdecl import (e.g. MSVCRT)
};

var import_registry: [MAX_IMPORTS]ImportEntry = undefined;
var import_count: u32 = 0;
var imports_sorted: bool = false;

/// One bit per registered import address, set when the address is registered
/// and never cleared (the registry only grows, see registerNativeImport).
/// `isNativeImport` runs on every interpreted instruction, where the address
/// is almost never an import, so a clear bit answers the question in one load
/// instead of a binary search over the registry. A set bit only means the
/// address might be registered: findImport still does the real lookup, so
/// collisions cost an extra binary search and nothing else.
const FILTER_WORDS = 1 << 10; // 8 KiB of filter, one bit per slot
/// Address bits below the shift are ignored, so neighbouring stubs (a vtable
/// of them lands in one page) share a bit instead of each taking their own.
const FILTER_ADDR_SHIFT = 8;
var import_filter = @as([FILTER_WORDS]u64, @splat(0));

/// The filter slot an address lands in: a word index and the bit within it.
const FilterSlot = struct { word: usize, bit: u64 };

inline fn filterSlot(addr: usize) FilterSlot {
    const h = (addr >> FILTER_ADDR_SHIFT) ^ (addr >> 19);
    return .{ .word = (h >> 6) & (FILTER_WORDS - 1), .bit = @as(u64, 1) << @intCast(h & 63) };
}

/// Register a COM vtable method with param count derived from the function type.
/// Returns the truncated 32-bit address for use in COM vtable u32 fields.
/// Deduplicates: shared stubs (Dummy, noop) are only registered once.
pub fn comPtr(comptime func: anytype, comptime name: []const u8) u32 {
    const full_addr: usize = @intFromPtr(&func);
    const addr: u32 = @truncate(full_addr);
    if (comptime @import("../platform.zig").is_native) {
        const param_count: u32 = comptime blk: {
            const info = @typeInfo(@TypeOf(func));
            break :blk if (info == .@"fn") @intCast(info.@"fn".param_types.len) else 4;
        };
        if (!isNativeImport(addr)) {
            registerNativeImport(full_addr, "COM", name, param_count * 4);
        }
    }
    return addr;
}

/// Register a resolved import address with its stdcall parameter byte count.
/// Called from loader.zig during import resolution.
pub fn registerNativeImport(addr: usize, dll_name: []const u8, func_name: []const u8, param_bytes: u32) void {
    // Dedupe: repeated registrations of the same address (e.g. every
    // GetProcAddress for one builtin export) would otherwise burn registry
    // slots with identical entries.
    for (import_registry[0..import_count]) |*existing| {
        if (existing.addr == addr) return;
    }

    if (import_count >= MAX_IMPORTS) {
        // A dropped entry leaves the IAT pointing at host code that
        // isNativeImport() no longer recognizes, so step() would decode
        // host machine bytes as guest x86: silent corruption. Abort instead.
        log.fatal("x86 thunks: native import registry full ({d} entries)", .{MAX_IMPORTS});
        std.process.exit(1);
    }
    const is_cdecl = @import("../win32/calling_convention.zig").isCdeclExport(dll_name, func_name);

    // Check for @N suffix (decorated stdcall names)
    var resolved_bytes = param_bytes;
    if (std.mem.lastIndexOfScalar(u8, func_name, '@')) |at_pos| {
        if (at_pos > 0) {
            const suffix = func_name[at_pos + 1 ..];
            if (std.fmt.parseInt(u32, suffix, 10)) |n| resolved_bytes = n else |_| {}
        }
    }

    import_registry[import_count] = .{
        .addr = addr,
        .param_bytes = resolved_bytes,
        .is_cdecl = is_cdecl,
    };
    import_count += 1;
    imports_sorted = false; // invalidate sort
    import_filter[filterSlot(addr).word] |= filterSlot(addr).bit;
}

/// Sort the import registry by addr for binary search, if not already sorted.
fn ensureImportsSorted() void {
    if (imports_sorted) return;
    const slice = import_registry[0..import_count];
    std.mem.sortUnstable(ImportEntry, slice, {}, struct {
        fn cmp(_: void, a: ImportEntry, b: ImportEntry) bool {
            return a.addr < b.addr;
        }
    }.cmp);
    imports_sorted = true;
}

/// Binary search for an import entry by address.
fn findImport(addr: usize) ?*const ImportEntry {
    // A clear filter bit means no registered address hashes there, so the
    // search below cannot match and is skipped.
    const slot = filterSlot(addr);
    if (import_filter[slot.word] & slot.bit == 0) return null;
    ensureImportsSorted();
    const slice = import_registry[0..import_count];
    const idx = std.sort.binarySearch(ImportEntry, slice, addr, struct {
        fn cmp(key: usize, entry: ImportEntry) std.math.Order {
            return std.math.order(key, entry.addr);
        }
    }.cmp);
    return if (idx) |i| &slice[i] else null;
}

/// Returns true if the address corresponds to a registered native import.
pub fn isNativeImport(addr: u32) bool {
    return findImport(@as(usize, addr)) != null;
}

/// Combined lookup: returns (is_cdecl, param_bytes) in a single binary search.
/// Used by dispatchNativeCall to avoid 3 separate lookups for the same address.
pub fn getImportInfo(addr: u32) struct { is_cdecl: bool, param_bytes: u32 } {
    if (findImport(@as(usize, addr))) |entry| {
        return .{ .is_cdecl = entry.is_cdecl, .param_bytes = entry.param_bytes };
    }
    return .{ .is_cdecl = false, .param_bytes = 0 };
}

// -----------------------------------------------------------------------
// Unresolved Import Name Table
// -----------------------------------------------------------------------
// Maps IAT slot addresses to "DLL::FuncName" strings for diagnostics.
// Populated by loader.zig when patching unresolved imports to not_implemented.
// Sorted by iat_slot_addr on first lookup for O(log n) binary search.

const MAX_UNRESOLVED = 512;

const UnresolvedEntry = struct {
    iat_slot_addr: u32,
    name: [128]u8,
    name_len: u8,
};

var unresolved_registry: [MAX_UNRESOLVED]UnresolvedEntry = undefined;
var unresolved_count: u32 = 0;
var unresolved_sorted: bool = false;

/// Registers an unresolved import for diagnostic purposes.
pub fn registerUnresolvedImport(iat_slot_addr: u32, dll_name: []const u8, func_name: []const u8) void {
    if (unresolved_count >= MAX_UNRESOLVED) return;
    var entry = &unresolved_registry[unresolved_count];
    entry.iat_slot_addr = iat_slot_addr;
    // Format as "DLL::FuncName"
    var pos: usize = 0;
    for (dll_name) |c| {
        if (pos >= 127) break;
        entry.name[pos] = c;
        pos += 1;
    }
    if (pos + 2 < 127) {
        entry.name[pos] = ':';
        entry.name[pos + 1] = ':';
        pos += 2;
    }
    for (func_name) |c| {
        if (pos >= 127) break;
        entry.name[pos] = c;
        pos += 1;
    }
    entry.name_len = @intCast(pos);
    unresolved_count += 1;
    unresolved_sorted = false;
}

fn ensureUnresolvedSorted() void {
    if (unresolved_sorted) return;
    const slice = unresolved_registry[0..unresolved_count];
    std.mem.sortUnstable(UnresolvedEntry, slice, {}, struct {
        fn cmp(_: void, a: UnresolvedEntry, b: UnresolvedEntry) bool {
            return a.iat_slot_addr < b.iat_slot_addr;
        }
    }.cmp);
    unresolved_sorted = true;
}

/// Look up an unresolved import name by examining the caller's CALL instruction.
/// The return address points just after `FF 15 [addr32]` (6 bytes), so the
/// IAT slot address is at `ret_addr - 4`.
pub fn lookupUnresolvedName(ret_addr: usize) ?[]const u8 {
    if (ret_addr < 6) return null;
    const call_site: [*]const u8 = @ptrFromInt(ret_addr - 6);
    // Check for FF 15 (CALL dword ptr [addr32])
    if (call_site[0] == 0xFF and call_site[1] == 0x15) {
        const iat_slot = @as(*align(1) const u32, @ptrCast(call_site + 2)).*;
        return lookupUnresolvedName_bySlot(iat_slot);
    }
    return null;
}

/// Look up an unresolved import name by IAT slot address directly.
/// Uses binary search on the sorted registry.
pub fn lookupUnresolvedName_bySlot(iat_slot: u32) ?[]const u8 {
    ensureUnresolvedSorted();
    const slice = unresolved_registry[0..unresolved_count];
    const idx = std.sort.binarySearch(UnresolvedEntry, slice, iat_slot, struct {
        fn cmp(key: u32, entry: UnresolvedEntry) std.math.Order {
            return std.math.order(key, entry.iat_slot_addr);
        }
    }.cmp);
    if (idx) |i| {
        return slice[i].name[0..slice[i].name_len];
    }
    return null;
}

/// Fallback function for unimplemented Win32 APIs, moved from main.zig.
/// It attempts to resolve the name of the missing API and logs a fatal error.
pub fn not_implemented_stub() callconv(.c) void {
    const ra = @returnAddress();
    const name = lookupUnresolvedName(ra);
    if (name) |func_name| {
        log.fatal("Unimplemented Win32 API: {s} (called from 0x{X})", .{ func_name, ra });
    } else {
        // Try to identify via E8->FF25 thunk chain
        var found_name: ?[]const u8 = null;
        if (ra >= 5) {
            const call_site: [*]const u8 = @ptrFromInt(ra - 5);
            if (call_site[0] == 0xE8) {
                const rel = @as(*align(1) const i32, @ptrCast(call_site + 1)).*;
                const target: usize = @intCast(@as(isize, @intCast(ra)) + rel);
                const thunk_ptr: [*]const u8 = @ptrFromInt(target);
                if (thunk_ptr[0] == 0xFF and thunk_ptr[1] == 0x25) {
                    const iat_slot = @as(*align(1) const u32, @ptrCast(thunk_ptr + 2)).*;
                    found_name = lookupUnresolvedName_bySlot(iat_slot);
                }
            }
        }
        if (found_name) |func_name| {
            log.fatal("Unimplemented Win32 API: {s} (called from 0x{X})", .{ func_name, ra });
        } else {
            log.fatal("Unimplemented Win32 API called from 0x{X}", .{ra});
            const esp: usize = @frameAddress();
            if (esp > 0x1000) {
                const stack = @as([*]const u32, @ptrFromInt(esp));
                log.fatal("  Stack context:", .{});
                for (0..8) |i| {
                    log.fatal("    [{d}] = 0x{X}", .{ i, stack[i] });
                }
            }
        }
    }
    std.process.exit(1);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

fn testHandler(cpu: *Cpu) void {
    // Simple stub: return param0 + param1
    const a = readParam(cpu, 0);
    const b = readParam(cpu, 1);
    cpu.eax = a + b;
}

test "thunks: register and dispatch" {
    reset();
    defer reset();
    const id = registerThunk(.{
        .name = "test_add",
        .param_count = 2,
        .handler = &testHandler,
    });
    try testing.expectEqual(@as(u32, 0), id);

    var mem: [256]u8 = @splat(0);
    var cpu = Cpu{ .memory = cpu_mod.GuestMemory{ .base = &mem } };
    cpu.esp = 200;

    // Push two params (stdcall: right to left)
    cpu.push32(7); // param1
    cpu.push32(3); // param0

    // Write thunk code at EIP
    cpu.eip = 100;
    // The dispatch function reads thunk_id from EIP
    cpu.memory.write32(100, id);
    cpu.eip = 100;

    dispatch(&cpu);

    try testing.expectEqual(@as(u32, 10), cpu.eax); // 3 + 7
    // ESP should be adjusted by 2*4 = 8 for stdcall
    try testing.expectEqual(@as(u32, 200), cpu.esp);
}

test "thunks: _ftol returns EDX:EAX and preserves the caller stack" {
    reset();
    defer reset();
    const id = registerNativeThunk("_ftol", @intFromPtr(&testHandler), 0, true);
    const cases = [_]struct { value: f64, expected: i64 }{
        .{ .value = 4294967297.75, .expected = 4294967297 },
        .{ .value = -1.75, .expected = -1 },
        .{ .value = std.math.nan(f64), .expected = std.math.minInt(i64) },
        .{ .value = 9223372036854775808.0, .expected = std.math.minInt(i64) },
    };
    for (cases) |case| {
        var mem: [256]u8 = @splat(0);
        var cpu = Cpu{ .memory = cpu_mod.GuestMemory{ .base = &mem } };
        cpu.esp = 200;
        cpu.push32(0x12345678);
        cpu.fpu.control_word = 0x0B7F;
        cpu.fpu.push(42.0);
        cpu.fpu.push(case.value);
        cpu.memory.write32(100, id);
        cpu.eip = 100;

        dispatch(&cpu);

        const result = (@as(u64, cpu.edx) << 32) | cpu.eax;
        try testing.expectEqual(case.expected, @as(i64, @bitCast(result)));
        try testing.expectEqual(@as(u32, 0x12345678), cpu.eip);
        try testing.expectEqual(@as(u32, 200), cpu.esp);
        try testing.expectEqual(@as(u3, 7), cpu.fpu.top);
        try testing.expectEqual(@as(f64, 42.0), cpu.fpu.st(0));
    }
}

test "thunks: duplicate native import registration keeps first entry" {
    reset();
    defer reset();
    registerNativeImport(0x12345000, "KERNEL32.dll", "FakeA", 12);
    registerNativeImport(0x12345000, "KERNEL32.dll", "FakeB", 20);
    // The second registration of the same address must be ignored.
    try testing.expectEqual(@as(u32, 12), getImportInfo(0x12345000).param_bytes);
}

test "thunks: import address filter never hides a registered address" {
    reset();
    defer reset();
    // Addresses chosen to differ only in the bits the filter hashes, plus one
    // that shares a filter word with an earlier entry: the filter may collide,
    // but it must never clear a bit that a registered address needs.
    const addrs = [_]u32{
        0x1000_0000,
        0x1000_0100,
        0x1000_1000,
        0x2000_0001,
        0x0804_1234,
        @intCast(@intFromPtr(&testHandler)),
    };
    for (addrs, 0..) |addr, i| {
        registerNativeImport(addr, "KERNEL32.dll", "Filtered", @intCast(i + 1));
    }
    for (addrs, 0..) |addr, i| {
        try testing.expect(isNativeImport(addr));
        try testing.expectEqual(@as(u32, @intCast(i + 1)), getImportInfo(addr).param_bytes);
    }
    // An unregistered address whose filter bits are all clear is a miss, and
    // one whose bits happen to be set still resolves to nothing.
    try testing.expect(!isNativeImport(0x7000_0000));
    try testing.expectEqual(@as(u32, 0), getImportInfo(0).param_bytes);
}

test "thunks: _initterm queue holds a full CRT init section" {
    // 512 entries: an MSVC 6 .CRT section of a few hundred static
    // initializers, well past the 64 the queue used to hold. Dropping one
    // would skip a static constructor, which the guest sees as an unrelated
    // misbehaviour much later.
    const queued = 512;
    pending_initterm_count = 0;
    defer pending_initterm_count = 0;

    for (0..queued) |i| {
        const addr: u32 = 0x0040_0000 + @as(u32, @intCast(i));
        queueInittermCallback(addr);
        try testing.expectEqual(addr, pending_initterm_callbacks[i]);
    }

    try testing.expectEqual(@as(usize, queued), pending_initterm_count);
}
