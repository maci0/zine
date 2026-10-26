//! Native adapters for pointer slots in the guest's fixed 32-bit ABI.
const std = @import("std");
const platform = @import("../platform.zig");

pub fn isPointerSlot(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) return false;
    const child = @typeInfo(info.pointer.child);
    return child == .pointer or (child == .optional and @typeInfo(child.optional.child) == .pointer);
}

/// Fully implemented: stage pointer outputs in host-sized slots, then copy
/// back exactly four bytes so adjacent guest memory is never overwritten.
pub fn nativeAddress(comptime func: anytype) usize {
    const Fn = if (@typeInfo(@TypeOf(func)) == .@"fn") @TypeOf(func) else @typeInfo(@TypeOf(func)).pointer.child;
    const info = @typeInfo(Fn).@"fn";
    comptime var needs_adapter = false;
    inline for (info.params) |param| {
        if (comptime isPointerSlot(param.type.?)) needs_adapter = true;
    }
    if (comptime !platform.is_x86_64 or !needs_adapter) return if (@typeInfo(@TypeOf(func)) == .@"fn") @intFromPtr(&func) else @intFromPtr(func);
    return @intFromPtr(&struct {
        fn call(a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize, a10: usize, a11: usize, a12: usize, a13: usize, a14: usize, a15: usize) callconv(info.calling_convention) usize {
            const raw = [_]usize{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 };
            var slots: [16]usize = @splat(0);
            var args: std.meta.ArgsTuple(Fn) = undefined;
            inline for (info.params, 0..) |param, i| {
                const T = param.type.?;
                if (comptime isPointerSlot(T)) {
                    if (raw[i] != 0) {
                        slots[i] = @as(*align(1) const u32, @ptrFromInt(raw[i])).*;
                        args[i] = @ptrCast(&slots[i]);
                    } else args[i] = @ptrFromInt(raw[i]);
                } else {
                    args[i] = switch (@typeInfo(T)) {
                        .pointer => @ptrFromInt(raw[i]),
                        .optional => if (raw[i] == 0) null else @ptrFromInt(raw[i]),
                        .int => @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(raw[i]))),
                        .bool => raw[i] != 0,
                        else => @compileError("unsupported compat pointer-output parameter"),
                    };
                }
            }
            const result = @call(.auto, func, args);
            inline for (info.params, 0..) |param, i| {
                if (comptime isPointerSlot(param.type.?)) {
                    if (raw[i] != 0) @as(*align(1) u32, @ptrFromInt(raw[i])).* = @intCast(slots[i]);
                }
            }
            return switch (@typeInfo(info.return_type.?)) {
                .void => 0,
                .int => @as(std.meta.Int(.unsigned, @bitSizeOf(info.return_type.?)), @bitCast(result)),
                else => @compileError("unsupported compat pointer-output result"),
            };
        }
    }.call);
}

test "compat pointer output preserves neighbouring guest words and signed return" {
    if (comptime !platform.is_x86_64) return;
    const Stub = struct {
        fn output(value: u32, slot: *?*anyopaque) callconv(.winapi) i32 {
            slot.* = @ptrFromInt(value);
            return -1;
        }
    };
    const mem = try platform.mmap(null, 4096, false, -1, 0, false, false);
    defer platform.munmap(mem);
    const words: *[3]u32 = @ptrCast(mem.ptr);
    words.* = .{ 0x11223344, 0, 0x55667788 };
    const result = @import("thunks.zig").callNativeByArity(nativeAddress(Stub.output), 8, .{ 0x12345678, @as(u32, @intCast(@intFromPtr(&words[1]))) } ++ .{0} ** 14);
    try std.testing.expectEqual(@as(u32, 0xffffffff), result);
    try std.testing.expectEqualSlices(u32, &.{ 0x11223344, 0x12345678, 0x55667788 }, words);
}
