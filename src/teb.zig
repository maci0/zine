const std = @import("std");
const platform = @import("platform.zig");

pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecord: ?*EXCEPTION_RECORD,
    ExceptionAddress: u32,
    NumberParameters: u32,
    ExceptionInformation: [15]u32,
};

pub const CONTEXT = extern struct {
    ContextFlags: u32,

    Dr0: u32, Dr1: u32, Dr2: u32, Dr3: u32, Dr6: u32, Dr7: u32,

    FloatSave: [112]u8,

    SegGs: u32, SegFs: u32, SegEs: u32, SegDs: u32,

    Edi: u32, Esi: u32, Ebx: u32, Edx: u32, Ecx: u32, Eax: u32,

    Ebp: u32, Eip: u32, SegCs: u32, EFlags: u32, Esp: u32, SegSs: u32,

    ExtendedRegisters: [512]u8,
};

pub const UNICODE_STRING = extern struct {
    Length: u16 = 0,
    MaximumLength: u16 = 0,
    Buffer: u32 = 0,
};

pub const CURDIR = extern struct {
    DosPath: UNICODE_STRING = .{},
    Handle: u32 = 0,
};

pub const RTL_USER_PROCESS_PARAMETERS = extern struct {
    MaximumLength: u32 = 0,
    Length: u32 = 0,
    Flags: u32 = 0,
    DebugFlags: u32 = 0,
    ConsoleHandle: u32 = 0,
    ConsoleFlags: u32 = 0,
    StandardInput: u32 = 0,
    StandardOutput: u32 = 0,
    StandardError: u32 = 0,
    CurrentDirectory: CURDIR = .{},
    DllPath: UNICODE_STRING = .{},
    ImagePathName: UNICODE_STRING = .{},
    CommandLine: UNICODE_STRING = .{},
    Environment: u32 = 0,
};

pub const PEB = extern struct {
    InheritedAddressSpace: u8 = 0,
    ReadImageFileExecOptions: u8 = 0,
    BeingDebugged: u8 = 0,
    BitField: u8 = 0,
    Mutant: u32 = 0,
    ImageBaseAddress: u32 = 0,
    Ldr: u32 = 0,
    ProcessParameters: u32 = 0,
    SubSystemData: u32 = 0,
    ProcessHeap: u32 = 0,
    FastPebLock: u32 = 0,
};

pub const NT_TIB = extern struct {
    ExceptionList: u32 = 0xFFFFFFFF, // -1 means end of SEH chain
    StackBase: u32 = 0,
    StackLimit: u32 = 0,
    SubSystemTib: u32 = 0,
    FiberData: u32 = 0,
    ArbitraryUserPointer: u32 = 0,
    Self: u32 = 0, // fs:0x18
};

pub const TEB = extern struct {
    NtTib: NT_TIB = .{},
    EnvironmentPointer: u32 = 0,
    ClientId: extern struct {
        UniqueProcess: u32 = 0,
        UniqueThread: u32 = 0,
    } = .{},
    ActiveRpcHandle: u32 = 0,
    ThreadLocalStoragePointer: u32 = 0,
    ProcessEnvironmentBlock: u32 = 0, // fs:0x30
    LastErrorValue: u32 = 0,
    CountOfOwnedCriticalSections: u32 = 0,
    CsrClientThread: u32 = 0,
    Win32ThreadInfo: u32 = 0,
    User32Reserved: [26]u32 = [_]u32{0} ** 26,
    UserReserved: [5]u32 = [_]u32{0} ** 5,
    WOW32Reserved: u32 = 0,
    CurrentLocale: u32 = 0,
    FpSoftwareStatusRegister: u32 = 0,
    _padding: [0x1000 - 0xCC]u8 = [_]u8{0} ** (0x1000 - 0xCC),
};

pub fn initTEB(allocator: std.mem.Allocator) !*TEB {
    _ = allocator; // PEB/params now use raw_alloc for 32-bit address range
    // Use page_allocator directly to ensure page alignment for TEB
    const slice = try std.heap.page_allocator.alloc(u8, @sizeOf(TEB));
    const teb_val = @as(*TEB, @ptrCast(@alignCast(slice.ptr)));
    @memset(slice, 0);

    // PEB and ProcessParameters must be in the low 32-bit memory range
    // because guest x86 code reads them via fs:[0x30] and follows the pointer
    // chain.  The arena allocator can return addresses above 4GB on x86-64.
    const kernel32_mem = @import("win32/kernel32/mem.zig");
    const peb = blk: {
        const raw = kernel32_mem.raw_alloc(@sizeOf(PEB)) orelse return error.OutOfMemory;
        break :blk @as(*PEB, @ptrCast(@alignCast(raw)));
    };
    peb.* = .{};
    peb.ProcessHeap = 0xDEADC0DE;

    const params = blk: {
        const raw = kernel32_mem.raw_alloc(@sizeOf(RTL_USER_PROCESS_PARAMETERS)) orelse return error.OutOfMemory;
        break :blk @as(*RTL_USER_PROCESS_PARAMETERS, @ptrCast(@alignCast(raw)));
    };
    params.* = .{};
    peb.ProcessParameters = @truncate(@intFromPtr(params));

    teb_val.NtTib.Self = @truncate(@intFromPtr(teb_val));
    teb_val.ProcessEnvironmentBlock = @truncate(@intFromPtr(peb));

    // Setup stack limits via platform abstraction.
    // Windows MSVC compilers (like c1.dll) check fs:[4] (StackBase) and fs:[8] (StackLimit)
    // to detect stack overflows. If they are 0 or unrealistic, they abort with C1063.
    const frame_addr: usize = @frameAddress();
    const bounds = platform.getStackBounds(frame_addr);
    teb_val.NtTib.StackBase = bounds.stack_base;
    teb_val.NtTib.StackLimit = bounds.stack_limit;

    return teb_val;
}

pub fn setupFS(teb_ptr: *TEB) !void {
    teb_address = @intFromPtr(teb_ptr);
    try platform.setupFS(teb_ptr);
}

/// Global TEB address — needed by timer threads that must set up FS base
/// for calling game x86 callbacks.
pub var teb_address: usize = 0;
/// On x86 (32-bit), the FS selector for the TEB GDT entry.
/// Timer threads need this to set FS to the game's TEB before calling callbacks.
pub var teb_fs_selector: u16 = 0;
