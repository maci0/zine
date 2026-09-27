//! Portable Executable (PE) structures and constants.
//!
//! This module defines the core data structures for Windows PE files,
//! including DOS headers, COFF file headers, Optional headers, and Section
//! headers, as well as common constants for imports and exports.

const std = @import("std");

/// The DOS header magic number "MZ".
pub const IMAGE_DOS_SIGNATURE = 0x5A4D;
/// The NT header signature "PE\0\0".
pub const IMAGE_NT_SIGNATURE = 0x00004550;

/// Windows GUI subsystem.
pub const IMAGE_SUBSYSTEM_WINDOWS_GUI = 2;
/// Windows CUI (console) subsystem.
pub const IMAGE_SUBSYSTEM_WINDOWS_CUI = 3;

/// Section contains executable code.
pub const IMAGE_SCN_CNT_CODE = 0x00000020;

/// Index of the Export Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_EXPORT = 0;
/// Index of the Import Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_IMPORT = 1;
/// Index of the Resource Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_RESOURCE = 2;
/// Index of the Exception Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_EXCEPTION = 3;
/// Index of the Security Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_SECURITY = 4;
/// Index of the Base Relocation Table in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_BASERELOC = 5;
/// Index of the Debug Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_DEBUG = 6;
/// Index of the Architecture Specific Data in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_ARCHITECTURE = 7;
/// Index of the Global Pointer Register in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_GLOBALPTR = 8;
/// Index of the Thread Local Storage Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_TLS = 9;
/// Index of the Load Configuration Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG = 10;
/// Index of the Bound Import Directory in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_BOUND_IMPORT = 11;
/// Index of the Import Address Table in the Data Directory.
pub const IMAGE_DIRECTORY_ENTRY_IAT = 12;

/// Standard MS-DOS header.
pub const IMAGE_DOS_HEADER = extern struct {
    /// Magic number "MZ".
    e_magic: u16,
    /// Bytes on last page of file.
    e_cblp: u16,
    /// Pages in file.
    e_cp: u16,
    /// Relocations.
    e_crlc: u16,
    /// Size of header in paragraphs.
    e_cparhdr: u16,
    /// Minimum extra paragraphs needed.
    e_minalloc: u16,
    /// Maximum extra paragraphs needed.
    e_maxalloc: u16,
    /// Initial (relative) SS value.
    e_ss: u16,
    /// Initial SP value.
    e_sp: u16,
    /// Checksum.
    e_csum: u16,
    /// Initial IP value.
    e_ip: u16,
    /// Initial (relative) CS value.
    e_cs: u16,
    /// File address of relocation table.
    e_lfarlc: u16,
    /// Overlay number.
    e_ovno: u16,
    /// Reserved words.
    e_res: [4]u16,
    /// OEM identifier (for e_oeminfo).
    e_oemid: u16,
    /// OEM information; e_oemid specific.
    e_oeminfo: u16,
    /// Reserved words.
    e_res2: [10]u16,
    /// File address of new exe header (NT header).
    e_lfanew: u32,
};

/// COFF File Header.
pub const IMAGE_FILE_HEADER = extern struct {
    /// The architecture type of the computer.
    Machine: u16,
    /// The number of sections.
    NumberOfSections: u16,
    /// The low 32 bits of the number of seconds since 00:00 January 1, 1970.
    TimeDateStamp: u32,
    /// The file offset of the COFF symbol table.
    PointerToSymbolTable: u32,
    /// The number of entries in the symbol table.
    NumberOfSymbols: u32,
    /// The size of the optional header, in bytes.
    SizeOfOptionalHeader: u16,
    /// The characteristics of the image.
    Characteristics: u16,
};

/// Entry in the Data Directory.
pub const IMAGE_DATA_DIRECTORY = extern struct {
    /// The relative virtual address of the table.
    VirtualAddress: u32,
    /// The size of the table, in bytes.
    Size: u32,
};

/// PE32 (32-bit) Optional Header.
pub const IMAGE_OPTIONAL_HEADER32 = extern struct {
    /// The state of the image file (0x10b for PE32, 0x20b for PE32+).
    Magic: u16,
    /// The major version number of the linker.
    MajorLinkerVersion: u8,
    /// The minor version number of the linker.
    MinorLinkerVersion: u8,
    /// The size of the code (text) section, or the sum of all code sections.
    SizeOfCode: u32,
    /// The size of the initialized data section, or the sum of all such sections.
    SizeOfInitializedData: u32,
    /// The size of the uninitialized data section (BSS), or the sum of all such sections.
    SizeOfUninitializedData: u32,
    /// The address of the entry point relative to the image base.
    AddressOfEntryPoint: u32,
    /// The address that is relative to the image base of the beginning-of-code section.
    BaseOfCode: u32,
    /// The address that is relative to the image base of the beginning-of-data section.
    BaseOfData: u32,
    /// The preferred address of the first byte of image when loaded into memory.
    ImageBase: u32,
    /// The alignment (in bytes) of sections when they are loaded into memory.
    SectionAlignment: u32,
    /// The alignment factor (in bytes) that is used to align the raw data of sections in the image file.
    FileAlignment: u32,
    /// The major version number of the required operating system.
    MajorOperatingSystemVersion: u16,
    /// The minor version number of the required operating system.
    MinorOperatingSystemVersion: u16,
    /// The major version number of the image.
    MajorImageVersion: u16,
    /// The minor version number of the image.
    MinorImageVersion: u16,
    /// The major version number of the subsystem.
    MajorSubsystemVersion: u16,
    /// The minor version number of the subsystem.
    MinorSubsystemVersion: u16,
    /// Reserved, must be zero.
    Win32VersionValue: u32,
    /// The size (in bytes) of the image, including all headers, as the image is loaded in memory.
    SizeOfImage: u32,
    /// The combined size of an MS-DOS stub, PE header, and section headers rounded up to a multiple of FileAlignment.
    SizeOfHeaders: u32,
    /// The image file checksum.
    CheckSum: u32,
    /// The subsystem that is required to run this image.
    Subsystem: u16,
    /// The DLL characteristics of the image.
    DllCharacteristics: u16,
    /// The size of the stack to reserve.
    SizeOfStackReserve: u32,
    /// The size of the stack to commit.
    SizeOfStackCommit: u32,
    /// The size of the heap to reserve.
    SizeOfHeapReserve: u32,
    /// The size of the heap to commit.
    SizeOfHeapCommit: u32,
    /// Reserved, must be zero.
    LoaderFlags: u32,
    /// The number of data-directory entries in the remainder of the optional header.
    NumberOfRvaAndSizes: u32,
    /// A pointer to the first IMAGE_DATA_DIRECTORY structure in the data directory.
    DataDirectory: [16]IMAGE_DATA_DIRECTORY,
};

/// PE32 (32-bit) NT Headers.
pub const IMAGE_NT_HEADERS32 = extern struct {
    /// PE signature "PE\0\0".
    Signature: u32,
    /// COFF File Header.
    FileHeader: IMAGE_FILE_HEADER,
    /// Optional Header.
    OptionalHeader: IMAGE_OPTIONAL_HEADER32,
};

/// PE Section Header.
pub const IMAGE_SECTION_HEADER = extern struct {
    /// An 8-byte, null-padded UTF-8 string.
    Name: [8]u8,
    /// Miscellaneous information.
    Misc: extern union {
        /// The file address.
        PhysicalAddress: u32,
        /// The total size of the section when loaded into memory.
        VirtualSize: u32,
    },
    /// The address of the first byte of the section when loaded into memory, relative to the image base.
    VirtualAddress: u32,
    /// The size of the initialized data on disk, in bytes.
    SizeOfRawData: u32,
    /// A file pointer to the first page within the COFF file.
    PointerToRawData: u32,
    /// A file pointer to the beginning of the relocation entries for the section.
    PointerToRelocations: u32,
    /// A file pointer to the beginning of the line-number entries for the section.
    PointerToLinenumbers: u32,
    /// The number of relocation entries for the section.
    NumberOfRelocations: u16,
    /// The number of line-number entries for the section.
    NumberOfLinenumbers: u16,
    /// The characteristics of the image.
    Characteristics: u32,
};

/// PE Export Directory.
pub const IMAGE_EXPORT_DIRECTORY = extern struct {
    /// Reserved, must be 0.
    Characteristics: u32,
    /// The time and date that the export data was created.
    TimeDateStamp: u32,
    /// The major version number.
    MajorVersion: u16,
    /// The minor version number.
    MinorVersion: u16,
    /// The address of the ASCII string that contains the name of the DLL.
    Name: u32,
    /// The starting ordinal number for exports in this image.
    Base: u32,
    /// The number of entries in the export address table.
    NumberOfFunctions: u32,
    /// The number of entries in the name pointer table.
    NumberOfNames: u32,
    /// The address of the export address table, relative to the image base.
    AddressOfFunctions: u32,
    /// The address of the export name pointer table, relative to the image base.
    AddressOfNames: u32,
    /// The address of the ordinal table, relative to the image base.
    AddressOfNameOrdinals: u32,
};

/// PE Import Descriptor.
pub const IMAGE_IMPORT_DESCRIPTOR = extern struct {
    /// The RVA of the import lookup table.
    OriginalFirstThunk: u32,
    /// The stamp that is set to zero until the image is bound.
    TimeDateStamp: u32,
    /// The index of the first forwarder reference.
    ForwarderChain: u32,
    /// The address of an ASCII string that contains the name of the DLL.
    Name: u32,
    /// The RVA of the import address table.
    FirstThunk: u32,
};

/// PE Thunk Data (32-bit).
pub const IMAGE_THUNK_DATA32 = extern struct {
    /// Union of possible thunk data.
    u1: extern union {
        /// RVA to forwarder string.
        ForwarderString: u32,
        /// RVA to function.
        Function: u32,
        /// Ordinal number.
        Ordinal: u32,
        /// RVA to IMAGE_IMPORT_BY_NAME.
        AddressOfData: u32,
    },
};

/// PE Import By Name entry.
pub const IMAGE_IMPORT_BY_NAME = extern struct {
    /// An index into the export name pointer table.
    Hint: u16,
    // Name follows (null-terminated string)
};

/// PE Base Relocation Block Header.
pub const IMAGE_BASE_RELOCATION = extern struct {
    /// The RVA of the image block.
    VirtualAddress: u32,
    /// The size of the relocation block, in bytes.
    SizeOfBlock: u32,
};

/// A helper struct to cleanly encapsulate PE parsing and metadata extraction.
pub const PEParser = struct {
    /// The raw byte data of the PE file.
    data: []u8,
    /// Offset to the IMAGE_NT_HEADERS32.
    nt_headers_offset: usize,
    /// Parsed section headers.
    sections: []IMAGE_SECTION_HEADER,

    /// Errors that can occur during PE parsing.
    pub const Error = error{
        /// The provided data buffer is too small to contain the expected headers.
        BufferTooSmall,
        /// The DOS magic number "MZ" was not found.
        InvalidDOSSignature,
        /// The PE signature "PE\0\0" was not found.
        InvalidPESignature,
        /// Memory allocation failed.
        OutOfMemory,
    };

    /// Parses a PE file from the given raw data buffer.
    /// Validates MZ and PE signatures and extracts section headers.
    pub fn parse(allocator: std.mem.Allocator, data: []u8) Error!PEParser {
        if (data.len < @sizeOf(IMAGE_DOS_HEADER)) return error.BufferTooSmall;

        const dos_header_ptr: *align(1) const IMAGE_DOS_HEADER = @ptrCast(data.ptr);
        if (dos_header_ptr.e_magic != IMAGE_DOS_SIGNATURE) return error.InvalidDOSSignature;

        if (dos_header_ptr.e_lfanew >= data.len or dos_header_ptr.e_lfanew + @sizeOf(IMAGE_NT_HEADERS32) > data.len) {
            return error.BufferTooSmall;
        }

        const nt_headers_ptr: *align(1) const IMAGE_NT_HEADERS32 = @ptrCast(data.ptr + @as(usize, @intCast(dos_header_ptr.e_lfanew)));
        if (nt_headers_ptr.Signature != IMAGE_NT_SIGNATURE) return error.InvalidPESignature;

        const num_sections = nt_headers_ptr.FileHeader.NumberOfSections;
        const sections_array = allocator.alloc(IMAGE_SECTION_HEADER, num_sections) catch return error.OutOfMemory;
        errdefer allocator.free(sections_array);

        const section_headers_offset = @as(usize, @intCast(dos_header_ptr.e_lfanew)) + @sizeOf(u32) + @sizeOf(IMAGE_FILE_HEADER) + nt_headers_ptr.FileHeader.SizeOfOptionalHeader;
        const section_headers_end = section_headers_offset + @as(usize, num_sections) * @sizeOf(IMAGE_SECTION_HEADER);
        if (section_headers_end > data.len) return error.BufferTooSmall;
        const sections_ptr: [*]align(1) const IMAGE_SECTION_HEADER = @ptrCast(data.ptr + section_headers_offset);

        for (0..num_sections) |i| {
            sections_array[i] = sections_ptr[i];
        }

        return PEParser{
            .data = data,
            .nt_headers_offset = @as(usize, @intCast(dos_header_ptr.e_lfanew)),
            .sections = sections_array,
        };
    }

    /// Frees the section headers array.
    pub fn deinit(self: *PEParser, allocator: std.mem.Allocator) void {
        allocator.free(self.sections);
    }

    /// Returns a pointer to the IMAGE_NT_HEADERS32.
    pub fn getNtHeaders(self: *const PEParser) *align(1) const IMAGE_NT_HEADERS32 {
        return @ptrCast(self.data.ptr + self.nt_headers_offset);
    }

    /// Returns the parsed section headers.
    pub fn getSectionHeaders(self: *const PEParser) []IMAGE_SECTION_HEADER {
        return self.sections;
    }
};

/// Canonical definition of a resource directory.
/// Re-exported from pe_resources.zig.
pub const IMAGE_RESOURCE_DIRECTORY = @import("pe_resources.zig").IMAGE_RESOURCE_DIRECTORY;
/// Canonical definition of a resource directory entry.
/// Re-exported from pe_resources.zig.
pub const IMAGE_RESOURCE_DIRECTORY_ENTRY = @import("pe_resources.zig").IMAGE_RESOURCE_DIRECTORY_ENTRY;
/// Canonical definition of a resource data entry.
/// Re-exported from pe_resources.zig.
pub const IMAGE_RESOURCE_DATA_ENTRY = @import("pe_resources.zig").IMAGE_RESOURCE_DATA_ENTRY;

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

test "parse: rejects data smaller than the DOS header" {
    const data = [_]u8{ 'M', 'Z', 0, 0 };
    try testing.expectError(error.BufferTooSmall, PEParser.parse(testing.allocator, @constCast(&data)));
}

test "parse: rejects truncated section header table" {
    // Build a minimal PE whose NumberOfSections claims more headers than
    // the buffer holds; parse must fail cleanly instead of reading OOB.
    // Layout: DOS header at 0, NT headers at 64 (248 bytes), one section
    // header slot's worth of slack after that.
    var buf: [64 + @sizeOf(IMAGE_NT_HEADERS32) + @sizeOf(IMAGE_SECTION_HEADER)]u8 align(8) = undefined;
    @memset(&buf, 0);

    const dos: *IMAGE_DOS_HEADER = @ptrCast(@alignCast(&buf));
    dos.e_magic = IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = 64;

    const nt: *IMAGE_NT_HEADERS32 = @ptrCast(@alignCast(buf[64..].ptr));
    nt.Signature = IMAGE_NT_SIGNATURE;
    nt.FileHeader.NumberOfSections = 2; // only room for one header
    nt.FileHeader.SizeOfOptionalHeader = @sizeOf(IMAGE_OPTIONAL_HEADER32);

    try testing.expectError(error.BufferTooSmall, PEParser.parse(testing.allocator, &buf));
}

test "parse: accepts well-formed minimal PE" {
    var buf: [512]u8 align(8) = undefined;
    @memset(&buf, 0);

    const dos: *IMAGE_DOS_HEADER = @ptrCast(@alignCast(&buf));
    dos.e_magic = IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = 64;

    const nt: *IMAGE_NT_HEADERS32 = @ptrCast(@alignCast(buf[64..].ptr));
    nt.Signature = IMAGE_NT_SIGNATURE;
    nt.FileHeader.NumberOfSections = 1;
    nt.FileHeader.SizeOfOptionalHeader = @sizeOf(IMAGE_OPTIONAL_HEADER32);

    var parser = try PEParser.parse(testing.allocator, &buf);
    defer parser.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), parser.sections.len);
}

test "parse: rejects a buffer without the MZ signature" {
    const data = [_]u8{ 'X', 'Y' } ++ ([_]u8{0} ** 62);
    try testing.expectError(error.InvalidDOSSignature, PEParser.parse(testing.allocator, @constCast(&data)));
}

test "parse: rejects an e_lfanew pointing past the buffer" {
    // DOS header valid, but the NT headers would start beyond the data.
    var buf: [64]u8 align(8) = undefined;
    @memset(&buf, 0);

    const dos: *IMAGE_DOS_HEADER = @ptrCast(@alignCast(&buf));
    dos.e_magic = IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = 128;

    try testing.expectError(error.BufferTooSmall, PEParser.parse(testing.allocator, &buf));
}

test "parse: rejects a wrong NT signature" {
    // Valid DOS header whose e_lfanew points at a non-PE signature.
    var buf: [64 + @sizeOf(IMAGE_NT_HEADERS32)]u8 align(8) = undefined;
    @memset(&buf, 0);

    const dos: *IMAGE_DOS_HEADER = @ptrCast(@alignCast(&buf));
    dos.e_magic = IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = 64;

    const nt: *IMAGE_NT_HEADERS32 = @ptrCast(@alignCast(buf[64..].ptr));
    nt.Signature = 0x454C4946; // "FILE" — plausible garbage, not "PE\0\0"

    try testing.expectError(error.InvalidPESignature, PEParser.parse(testing.allocator, &buf));
}
