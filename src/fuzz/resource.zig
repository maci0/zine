//! Fuzz harness for the PE resource-directory walk behind
//! `Module.getResource` and its siblings.
//!
//! One input is one mapped image plus the RVA its resource directory lives
//! at. Every offset the walk dereferences comes from the file: the directory
//! header's entry counts, three levels of subdirectory offsets, a data entry's
//! RVA and size, and a named entry's UTF-16 length word. The first four bytes
//! of the input are the directory RVA, so a mutation that walks off the start
//! of the image is reachable too.

const std = @import("std");
const pe_resources = @import("../pe_resources.zig");
const module = @import("../loader/module.zig");

/// RVA the seed image below places its resource directory at. The harness
/// reads the RVA from the input, so this only has to match the seed.
const seed_res_rva: u32 = 0x100;
const image_len = 4096;
const rva_len = @sizeOf(u32);

/// Resource types and ids the harness asks for, in a range that covers the
/// real types (1..24) and the ids around them.
const checked_types = [_]u32{ pe_resources.RT_ICON, pe_resources.RT_DIALOG, pe_resources.RT_STRING, 24, 0 };
const checked_ids = [_]u32{ 0, 1, 2, 16, 0xFFFF_FFFF };

/// Names the by-name lookup is driven with, short and long enough that the
/// length word and the character loop both run.
const checked_names = [_][]const u8{ "MAINICON", "mainicon", "a", "" };

/// Build a mapped image whose resource tree resolves, so the fuzzer starts
/// from a walk that actually reaches the data entry. Returned by value so the
/// seed corpus is a compile-time constant.
fn buildImage() [image_len]u8 {
    var buf = [_]u8{0} ** image_len;
    std.mem.writeInt(u32, buf[0..4], seed_res_rva, .little);

    const dir = struct {
        const header_len = @sizeOf(pe_resources.IMAGE_RESOURCE_DIRECTORY);

        /// A directory with `count` id entries, each `id` pointing at `target`.
        fn write(image: []u8, off: u32, ids: []const u32, targets: []const u32, first_is_dir: bool) void {
            std.mem.writeInt(u16, image[off + 12 ..][0..2], 0, .little); // NumberOfNamedEntries
            std.mem.writeInt(u16, image[off + 14 ..][0..2], @intCast(ids.len), .little);
            for (ids, targets, 0..) |id, target, i| {
                const entry = off + header_len + @as(u32, @intCast(i)) * @sizeOf(pe_resources.IMAGE_RESOURCE_DIRECTORY_ENTRY);
                std.mem.writeInt(u32, image[entry..][0..4], id, .little);
                const bit: u32 = if (first_is_dir and i == 0) 0x80000000 else 0;
                std.mem.writeInt(u32, image[entry + 4 ..][0..4], target | bit, .little);
            }
        }
    };

    // Root: RT_ICON(3) -> id dir, and RT_DIALOG(5) -> a dir holding the named
    // entry "MAINICON". The second type is a plain id entry the by-name walk
    // matches on raw.
    dir.write(&buf, seed_res_rva, &.{ pe_resources.RT_ICON, pe_resources.RT_DIALOG }, &.{ 0x80, 0x40 }, true);
    dir.write(&buf, seed_res_rva + 0x80, &.{1}, &.{0xC0}, true);
    dir.write(&buf, seed_res_rva + 0xC0, &.{0x409}, &.{0x100}, false);

    // Data entry: RVA seed_res_rva + 0x200, size 8.
    std.mem.writeInt(u32, buf[seed_res_rva + 0x100 ..][0..4], seed_res_rva + 0x200, .little);
    std.mem.writeInt(u32, buf[seed_res_rva + 0x104 ..][0..4], 8, .little);
    @memcpy(buf[seed_res_rva + 0x200 ..][0..8], "ICONDATA");

    // The named entry's string, at seed_res_rva + 0x180: a length word and
    // the wchars the by-name walk compares.
    const name_rva = seed_res_rva + 0x180;
    std.mem.writeInt(u16, buf[name_rva..][0..2], 8, .little);
    for ("MAINICON", 0..) |c, i| {
        std.mem.writeInt(u16, buf[name_rva + 2 + 2 * i ..][0..2], c, .little);
    }
    // Type dir: one NAMED entry (bit 31 set) naming the string above, and its
    // language dir, which in turn points at the data entry.
    std.mem.writeInt(u16, buf[seed_res_rva + 0x40 + 12 ..][0..2], 1, .little); // NumberOfNamedEntries
    std.mem.writeInt(u16, buf[seed_res_rva + 0x40 + 14 ..][0..2], 0, .little);
    std.mem.writeInt(u32, buf[seed_res_rva + 0x40 + 16 ..][0..4], 0x80000000 | 0x180, .little);
    std.mem.writeInt(u32, buf[seed_res_rva + 0x40 + 20 ..][0..4], 0x80000000 | 0x140, .little);
    dir.write(&buf, seed_res_rva + 0x140, &.{0x409}, &.{0x1C0}, false);
    std.mem.writeInt(u32, buf[seed_res_rva + 0x1C0 ..][0..4], seed_res_rva + 0x300, .little);
    std.mem.writeInt(u32, buf[seed_res_rva + 0x1C4 ..][0..4], 8, .little);
    @memcpy(buf[seed_res_rva + 0x300 ..][0..8], "NAMEDATA");

    return buf;
}

const tree_image = buildImage();

/// The same tree with a directory RVA past the end of the image, so the
/// harness starts from the case every bounds check has to reject.
const out_of_range_image = blk: {
    var buf = tree_image;
    std.mem.writeInt(u32, buf[0..4], 0xFFFF_0000, .little);
    break :blk buf;
};

/// Seed corpus: the resolving tree, the same tree at an unreachable RVA, and
/// an input too short to even hold the RVA.
pub const seeds = [_][]const u8{
    &tree_image,
    &out_of_range_image,
    &[_]u8{0xFF},
};

/// Errors that mean a lookup produced something impossible: bytes from
/// outside the image, or a walk that answers differently the second time it is
/// given the same image.
pub const Failure = error{
    ResourceSliceOutOfImage,
    LookupNotRepeatable,
};

fn checkResult(image: []const u8, data: ?[]const u8) Failure!void {
    const bytes = data orelse return;
    if (bytes.len == 0) return;
    const start = @intFromPtr(bytes.ptr) - @intFromPtr(image.ptr);
    if (start > image.len or image.len - start < bytes.len) return error.ResourceSliceOutOfImage;
}

/// Runs one image through every resource lookup a guest can trigger and checks
/// the invariants each one owes its caller.
pub fn harness(allocator: std.mem.Allocator, data: []u8) Failure!void {
    _ = allocator;
    if (data.len < rva_len) return;

    const res_dir_rva = std.mem.readInt(u32, data[0..4], .little);

    for (checked_types) |resource_type| {
        for (checked_ids) |resource_id| {
            const found = module.findResourceInImage(data, res_dir_rva, resource_type, resource_id);
            try checkResult(data, found);
            // The walk reads nothing but `data`, so the same lookup must
            // resolve to the same bytes every time.
            const again = module.findResourceInImage(data, res_dir_rva, resource_type, resource_id);
            if (found == null and again == null) continue;
            if (found == null or again == null or !std.mem.eql(u8, found.?, again.?)) {
                return error.LookupNotRepeatable;
            }
        }
        try checkResult(data, module.findFirstResourceInImage(data, res_dir_rva, resource_type));

        for (checked_names) |name| {
            try checkResult(data, module.findResourceByNameInImage(data, res_dir_rva, resource_type, name));
        }
    }
}
