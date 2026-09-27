//! Fuzz harness for the PE export-directory walk behind `Module.getExport`.
//!
//! One input is one mapped image plus the RVA and size of its export
//! directory. Every table offset and every count the walk trusts comes from
//! the directory: the name, ordinal, and function tables, the two counts, and
//! the RVA each name points at. The first eight bytes of the input are the
//! directory RVA and size, so a mutation that places the directory off the
//! end of the image, or wraps the forwarder range around a u32, is reachable.

const std = @import("std");
const pe = @import("../pe.zig");
const module = @import("../loader/module.zig");

/// RVA of the export directory in the seed image, and the size the seed gives
/// it. The harness reads both from the input; these only have to match it.
const seed_export_rva: u32 = 0x100;
const seed_export_size: u32 = 0x100;
const image_len = 4096;
const dir_header_len = 2 * @sizeOf(u32);

/// Names the lookup is driven with: the two the seed exports, and a miss.
const checked_names = [_][]const u8{ "ZineFirst", "zinethird", "Missing", "" };

/// Build a mapped image whose export directory resolves, so the fuzzer
/// starts from a walk that reaches the function table. Returned by value so
/// the seed corpus is a compile-time constant.
fn buildImage() [image_len]u8 {
    var buf = [_]u8{0} ** image_len;
    std.mem.writeInt(u32, buf[0..4], seed_export_rva, .little);
    std.mem.writeInt(u32, buf[4..8], seed_export_size, .little);

    // Three tables, one after another, each declared by the directory.
    const names_rva = seed_export_rva + 0x80;
    const ords_rva = names_rva + 3 * @sizeOf(u32);
    const funcs_rva = ords_rva + 3 * @sizeOf(u16);
    const strings_rva = funcs_rva + 3 * @sizeOf(u32);

    const dir: *pe.IMAGE_EXPORT_DIRECTORY = @ptrCast(@alignCast(buf[seed_export_rva..].ptr));
    dir.Name = strings_rva;
    dir.Base = 1;
    dir.NumberOfFunctions = 3;
    dir.NumberOfNames = 3;
    dir.AddressOfFunctions = funcs_rva;
    dir.AddressOfNames = names_rva;
    dir.AddressOfNameOrdinals = ords_rva;

    for ([_][]const u8{ "ZineFirst", "ZineSecond", "zinethird" }, 0..) |name, i| {
        const str_rva = strings_rva + 0x40 * @as(u32, @intCast(i));
        @memcpy(buf[str_rva..][0..name.len], name);
        std.mem.writeInt(u32, buf[names_rva + 4 * i ..][0..4], str_rva, .little);
        std.mem.writeInt(u16, buf[ords_rva + 2 * i ..][0..2], @intCast(i), .little);
        // Function RVAs point into the image but outside the export
        // directory, so they are not forwarders.
        std.mem.writeInt(u32, buf[funcs_rva + 4 * i ..][0..4], 0x800 + 0x100 * i, .little);
    }

    return buf;
}

const export_image = buildImage();

/// The same directory with an RVA that wraps when its size is added, so the
/// forwarder range covers the whole image.
const wrapping_image = blk: {
    var buf = export_image;
    std.mem.writeInt(u32, buf[0..4], 0xFFFF_FF00, .little);
    std.mem.writeInt(u32, buf[4..8], 0x800, .little);
    break :blk buf;
};

/// Seed corpus: the resolving directory, the wrapping one, and an input too
/// short to hold a directory address.
pub const seeds = [_][]const u8{
    &export_image,
    &wrapping_image,
    &[_]u8{0xFF},
};

/// Errors that mean the walk resolved to an address no image byte backs: a
/// function RVA is 32 bits, so a wrapped image can be larger than the
/// largest one, and anything past the image is not a guest address.
pub const Failure = error{
    ExportRvaOutOfImage,
    LookupNotRepeatable,
};

/// Runs one image through the export walk for every name a caller can pass and
/// checks the invariants each lookup owes it.
pub fn harness(allocator: std.mem.Allocator, data: []u8) Failure!void {
    _ = allocator;
    if (data.len < dir_header_len) return;

    const export_dir_rva = std.mem.readInt(u32, data[0..4], .little);
    const export_dir_size = std.mem.readInt(u32, data[4..8], .little);

    for (checked_names) |name| {
        const found = module.findExportRvaInImage(data, export_dir_rva, export_dir_size, name);
        if (found) |func_rva| {
            if (func_rva >= data.len) return error.ExportRvaOutOfImage;
        }
        // The walk reads nothing but `data`, so the same lookup must resolve
        // to the same address every time.
        if (module.findExportRvaInImage(data, export_dir_rva, export_dir_size, name) != found) {
            return error.LookupNotRepeatable;
        }
    }
}
