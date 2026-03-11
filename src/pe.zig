const std = @import("std");

pub const IMAGE_DOS_SIGNATURE = 0x5A4D; // MZ
pub const IMAGE_NT_SIGNATURE = 0x00004550; // PE\0\0

pub const IMAGE_DIRECTORY_ENTRY_EXPORT = 0;
pub const IMAGE_DIRECTORY_ENTRY_IMPORT = 1;
pub const IMAGE_DIRECTORY_ENTRY_RESOURCE = 2;
pub const IMAGE_DIRECTORY_ENTRY_EXCEPTION = 3;
pub const IMAGE_DIRECTORY_ENTRY_SECURITY = 4;
pub const IMAGE_DIRECTORY_ENTRY_BASERELOC = 5;
pub const IMAGE_DIRECTORY_ENTRY_DEBUG = 6;
pub const IMAGE_DIRECTORY_ENTRY_ARCHITECTURE = 7;
pub const IMAGE_DIRECTORY_ENTRY_GLOBALPTR = 8;
pub const IMAGE_DIRECTORY_ENTRY_TLS = 9;
pub const IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG = 10;
pub const IMAGE_DIRECTORY_ENTRY_BOUND_IMPORT = 11;
pub const IMAGE_DIRECTORY_ENTRY_IAT = 12;

pub const IMAGE_DOS_HEADER = extern struct {
    e_magic: u16,
    e_cblp: u16,
    e_cp: u16,
    e_crlc: u16,
    e_cparhdr: u16,
    e_minalloc: u16,
    e_maxalloc: u16,
    e_ss: u16,
    e_sp: u16,
    e_csum: u16,
    e_ip: u16,
    e_cs: u16,
    e_lfarlc: u16,
    e_ovno: u16,
    e_res: [4]u16,
    e_oemid: u16,
    e_oeminfo: u16,
    e_res2: [10]u16,
    e_lfanew: u32,
};

pub const IMAGE_FILE_HEADER = extern struct {
    Machine: u16,
    NumberOfSections: u16,
    TimeDateStamp: u32,
    PointerToSymbolTable: u32,
    NumberOfSymbols: u32,
    SizeOfOptionalHeader: u16,
    Characteristics: u16,
};

pub const IMAGE_DATA_DIRECTORY = extern struct {
    VirtualAddress: u32,
    Size: u32,
};

pub const IMAGE_OPTIONAL_HEADER32 = extern struct {
    Magic: u16,
    MajorLinkerVersion: u8,
    MinorLinkerVersion: u8,
    SizeOfCode: u32,
    SizeOfInitializedData: u32,
    SizeOfUninitializedData: u32,
    AddressOfEntryPoint: u32,
    BaseOfCode: u32,
    BaseOfData: u32,
    ImageBase: u32,
    SectionAlignment: u32,
    FileAlignment: u32,
    MajorOperatingSystemVersion: u16,
    MinorOperatingSystemVersion: u16,
    MajorImageVersion: u16,
    MinorImageVersion: u16,
    MajorSubsystemVersion: u16,
    MinorSubsystemVersion: u16,
    Win32VersionValue: u32,
    SizeOfImage: u32,
    SizeOfHeaders: u32,
    CheckSum: u32,
    Subsystem: u16,
    DllCharacteristics: u16,
    SizeOfStackReserve: u32,
    SizeOfStackCommit: u32,
    SizeOfHeapReserve: u32,
    SizeOfHeapCommit: u32,
    LoaderFlags: u32,
    NumberOfRvaAndSizes: u32,
    DataDirectory: [16]IMAGE_DATA_DIRECTORY,
};

pub const IMAGE_NT_HEADERS32 = extern struct {
    Signature: u32,
    FileHeader: IMAGE_FILE_HEADER,
    OptionalHeader: IMAGE_OPTIONAL_HEADER32,
};

pub const IMAGE_SECTION_HEADER = extern struct {
    Name: [8]u8,
    Misc: extern union {
        PhysicalAddress: u32,
        VirtualSize: u32,
    },
    VirtualAddress: u32,
    SizeOfRawData: u32,
    PointerToRawData: u32,
    PointerToRelocations: u32,
    PointerToLinenumbers: u32,
    NumberOfRelocations: u16,
    NumberOfLinenumbers: u16,
    Characteristics: u32,
};

pub const IMAGE_EXPORT_DIRECTORY = extern struct {
    Characteristics: u32,
    TimeDateStamp: u32,
    MajorVersion: u16,
    MinorVersion: u16,
    Name: u32,
    Base: u32,
    NumberOfFunctions: u32,
    NumberOfNames: u32,
    AddressOfFunctions: u32, // RVA from base of image
    AddressOfNames: u32, // RVA from base of image
    AddressOfNameOrdinals: u32, // RVA from base of image
};

pub const IMAGE_IMPORT_DESCRIPTOR = extern struct {
    OriginalFirstThunk: u32,
    TimeDateStamp: u32,
    ForwarderChain: u32,
    Name: u32,
    FirstThunk: u32,
};

pub const IMAGE_THUNK_DATA32 = extern struct {
    u1: extern union {
        ForwarderString: u32,
        Function: u32,
        Ordinal: u32,
        AddressOfData: u32,
    },
};

pub const IMAGE_IMPORT_BY_NAME = extern struct {
    Hint: u16,
};

pub const IMAGE_BASE_RELOCATION = extern struct {
    VirtualAddress: u32,
    SizeOfBlock: u32,
};

/// A helper struct to cleanly encapsulate PE parsing
pub const PEParser = struct {
    data: []u8,
    dos_header_offset: usize,
    nt_headers_offset: usize,
    sections: []IMAGE_SECTION_HEADER,

    pub const Error = error{
        BufferTooSmall,
        InvalidDOSSignature,
        InvalidPESignature,
        OutOfMemory,
    };

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

        const section_headers_offset = @as(usize, @intCast(dos_header_ptr.e_lfanew)) + @sizeOf(u32) + @sizeOf(IMAGE_FILE_HEADER) + nt_headers_ptr.FileHeader.SizeOfOptionalHeader;
        const sections_ptr: [*]align(1) const IMAGE_SECTION_HEADER = @ptrCast(data.ptr + section_headers_offset);

        for (0..num_sections) |i| {
            sections_array[i] = sections_ptr[i];
        }

        return PEParser{
            .data = data,
            .dos_header_offset = 0,
            .nt_headers_offset = @as(usize, @intCast(dos_header_ptr.e_lfanew)),
            .sections = sections_array,
        };
    }

    pub fn deinit(self: *PEParser, allocator: std.mem.Allocator) void {
        allocator.free(self.sections);
    }

    pub fn getDosHeader(self: *const PEParser) *align(1) const IMAGE_DOS_HEADER {
        return @ptrCast(self.data.ptr + self.dos_header_offset);
    }

    pub fn getNtHeaders(self: *const PEParser) *align(1) const IMAGE_NT_HEADERS32 {
        return @ptrCast(self.data.ptr + self.nt_headers_offset);
    }

    pub fn getSectionHeaders(self: *const PEParser) []IMAGE_SECTION_HEADER {
        return self.sections;
    }
};

// NOTE: These structs are also defined in pe_resources.zig. They are kept here
// because stubs/user32/resource.zig imports pe.zig for resource walking.
// Consider consolidating to a single location.
pub const IMAGE_RESOURCE_DIRECTORY = extern struct {
    Characteristics: u32,
    TimeDateStamp: u32,
    MajorVersion: u16,
    MinorVersion: u16,
    NumberOfNamedEntries: u16,
    NumberOfIdEntries: u16,
};

pub const IMAGE_RESOURCE_DIRECTORY_ENTRY = extern struct {
    NameId: u32,
    OffsetToData: u32,
};

pub const IMAGE_RESOURCE_DATA_ENTRY = extern struct {
    OffsetToData: u32,
    Size: u32,
    CodePage: u32,
    Reserved: u32,
};
