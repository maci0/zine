const std = @import("std");
const wasm = @import("wasm.zig");

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{
            .allocator = allocator,
            .bytes = .{},
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn append(self: *Buffer, byte: u8) !void {
        try self.bytes.append(self.allocator, byte);
    }

    pub fn appendSlice(self: *Buffer, slice: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, slice);
    }

    pub fn appendUleb128(self: *Buffer, value: u32) !void {
        var v = value;
        while (true) {
            const byte: u8 = @truncate(v & 0x7F);
            v >>= 7;
            if (v == 0) {
                try self.append(byte);
                break;
            } else {
                try self.append(byte | 0x80);
            }
        }
    }

    pub fn appendIleb128(self: *Buffer, value: i32) !void {
        var v = value;
        var more = true;
        while (more) {
            var byte: u8 = @truncate(@as(u32, @bitCast(v)) & 0x7F);
            v >>= 7;
            const sign_bit_set = (byte & 0x40) != 0;

            if ((v == 0 and !sign_bit_set) or (v == -1 and sign_bit_set)) {
                more = false;
            } else {
                byte |= 0x80;
            }
            try self.append(byte);
        }
    }

    pub fn appendOpcode(self: *Buffer, op: wasm.Opcode) !void {
        try self.append(@intFromEnum(op));
    }
};

pub const WasmModule = struct {
    allocator: std.mem.Allocator,
    type_section: Buffer,
    func_section: Buffer,
    export_section: Buffer,
    code_section: Buffer,

    pub fn init(allocator: std.mem.Allocator) WasmModule {
        return .{
            .allocator = allocator,
            .type_section = Buffer.init(allocator),
            .func_section = Buffer.init(allocator),
            .export_section = Buffer.init(allocator),
            .code_section = Buffer.init(allocator),
        };
    }

    pub fn deinit(self: *WasmModule) void {
        self.type_section.deinit();
        self.func_section.deinit();
        self.export_section.deinit();
        self.code_section.deinit();
    }

    fn writeSection(out: *Buffer, id: wasm.SectionId, content: *const Buffer) !void {
        if (content.bytes.items.len == 0) return;
        try out.append(@intFromEnum(id));
        try out.appendUleb128(@as(u32, @intCast(content.bytes.items.len)));
        try out.appendSlice(content.bytes.items);
    }

    pub fn finish(self: *WasmModule) ![]u8 {
        var out = Buffer.init(self.allocator);
        errdefer out.deinit();

        try out.appendSlice(&wasm.magic);
        try out.appendSlice(&wasm.version);

        try writeSection(&out, .type_, &self.type_section);
        try writeSection(&out, .func, &self.func_section);
        try writeSection(&out, .export_, &self.export_section);
        try writeSection(&out, .code, &self.code_section);

        return out.bytes.toOwnedSlice(self.allocator);
    }
};

test "leb128 unsigned" {
    var buf = Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try buf.appendUleb128(624485);
    try std.testing.expectEqualSlices(u8, &.{ 0xE5, 0x8E, 0x26 }, buf.bytes.items);
}

test "leb128 signed" {
    var buf = Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try buf.appendIleb128(-123456);
    try std.testing.expectEqualSlices(u8, &.{ 0xC0, 0xBB, 0x78 }, buf.bytes.items);
}
