// Import thunk mechanism for the x86 interpreter.
//
// When PE import tables are resolved for interpreter targets (WASM or
// native --interpret), each imported function gets a thunk slot in guest
// memory.  The thunk is a short x86 code sequence (INT 0xFE + thunk_id)
// that traps into the interpreter, which dispatches to the corresponding
// Zig stub.
//
// This module provides:
//   - registerThunk(): registration of stub functions by thunk ID
//   - dispatch(): called from execute.zig when INT 0xFE is hit
//   - writeThunkCode(): generate thunk code in guest memory

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const profiler = @import("../profiler.zig");
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
};

/// Maximum number of thunks.
pub const MAX_THUNKS = 4096;

/// Global thunk table (populated during PE loading).
var thunk_entries: [MAX_THUNKS]?ThunkEntry = .{null} ** MAX_THUNKS;
var thunk_count: u32 = 0;

/// Register a thunk and return its ID.
pub fn registerThunk(entry: ThunkEntry) u32 {
    if (thunk_count >= MAX_THUNKS) {
        std.log.err("x86 thunks: thunk table full", .{});
        return 0;
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
    memory.write8(addr, 0xCD); // INT
    memory.write8(addr +% 1, 0xFE); // 0xFE
    memory.write32(addr +% 2, thunk_id);
    return addr +% 6;
}

/// Dispatch a thunk call from the interpreter.
/// Called when INT 0xFE is executed.  The thunk_id follows the INT
/// instruction in the code stream (already consumed by the decoder
/// as the immediate; we read it from the instruction's imm field).
///
/// The CPU's EIP is already past the INT instruction.  We need to
/// read the 4-byte thunk ID that follows it.
pub fn dispatch(cpu: *Cpu) void {
    // Read thunk_id from code stream (4 bytes after INT 0xFE)
    const thunk_id = cpu.memory.read32(cpu.eip);
    cpu.eip +%= 4; // skip past the thunk_id

    if (thunk_id >= MAX_THUNKS) {
        std.log.err("x86 thunks: invalid thunk ID {d}", .{thunk_id});
        cpu.halted = true;
        return;
    }

    if (thunk_entries[thunk_id]) |entry| {
        profiler.tickThunk(thunk_id);
        entry.handler(cpu);

        // For stdcall: callee pops parameters
        if (entry.param_count) |n| {
            cpu.esp +%= @as(u32, n) * 4;
        }
    } else {
        std.log.err("x86 thunks: unregistered thunk ID {d}", .{thunk_id});
        cpu.halted = true;
    }
}

/// Convenience: read a stdcall parameter from the guest stack.
/// Parameter 0 is at [ESP+0] (after the return address has been consumed
/// by CALL → INT 0xFE sequence), parameter 1 at [ESP+4], etc.
pub fn readParam(cpu: *const Cpu, index: u32) u32 {
    return cpu.memory.read32(cpu.esp +% index * 4);
}

/// Reset the thunk table (for testing).
pub fn reset() void {
    thunk_entries = .{null} ** MAX_THUNKS;
    thunk_count = 0;
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
    return registerThunk(.{
        .name = name,
        .param_count = null, // We handle ESP ourselves
        .handler = &dispatchNativeThunk,
        .native_addr = native_addr,
        .native_param_bytes = param_bytes,
        .native_is_cdecl = is_cdecl,
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

    if (target_addr == 0) {
        std.log.warn("x86 thunks: null native address for thunk {d} ({s})", .{ thunk_id, entry.name });
        cpu.eax = 0;
        return;
    }

    // The CALL instruction pushed a return address. The INT 0xFE thunk
    // consumed it conceptually — we need to pop it and restore EIP.
    // Actually, the x86 code did: CALL [IAT] → pushes ret_addr, jumps to
    // thunk. The thunk is: INT 0xFE (2 bytes) + thunk_id (4 bytes).
    // After dispatch(), EIP is past the thunk_id. We need to set EIP
    // to the return address that was pushed by CALL.
    const ret_addr = cpu.pop32();

    // Read up to 16 dword arguments from guest stack
    var args: [16]u32 = undefined;
    for (0..16) |i| {
        args[i] = cpu.memory.read32(cpu.esp +% @as(u32, @intCast(i * 4)));
    }

    cpu.eax = if (entry.native_is_cdecl)
        callNativeCdecl(target_addr, args)
    else
        callNativeByArity(target_addr, entry.native_param_bytes, args);

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
pub fn callNativeCdecl(addr: usize, args: [16]u32) u32 {
    const GenericFnC = *const fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(.c) u32;
    const func: GenericFnC = @ptrFromInt(addr);
    return func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15]);
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
    std.log.warn("x86: native call unsupported param_bytes={d}", .{param_bytes});
    return callNativeCdecl(addr, args);
}

/// Comptime-generated call with exactly N u32 arguments using WINAPI convention.
fn callNativeN(comptime n: usize, addr: usize, args: [16]u32) u32 {
    const FnType = FnTypeForArity(n);
    const func: *const FnType = @ptrFromInt(addr);
    var call_args: std.meta.ArgsTuple(FnType) = undefined;
    inline for (0..n) |i| {
        call_args[i] = args[i];
    }
    return @call(.auto, func, call_args);
}

/// Generate a function type: fn(u32, u32, ...) callconv(WINAPI) u32 with N params.
fn FnTypeForArity(comptime n: usize) type {
    comptime var params: [n]std.builtin.Type.Fn.Param = undefined;
    inline for (0..n) |i| {
        params[i] = .{ .is_generic = false, .is_noalias = false, .type = u32 };
    }
    return @Type(.{ .@"fn" = .{
        .calling_convention = @import("../calling_convention.zig").WINAPI,
        .is_generic = false,
        .is_var_args = false,
        .return_type = u32,
        .params = &params,
    } });
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
    addr: u32,
    param_bytes: u32, // stdcall bytes to pop (n_params * 4)
    is_cdecl: bool,   // true if this is a cdecl import (e.g. MSVCRT)
};

var import_registry: [MAX_IMPORTS]ImportEntry = undefined;
var import_count: u32 = 0;
var imports_sorted: bool = false;

/// Register a resolved import address with its stdcall parameter byte count.
/// Called from loader.zig during import resolution.
pub fn registerNativeImport(addr: u32, dll_name: []const u8, func_name: []const u8, param_bytes: u32) void {
    if (import_count >= MAX_IMPORTS) return;
    const is_msvcrt = std.ascii.eqlIgnoreCase(dll_name, "MSVCRT.dll") or std.ascii.eqlIgnoreCase(dll_name, "MSVCP60.dll");
    
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
        .is_cdecl = is_msvcrt,
    };
    import_count += 1;
    imports_sorted = false; // invalidate sort
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
fn findImport(addr: u32) ?*const ImportEntry {
    ensureImportsSorted();
    const slice = import_registry[0..import_count];
    const idx = std.sort.binarySearch(ImportEntry, slice, addr, struct {
        fn cmp(key: u32, entry: ImportEntry) std.math.Order {
            return std.math.order(key, entry.addr);
        }
    }.cmp);
    return if (idx) |i| &slice[i] else null;
}

pub fn getParamBytes(addr: u32) u32 {
    return if (findImport(addr)) |entry| entry.param_bytes else 0;
}

pub fn isTargetCdecl(addr: u32) bool {
    return if (findImport(addr)) |entry| entry.is_cdecl else false;
}

pub fn isNativeImport(addr: u32) bool {
    return findImport(addr) != null;
}

pub const getStdcallCleanup = getParamBytes;

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
    const id = registerThunk(.{
        .name = "test_add",
        .param_count = 2,
        .handler = &testHandler,
    });
    try testing.expectEqual(@as(u32, 0), id);

    var mem: [256]u8 = .{0} ** 256;
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
