//! Guest TEB/PEB structure layouts and the host-visible TEB state.
//!
//! Layout declarations and the three `teb_*` globals are dependency-free on
//! purpose: the host platform layer (`src/platform/native.zig`) reads and
//! writes them from the signal handler, so importing anything that reaches
//! back into `src/platform.zig` would close an import cycle.
//! Allocation and FS setup live in `teb.zig`.

const std = @import("std");

/// EXCEPTION_RECORD
pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecordPtr: u32 = 0,
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
    /// FastPebLockRoutine
    FastPebLockRoutine: u32 = 0,
    /// FastPebUnlockRoutine
    FastPebUnlockRoutine: u32 = 0,
    /// EnvironmentUpdateCount
    EnvironmentUpdateCount: u32 = 0,
    /// KernelCallbackTable
    KernelCallbackTable: u32 = 0,
    /// SystemReserved
    SystemReserved: [1]u32 = .{0},
    /// AtlThunkSListPtr32
    AtlThunkSListPtr32: u32 = 0,
    /// FreeList
    FreeList: u32 = 0,
    /// TlsExpansionCounter
    TlsExpansionCounter: u32 = 0,
    /// TlsBitmap
    TlsBitmap: u32 = 0,
    /// TlsBitmapBits
    TlsBitmapBits: [2]u32 = .{ 0, 0 },
    /// ReadOnlySharedMemoryBase
    ReadOnlySharedMemoryBase: u32 = 0,
    /// SharedData
    SharedData: u32 = 0,
    /// ReadOnlyStaticServerData
    ReadOnlyStaticServerData: u32 = 0,
    /// AnsiCodePageData
    AnsiCodePageData: u32 = 0,
    /// OemCodePageData
    OemCodePageData: u32 = 0,
    /// UnicodeCaseTableData
    UnicodeCaseTableData: u32 = 0,
    /// NumberOfProcessors
    NumberOfProcessors: u32 = 1,
    /// NtGlobalFlag
    NtGlobalFlag: u32 = 0,
    /// CriticalSectionTimeout
    Padding_NtGlobalFlag: u32 = 0,
    CriticalSectionTimeout: u64 align(4) = 0,
    /// HeapSegmentReserve
    HeapSegmentReserve: u32 = 0,
    /// HeapSegmentCommit
    HeapSegmentCommit: u32 = 0,
    /// HeapDeCommitTotalFreeThreshold
    HeapDeCommitTotalFreeThreshold: u32 = 0,
    /// HeapDeCommitFreeBlockThreshold
    HeapDeCommitFreeBlockThreshold: u32 = 0,
    /// NumberOfHeaps
    NumberOfHeaps: u32 = 0,
    /// MaximumNumberOfHeaps
    MaximumNumberOfHeaps: u32 = 0,
    /// ProcessHeaps
    ProcessHeaps: u32 = 0,
    /// GdiSharedHandleTable
    GdiSharedHandleTable: u32 = 0,
    /// ProcessStarterHelper
    ProcessStarterHelper: u32 = 0,
    /// GdiDCAttributeList
    GdiDCAttributeList: u32 = 0,
    /// LoaderLock
    LoaderLock: u32 = 0,
    /// OSMajorVersion
    OSMajorVersion: u32 = 5,
    /// OSMinorVersion
    OSMinorVersion: u32 = 1,
    /// OSBuildNumber
    OSBuildNumber: u16 = 2600,
    /// OSCSDVersion
    OSCSDVersion: u16 = 0,
    /// OSPlatformId
    OSPlatformId: u32 = 2,
    /// ImageSubsystem
    ImageSubsystem: u32 = 2,
    /// ImageSubsystemMajorVersion
    ImageSubsystemMajorVersion: u32 = 5,
    /// ImageSubsystemMinorVersion
    ImageSubsystemMinorVersion: u32 = 1,
    /// ImageProcessAffinityMask
    ImageProcessAffinityMask: u32 = 1,
    /// GdiHandleBuffer
    GdiHandleBuffer: [34]u32 = .{0} ** 34,
    /// PostProcessInitRoutine
    PostProcessInitRoutine: u32 = 0,
    /// TlsExpansionBitmap
    TlsExpansionBitmap: u32 = 0,
    /// TlsExpansionBitmapBits
    TlsExpansionBitmapBits: [32]u32 = .{0} ** 32,
    /// SessionId
    SessionId: u32 = 0,
    /// AppCompatFlags
    AppCompatFlags: u64 align(4) = 0,
    /// AppCompatFlagsUser
    AppCompatFlagsUser: u64 align(4) = 0,
    /// pShimData
    pShimData: u32 = 0,
    /// AppCompatInfo
    AppCompatInfo: u32 = 0,
    /// CSDVersion
    CSDVersion: UNICODE_STRING = .{},
    /// ActivationContextData
    ActivationContextData: u32 = 0,
    /// ProcessAssemblyStorageMap
    ProcessAssemblyStorageMap: u32 = 0,
    /// SystemDefaultActivationContextData
    SystemDefaultActivationContextData: u32 = 0,
    /// SystemAssemblyStorageMap
    SystemAssemblyStorageMap: u32 = 0,
    /// MinimumStackCommit
    MinimumStackCommit: u32 = 0,
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

/// Global TEB address — needed by timer threads that must set up FS base
/// for calling game x86 callbacks.
pub var teb_address: usize = 0;
/// On x86 (32-bit), the FS selector for the TEB GDT entry.
/// Timer threads need this to set FS to the game's TEB before calling callbacks.
pub var teb_fs_selector: u16 = 0;
pub var teb_base_addr: usize = 0;
