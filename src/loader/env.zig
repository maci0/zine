const std = @import("std");
const pe = @import("../pe.zig");
pub const Module = @import("module.zig").Module;
const Registry = @import("registry.zig").Registry;
const x86_cpu = @import("../x86/cpu.zig");
const x86_thunks = @import("../x86/thunks.zig");
const platform = @import("../platform.zig");

const Cpu = x86_cpu.Cpu;

pub const BuiltinExport = struct {
    addr: usize,
    param_bytes: u32,
    /// On WASM, a comptime-generated handler that reads args from the guest
    /// stack and calls the actual stub function with the correct signature.
    /// Null on native (where we can use @ptrFromInt to call directly).
    thunk_handler: ?*const fn (*Cpu) void = null,
};

pub const BuiltinModule = struct {
    handle: usize,
    exports: std.StringHashMap(BuiltinExport),
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    registry: Registry,

    // Fallback static map for built-in/stubbed exports
    builtins: std.StringHashMap(BuiltinModule),

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .builtins = std.StringHashMap(BuiltinModule).init(allocator),
        };
    }

    pub fn deinit(self: *Environment) void {
        var it = self.builtins.iterator();
        while (it.next()) |entry| {
            var val = entry.value_ptr.*;
            val.exports.deinit();
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

        // Allocate a page for the fake PE header
        const header = try self.allocator.alloc(u8, 4096);
        @memset(header, 0);

        // Minimal MZ/PE header
        const mz = @as(*align(1) u16, @ptrCast(&header[0]));
        mz.* = 0x5A4D; // "MZ"
        const e_lfanew = @as(*align(1) u32, @ptrCast(&header[0x3C]));
        e_lfanew.* = 0x40;
        const pe_sig = @as(*align(1) u32, @ptrCast(&header[0x40]));
        pe_sig.* = 0x00004550; // "PE\0\0"

        const new_builtin = BuiltinModule{
            .handle = @intFromPtr(header.ptr),
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

    /// Register a typed Zig function as a built-in export.
    /// On WASM, this generates an intelligent thunk handler that unwraps
    /// guest arguments into the native function signature safely.
    pub fn addBuiltinExportComptime(self: *Environment, dll: []const u8, name: []const u8, comptime func: anytype) !void {
        const info = @typeInfo(@TypeOf(func));
        comptime var param_len: usize = 0;
        comptime var is_bare_fn = false;
        if (info == .pointer and @typeInfo(info.pointer.child) == .@"fn") {
            param_len = @typeInfo(info.pointer.child).@"fn".params.len;
        } else if (info == .@"fn") {
            param_len = info.@"fn".params.len;
            is_bare_fn = true;
        } else {
            @compileError("addBuiltinExportComptime requires a function or function pointer");
        }
        const param_bytes = param_len * 4;
        const addr = if (is_bare_fn) @intFromPtr(&func) else @intFromPtr(func);

        // On WASM, generate a comptime thunk handler that reads args from the
        // guest stack and calls the function with the exact correct signature.
        // On native, the thunk_handler is null (dispatchNativeCall handles it).
        const handler: ?*const fn (*Cpu) void = if (comptime platform.is_wasm)
            &(struct {
                // Convert any return value to u32 for EAX
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

                fn callAndConvert(fptr: anytype, args: [16]u32) u32 {
                    // Get the actual function type info to know each parameter's type
                    const FnType = if (is_bare_fn) @TypeOf(func) else @typeInfo(@TypeOf(func)).pointer.child;
                    const fn_info = @typeInfo(FnType).@"fn";

                    // Build a tuple of correctly-typed arguments
                    var call_args: std.meta.ArgsTuple(FnType) = undefined;
                    inline for (0..param_len) |i| {
                        const ParamType = fn_info.params[i].type.?;
                        call_args[i] = castArg(ParamType, args[i]);
                    }

                    const result = @call(.auto, fptr, call_args);
                    return toU32(result);
                }

                fn castArg(comptime T: type, val: u32) T {
                    const ti = @typeInfo(T);
                    return switch (ti) {
                        .pointer => @ptrFromInt(val),
                        .optional => |opt| blk: {
                            if (@typeInfo(opt.child) == .pointer) {
                                break :blk if (val == 0) null else @as(T, @ptrFromInt(val));
                            }
                            break :blk @bitCast(val);
                        },
                        .int => |int_info| blk: {
                            if (int_info.signedness == .signed) {
                                if (int_info.bits <= 32) {
                                    break :blk @truncate(@as(i32, @bitCast(val)));
                                }
                                break :blk @as(T, @as(i32, @bitCast(val)));
                            } else {
                                break :blk @truncate(val);
                            }
                        },
                        .bool => val != 0,
                        .@"enum" => @enumFromInt(val),
                        else => @bitCast(val),
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

                    cpu.eax = callAndConvert(fptr, args);

                    // Stdcall: callee pops parameters
                    cpu.esp +%= @as(u32, param_len * 4);

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

    /// Recursively registers all function pointers in a COM VTable struct
    /// to the native thunk registry so the interpreter doesn't crash if
    /// a COM method is called natively.
    pub fn addBuiltinVtableComptime(self: *Environment, comptime VTableType: type, vtable: *const VTableType) void {
        _ = self;
        if (comptime platform.is_native) {
            const info = @typeInfo(VTableType);
            if (info != .@"struct") @compileError("VTableType must be a struct");
            
            inline for (info.@"struct".fields) |field| {
                const func_ptr = @field(vtable, field.name);
                const FuncType = @TypeOf(func_ptr);

                var target_ptr: usize = 0;
                var param_len: u32 = 0;

                switch (@typeInfo(FuncType)) {
                    .pointer => |p| {
                        if (@typeInfo(p.child) == .@"fn") {
                            target_ptr = @intFromPtr(func_ptr);
                            param_len = @intCast(@typeInfo(p.child).@"fn".params.len);
                        }
                    },
                    .optional => |opt| {
                        if (@typeInfo(opt.child) == .pointer) {
                            const p = @typeInfo(opt.child).pointer;
                            if (@typeInfo(p.child) == .@"fn") {
                                if (func_ptr) |ptr| {
                                    target_ptr = @intFromPtr(ptr);
                                    param_len = @intCast(@typeInfo(p.child).@"fn".params.len);
                                }
                            }
                        }
                    },
                    .int => {
                        // Sometimes dummy entries are typed as usize
                        target_ptr = @intCast(func_ptr);
                    },
                    else => {},
                }

                if (target_ptr != 0) {
                    x86_thunks.registerNativeImport(
                        @intCast(target_ptr),
                        "COM",
                        field.name,
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

    /// Resolves an imported function by name from loaded PE modules or built-in stubs.
    pub fn resolveExport(self: *Environment, dll_name: []const u8, func_name: []const u8) ?BuiltinExport {
        // First, try loaded PE modules (they can export functions)
        var lower_buf: [256]u8 = undefined;
        var search_dll: []const u8 = dll_name;
        if (dll_name.len <= lower_buf.len) {
            const lower = lower_buf[0..dll_name.len];
            _ = std.ascii.lowerString(lower, dll_name);
            search_dll = lower;
        }

        // Check PE DLLs from the registry that were loaded from disk
        if (self.registry.modules.get(search_dll)) |mod| {
            if (mod.getExport(func_name)) |exported_addr| {
                return .{ .addr = exported_addr, .param_bytes = 0 };
            }
        }

        // Fallback: check builtin stubs
        if (self.builtins.get(search_dll)) |builtin| {
            if (builtin.exports.get(func_name)) |exp| {
                return exp;
            }
        }
        return null;
    }
};
