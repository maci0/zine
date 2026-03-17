//! Thread Environment Block (TEB) and Process Environment Block (PEB) structures.
//!
//! This module defines the core Windows internal structures used for thread
//! and process state, which are accessed by guest code via the FS segment
//! (e.g., FS:[0x30] for PEB).

const std = @import("std");
const platform = @import("../platform.zig");

/// EXCEPTION_RECORD
pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecord: ?*EXCEPTION_RECORD,
    ExceptionAddress: u32,
    NumberParameters: u32,
    ExceptionInformation: [15]u32,
};

/// CONTEXT
pub const CONTEXT = extern struct {
    ContextFlags: u32,

    Dr0: u32,
    Dr1: u32,
    Dr2: u32,
    Dr3: u32,
    Dr6: u32,
    Dr7: u32,

    FloatSave: [112]u8,

    SegGs: u32,
    SegFs: u32,
    SegEs: u32,
    SegDs: u32,

    Edi: u32,
    Esi: u32,
    Ebx: u32,
    Edx: u32,
    Ecx: u32,
    Eax: u32,

    Ebp: u32,
    Eip: u32,
    SegCs: u32,
    EFlags: u32,
    Esp: u32,
    SegSs: u32,

    ExtendedRegisters: [512]u8,
};

/// UNICODE_STRING
pub const UNICODE_STRING = extern struct {
    Length: u16 = 0,
    MaximumLength: u16 = 0,
    Buffer: u32 = 0,
};

/// CURDIR
pub const CURDIR = extern struct {
    DosPath: UNICODE_STRING = .{},
    Handle: u32 = 0,
};

/// RTL_USER_PROCESS_PARAMETERS
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

/// Process Environment Block (PEB)
pub const PEB = extern struct {
    /// Inherited address space flag
    InheritedAddressSpace: u8 = 0,
    /// Read image file execution options flag
    ReadImageFileExecOptions: u8 = 0,
    /// Whether the process is being debugged
    BeingDebugged: u8 = 0,
    /// Bit field for various flags
    BitField: u8 = 0,
    /// Mutant handle
    Mutant: u32 = 0,
    /// Base address of the process image
    ImageBaseAddress: u32 = 0,
    /// Loader data structure
    Ldr: u32 = 0,
    /// Process parameters structure
    ProcessParameters: u32 = 0,
    /// Subsystem data
    SubSystemData: u32 = 0,
    /// Process heap handle
    ProcessHeap: u32 = 0,
    /// Fast PEB lock handle
    FastPebLock: u32 = 0,
};

/// Thread Information Block (TIB) - located at the start of the TEB
pub const NT_TIB = extern struct {
    /// Pointer to the first SEH registration record
    ExceptionList: u32 = 0xFFFFFFFF, // -1 means end of SEH chain
    /// Base address of the thread stack
    StackBase: u32 = 0,
    /// Limit address of the thread stack
    StackLimit: u32 = 0,
    /// Subsystem TIB pointer
    SubSystemTib: u32 = 0,
    /// Fiber data pointer
    FiberData: u32 = 0,
    /// Arbitrary user pointer
    ArbitraryUserPointer: u32 = 0,
    /// Pointer to the TIB itself (FS:[0x18])
    Self: u32 = 0,
};

/// Thread Environment Block (TEB)
pub const TEB = extern struct {
    /// Thread Information Block
    NtTib: NT_TIB = .{},
    /// Pointer to the environment block
    EnvironmentPointer: u32 = 0,
    /// Client ID structure
    ClientId: extern struct {
        UniqueProcess: u32 = 0,
        UniqueThread: u32 = 0,
    } = .{},
    /// Active RPC handle
    ActiveRpcHandle: u32 = 0,
    /// Pointer to the thread local storage (TLS) array
    ThreadLocalStoragePointer: u32 = 0,
    /// Pointer to the process environment block (PEB)
    ProcessEnvironmentBlock: u32 = 0,
    /// Last error value (GetLastError result)
    LastErrorValue: u32 = 0,
    /// Number of owned critical sections
    CountOfOwnedCriticalSections: u32 = 0,
    /// CSR client thread pointer
    CsrClientThread: u32 = 0,
    /// Win32 thread info pointer
    Win32ThreadInfo: u32 = 0,
    /// User32 reserved fields
    User32Reserved: [26]u32 = [_]u32{0} ** 26,
    /// User reserved fields
    UserReserved: [5]u32 = [_]u32{0} ** 5,
    /// WOW32 reserved field
    WOW32Reserved: u32 = 0,
    /// Current locale ID
    CurrentLocale: u32 = 0,
    /// FPU software status register
    FpSoftwareStatusRegister: u32 = 0,
    /// Reserved padding to ensure TEB size
    _padding: [0x1000 - 0xCC]u8 = [_]u8{0} ** (0x1000 - 0xCC),
};

/// initTEB
/// Implementation status: Partially implemented
pub fn initTEB(allocator: std.mem.Allocator) !*TEB {
    _ = allocator; // PEB/params now use raw_alloc for 32-bit address range
    // On x86_64, TEB must be in low 4GB because guest code reads it via
    // FS-relative 32-bit pointers. Use platform.mmap which sets MAP_32BIT.
    // On x86, page_allocator is fine (everything is 32-bit).
    const slice = if (comptime platform.is_x86_64)
        try platform.mmap(null, @sizeOf(TEB), false, -1, 0, false, false)
    else
        try std.heap.page_allocator.alloc(u8, @sizeOf(TEB));
    const teb_val = @as(*TEB, @ptrCast(@alignCast(slice.ptr)));
    @memset(slice, 0);

    // PEB and ProcessParameters must be in the low 32-bit memory range
    // because guest x86 code reads them via fs:[0x30] and follows the pointer
    // chain.  The arena allocator can return addresses above 4GB on x86-64.
    const kernel32_mem = @import("kernel32/mem.zig");
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

    // Allocate TLS array (Thread Local Storage) — MinGW UCRT uses TLS for
    // per-thread locale data in printf. TEB.ThreadLocalStoragePointer (offset 0x2C)
    // points to an array of pointers indexed by TLS module ID.
    // TLS array: each slot points to a per-module TLS data block.
    // Allocate 64 slots, each pointing to a 256-byte zeroed data block.
    const tls_array = blk: {
        const raw = kernel32_mem.raw_alloc(64 * 4) orelse return error.OutOfMemory;
        const arr = @as(*[64]u32, @ptrCast(@alignCast(raw)));
        // Allocate a shared TLS data block for slots that get accessed
        const tls_data = kernel32_mem.raw_alloc(4096) orelse return error.OutOfMemory;
        @memset(@as([*]u8, @ptrCast(tls_data))[0..4096], 0);
        const data_addr: u32 = @truncate(@intFromPtr(tls_data));
        for (0..64) |i| arr[i] = data_addr;
        break :blk arr;
    };
    teb_val.ThreadLocalStoragePointer = @truncate(@intFromPtr(tls_array));

    // Setup stack limits via platform abstraction.
    // Windows MSVC compilers (like c1.dll) check fs:[4] (StackBase) and fs:[8] (StackLimit)
    // to detect stack overflows. If they are 0 or unrealistic, they abort with C1063.
    const frame_addr: usize = @frameAddress();
    const bounds = platform.getStackBounds(frame_addr);
    teb_val.NtTib.StackBase = bounds.stack_base;
    teb_val.NtTib.StackLimit = bounds.stack_limit;

    return teb_val;
}

/// setupFS
/// Implementation status: Partially implemented
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
pub var teb_base_addr: usize = 0;
