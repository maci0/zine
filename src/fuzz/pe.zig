//! Fuzz harness for the PE header parser.
//!
//! One input is one raw PE image, the same bytes `loader` hands to
//! `PEParser.parse` before any section is mapped.

const std = @import("std");
const pe = @import("../pe.zig");

/// Build a minimal, well-formed PE32 image with `sections` section headers.
/// Returned by value so the seed corpus is a compile-time constant.
fn buildImage(comptime sections: u16, comptime file_len: usize) [file_len]u8 {
    var buf = [_]u8{0} ** file_len;
    const dos: *pe.IMAGE_DOS_HEADER = @ptrCast(@alignCast(&buf));
    dos.e_magic = pe.IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = 64;

    const nt: *pe.IMAGE_NT_HEADERS32 = @ptrCast(@alignCast(buf[64..].ptr));
    nt.Signature = pe.IMAGE_NT_SIGNATURE;
    nt.FileHeader.Machine = 0x014C; // i386
    nt.FileHeader.NumberOfSections = sections;
    nt.FileHeader.SizeOfOptionalHeader = @sizeOf(pe.IMAGE_OPTIONAL_HEADER32);
    nt.OptionalHeader.Magic = 0x010B;
    nt.OptionalHeader.ImageBase = 0x00400000;
    nt.OptionalHeader.SectionAlignment = 0x1000;
    nt.OptionalHeader.FileAlignment = 0x200;
    nt.OptionalHeader.Subsystem = pe.IMAGE_SUBSYSTEM_WINDOWS_GUI;

    for (0..sections) |i| {
        const header: *pe.IMAGE_SECTION_HEADER = @ptrCast(@alignCast(
            buf[64 + @sizeOf(pe.IMAGE_NT_HEADERS32) + i * @sizeOf(pe.IMAGE_SECTION_HEADER) ..].ptr,
        ));
        @memcpy(&header.Name, ".text\x00\x00\x00");
        header.Misc.VirtualSize = 0x1000;
        header.VirtualAddress = 0x1000 * (i + 1);
        header.SizeOfRawData = 0x200;
        header.PointerToRawData = 0x400 + 0x200 * i;
        header.Characteristics = pe.IMAGE_SCN_CNT_CODE;
    }
    return buf;
}

const image_one_section = buildImage(1, 512);
const image_three_sections = buildImage(3, 4096);
const image_no_sections = buildImage(0, 512);

/// Seed corpus: a minimal image, a three-section image, and a bare MZ header
/// so the fuzzer starts from inputs that reach the signature checks.
pub const seeds = [_][]const u8{
    &image_one_section,
    &image_three_sections,
    &image_no_sections,
    &([_]u8{ 'M', 'Z' } ++ [_]u8{0} ** 62),
};

/// Errors that mean the parser produced something impossible.
pub const Failure = error{
    SectionCountMismatch,
    SectionTableOutOfBounds,
    NtHeadersOutOfBounds,
    /// Reported by the allocator, not by a parser contract violation.
    OutOfMemory,
};

/// Runs one image through the parser and checks the invariants every
/// successful parse must satisfy.
pub fn harness(allocator: std.mem.Allocator, data: []u8) Failure!void {
    var parser = pe.PEParser.parse(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parser.deinit(allocator);

    const nt = parser.getNtHeaders();
    if (parser.sections.len != nt.FileHeader.NumberOfSections) return error.SectionCountMismatch;

    // The parsed headers are handed back as pointers into the caller's
    // buffer, so a successful parse must place both the NT headers and the
    // whole section table inside it. Section *contents* may run past EOF
    // (Module.load clamps those), but the header table may not.
    const nt_end = std.math.add(usize, parser.nt_headers_offset, @sizeOf(pe.IMAGE_NT_HEADERS32)) catch
        return error.NtHeadersOutOfBounds;
    if (nt_end > data.len) return error.NtHeadersOutOfBounds;

    const table_offset = std.math.add(
        usize,
        parser.nt_headers_offset + @sizeOf(u32) + @sizeOf(pe.IMAGE_FILE_HEADER),
        nt.FileHeader.SizeOfOptionalHeader,
    ) catch return error.SectionTableOutOfBounds;
    const table_end = std.math.add(
        usize,
        table_offset,
        parser.sections.len * @sizeOf(pe.IMAGE_SECTION_HEADER),
    ) catch return error.SectionTableOutOfBounds;
    if (table_end > data.len) return error.SectionTableOutOfBounds;
}
