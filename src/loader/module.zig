//! Win32 PE module representation.
//!
//! This module defines the `Module` struct, which represents a loaded PE
//! executable or DLL in the guest address space, and provides functions for
//! loading, mapping, and resolving exports.

const std = @import("std");
const runtime = @import("../runtime.zig");
const pe = @import("../pe.zig");
const log = @import("../log.zig");
const builtin = @import("builtin");

/// statx mask for raw fstat (see openFilePortable for why std.Io is avoided
/// in the compat-mode signal dispatch context).
const linux_statx_mask: std.os.linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .ATIME = true,
    .MTIME = true,
    .CTIME = true,
    .INO = true,
    .SIZE = true,
    .NLINK = true,
    .BLOCKS = true,
};

/// Raw fstat (statx with EMPTY_PATH) on native Linux.
fn fileLengthLinux(file: std.Io.File) !u64 {
    const linux = std.os.linux;
    var stx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux_statx_mask, &stx);
    if (@as(isize, @bitCast(rc)) < 0) return error.Unexpected;
    return stx.size;
}

/// PE resource directory constants.
const RESOURCE_DATA_IS_DIRECTORY: u32 = 0x80000000;
const RESOURCE_OFFSET_MASK: u32 = 0x7FFFFFFF;

/// CVTRES under the emulator writes resource type/name entries as string names
/// holding the NUMERIC value in a single wchar (char 0x0006 for type 6), and
/// byte-swaps the resource data RVA. Normalize an entry's NameOrId to its
/// numeric id so lookups match both forms.
/// True if `[off, off+size)` lies entirely within the mapped image. Every
/// pointer formed from PE-supplied resource-directory offsets must pass this
/// first: malformed PEs can otherwise form out-of-bounds references into
/// host memory adjacent to the mapping.
fn inImage(self: *Module, off: u64, size: u64) bool {
    return off + size <= self.mapped_memory.len;
}

fn entryNameValue(self: *Module, res_dir_rva: u32, name_or_id: u32) ?u32 {
    if (name_or_id & 0x80000000 == 0) return name_or_id;
    const off = @as(u64, res_dir_rva) + (name_or_id & RESOURCE_OFFSET_MASK);
    if (!inImage(self, off, 4)) return null;
    const len = std.mem.readInt(u16, self.mapped_memory[@intCast(off)..][0..2], .little);
    if (len != 1) return null;
    return std.mem.readInt(u16, self.mapped_memory[@intCast(off + 2)..][0..2], .little);
}

/// CVTRES byte-swaps the 16-bit halves of the resource data RVA (0x9060
/// written as 0x6090). Return a value that actually points into the image.
fn fixDataRva(self: *Module, rva: u32, size: u32) u32 {
    if (@as(u64, rva) + size <= self.mapped_memory.len) return rva;
    const swapped = ((rva & 0xFFFF) << 16) | (rva >> 16);
    if (@as(u64, swapped) + size <= self.mapped_memory.len) return swapped;
    return rva;
}

/// Open a file portably — on WASI, resolves absolute paths through preopened dirs.
fn openFilePortable(path: []const u8) !std.Io.File {
    if (comptime builtin.os.tag == .linux) {
        // Raw open: std.Io.Dir goes through Io.Threaded (TLS), which faults
        // when invoked from a stub (e.g. LoadLibraryA) running inside the
        // compat-mode SIGSEGV dispatch handler (FS points at the guest TEB).
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        if (path.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const rc = std.os.linux.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        const fd: isize = @bitCast(rc);
        if (fd < 0) return error.FileNotFound;
        return std.Io.File{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };
    }
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
                    const dir = std.Io.Dir{ .handle = fd };
                    return dir.openFile(runtime.io(), rest, .{});
                }
            }
            return error.FileNotFound;
        }
        // Relative path: the WASI cwd (fd 3) may not be the actual working
        // dir — zine-host preopens "/" at fd 3, so relative opens against the
        // cwd fail. Try the path against every preopened dir.
        var fd2: std.os.wasi.fd_t = 3;
        while (true) : (fd2 += 1) {
            var prestat: std.os.wasi.prestat_t = undefined;
            switch (std.os.wasi.fd_prestat_get(fd2, &prestat)) {
                .SUCCESS => {},
                else => break,
            }
            const dir = std.Io.Dir{ .handle = fd2 };
            if (dir.openFile(runtime.io(), path, .{})) |f| return f else |_| {}
        }
        return error.FileNotFound;
    }
    return std.Io.Dir.cwd().openFile(runtime.io(), path, .{});
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
        defer if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.close(file.handle);
        } else {
            file.close(runtime.io());
        };

        const file_size = if (comptime builtin.os.tag == .linux)
            try fileLengthLinux(file)
        else
            try file.length(runtime.io());
        const file_data = try allocator.alloc(u8, @intCast(file_size));
        errdefer allocator.free(file_data);

        if (comptime builtin.os.tag == .linux) {
            var off: u64 = 0;
            while (off < file_data.len) {
                const rc = std.os.linux.pread(file.handle, file_data.ptr + @as(usize, @intCast(off)), file_data.len - @as(usize, @intCast(off)), @as(i64, @intCast(off)));
                const signed: isize = @bitCast(rc);
                if (signed <= 0) return error.ReadFailed;
                off += @intCast(rc);
            }
        } else {
            _ = try file.readPositionalAll(runtime.io(), file_data, 0);
        }

        var parser = pe.PEParser.parse(allocator, file_data) catch |err| {
            log.err("Module.load: failed to parse '{s}': {} ({d} bytes)", .{ path, err, file_data.len });
            return err;
        };
        errdefer parser.deinit(allocator);
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

        if (opt_header.SizeOfHeaders > mapped_slice.len or opt_header.SizeOfHeaders > file_data.len) {
            log.err("Module.load: '{s}': SizeOfHeaders {d} exceeds image ({d}) or file size ({d})", .{
                std.fs.path.basename(path), opt_header.SizeOfHeaders, mapped_slice.len, file_data.len,
            });
            return error.InvalidPELayout;
        }
        @memcpy(mapped_slice[0..opt_header.SizeOfHeaders], file_data[0..opt_header.SizeOfHeaders]);

        const sections = parser.getSectionHeaders();
        for (sections) |section| {
            const vsize = section.Misc.VirtualSize;
            if (section.SizeOfRawData > 0) {
                // Malformed PEs may declare section ranges beyond the image or
                // past EOF; skip them instead of panicking or reading out of bounds.
                const sec_end = @as(u64, section.VirtualAddress) + section.SizeOfRawData;
                if (sec_end > mapped_slice.len or section.PointerToRawData > file_data.len) {
                    log.warn("Module.load: '{s}': section '{s}' range out of bounds (VA=0x{X} raw=0x{X} size={d}), skipping", .{
                        std.fs.path.basename(path),
                        std.mem.sliceTo(&section.Name, 0),
                        section.VirtualAddress,
                        section.PointerToRawData,
                        section.SizeOfRawData,
                    });
                    continue;
                }
                const copy_size = @min(section.SizeOfRawData, file_data.len - section.PointerToRawData);
                const dest = mapped_slice[section.VirtualAddress .. section.VirtualAddress + section.SizeOfRawData];
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
                var reloc_offset: usize = reloc_dir.VirtualAddress;
                // Clamp the reloc table to the mapped image; malformed PEs may
                // declare a directory extending past SizeOfImage.
                const reloc_end = @min(@as(u64, reloc_offset) + reloc_dir.Size, mapped_slice.len);
                var skipped_blocks: usize = 0;

                while (reloc_offset + @sizeOf(pe.IMAGE_BASE_RELOCATION) <= reloc_end) {
                    const block = @as(*pe.IMAGE_BASE_RELOCATION, @ptrCast(@alignCast(&mapped_slice[reloc_offset])));
                    if (block.SizeOfBlock < @sizeOf(pe.IMAGE_BASE_RELOCATION)) break;
                    if (@as(u64, reloc_offset) + block.SizeOfBlock > mapped_slice.len) {
                        skipped_blocks += 1;
                        break;
                    }

                    const entries_count = (block.SizeOfBlock - @sizeOf(pe.IMAGE_BASE_RELOCATION)) / @sizeOf(u16);
                    const entries = @as([*]u16, @ptrCast(@alignCast(&mapped_slice[reloc_offset + @sizeOf(pe.IMAGE_BASE_RELOCATION)])));

                    for (0..entries_count) |e| {
                        const entry = entries[e];
                        const reloc_type = entry >> 12;
                        const offset = entry & 0x0FFF;

                        const IMAGE_REL_BASED_HIGHLOW = 3;
                        if (reloc_type == IMAGE_REL_BASED_HIGHLOW) {
                            const patch_addr = @as(u64, block.VirtualAddress) + offset;
                            // Skip entries pointing outside the image instead of
                            // corrupting host memory adjacent to the mapping.
                            if (patch_addr + @sizeOf(u32) > mapped_slice.len) {
                                skipped_blocks += 1;
                                continue;
                            }
                            const ptr = @as(*align(1) u32, @ptrCast(&mapped_slice[@intCast(patch_addr)]));
                            ptr.* = ptr.* +% @as(u32, @truncate(@as(usize, @bitCast(delta))));
                        }
                    }
                    reloc_offset += block.SizeOfBlock;
                }
                if (skipped_blocks > 0) {
                    log.warn("Module.load: '{s}': skipped {d} out-of-bounds relocation {s}", .{
                        std.fs.path.basename(path), skipped_blocks, if (skipped_blocks == 1) "entry" else "entries",
                    });
                }
            }
        }

        // From here on, ownership of parser state moves into the Module; the
        // errdefers below only run if construction itself fails.
        const name = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(name);
        const mod = try allocator.create(Module);
        errdefer allocator.destroy(mod);
        mod.* = .{
            .allocator = allocator,
            .name = name,
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

    /// Resolves a named exported symbol and returns its virtual address.
    /// Returns null for forwarded exports (e.g. NTDLL.RtlAllocateHeap →
    /// KERNEL32.HeapAlloc) which are not yet followed.
    pub fn getExport(self: *Module, name: []const u8) ?usize {
        const opt_header = &self.parser.getNtHeaders().OptionalHeader;
        const export_dir_rva = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;

        if (export_dir_rva == 0 or export_dir_rva + @sizeOf(pe.IMAGE_EXPORT_DIRECTORY) > self.mapped_memory.len) return null;

        const export_dir_size = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        const export_dir = @as(*pe.IMAGE_EXPORT_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[export_dir_rva])));

        const names_rva = export_dir.AddressOfNames;
        const funcs_rva = export_dir.AddressOfFunctions;
        const ords_rva = export_dir.AddressOfNameOrdinals;

        // Malformed export directories can point outside the image; bail out
        // instead of reading host memory adjacent to the mapping.
        const tables_end = @max(names_rva, @max(funcs_rva, ords_rva));
        const forwarder_end = @as(u64, export_dir_rva) + export_dir_size;
        if (tables_end > self.mapped_memory.len or
            @as(u64, names_rva) + @as(u64, export_dir.NumberOfNames) * @sizeOf(u32) > self.mapped_memory.len or
            @as(u64, funcs_rva) + @as(u64, export_dir.NumberOfFunctions) * @sizeOf(u32) > self.mapped_memory.len or
            @as(u64, ords_rva) + @as(u64, export_dir.NumberOfNames) * @sizeOf(u16) > self.mapped_memory.len or
            forwarder_end > self.mapped_memory.len)
        {
            return null;
        }

        const names = @as([*]u32, @ptrCast(@alignCast(&self.mapped_memory[names_rva])));
        const funcs = @as([*]u32, @ptrCast(@alignCast(&self.mapped_memory[funcs_rva])));
        const ords = @as([*]u16, @ptrCast(@alignCast(&self.mapped_memory[ords_rva])));

        for (0..export_dir.NumberOfNames) |i| {
            const name_rva = names[i];
            if (name_rva >= self.mapped_memory.len) continue;
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
        if (!inImage(self, res_dir_rva, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY))) return null;
        const root_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva])));

        const num_type_entries = root_dir.NumberOfNamedEntries + root_dir.NumberOfIdEntries;
        if (!inImage(self, @as(u64, res_dir_rva) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY), @as(u64, num_type_entries) * @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;
        const type_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));

        var type_offset: ?u32 = null;
        for (0..num_type_entries) |i| {
            if ((entryNameValue(self, res_dir_rva, type_entries[i].NameOrId) orelse continue) == resource_type) {
                type_offset = type_entries[i].OffsetToData & RESOURCE_OFFSET_MASK;
                break;
            }
        }
        if (type_offset == null) return null;
        if (!inImage(self, @as(u64, res_dir_rva) + type_offset.?, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;

        const name_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.?])));
        const num_name_entries = name_dir.NumberOfNamedEntries + name_dir.NumberOfIdEntries;
        if (num_name_entries == 0) return null;
        const name_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        var name_offset: ?u32 = null;
        for (0..num_name_entries) |i| {
            if ((entryNameValue(self, res_dir_rva, name_entries[i].NameOrId) orelse continue) == resource_type) {
                name_offset = name_entries[i].OffsetToData & RESOURCE_OFFSET_MASK;
                break;
            }
        }
        if (name_offset == null) name_offset = name_entries[0].OffsetToData & RESOURCE_OFFSET_MASK;
        const name_offset_val = name_offset.?;
        if (!inImage(self, @as(u64, res_dir_rva) + name_offset_val, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;

        const lang_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset_val])));
        if (lang_dir.NumberOfIdEntries == 0 and lang_dir.NumberOfNamedEntries == 0) return null;

        const lang_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset_val + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        const data_offset = lang_entries[0].OffsetToData & RESOURCE_OFFSET_MASK;
        if (!inImage(self, @as(u64, res_dir_rva) + data_offset, @sizeOf(pe_res.IMAGE_RESOURCE_DATA_ENTRY))) return null;

        const data_entry = @as(*pe_res.IMAGE_RESOURCE_DATA_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + data_offset])));

        const data_rva = fixDataRva(self, data_entry.OffsetToData, data_entry.Size);
        if (@as(u64, data_rva) + data_entry.Size > self.mapped_memory.len) return null;
        return self.mapped_memory[@intCast(data_rva)..@intCast(data_rva + data_entry.Size)];
    }

    /// Returns the raw data of a specific resource by type and ID.
    /// Traverses the PE resource directory tree: Type -> Name/ID -> Language.
    /// Always returns the first language entry found for the given ID.
    pub fn getResource(self: *Module, resource_type: u32, resource_id: u32) ?[]const u8 {
        const opt_header = &self.parser.getNtHeaders().OptionalHeader;
        const res_dir_rva = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_RESOURCE].VirtualAddress;

        if (res_dir_rva == 0) return null;

        const pe_res = @import("../pe_resources.zig");
        if (!inImage(self, res_dir_rva, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY))) return null;
        const root_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva])));

        const num_type_entries = root_dir.NumberOfNamedEntries + root_dir.NumberOfIdEntries;
        if (!inImage(self, @as(u64, res_dir_rva) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY), @as(u64, num_type_entries) * @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;
        const type_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));

        var type_offset: ?u32 = null;
        for (0..num_type_entries) |i| {
            if ((entryNameValue(self, res_dir_rva, type_entries[i].NameOrId) orelse continue) == resource_type) {
                type_offset = type_entries[i].OffsetToData & RESOURCE_OFFSET_MASK;
                break;
            }
        }
        if (type_offset == null) return null;
        if (!inImage(self, @as(u64, res_dir_rva) + type_offset.?, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;

        const name_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.?])));
        const num_name_entries = name_dir.NumberOfNamedEntries + name_dir.NumberOfIdEntries;
        const name_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));

        var name_offset: ?u32 = null;
        for (0..num_name_entries) |i| {
            if ((entryNameValue(self, res_dir_rva, name_entries[i].NameOrId) orelse continue) == resource_id) {
                name_offset = name_entries[i].OffsetToData & RESOURCE_OFFSET_MASK;
                break;
            }
        }
        if (name_offset == null) return null;
        if (!inImage(self, @as(u64, res_dir_rva) + name_offset.?, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;

        const lang_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset.?])));
        if (lang_dir.NumberOfIdEntries == 0 and lang_dir.NumberOfNamedEntries == 0) return null;

        const lang_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        const data_offset = lang_entries[0].OffsetToData & RESOURCE_OFFSET_MASK;
        if (!inImage(self, @as(u64, res_dir_rva) + data_offset, @sizeOf(pe_res.IMAGE_RESOURCE_DATA_ENTRY))) return null;

        const data_entry = @as(*pe_res.IMAGE_RESOURCE_DATA_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + data_offset])));

        const data_rva = fixDataRva(self, data_entry.OffsetToData, data_entry.Size);
        if (@as(u64, data_rva) + data_entry.Size > self.mapped_memory.len) return null;
        return self.mapped_memory[@intCast(data_rva)..@intCast(data_rva + data_entry.Size)];
    }

    /// Look up a resource by type ID and string name (e.g., Delphi form resources).
    /// Named resource entries have bit 31 set in NameOrId, pointing to a
    /// UTF-16 name string in the resource directory.
    pub fn getResourceByName(self: *Module, resource_type: u32, name: []const u8) ?[]const u8 {
        const opt_header = &self.parser.getNtHeaders().OptionalHeader;
        const res_dir_rva = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_RESOURCE].VirtualAddress;
        if (res_dir_rva == 0) return null;

        const pe_res = @import("../pe_resources.zig");
        if (!inImage(self, res_dir_rva, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY))) return null;
        const root_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva])));
        const num_type_entries = root_dir.NumberOfNamedEntries + root_dir.NumberOfIdEntries;
        if (!inImage(self, @as(u64, res_dir_rva) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY), @as(u64, num_type_entries) * @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;
        const type_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));

        // Find the type subdirectory
        var type_offset: ?u32 = null;
        for (0..num_type_entries) |i| {
            if (type_entries[i].NameOrId == resource_type) {
                type_offset = type_entries[i].OffsetToData & RESOURCE_OFFSET_MASK;
                break;
            }
        }
        if (type_offset == null) return null;
        if (!inImage(self, @as(u64, res_dir_rva) + type_offset.?, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;

        // Search name entries — named entries have bit 31 set
        const name_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.?])));
        const num_name_entries = name_dir.NumberOfNamedEntries + name_dir.NumberOfIdEntries;
        if (!inImage(self, @as(u64, res_dir_rva) + type_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY), @as(u64, num_name_entries) * @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;
        const name_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + type_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));

        var name_offset: ?u32 = null;
        for (0..num_name_entries) |i| {
            const entry = name_entries[i];
            if (entry.NameOrId & RESOURCE_DATA_IS_DIRECTORY != 0) {
                // Named entry — compare with the UTF-16 name. Bounds-check the
                // whole string (length word + str_len wchars): str_data is a
                // many-pointer, so indexing it past the image would read host
                // memory beyond the mapping.
                const name_rva = entry.NameOrId & RESOURCE_OFFSET_MASK;
                const str_off = @as(u64, res_dir_rva) + name_rva;
                if (!inImage(self, str_off, 2 + 2 * @as(u64, name.len))) continue;
                const str_len = std.mem.readInt(u16, self.mapped_memory[@intCast(str_off)..][0..2], .little);
                if (str_len != name.len) continue;
                const str_data = @as([*]const u16, @ptrCast(@alignCast(&self.mapped_memory[@intCast(str_off + 2)])));
                var matches = true;
                for (0..name.len) |j| {
                    const wc = str_data[j];
                    const nc: u16 = name[j];
                    // Case-insensitive compare
                    const wl = if (wc >= 'A' and wc <= 'Z') wc + 32 else wc;
                    const nl = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
                    if (wl != nl) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    name_offset = entry.OffsetToData & RESOURCE_OFFSET_MASK;
                    break;
                }
            }
        }
        if (name_offset == null) return null;
        if (!inImage(self, @as(u64, res_dir_rva) + name_offset.?, @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY) + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY))) return null;

        // Get the language entry and data
        const lang_dir = @as(*pe_res.IMAGE_RESOURCE_DIRECTORY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset.?])));
        if (lang_dir.NumberOfIdEntries == 0 and lang_dir.NumberOfNamedEntries == 0) return null;
        const lang_entries = @as([*]pe_res.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + name_offset.? + @sizeOf(pe_res.IMAGE_RESOURCE_DIRECTORY)])));
        const data_offset = lang_entries[0].OffsetToData & RESOURCE_OFFSET_MASK;
        if (!inImage(self, @as(u64, res_dir_rva) + data_offset, @sizeOf(pe_res.IMAGE_RESOURCE_DATA_ENTRY))) return null;
        const data_entry = @as(*pe_res.IMAGE_RESOURCE_DATA_ENTRY, @ptrCast(@alignCast(&self.mapped_memory[res_dir_rva + data_offset])));

        const data_rva = fixDataRva(self, data_entry.OffsetToData, data_entry.Size);
        if (@as(u64, data_rva) + data_entry.Size > self.mapped_memory.len) return null;
        return self.mapped_memory[@intCast(data_rva)..@intCast(data_rva + data_entry.Size)];
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;
const pe_resources = @import("../pe_resources.zig");

const TestImage = struct {
    file_data: []u8,
    image: []align(4096) u8,
    parser: pe.PEParser,
    mod: Module,

    const res_rva: u32 = 0x100;

    /// Build a minimal PE (headers only) plus a page-aligned mapped image
    /// whose resource directory lives at `res_rva`. Callers then poke raw
    /// words into `image` to shape the directory tree.
    fn create(allocator: std.mem.Allocator) !TestImage {
        const file_data = try allocator.alloc(u8, 512);
        errdefer allocator.free(file_data);
        @memset(file_data, 0);
        // DOS header with e_lfanew = 64
        @memcpy(file_data[0..2], "MZ");
        std.mem.writeInt(u32, file_data[60..64], 64, .little);
        // NT signature + COFF header (no sections, optional header = 224)
        @memcpy(file_data[64..68], "PE\x00\x00");
        std.mem.writeInt(u16, file_data[68 + 16 ..][0..2], 224, .little);
        // Optional header: magic 0x10b, 16 data directories
        std.mem.writeInt(u16, file_data[88..][0..2], 0x10b, .little);
        std.mem.writeInt(u32, file_data[88 + 92 ..][0..4], 16, .little);
        std.mem.writeInt(u32, file_data[88 + 96 + 2 * 8 ..][0..4], res_rva, .little);

        var parser = try pe.PEParser.parse(allocator, file_data);
        errdefer parser.deinit(allocator);

        const image = try testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 8192);
        errdefer testing.allocator.free(image);
        @memset(image, 0);

        var ti = TestImage{
            .file_data = file_data,
            .image = image,
            .parser = parser,
            .mod = undefined,
        };
        ti.mod = .{
            .allocator = allocator,
            .name = "test.dll",
            .file_data = file_data,
            .mapped_memory = image,
            .image_base = @intFromPtr(image.ptr),
            .entry_point = null,
            .parser = parser,
        };
        return ti;
    }

    fn destroy(self: *TestImage, allocator: std.mem.Allocator) void {
        self.parser.deinit(allocator);
        testing.allocator.free(self.image);
        allocator.free(self.file_data);
    }

    fn put32(self: *TestImage, img_off: u32, value: u32) void {
        std.mem.writeInt(u32, self.image[img_off..][0..4], value, .little);
    }

    fn put16(self: *TestImage, img_off: u32, value: u16) void {
        std.mem.writeInt(u16, self.image[img_off..][0..2], value, .little);
    }

    /// Write a resource-directory header: named/id entry counts.
    fn putDirHeader(self: *TestImage, dir_rva: u32, num_id: u16) void {
        self.put16(dir_rva + 12, 0); // NumberOfNamedEntries
        self.put16(dir_rva + 14, num_id); // NumberOfIdEntries
    }
};

test "getResource resolves a well-formed resource tree" {
    var ti = try TestImage.create(testing.allocator);
    defer ti.destroy(testing.allocator);

    const rva = TestImage.res_rva;
    // Root dir: 1 id entry of type RT_ICON(3), subdirectory at rva+0x80.
    ti.putDirHeader(rva, 1);
    ti.put32(rva + 16, 3); // entry NameOrId
    ti.put32(rva + 20, 0x80000080); // entry OffsetToData -> subdir
    // Name/ID dir: 1 id entry id=1, language dir at rva+0xC0.
    ti.putDirHeader(rva + 0x80, 1);
    ti.put32(rva + 0x80 + 16, 1);
    ti.put32(rva + 0x80 + 20, 0x800000C0);
    // Lang dir: 1 entry, data entry at rva+0x100.
    ti.putDirHeader(rva + 0xC0, 1);
    ti.put32(rva + 0xC0 + 16, 0x409);
    ti.put32(rva + 0xC0 + 20, 0x100);
    // Data entry: data RVA rva+0x200, size 8.
    ti.put32(rva + 0x100, rva + 0x200);
    ti.put32(rva + 0x104, 8);
    @memcpy(ti.image[rva + 0x200 ..][0..8], "ICONDATA");

    const data = ti.mod.getResource(pe_resources.RT_ICON, 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("ICONDATA", data);
}

test "getResource rejects out-of-bounds data-entry offsets instead of panicking" {
    var ti = try TestImage.create(testing.allocator);
    defer ti.destroy(testing.allocator);

    const rva = TestImage.res_rva;
    ti.putDirHeader(rva, 1);
    ti.put32(rva + 16, 3);
    ti.put32(rva + 20, 0x80000080);
    ti.putDirHeader(rva + 0x80, 1);
    ti.put32(rva + 0x80 + 16, 1);
    ti.put32(rva + 0x80 + 20, 0xFFFFFFF0); // far past the image end

    try testing.expectEqual(@as(?[]const u8, null), ti.mod.getResource(pe_resources.RT_ICON, 1));
}

test "getResourceByName skips named entries whose string runs past the image" {
    var ti = try TestImage.create(testing.allocator);
    defer ti.destroy(testing.allocator);

    const rva = TestImage.res_rva;
    // Type dir: direct NameOrId match on type 42.
    ti.putDirHeader(rva, 1);
    ti.put32(rva + 16, 42);
    ti.put32(rva + 20, 0x80000080);
    // Name dir: one NAMED entry whose string starts at the last 2 bytes of
    // the image; its length word would claim chars beyond the mapping.
    ti.putDirHeader(rva + 0x80, 1);
    ti.put32(rva + 0x80 + 16, 0x80000000 | @as(u32, @intCast(ti.image.len - 2 - rva)));
    ti.put32(rva + 0x80 + 20, 0x800000C0);
    std.mem.writeInt(u16, ti.image[ti.image.len - 2 ..][0..2], 4, .little); // claims 4 wchars

    try testing.expectEqual(@as(?[]const u8, null), ti.mod.getResourceByName(42, "abcd"));
}
