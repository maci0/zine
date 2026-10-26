//! Win32 environment and module management.
//!
//! This module defines the Win32 environment, which handles module registration,
//! built-in export management, and import resolution for both native and WASM
//! execution.

const std = @import("std");
const pe = @import("../pe.zig");
pub const Module = @import("module.zig").Module;
const Registry = @import("registry.zig").Registry;
const x86_cpu = @import("../x86/cpu.zig");
const x86_thunks = @import("../x86/thunks.zig");
const platform = @import("../platform.zig");

const Cpu = x86_cpu.Cpu;

/// Represents a built-in export from a stub DLL.
pub const BuiltinExport = struct {
    /// Host address of the stub function, or guest VA of the relocated data.
    addr: usize,
    /// Number of bytes to pop from the guest stack (for stdcall).
    param_bytes: u32,
    /// On WASM, a comptime-generated handler that reads args from the guest
    /// stack and calls the actual stub function with the correct signature.
    /// Null on native (where we can use @ptrFromInt to call directly).
    thunk_handler: ?*const fn (*Cpu) void = null,
    /// Whether this export is a host native stub (true) or a guest PE export (false).
    is_native: bool = true,
    /// True if this is a data export (e.g., _iob, _adjust_fdiv) as opposed to
    /// a function export. On WASM, data exports are written directly to the IAT
    /// as data addresses, while function exports get thunk code.
    is_data: bool = false,
    /// Size in bytes of the data export (only meaningful when is_data == true).
    data_size: u32 = 0,
    /// Number of fixed params for variadic functions (0 = not variadic).
    /// Used on x86_64 compat mode to pass a guest stack pointer as the va_list arg.
    va_fixed: u8 = 0,
};

/// Represents a built-in module (DLL) with its registered exports.
pub const BuiltinModule = struct {
    /// Handle to the fake PE header page for this module.
    handle: usize,
    /// The same page as `handle`, retained so deinit can release it.
    header: []align(4096) u8,
    /// True when `header` came from platform.mmap and must be munmap'd
    /// rather than freed through the allocator.
    handle_is_mapped: bool,
    /// Mapping from function name to export metadata.
    exports: std.StringHashMap(BuiltinExport),
};

/// The Win32 environment, managing module registration and import resolution.
pub const Environment = struct {
    /// The allocator used for environment metadata.
    allocator: std.mem.Allocator,
    /// The module registry for loading PEs from disk.
    registry: Registry,
    /// Mapping from DLL name to built-in/stubbed module metadata.
    builtins: std.StringHashMap(BuiltinModule),

    /// Initializes a new Win32 environment.
    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .builtins = std.StringHashMap(BuiltinModule).init(allocator),
        };
    }

    /// Frees all resources associated with the environment.
    pub fn deinit(self: *Environment) void {
        var it = self.builtins.iterator();
        while (it.next()) |entry| {
            var val = entry.value_ptr.*;
            val.exports.deinit();
            if (val.handle_is_mapped) {
                platform.munmap(val.header);
            } else {
                self.allocator.free(val.header);
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.builtins.deinit();
        self.registry.deinit();
    }

    /// Ensure a BuiltinModule exists for the given DLL name (case-insensitive).
    /// Creates a fake PE header for the module if it doesn't exist yet.
    fn getOrCreateModule(self: *Environment, dll: []const u8) !*BuiltinModule {
        const lower_dll = try self.allocator.alloc(u8, dll.len);
        defer self.allocator.free(lower_dll);
        _ = std.ascii.lowerString(lower_dll, dll);

        if (self.builtins.getPtr(lower_dll)) |existing| {
            return existing;
        }

        // Allocate a page for the fake PE header.
        // On x86_64, this must be in low 4GB because guest code receives
        // the address as a module handle (HMODULE) in 32-bit registers.
        const header: []align(4096) u8 = if (comptime platform.is_x86_64)
            try platform.mmap(null, 4096, false, -1, 0, false, false)
        else
            try self.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
        @memset(header, 0);

        // Minimal MZ/PE header
        const mz = @as(*align(1) u16, @ptrCast(&header[0]));
        mz.* = 0x5A4D;
        const e_lfanew = @as(*align(1) u32, @ptrCast(&header[0x3C]));
        e_lfanew.* = 0x40;
        const pe_sig = @as(*align(1) u32, @ptrCast(&header[0x40]));
        pe_sig.* = 0x00004550;

        const new_builtin = BuiltinModule{
            .handle = @intFromPtr(header.ptr),
            .header = header,
            .handle_is_mapped = comptime platform.is_x86_64,
            .exports = std.StringHashMap(BuiltinExport).init(self.allocator),
        };
        try self.builtins.put(try self.allocator.dupe(u8, lower_dll), new_builtin);
        return self.builtins.getPtr(lower_dll).?;
    }

    /// Register a raw pointer as a built-in export.
    /// This bypasses comptime type checking and thunk generation.
    pub fn addBuiltinExport(self: *Environment, dll: []const u8, name: []const u8, addr: usize) !void {
        const builtin = try self.getOrCreateModule(dll);
        try builtin.exports.put(name, .{ .addr = addr, .param_bytes = 0 });
    }

    /// Register a data export (e.g., _iob, _adjust_fdiv). On WASM, these are
    /// written directly to the IAT as data addresses, not wrapped in thunks.
    pub fn addBuiltinDataExport(self: *Environment, dll: []const u8, name: []const u8, addr: usize, size: u32) !void {
        const builtin = try self.getOrCreateModule(dll);
        try builtin.exports.put(name, .{ .addr = addr, .param_bytes = 0, .is_data = true, .data_size = size });
    }

    /// One data export waiting to be relocated, tagged with the module and
    /// export name that order it.
    const PendingDataExport = struct {
        dll_name: []const u8,
        export_name: []const u8,
        exp: *BuiltinExport,
    };

    /// Relocate all data exports into guest memory. Call this on WASM before
    /// import resolution so that IAT entries point to guest-addressable data.
    /// Finds is_data exports in every builtin module, allocates guest memory,
    /// copies the host data, and updates the export address.
    ///
    /// Allocation follows (module name, export name) order rather than hash
    /// order, because the guest reads these addresses back: a guest that dumps
    /// a pointer, or whose data references another export, must see the same
    /// layout on every run, and hash order changes with the export set.
    pub fn relocateDataExports(self: *Environment, gmem: anytype, combined_buf: []u8, base_addr: u32) !void {
        var pending: std.ArrayList(PendingDataExport) = .empty;
        defer pending.deinit(self.allocator);

        var mod_it = self.builtins.iterator();
        while (mod_it.next()) |mod_entry| {
            var exp_it = mod_entry.value_ptr.exports.iterator();
            while (exp_it.next()) |exp_entry| {
                const exp = exp_entry.value_ptr;
                if (!exp.is_data or exp.data_size == 0) continue;
                try pending.append(self.allocator, .{
                    .dll_name = mod_entry.key_ptr.*,
                    .export_name = exp_entry.key_ptr.*,
                    .exp = exp,
                });
            }
        }

        std.mem.sort(PendingDataExport, pending.items, {}, struct {
            fn lessThan(_: void, lhs: PendingDataExport, rhs: PendingDataExport) bool {
                return switch (std.mem.order(u8, lhs.dll_name, rhs.dll_name)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.order(u8, lhs.export_name, rhs.export_name) == .lt,
                };
            }
        }.lessThan);

        for (pending.items) |item| {
            const exp = item.exp;
            const guest_va = gmem.guestAlloc(exp.data_size);
            if (guest_va == 0) continue;

            const off = guest_va - base_addr;
            const src = @as([*]const u8, @ptrFromInt(exp.addr))[0..exp.data_size];
            @memcpy(combined_buf[off .. off + exp.data_size], src);
            exp.addr = guest_va;
        }
    }

    /// Register a typed Zig function as a built-in export.
    /// On WASM, this generates an intelligent thunk handler that unwraps
    /// guest arguments into the native function signature safely.
    pub fn addBuiltinExportComptime(self: *Environment, comptime dll: []const u8, name: []const u8, comptime func: anytype) !void {
        // Detect cdecl vs stdcall from the DLL name:
        // MSVCRT/MSVCP* functions use cdecl, everything else is stdcall.
        const comptime_is_cdecl = comptime blk: {
            break :blk std.ascii.eqlIgnoreCase(dll, "MSVCRT.dll") or
                std.ascii.startsWithIgnoreCase(dll, "MSVCP");
        };
        return self.addBuiltinExportComptimeCC(dll, name, func, comptime_is_cdecl);
    }

    /// Register a typed Zig function as a built-in export with explicit calling convention.
    pub fn addBuiltinExportComptimeCC(self: *Environment, dll: []const u8, name: []const u8, comptime func: anytype, comptime is_cdecl: bool) !void {
        const info = @typeInfo(@TypeOf(func));
        comptime var param_len: usize = 0;
        comptime var is_bare_fn = false;
        comptime var is_variadic = false;
        if (info == .pointer and @typeInfo(info.pointer.child) == .@"fn") {
            param_len = @typeInfo(info.pointer.child).@"fn".param_types.len;
            is_variadic = @typeInfo(info.pointer.child).@"fn".attrs.varargs;
        } else if (info == .@"fn") {
            param_len = info.@"fn".param_types.len;
            is_variadic = info.@"fn".attrs.varargs;
            is_bare_fn = true;
        } else {
            @compileError("addBuiltinExportComptime requires a function or function pointer");
        }
        const param_bytes = param_len * 4;
        const addr = @import("../x86/compat_abi.zig").nativeAddress(func);

        // On WASM, generate a comptime thunk handler that reads args from the
        // guest stack and calls the function with the exact correct signature.
        // On native, the thunk_handler is null (dispatchNativeCall handles it).
        // Variadic functions can't have ArgsTuple created, so skip thunk generation for them.
        const handler: ?*const fn (*Cpu) void = if (comptime platform.is_wasm and !is_variadic)
            &(struct {
                // Convert any return value to u32 for EAX.
                // For pointer return types on WASM, reverse-translate
                // host address back to guest VA so the x86 code gets
                // a valid guest-space pointer.
                fn toU32(val: anytype, cpu_ref: *Cpu) u32 {
                    const T = @TypeOf(val);
                    const ti = @typeInfo(T);
                    return switch (ti) {
                        .void, .noreturn => 0,
                        .pointer => blk: {
                            const host_addr = @intFromPtr(val);
                            if (host_addr == 0) break :blk 0;
                            // Reverse translate: host addr → guest VA
                            const base_ptr = @intFromPtr(cpu_ref.memory.base.ptr);
                            const base_end = base_ptr + cpu_ref.memory.base.len;
                            if (host_addr >= base_ptr and host_addr < base_end) {
                                break :blk cpu_ref.memory.base_addr +% @as(u32, @intCast(host_addr - base_ptr));
                            }
                            break :blk @as(u32, @truncate(host_addr));
                        },
                        .optional => if (val) |v| toU32(v, cpu_ref) else 0,
                        .int => |int_info| blk: {
                            if (int_info.bits <= 32) {
                                if (int_info.signedness == .signed) {
                                    break :blk @bitCast(@as(i32, val));
                                } else {
                                    break :blk @intCast(val);
                                }
                            } else {
                                if (int_info.signedness == .signed) {
                                    break :blk @bitCast(@as(i32, @truncate(@as(i64, val))));
                                } else {
                                    break :blk @truncate(@as(u64, @intCast(val)));
                                }
                            }
                        },
                        .bool => @intFromBool(val),
                        else => 0,
                    };
                }

                fn callAndConvert(fptr: anytype, args: [16]u32, cpu: *Cpu) u32 {
                    // Get the actual function type info to know each parameter's type
                    const FnType = if (is_bare_fn) @TypeOf(func) else @typeInfo(@TypeOf(func)).pointer.child;
                    const fn_info = @typeInfo(FnType).@"fn";

                    // Build a tuple of correctly-typed arguments
                    var call_args: std.meta.ArgsTuple(FnType) = undefined;
                    var pointer_slots: [param_len]usize = @splat(0);
                    inline for (0..param_len) |i| {
                        const ParamType = fn_info.param_types[i].?;
                        if (comptime @import("../x86/compat_abi.zig").isPointerSlot(ParamType)) {
                            // Pointer outputs need host-to-guest translation as well as four-byte slots.
                            pointer_slots[i] = translateGuestAddr(cpu.memory.read32(args[i]), cpu);
                            call_args[i] = @ptrCast(&pointer_slots[i]);
                        } else call_args[i] = castArg(ParamType, args[i], cpu);
                    }

                    const result = @call(.auto, fptr, call_args);
                    inline for (0..param_len) |i| {
                        if (comptime @import("../x86/compat_abi.zig").isPointerSlot(fn_info.param_types[i].?)) {
                            const value = pointer_slots[i];
                            cpu.memory.write32(args[i], if (value == 0) 0 else toU32(@as(*anyopaque, @ptrFromInt(value)), cpu));
                        }
                    }
                    return toU32(result, cpu);
                }

                fn translateGuestAddr(val: u32, cpu: *Cpu) usize {
                    if (val == 0) return 0;
                    // On WASM, guest virtual addresses must be translated
                    // to host addresses using the GuestMemory mapping.
                    const plat = @import("../platform.zig");
                    if (comptime plat.is_native) {
                        return val; // On native, guest = host addresses
                    }
                    const offset = val -% cpu.memory.base_addr;
                    if (offset >= cpu.memory.base.len) {
                        // Address outside the combined buffer — might be a
                        // host-returned pointer from a previous stub call
                        // (e.g. malloc). Pass it through as-is.
                        return val;
                    }
                    return @intFromPtr(cpu.memory.base.ptr) + offset;
                }

                fn castArg(comptime T: type, val: u32, cpu: *Cpu) T {
                    const ti = @typeInfo(T);
                    return switch (ti) {
                        .pointer => @ptrFromInt(translateGuestAddr(val, cpu)),
                        .optional => |opt| blk: {
                            if (@typeInfo(opt.child) == .pointer) {
                                break :blk if (val == 0) null else @as(T, @ptrFromInt(translateGuestAddr(val, cpu)));
                            }
                            break :blk @bitCast(val);
                        },
                        .int => |int_info| blk: {
                            // Do NOT auto-translate usize params here: stub
                            // functions call trace.addr() themselves, so
                            // auto-translating would cause double-translation
                            // when the host buffer address overlaps the guest
                            // VA range.
                            if (int_info.signedness == .signed) {
                                if (int_info.bits <= 32) {
                                    break :blk @truncate(@as(i32, @bitCast(val)));
                                }
                                break :blk @as(T, @as(i32, @bitCast(val)));
                            } else {
                                if (int_info.bits <= 32) {
                                    break :blk @truncate(val);
                                }
                                break :blk @as(T, val);
                            }
                        },
                        .bool => val != 0,
                        .@"enum" => @fromBackingInt(@intCast(val)),
                        else => blk: {
                            // Only @bitCast when sizes match (both 32 bits)
                            if (@sizeOf(T) == @sizeOf(u32)) {
                                break :blk @bitCast(val);
                            } else if (T == f32) {
                                break :blk @bitCast(val);
                            } else if (T == f64) {
                                // f64 is 64 bits — we only have 32 bits; treat as f32 then widen
                                break :blk @as(f64, @as(f32, @bitCast(val)));
                            } else {
                                // Unsupported type — return zero-initialized
                                break :blk std.mem.zeroes(T);
                            }
                        },
                    };
                }

                fn thunkHandler(cpu: *Cpu) void {
                    // Pop return address (pushed by the CALL instruction)
                    const ret_addr = cpu.pop32();

                    // Read parameters from guest stack
                    var args: [16]u32 = undefined;
                    inline for (0..16) |i| {
                        args[i] = cpu.memory.read32(cpu.esp +% @as(u32, @intCast(i * 4)));
                    }

                    // Call the actual function with the exact right number of params
                    const FnPtr = if (is_bare_fn) *const @TypeOf(func) else @TypeOf(func);
                    const fptr: FnPtr = if (is_bare_fn) &func else func;

                    cpu.eax = callAndConvert(fptr, args, cpu);

                    // Stdcall (WINAPI): callee pops parameters.
                    // cdecl (.c, e.g. MSVCRT): caller pops, so we leave ESP alone.
                    if (!is_cdecl) {
                        cpu.esp +%= @as(u32, param_len * 4);
                    }

                    cpu.eip = ret_addr;
                }
            }.thunkHandler)
        else
            null;

        const builtin = try self.getOrCreateModule(dll);
        try builtin.exports.put(name, .{
            .addr = addr,
            .param_bytes = param_bytes,
            .thunk_handler = handler,
        });
    }

    /// Register a variadic C function (printf, sprintf, etc.) as a built-in export.
    ///
    /// The Zig stub must NOT be declared as variadic (`...`). Instead, it takes
    /// its fixed parameters followed by a final `ap: usize` parameter which will
    /// receive a host pointer to the variadic arguments on the guest x86 stack.
    ///
    /// Example: `printf(fmt_ptr: usize, ap: usize)` — `ap` points to the
    /// first variadic arg on the guest stack, translated to a host address.
    ///
    /// `fixed_params` is the number of guest-visible parameters BEFORE the varargs
    /// (e.g., 1 for printf, 2 for sprintf, 3 for snprintf).
    pub fn addBuiltinExportComptimeVA(
        self: *Environment,
        comptime dll: []const u8,
        name: []const u8,
        comptime func: anytype,
        comptime fixed_params: usize,
    ) !void {
        const info = @typeInfo(@TypeOf(func));
        comptime var stub_param_len: usize = 0;
        comptime var is_bare_fn = false;
        if (info == .pointer and @typeInfo(info.pointer.child) == .@"fn") {
            stub_param_len = @typeInfo(info.pointer.child).@"fn".param_types.len;
        } else if (info == .@"fn") {
            stub_param_len = info.@"fn".param_types.len;
            is_bare_fn = true;
        } else {
            @compileError("addBuiltinExportComptimeVA requires a function or function pointer");
        }

        // On WASM, the stub must have fixed_params + 1 params (last is va_list).
        // On native, the stub is variadic with @cVaStart — different param count.
        if (comptime platform.is_wasm and stub_param_len != fixed_params + 1) {
            @compileError("Variadic stub must have exactly fixed_params + 1 parameters (last is va_list)");
        }

        // This path has no per-parameter flag: it translates every usize fixed
        // parameter as a guest address, so a usize count or handle is silently
        // rewritten when it happens to land in the guest VA window. Pointers
        // must be declared as pointers, and integers as a sized int type.
        if (comptime !platform.is_native) {
            const fn_type = if (is_bare_fn) @TypeOf(func) else @typeInfo(@TypeOf(func)).pointer.child;
            const fn_info = @typeInfo(fn_type).@"fn";
            inline for (0..fixed_params) |i| {
                if (comptime fn_info.param_types[i].? == usize) {
                    @compileError("Variadic stub fixed parameters must not be usize: declare the parameter as a pointer or a sized int");
                }
            }
        }

        const addr = if (is_bare_fn) @intFromPtr(&func) else @intFromPtr(func);

        // On WASM, generate a variadic thunk handler that reads fixed params
        // from the guest stack and passes a translated va_list as the last arg.
        // On native, thunk_handler is null — the stubs use @cVaStart directly.
        const handler: ?*const fn (*Cpu) void = if (comptime platform.is_wasm)
            &(struct {
                fn toU32(val: anytype) u32 {
                    const T = @TypeOf(val);
                    const ti = @typeInfo(T);
                    return switch (ti) {
                        .void, .noreturn => 0,
                        .pointer => @as(u32, @truncate(@intFromPtr(val))),
                        .optional => if (val) |v| toU32(v) else 0,
                        .int => |int_info| blk: {
                            if (int_info.bits <= 32) {
                                if (int_info.signedness == .signed) {
                                    break :blk @bitCast(@as(i32, val));
                                } else {
                                    break :blk @intCast(val);
                                }
                            } else {
                                break :blk @truncate(val);
                            }
                        },
                        .bool => @intFromBool(val),
                        else => 0,
                    };
                }

                fn translateGuestAddr(val: u32, cpu: *Cpu) usize {
                    if (val == 0) return 0;
                    const plat = @import("../platform.zig");
                    if (comptime plat.is_native) return val;
                    const offset = val -% cpu.memory.base_addr;
                    if (offset >= cpu.memory.base.len) return val;
                    return @intFromPtr(cpu.memory.base.ptr) + offset;
                }

                fn castArg(comptime T: type, val: u32, cpu: *Cpu) T {
                    const ti = @typeInfo(T);
                    return switch (ti) {
                        .pointer => @ptrFromInt(translateGuestAddr(val, cpu)),
                        .optional => |opt| blk: {
                            if (@typeInfo(opt.child) == .pointer) {
                                break :blk if (val == 0) null else @as(T, @ptrFromInt(translateGuestAddr(val, cpu)));
                            }
                            break :blk @bitCast(val);
                        },
                        .int => |int_info| blk: {
                            // On WASM, usize parameters are often guest pointers
                            // (Win32 stubs use usize for pointer args). Translate
                            // values that fall within the guest VA range.
                            if (T == usize and comptime !platform.is_native) {
                                break :blk translateGuestAddr(val, cpu);
                            }
                            if (int_info.signedness == .signed) {
                                if (int_info.bits <= 32) {
                                    break :blk @truncate(@as(i32, @bitCast(val)));
                                }
                                break :blk @as(T, @as(i32, @bitCast(val)));
                            } else {
                                if (int_info.bits <= 32) {
                                    break :blk @truncate(val);
                                }
                                break :blk @as(T, val);
                            }
                        },
                        .bool => val != 0,
                        .@"enum" => @fromBackingInt(@intCast(val)),
                        else => blk: {
                            if (@sizeOf(T) == @sizeOf(u32)) {
                                break :blk @bitCast(val);
                            } else {
                                break :blk std.mem.zeroes(T);
                            }
                        },
                    };
                }

                fn thunkHandler(cpu: *Cpu) void {
                    const ret_addr = cpu.pop32();

                    // Read fixed parameters from guest stack
                    var args: [16]u32 = undefined;
                    inline for (0..16) |i| {
                        args[i] = cpu.memory.read32(cpu.esp +% @as(u32, @intCast(i * 4)));
                    }

                    // Build call args: fixed params + translated va_list
                    const FnType = if (is_bare_fn) @TypeOf(func) else @typeInfo(@TypeOf(func)).pointer.child;
                    const fn_info = @typeInfo(FnType).@"fn";

                    var call_args: std.meta.ArgsTuple(FnType) = undefined;

                    // Fill fixed params (all except the last, which is va_list)
                    inline for (0..fixed_params) |i| {
                        const ParamType = fn_info.param_types[i].?;
                        call_args[i] = castArg(ParamType, args[i], cpu);
                    }

                    // Last param is the va_list: translated host pointer to
                    // the guest stack location of the first variadic argument
                    const va_guest_addr = cpu.esp +% @as(u32, fixed_params * 4);
                    call_args[fixed_params] = translateGuestAddr(va_guest_addr, cpu);

                    const FnPtr = if (is_bare_fn) *const @TypeOf(func) else @TypeOf(func);
                    const fptr: FnPtr = if (is_bare_fn) &func else func;

                    cpu.eax = toU32(@call(.auto, fptr, call_args));

                    // cdecl: caller pops, so we don't adjust ESP
                    cpu.eip = ret_addr;
                }
            }.thunkHandler)
        else
            null;

        const builtin = try self.getOrCreateModule(dll);
        // For variadic functions, param_bytes is just the fixed params
        // (cdecl — caller cleans up, so exact byte count doesn't matter for ESP adjustment)
        try builtin.exports.put(name, .{
            .addr = addr,
            .param_bytes = fixed_params * 4,
            .thunk_handler = handler,
            .va_fixed = @intCast(fixed_params),
        });
    }

    /// Recursively registers all function pointers in a COM VTable struct
    /// to the native thunk registry so the interpreter doesn't crash if
    /// a COM method is called natively.
    pub fn addBuiltinVtableComptime(self: *Environment, comptime VTableType: type, vtable: *const VTableType) void {
        _ = self;
        if (comptime platform.is_native) {
            const info = @typeInfo(VTableType);
            if (info != .@"struct") @compileError("VTableType must be a struct");

            inline for (info.@"struct".field_names) |field_name| {
                const func_ptr = @field(vtable, field_name);
                const FuncType = @TypeOf(func_ptr);

                var target_ptr: usize = 0;
                var param_len: u32 = 0;

                switch (@typeInfo(FuncType)) {
                    .pointer => |p| {
                        if (@typeInfo(p.child) == .@"fn") {
                            target_ptr = @intFromPtr(func_ptr);
                            param_len = @intCast(@typeInfo(p.child).@"fn".param_types.len);
                        }
                    },
                    .optional => |opt| {
                        if (@typeInfo(opt.child) == .pointer) {
                            const p = @typeInfo(opt.child).pointer;
                            if (@typeInfo(p.child) == .@"fn") {
                                if (func_ptr) |ptr| {
                                    target_ptr = @intFromPtr(ptr);
                                    param_len = @intCast(@typeInfo(p.child).@"fn".param_types.len);
                                }
                            }
                        }
                    },
                    .int => {
                        // u32 COM vtable entries — registered individually via
                        // thunks.comPtr() with correct param counts. Skip here.
                    },
                    else => {},
                }

                if (target_ptr != 0) {
                    x86_thunks.registerNativeImport(
                        @intCast(target_ptr),
                        "COM",
                        field_name,
                        param_len * 4,
                    );
                }
            }
        }
    }

    /// Retrieves the fake PE header handle for a built-in module.
    pub fn getBuiltinHandle(self: *Environment, dll_name: []const u8) ?usize {
        var search_name: []const u8 = dll_name;
        // Handle case-insensitive lookup for known DLLs
        var lower_buf: [256]u8 = undefined;
        if (dll_name.len <= lower_buf.len) {
            const lower = lower_buf[0..dll_name.len];
            _ = std.ascii.lowerString(lower, dll_name);
            search_name = lower;
        }
        if (self.builtins.get(search_name)) |builtin| {
            return builtin.handle;
        }
        return null;
    }

    /// Build a real PE export directory in the fake header page so games
    /// that manually parse PE exports (instead of GetProcAddress) can find
    /// the registered exports.  Must be called AFTER all exports are registered.
    pub fn finalizeExports(self: *Environment, dll_name: []const u8) void {
        var lower_buf: [256]u8 = undefined;
        var search: []const u8 = dll_name;
        if (dll_name.len <= lower_buf.len) {
            const lower = lower_buf[0..dll_name.len];
            _ = std.ascii.lowerString(lower, dll_name);
            search = lower;
        }
        const builtin = self.builtins.getPtr(search) orelse return;
        const n = builtin.exports.count();
        if (n == 0) return;

        const header = @as([*]u8, @ptrFromInt(builtin.handle));
        const base: usize = builtin.handle;
        const base32: u32 = @intCast(builtin.handle);

        // PE layout:
        //   0x00: MZ header
        //   0x3C: e_lfanew → 0x40
        //   0x40: PE signature
        //   0x44: COFF header (20 bytes)
        //   0x58: Optional header (PE32, 224 bytes)
        //     +28 (0x74): ImageBase
        //     +56 (0x90): SizeOfImage
        //     +92 (0xB4): NumberOfRvaAndSizes
        //     +96 (0xB8): DataDirectory[0] = Export (VA, Size)

        // COFF: SizeOfOptionalHeader = 224
        @as(*align(1) u16, @ptrFromInt(base + 0x54)).* = 224;
        // Optional: Magic = PE32
        @as(*align(1) u16, @ptrFromInt(base + 0x58)).* = 0x10B;
        // ImageBase = actual base (so game adds 0 displacement)
        @as(*align(1) u32, @ptrFromInt(base + 0x74)).* = base32;
        // SizeOfImage = 0x1000 (one page). Optional header offset 56.
        @as(*align(1) u32, @ptrFromInt(base + 0x90)).* = 0x1000;
        // NumberOfRvaAndSizes = 16
        @as(*align(1) u32, @ptrFromInt(base + 0xB4)).* = 16;

        // All RVAs are relative to module base (= base).
        // Layout within page (all offsets from base):
        //   0x200: IMAGE_EXPORT_DIRECTORY (40 bytes)
        //   0x228: DLL name string (up to 64 bytes)
        //   0x268: Thunks — 10 bytes each: FF 25 [addr32] + the 4-byte target (for up to 32 exports)
        //   0x368: AddressOfFunctions array (n * 4) — RVAs to thunks
        //   after: AddressOfNames array (n * 4) — RVAs to name strings
        //   after: AddressOfNameOrdinals array (n * 2)
        //   after: Name strings (packed, null-terminated)

        const export_dir_off: u32 = 0x200;
        const dll_name_off: u32 = 0x228;
        const thunks_off: u32 = 0x268;
        const thunk_size: u32 = 10; // 6 bytes for jmp + 4 bytes for the target address
        const funcs_off: u32 = thunks_off + @as(u32, @intCast(n)) * thunk_size;
        const names_off: u32 = funcs_off + @as(u32, @intCast(n)) * 4;
        const ords_off: u32 = names_off + @as(u32, @intCast(n)) * 4;
        const strings_off: u32 = ords_off + @as(u32, @intCast(n)) * 2;

        // Write DLL name
        const dll_copy_len = @min(dll_name.len, @as(usize, 63));
        @memcpy(header[dll_name_off .. dll_name_off + dll_copy_len], dll_name[0..dll_copy_len]);
        header[dll_name_off + dll_copy_len] = 0;

        // Collect exports sorted by name (PE requires name table sorted)
        var sorted_names: [64][]const u8 = undefined;
        var sorted_addrs: [64]usize = undefined;
        var idx: usize = 0;
        var it = builtin.exports.iterator();
        while (it.next()) |entry| {
            if (idx >= 64) break;
            sorted_names[idx] = entry.key_ptr.*;
            sorted_addrs[idx] = entry.value_ptr.addr;
            idx += 1;
        }
        const count = idx;

        // Simple insertion sort by name
        var i: usize = 1;
        while (i < count) : (i += 1) {
            var j = i;
            while (j > 0) {
                const order = std.mem.order(u8, sorted_names[j], sorted_names[j - 1]);
                if (order == .lt) {
                    const tmp_name = sorted_names[j];
                    sorted_names[j] = sorted_names[j - 1];
                    sorted_names[j - 1] = tmp_name;
                    const tmp_addr = sorted_addrs[j];
                    sorted_addrs[j] = sorted_addrs[j - 1];
                    sorted_addrs[j - 1] = tmp_addr;
                    j -= 1;
                } else break;
            }
        }

        var str_pos: u32 = strings_off;
        for (0..count) |si| {
            // Build a jmp thunk: FF 25 [absolute 4-byte addr]
            // This is an indirect jump through an absolute address.
            // On x86: FF 25 DD CC BB AA  → jmp dword ptr [0xAABBCCDD]
            // We store the target address right after the instruction bytes.
            const thunk_addr = thunks_off + @as(u32, @intCast(si)) * thunk_size;
            header[thunk_addr + 0] = 0xFF; // jmp
            header[thunk_addr + 1] = 0x25; // [disp32]
            // The disp32 is the absolute address of the 4 bytes that hold the target
            @as(*align(1) u32, @ptrFromInt(base + thunk_addr + 2)).* = base32 + thunk_addr + 6;
            // The actual target address (stored at thunk+6)
            // On x86_64, stub addresses are above 4GB (in the Zig binary) and
            // can't fit in the 32-bit jmp thunk. Truncate — these thunks are
            // only used by games that manually parse PE exports (very rare).
            @as(*align(1) u32, @ptrFromInt(base + thunk_addr + 6)).* = @truncate(sorted_addrs[si]);

            // Function RVA → thunk offset
            @as(*align(1) u32, @ptrFromInt(base + funcs_off + si * 4)).* = thunk_addr;
            // Name RVA → string offset
            @as(*align(1) u32, @ptrFromInt(base + names_off + si * 4)).* = str_pos;
            // Ordinal index
            @as(*align(1) u16, @ptrFromInt(base + ords_off + si * 2)).* = @intCast(si);

            // Write name string
            const name_str = sorted_names[si];
            const name_len: u32 = @intCast(@min(name_str.len, @as(usize, 4096 - str_pos - 1)));
            @memcpy(header[str_pos .. str_pos + name_len], name_str[0..name_len]);
            header[str_pos + name_len] = 0;
            str_pos += name_len + 1;
        }

        // Write IMAGE_EXPORT_DIRECTORY (40 bytes at export_dir_off)
        @as(*align(1) u32, @ptrFromInt(base + export_dir_off + 0x0C)).* = dll_name_off; // Name RVA
        @as(*align(1) u32, @ptrFromInt(base + export_dir_off + 0x10)).* = 1; // Base
        @as(*align(1) u32, @ptrFromInt(base + export_dir_off + 0x14)).* = @intCast(count); // NumberOfFunctions
        @as(*align(1) u32, @ptrFromInt(base + export_dir_off + 0x18)).* = @intCast(count); // NumberOfNames
        @as(*align(1) u32, @ptrFromInt(base + export_dir_off + 0x1C)).* = funcs_off; // AddressOfFunctions RVA
        @as(*align(1) u32, @ptrFromInt(base + export_dir_off + 0x20)).* = names_off; // AddressOfNames RVA
        @as(*align(1) u32, @ptrFromInt(base + export_dir_off + 0x24)).* = ords_off; // AddressOfNameOrdinals RVA

        // Set DataDirectory[0] (Export) — at offset 0xB8 from file start
        @as(*align(1) u32, @ptrFromInt(base + 0xB8)).* = export_dir_off; // VirtualAddress (RVA)
        @as(*align(1) u32, @ptrFromInt(base + 0xBC)).* = 40; // Size

        // Make the page executable (thunks need to be executable)
        platform.mprotect(@intCast(base), 4096, true, true, true);
    }

    /// Resolves an imported function by name from built-in stubs or loaded PE modules.
    pub fn resolveExport(self: *Environment, dll_name: []const u8, func_name: []const u8) ?BuiltinExport {
        var lower_buf: [256]u8 = undefined;
        var search_dll: []const u8 = dll_name;
        if (dll_name.len <= lower_buf.len) {
            const lower = lower_buf[0..dll_name.len];
            _ = std.ascii.lowerString(lower, dll_name);
            search_dll = lower;
        }

        // Check builtin stubs FIRST — these are our verified implementations
        // and take priority over PE exports (e.g. proxy/wrapper DLLs like
        // dxwrapper whose forwarding thunks may point to a missing system DLL).
        if (self.builtins.get(search_dll)) |builtin| {
            if (builtin.exports.get(func_name)) |exp| {
                return exp;
            }
        }

        // Fallback: check PE DLLs loaded from disk
        if (self.registry.modules.get(search_dll)) |mod| {
            if (mod.getExport(func_name)) |exported_addr| {
                return .{ .addr = exported_addr, .param_bytes = 0, .is_native = false };
            }
        }

        // Windows API set DLLs: redirect api-ms-win-crt-* to MSVCRT.dll
        // and api-ms-win-core-* to kernel32.dll (Universal CRT forwarding).
        if (std.ascii.startsWithIgnoreCase(search_dll, "api-ms-win-crt-")) {
            if (self.builtins.get("msvcrt.dll")) |builtin| {
                if (builtin.exports.get(func_name)) |exp| {
                    return exp;
                }
            }
        } else if (std.ascii.startsWithIgnoreCase(search_dll, "api-ms-win-core-")) {
            if (self.builtins.get("kernel32.dll")) |builtin| {
                if (builtin.exports.get(func_name)) |exp| {
                    return exp;
                }
            }
        }

        return null;
    }
};

const testing = std.testing;

/// Guest memory stand-in: hands out 16-byte-aligned addresses from a fixed
/// base, so a test reads the address each export was given.
const SequencedGuestMemory = struct {
    next: u32,

    pub fn guestAlloc(self: *@This(), size: u32) u32 {
        const addr = self.next;
        self.next += (size + 15) & ~@as(u32, 15);
        return addr;
    }
};

test "data exports relocate in module then name order, whatever order they registered" {
    const guest_base: u32 = 0x0040_0000;
    const names = [_]struct { dll: []const u8, name: []const u8, byte: u8 }{
        .{ .dll = "MSVCRT.dll", .name = "_iob", .byte = 1 },
        .{ .dll = "KERNEL32.dll", .name = "zz_data", .byte = 2 },
        .{ .dll = "MSVCRT.dll", .name = "__pioinfo", .byte = 3 },
        .{ .dll = "ADVAPI32.dll", .name = "mid_data", .byte = 4 },
        .{ .dll = "MSVCRT.dll", .name = "_nhandle", .byte = 5 },
        .{ .dll = "KERNEL32.dll", .name = "aa_data", .byte = 6 },
    };

    // Sorted by (dll, name), which is the order the addresses must follow.
    const sorted = [_]usize{ 3, 5, 1, 2, 0, 4 };

    var env = Environment.init(testing.allocator);
    defer env.deinit();

    var storage: [names.len][8]u8 = undefined;
    for (names, 0..) |n, i| {
        @memset(&storage[i], n.byte);
        try env.addBuiltinDataExport(n.dll, n.name, @intFromPtr(&storage[i]), 8);
    }

    var buf: [names.len * 16]u8 = undefined;
    var gmem = SequencedGuestMemory{ .next = guest_base };
    try env.relocateDataExports(&gmem, &buf, guest_base);

    for (sorted, 0..) |n, slot| {
        const exp = env.resolveExport(names[n].dll, names[n].name).?;
        try testing.expectEqual(guest_base + @as(u32, @intCast(slot * 16)), exp.addr);
        // The host bytes travelled with the address.
        const off: usize = exp.addr - guest_base;
        try testing.expectEqualSlices(u8, &storage[n], buf[off..][0..8]);
    }
}
