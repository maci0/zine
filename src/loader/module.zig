//! Win32 PE module representation.
//!
//! This module defines the `Module` struct, which represents a loaded PE
//! executable or DLL in the guest address space, and provides functions for
//! loading, mapping, and resolving exports.

const std = @import("std");
const pe = @import("../pe.zig");
const log = @import("../log.zig");
const builtin = @import("builtin");

/// Open a file portably — on WASI, resolves absolute paths through preopened dirs.
fn openFilePortable(path: []const u8) !std.fs.File {
    if (comptime builtin.os.tag == .wasi) {
        if (std.fs.path.isAbsolute(path)) {
            // Iterate WASI preopened fds (start at fd 3, after stdin/stdout/stderr)
            var fd: std.os.wasi.fd_t = 3;
            while (true) : (fd += 1) {
                var prestat: std.os.wasi.prestat_t = undefined;
                switch (std.os.wasi.fd_prestat_get(fd, &prestat)) {
                    .SUCCESS => {},
                    .OPNOTSUPP, .BADF => break,
                    else => break,
                }
                const name_len = prestat.u.dir.pr_name_len;
                var name_buf: [4096]u8 = undefined;
                if (name_len > name_buf.len) continue;
                switch (std.os.wasi.fd_prestat_dir_name(fd, &name_buf, name_len)) {
                    .SUCCESS => {},
                    else => continue,
                }
                const preopen_path = name_buf[0..name_len];
                if (std.mem.startsWith(u8, path, preopen_path)) {
                    var rest = path[preopen_path.len..];
                    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
                    const dir = std.fs.Dir{ .fd = fd };
                    return dir.openFile(rest, .{});
                }
            }
            return error.FileNotFound;
        }
    }
    return std.fs.cwd().openFile(path, .{});
}

/// Represents a loaded Win32 PE module (executable or DLL) in the guest address space.
///
/// A Module encapsulates the raw file data, the mapped memory image, its
/// metadata (parsed PE headers), and state related to its lifecycle in the
/// guest environment (such as whether imports have been resolved).
pub const Module = struct {
    /// The allocator used for this module's metadata.
    allocator: std.mem.Allocator,
    /// The name of the module (e.g., "kernel32.dll").
    name: []const u8,
    /// Raw bytes of the PE file as loaded from disk.
    file_data: []u8,
    /// The mapped PE image in guest memory (aligned to 4096).
    mapped_memory: []align(4096) u8,
    /// The actual base address where the image was mapped.
    image_base: usize,
    /// Virtual address of the entry point, if any.
    entry_point: ?usize,
    /// The PE parser instance for this module.
    parser: pe.PEParser,
    /// Whether this module's imports have been resolved.
    imports_resolved: bool = false,
    /// Whether this module is attached to the environment.
    attached: bool = false,

    /// Loads a PE module from the specified path and prepares it for execution.
    ///
    /// This function:
    ///   1. Reads the file data into memory.
    ///   2. Parses the PE headers.
    ///   3. Allocates executable guest memory for the image (attempting to match its preferred ImageBase).
    ///   4. Maps all PE sections into the newly allocated memory.
    ///   5. Applies base relocations if the mapping base address differs from the preferred ImageBase.
    ///
    /// Returns a pointer to the initialized Module.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*Module {
        const file = openFilePortable(path) catch |err| {
            log.err("Module.load: failed to open '{s}': {}", .{ path, err });
            return err;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        const file_data = try allocator.alloc(u8, @intCast(file_size));
        errdefer allocator.free(file_data);

        _ = try file.readAll(file_data);

        var parser = try pe.PEParser.parse(allocator, file_data);
        const opt_header = &parser.getNtHeaders().OptionalHeader;

        const platform = @import("../platform.zig");
        // Map the PE image into executable memory via platform abstraction
        const ptr_hint: ?[*]align(4096) u8 = @ptrFromInt(opt_header.ImageBase);

        const has_relocs = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC].Size > 0;

        const mapped_slice = try platform.mmap(
            ptr_hint,
            opt_header.SizeOfImage,
            true,
            -1,
            0,
            false,
            !has_relocs, // Force fixed mapping if no relocations
        );
        errdefer platform.munmap(mapped_slice);

        const actual_base = @intFromPtr(mapped_slice.ptr);
        const delta: isize = @as(isize, @bitCast(actual_base)) -% @as(isize, @intCast(opt_header.ImageBase));
        log.info("Mapped {s} at 0x{X} (preferred: 0x{X}, delta: 0x{X})", .{ std.fs.path.basename(path), actual_base, opt_header.ImageBase, delta });

        @memcpy(mapped_slice[0..opt_header.SizeOfHeaders], file_data[0..opt_header.SizeOfHeaders]);

        const sections = parser.getSectionHeaders();
        for (sections) |section| {
            const vsize = section.Misc.VirtualSize;
            if (section.SizeOfRawData > 0) {
                const dest = mapped_slice[section.VirtualAddress .. section.VirtualAddress + section.SizeOfRawData];

                const copy_size = @min(section.SizeOfRawData, file_data.len - section.PointerToRawData);
                const src = file_data[section.PointerToRawData .. section.PointerToRawData + copy_size];

                @memcpy(dest[0..copy_size], src);

                if (copy_size < dest.len) {
                    @memset(dest[copy_size..], 0);
                }
            }
            // Zero-fill BSS tail: when VirtualSize > SizeOfRawData, the region
            // beyond the raw data is uninitialized data that must be zeroed.
            // On native Linux, mmap returns zero-filled pages so this happens
            // implicitly. On WASM, the allocator fills with 0xAA in debug mode.
            if (vsize > section.SizeOfRawData) {
                const bss_start = section.VirtualAddress + section.SizeOfRawData;
                const bss_end = section.VirtualAddress + vsize;
                if (bss_end <= mapped_slice.len) {
                    @memset(mapped_slice[bss_start..bss_end], 0);
                }
            }
        }

        if (delta != 0) {
            const reloc_dir = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC];
            if (reloc_dir.Size > 0) {
                var reloc_offset = reloc_dir.VirtualAddress;
                const reloc_end = reloc_offset + reloc_dir.Size;

                while (reloc_offset < reloc_end) {
                    const block = @as(*pe.IMAGE_BASE_RELOCATION, @ptrCast(@alignCast(&mapped_slice[reloc_offset])));
                    if (block.SizeOfBlock < @sizeOf(pe.IMAGE_BASE_RELOCATION)) break;

                    const entries_count = (block.SizeOfBlock - @sizeOf(pe.IMAGE_BASE_RELOCATION)) / @sizeOf(u16);
                    const entries = @as([*]u16, @ptrCast(@alignCast(&mapped_slice[reloc_offset + @sizeOf(pe.IMAGE_BASE_RELOCATION)])));

                    for (0..entries_count) |e| {
                        const entry = entries[e];
                        const reloc_type = entry >> 12;
                        const offset = entry & 0x0FFF;

                        if (reloc_type == 3) { // IMAGE_REL_BASED_HIGHLOW
                            const patch_addr = block.VirtualAddress + offset;
                            const ptr = @as(*align(1) u32, @ptrCast(&mapped_slice[patch_addr]));
                            ptr.* = ptr.* +% @as(u32, @truncate(@as(usize, @bitCast(delta))));
                        }
                    }
                    reloc_offset += block.SizeOfBlock;
                }
            }
        }

        const mod = try allocator.create(Module);
        mod.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, std.fs.path.basename(path)),
            .file_data = file_data,
            .mapped_memory = mapped_slice,
            .image_base = actual_base,
            .entry_point = if (opt_header.AddressOfEntryPoint != 0) actual_base + opt_header.AddressOfEntryPoint else null,
            .parser = parser,
        };

        return mod;
    }

    /// Frees all memory associated with the module, including the mapped image.
    pub fn deinit(self: *Module) void {
        const platform = @import("../platform.zig");
        platform.munmap(self.mapped_memory);
        self.allocator.free(self.file_data);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Resolves an exported symbol by name and returns its virtual address.
    /// This function handles named exports but returns null for forwarded exports
    /// (e.g. NTDLL.RtlAllocateHeap -> KERNEL32.HeapAlloc).
    pub fn getExport(self: *Module, name: []const u8) ?usize {
        const opt_header = &self.parser.getNtHeaders().OptionalHeader;
        const export_dir_rva = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;

        if (export_dir_rva == 0 or export_dir_rva + @sizeOf(pe.IMAGE_EXPORT_DIRECTORY) > self.mapped_memory.len) return null;

        const export_dir_size = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        const export_dir = @as(*pe.IMAGE_EXPORT_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[export_dir_rva])));

        const names_rva = export_dir.AddressOfNames;
        const funcs_rva = export_dir.AddressOfFunctions;
        const ords_rva = export_dir.AddressOfNameOrdinals;

        const names = @as([*]u32, @ptrCast(@alignCast(&self.mapped_memory[names_rva])));
        const funcs = @as([*]u32, @ptrCast(@alignCast(&self.mapped_memory[funcs_rva])));
        const ords = @as([*]u16, @ptrCast(@alignCast(&self.mapped_memory[ords_rva])));

        for (0..export_dir.NumberOfNames) |i| {
            const name_rva = names[i];
            const func_name = std.mem.span(@as([*:0]const u8, @ptrCast(&self.mapped_memory[name_rva])));

            if (std.mem.eql(u8, func_name, name)) {
                const ordinal = ords[i];
                if (ordinal >= export_dir.NumberOfFunctions) return null;
                const func_rva = funcs[ordinal];

                // Check for forwarded exports: if func_rva points inside the export directory, it's a forwarder
                if (func_rva >= export_dir_rva and func_rva < export_dir_rva + export_dir_size) {
                    const forwarder = std.mem.span(@as([*:0]const u8, @ptrCast(&self.mapped_memory[func_rva])));
                    log.warn("Forwarded export {s} -> {s}", .{ name, forwarder });
                    // Forwarded export (not yet implemented)
                    return null;
                }

                return self.image_base + func_rva;
            }
        }

        return null;
    }

    /// Returns the raw data of the first resource of a given type.
    /// Used when the resource ID is unknown or the first available resource
    /// of that type is needed (e.g. the first icon in a module).
    pub fn getFirstResource(self: *Module, resource_type: u32) ?[]const u8 {
        const opt_header = &self.parser.getNtHeaders().OptionalHeader;
        const res_dir_rva = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_RESOURCE].VirtualAddress;

        if (res_dir_rva == 0) return null;
        
        const pe_res = @import("../pe_resources.zig");
        const root_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva])));
        
        const num_type_entries = root_dir.NumberOfNamedEntries + root_dir.NumberOfIdEntries;
        const type_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        
        var type_offset: ?u32 = null;
        for (0..num_type_entries) |i| {
            if (type_entries[i].NameOrId == resource_type) {
                type_offset = type_entries[i].OffsetToData & 0x7FFFFFFF;
                break;
            }
        }
        if (type_offset == null) return null;

        const name_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.?])));
        const num_name_entries = name_dir.NumberOfNamedEntries + name_dir.NumberOfIdEntries;
        if (num_name_entries == 0) return null;
        const name_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        const name_offset = name_entries[0].OffsetToData & 0x7FFFFFFF;

        const lang_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset])));
        if (lang_dir.NumberOfIdEntries == 0 and lang_dir.NumberOfNamedEntries == 0) return null;
        
        const lang_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        const data_offset = lang_entries[0].OffsetToData & 0x7FFFFFFF;

        const data_entry = @as(*pe_res.IMAGE_RESOURCE_DATA_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + data_offset])));

        if (data_entry.OffsetToData + data_entry.Size > self.mapped_memory.len) return null;
        return self.mapped_memory[data_entry.OffsetToData .. data_entry.OffsetToData + data_entry.Size];
    }

    /// Returns the raw data of a specific resource by type and ID.
    /// Traverses the PE resource directory tree: Type -> Name/ID -> Language.
    /// Always returns the first language entry found for the given ID.
    pub fn getResource(self: *Module, resource_type: u32, resource_id: u32) ?[]const u8 {
        const opt_header = &self.parser.getNtHeaders().OptionalHeader;
        const res_dir_rva = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_RESOURCE].VirtualAddress;

        if (res_dir_rva == 0) return null;
        
        const pe_res = @import("../pe_resources.zig");
        const root_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva])));
        
        const num_type_entries = root_dir.NumberOfNamedEntries + root_dir.NumberOfIdEntries;
        const type_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        
        var type_offset: ?u32 = null;
        for (0..num_type_entries) |i| {
            if (type_entries[i].NameOrId == resource_type) {
                type_offset = type_entries[i].OffsetToData & 0x7FFFFFFF;
                break;
            }
        }
        if (type_offset == null) return null;

        const name_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.?])));
        const num_name_entries = name_dir.NumberOfNamedEntries + name_dir.NumberOfIdEntries;
        const name_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));

        var name_offset: ?u32 = null;
        for (0..num_name_entries) |i| {
            if (name_entries[i].NameOrId == resource_id) {
                name_offset = name_entries[i].OffsetToData & 0x7FFFFFFF;
                break;
            }
        }
        if (name_offset == null) return null;

        const lang_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset.?])));
        if (lang_dir.NumberOfIdEntries == 0 and lang_dir.NumberOfNamedEntries == 0) return null;
        
        const lang_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        const data_offset = lang_entries[0].OffsetToData & 0x7FFFFFFF;

        const data_entry = @as(*pe_res.IMAGE_RESOURCE_DATA_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + data_offset])));

        if (data_entry.OffsetToData + data_entry.Size > self.mapped_memory.len) return null;
        return self.mapped_memory[data_entry.OffsetToData .. data_entry.OffsetToData + data_entry.Size];
    }
};
