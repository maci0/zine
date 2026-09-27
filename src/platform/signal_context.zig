//! Host CPU register file and signal context as the Linux kernel delivers them.
//!
//! These are plain type definitions, not behaviour: the guest SEH path
//! (`win32/kernel32/error.zig`) and the x86-64 compat thunks
//! (`x86/compat_thunks.zig`) both have to read a host `ucontext_t` to resume
//! execution, so they import these types directly rather than reaching
//! through `platform/native.zig`, which depends on them.

const std = @import("std");
const builtin = @import("builtin");

const native_arch = builtin.target.cpu.arch;

// glibc-compatible REG indices into mcontext_t.gregs (see sys/ucontext.h).
// Kept in-tree because std.os.linux dropped these constants in 0.16.
pub const REG = if (native_arch == .x86) struct {
    pub const GS = 0;
    pub const FS = 1;
    pub const ES = 2;
    pub const DS = 3;
    pub const EDI = 4;
    pub const ESI = 5;
    pub const EBP = 6;
    pub const ESP = 7;
    pub const EBX = 8;
    pub const EDX = 9;
    pub const ECX = 10;
    pub const EAX = 11;
    pub const TRAPNO = 12;
    pub const ERR = 13;
    pub const EIP = 14;
    pub const CS = 15;
    pub const EFL = 16;
    pub const UESP = 17;
    pub const SS = 18;
} else struct {
    pub const R8 = 0;
    pub const R9 = 1;
    pub const R10 = 2;
    pub const R11 = 3;
    pub const R12 = 4;
    pub const R13 = 5;
    pub const R14 = 6;
    pub const R15 = 7;
    pub const RDI = 8;
    pub const RSI = 9;
    pub const RBP = 10;
    pub const RBX = 11;
    pub const RDX = 12;
    pub const RAX = 13;
    pub const RCX = 14;
    pub const RSP = 15;
    pub const RIP = 16;
    pub const EFL = 17;
    pub const CSGSFS = 18;
    pub const ERR = 19;
    pub const TRAPNO = 20;
    pub const OLDMASK = 21;
    pub const CR2 = 22;
};

// glibc-compatible ucontext_t as delivered by the kernel to signal handlers
// with SA_SIGINFO. Std removed the built-in wrapper in 0.16.
const greg_t = if (native_arch == .x86) u32 else usize;
const gregset_t = if (native_arch == .x86) [19]greg_t else [23]greg_t;

const fpregset_t_x86 = extern struct {
    cw: u32,
    sw: u32,
    tag: u32,
    ipoff: u32,
    cssel: u32,
    dataoff: u32,
    datasel: u32,
    st: [8]extern struct { significand: [4]u16, exponent: u16 },
    status: u32,
};

const fpregset_t_x86_64 = extern struct {
    cwd: u16,
    swd: u16,
    ftw: u16,
    fop: u16,
    rip: u64,
    rdp: u64,
    mxcsr: u32,
    mxcr_mask: u32,
    st: [8]extern struct { significand: [4]u16, exponent: u16, padding: [3]u16 },
    xmm: [16]extern struct { element: [4]u32 },
    padding: [24]u32,
};

pub const mcontext_t = if (native_arch == .x86) extern struct {
    gregs: gregset_t,
    fpregs: *fpregset_t_x86,
    oldmask: u32,
    cr2: u32,
} else extern struct {
    gregs: gregset_t,
    fpregs: *fpregset_t_x86_64,
    __reserved1: [8]u64,
};

pub const ucontext_t = extern struct {
    flags: usize,
    link: ?*ucontext_t,
    stack: std.posix.stack_t,
    mcontext: mcontext_t,
    sigmask: std.posix.sigset_t,
    fpregs_mem: if (native_arch == .x86) fpregset_t_x86 else fpregset_t_x86_64,
};
