//! WASM binary emitter.
//!
//! This module provides the `Buffer` and `WasmModule` structs for
//! programmatically constructing WebAssembly binary modules. It handles
//! section generation and LEB128 encoding of integers.

const std = @import("std");
const wasm = @import("wasm.zig");

/// A simple byte buffer that supports LEB128 encoding.
pub const Buffer = struct {
    /// The allocator used for the buffer's backing storage.
    allocator: std.mem.Allocator,
    /// The raw bytes currently in the buffer.
    bytes: std.ArrayListUnmanaged(u8),

    /// Initializes a new, empty Buffer.
    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{
            .allocator = allocator,
            .bytes = .{},
        };
    }

    /// Frees all memory associated with the buffer.
    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.allocator);
    }

    /// Appends a single byte to the buffer.
    pub fn append(self: *Buffer, byte: u8) !void {
        try self.bytes.append(self.allocator, byte);
    }

    /// Appends a slice of bytes to the buffer.
    pub fn appendSlice(self: *Buffer, slice: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, slice);
    }

    /// Appends a 32-bit unsigned integer in ULEB128 encoding.
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

    /// Appends a 32-bit signed integer in ILEB128 encoding.
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

    /// Appends a WASM opcode byte to the buffer.
    pub fn appendOpcode(self: *Buffer, op: wasm.Opcode) !void {
        try self.append(@intFromEnum(op));
    }
};

/// A builder for a complete WASM binary module.
pub const WasmModule = struct {
    /// The allocator used for all module sections.
    allocator: std.mem.Allocator,
    /// The Type section (section ID 1).
    type_section: Buffer,
    /// The Import section (section ID 2).
    import_section: Buffer,
    /// The Function section (section ID 3).
    func_section: Buffer,
    /// The Export section (section ID 7).
    export_section: Buffer,
    /// The Code section (section ID 10).
    code_section: Buffer,

    /// Initializes a new WasmModule builder.
    pub fn init(allocator: std.mem.Allocator) WasmModule {
        return .{
            .allocator = allocator,
            .type_section = Buffer.init(allocator),
            .import_section = Buffer.init(allocator),
            .func_section = Buffer.init(allocator),
            .export_section = Buffer.init(allocator),
            .code_section = Buffer.init(allocator),
        };
    }

    /// Frees all memory associated with the builder's sections.
    pub fn deinit(self: *WasmModule) void {
        self.type_section.deinit();
        self.import_section.deinit();
        self.func_section.deinit();
        self.export_section.deinit();
        self.code_section.deinit();
    }

    /// Writes a single section to the output buffer.
    fn writeSection(out: *Buffer, id: wasm.SectionId, content: *const Buffer) !void {
        if (content.bytes.items.len == 0) return;
        try out.append(@intFromEnum(id));
        try out.appendUleb128(@as(u32, @intCast(content.bytes.items.len)));
        try out.appendSlice(content.bytes.items);
    }

    /// Finalizes the module and returns the complete WASM binary.
    /// The caller is responsible for freeing the returned slice.
    pub fn finish(self: *WasmModule) ![]u8 {
        var out = Buffer.init(self.allocator);
        errdefer out.deinit();

        try out.appendSlice(&wasm.magic);
        try out.appendSlice(&wasm.version);

        try writeSection(&out, .type_, &self.type_section);
        try writeSection(&out, .import, &self.import_section);
        try writeSection(&out, .func, &self.func_section);
        try writeSection(&out, .export_, &self.export_section);
        try writeSection(&out, .code, &self.code_section);

        return out.bytes.toOwnedSlice(self.allocator);
    }
};
