//! Fuzz harness for the PE string-table walk behind LoadStringA/LoadStringW.
//!
//! One input is one mapped image, the bytes a module's `mapped_memory` holds
//! after the sections are placed. The walk starts at the resource data
//! directory, follows three directory levels of PE-supplied offsets, then
//! steps through 16 length-prefixed UTF-16 strings, so every offset it
//! dereferences comes from the file.

const std = @import("std");
const pe = @import("../pe.zig");
const pe_resources = @import("../pe_resources.zig");
const resource = @import("../win32/user32/resource.zig");

/// RVAs of the pieces the seed image below places.
pub const res_rva: u32 = 0x100;
const res_size: u32 = 0x200;
const data_rva: u32 = 0x300;
const image_len = 4096;

/// Strings written into block 1 of the seed image, in `uID & 0xF` order.
pub const seed_strings = [_][]const u16{ &.{ 'H', 'e', 'l', 'l', 'o' }, &.{ 'W', 'o', 'r', 'l', 'd' } };

/// Build a mapped image whose RT_STRING block 1 holds `seed_strings`.
/// Returned by value so the seed corpus is a compile-time constant.
fn buildImage() [image_len]u8 {
    var buf = [_]u8{0} ** image_len;
    const dos: *pe.IMAGE_DOS_HEADER = @ptrCast(@alignCast(&buf));
    dos.e_magic = pe.IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = 64;

    const nt: *pe.IMAGE_NT_HEADERS32 = @ptrCast(@alignCast(buf[64..].ptr));
    nt.Signature = pe.IMAGE_NT_SIGNATURE;
    nt.FileHeader.Machine = 0x014C; // i386
    nt.FileHeader.SizeOfOptionalHeader = @sizeOf(pe.IMAGE_OPTIONAL_HEADER32);
    nt.OptionalHeader.Magic = 0x010B;
    nt.OptionalHeader.ImageBase = 0x00400000;
    nt.OptionalHeader.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_RESOURCE] = .{
        .VirtualAddress = res_rva,
        .Size = res_size,
    };

    // Root -> RT_STRING(6) -> block 1 -> language 0x409 -> data entry.
    const dir = struct {
        fn write(image: []u8, off: u32, id: u32, target: u32, is_dir: bool) void {
            const d: *pe.IMAGE_RESOURCE_DIRECTORY = @ptrCast(@alignCast(image[off..].ptr));
            d.NumberOfIdEntries = 1;
            const e: *pe.IMAGE_RESOURCE_DIRECTORY_ENTRY = @ptrCast(@alignCast(image[off + @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY) ..].ptr));
            e.NameOrId = id;
            e.OffsetToData = target | if (is_dir) 0x80000000 else 0;
        }
    }.write;

    dir(&buf, res_rva, pe_resources.RT_STRING, 0x80, true);
    dir(&buf, res_rva + 0x80, 1, 0xC0, true);
    dir(&buf, res_rva + 0xC0, 0x409, 0x100, false);

    const data_entry: *pe.IMAGE_RESOURCE_DATA_ENTRY = @ptrCast(@alignCast(buf[res_rva + 0x100 ..].ptr));
    data_entry.OffsetToData = data_rva;
    data_entry.Size = 0x40;

    var off: u32 = data_rva;
    for (seed_strings) |s| {
        const len: *u16 = @ptrCast(@alignCast(buf[off..].ptr));
        len.* = @intCast(s.len);
        for (s, 0..) |wc, i| {
            const dst: *u16 = @ptrCast(@alignCast(buf[off + 2 + 2 * i ..].ptr));
            dst.* = wc;
        }
        off += 2 + 2 * @as(u32, @intCast(s.len));
    }
    return buf;
}

const string_table_image = buildImage();

const no_resource_image = blk: {
    var buf = string_table_image;
    @memset(buf[64..][0..@sizeOf(pe.IMAGE_NT_HEADERS32)], 0);
    break :blk buf;
};

/// Seed corpus: an image with a real string table, the same image with the
/// resource directory removed, and a bare MZ header.
pub const seeds = [_][]const u8{
    &string_table_image,
    &no_resource_image,
    &([_]u8{ 'M', 'Z' } ++ [_]u8{0} ** 62),
};

/// Buffer sizes the harness copies into, small enough that a length field
/// larger than them is truncated rather than trusted.
const narrow_buf_len = 64;
const wide_buf_len = 64;

/// String ids the harness asks for: the strings the seed table holds, plus
/// one past the end of the block, where a walk must stop.
const checked_ids: usize = 4;

/// Errors that mean the walk produced something impossible: a string that
/// does not fit the caller's buffer without a terminator, or the two walkers
/// over the same image disagreeing on its length.
pub const Failure = error{
    NarrowStringOverflowedBuffer,
    WideStringOverflowedBuffer,
    UnterminatedNarrowString,
    UnterminatedWideString,
    WalkerLengthMismatch,
};

/// Runs one mapped image through both string-table walks for the string ids
/// a guest can ask for and checks the invariants every load must satisfy.
pub fn harness(allocator: std.mem.Allocator, data: []u8) Failure!void {
    _ = allocator;

    for (0..checked_ids) |uID| {
        var narrow: [narrow_buf_len]u8 = undefined;
        const narrow_len = resource.loadStringFromImage(data, @intCast(uID), &narrow, narrow_buf_len);
        if (narrow_len >= narrow_buf_len) return error.NarrowStringOverflowedBuffer;
        // A string the walk rejects leaves the buffer for the stub to clear,
        // so only a returned string carries the terminator the API promises.
        if (narrow_len > 0 and narrow[narrow_len] != 0) return error.UnterminatedNarrowString;

        var wide: [wide_buf_len]u16 = undefined;
        const wide_len = resource.loadStringFromImageW(data, @intCast(uID), &wide, wide_buf_len);
        if (wide_len >= wide_buf_len) return error.WideStringOverflowedBuffer;
        if (wide_len > 0 and wide[wide_len] != 0) return error.UnterminatedWideString;

        // Both walks resolve the same length-prefixed string, so the wide
        // copy must return the same character count as the narrow one.
        if (narrow_len != wide_len) return error.WalkerLengthMismatch;
    }
}
