//! Fuzz harness for the x86 instruction decoder.
//!
//! One input is one slice of guest code, the same bytes `scanBlock` and the
//! JIT hand to `decode` a section at a time. The interpreter fetches 16 bytes,
//! but a block scan walks the whole section, so a prefix run or a length that
//! runs past the slice is reachable from a guest PE.

const std = @import("std");
const decoder = @import("../x86/decoder.zig");

/// 300 operand-size prefixes and nothing else: longer than the 15 bytes one
/// encoding can occupy, so the length must stop instead of walking them all.
pub const prefix_run = blk: {
    var bytes: [300]u8 = undefined;
    for (&bytes) |*byte| byte.* = 0x66;
    break :blk bytes;
};

/// Seed corpus: the encodings the interpreter actually executes, then the
/// shapes a section can hold that a one-byte test never builds: every prefix,
/// a prefix run longer than one instruction, a truncated immediate, a ModR/M
/// with a SIB and a displacement, and an empty slice.
pub const seeds = [_][]const u8{
    &[_]u8{0x90}, // NOP
    &[_]u8{ 0xB8, 0x78, 0x56, 0x34, 0x12 }, // MOV EAX, imm32
    &[_]u8{0x55}, // PUSH EBP
    &[_]u8{ 0x89, 0xE5 }, // MOV EBP, ESP
    &[_]u8{ 0x83, 0xEC, 0x10 }, // SUB ESP, imm8
    &[_]u8{ 0xE8, 0x00, 0x00, 0x00, 0x00 }, // CALL rel32
    &[_]u8{ 0x74, 0xFE }, // JE rel8
    &[_]u8{ 0x0F, 0x84, 0x00, 0x00, 0x00, 0x00 }, // JE rel32
    &[_]u8{ 0x64, 0xA1, 0x00, 0x00, 0x00, 0x00 }, // MOV EAX, FS:[moffs32]
    &[_]u8{ 0x89, 0x45, 0xFC }, // MOV [EBP-4], EAX
    &[_]u8{ 0x8B, 0x44, 0x88, 0x10 }, // MOV EAX, [EAX+ECX*4+0x10]
    &[_]u8{ 0x0F, 0xB6, 0xC0 }, // MOVZX EAX, AL
    &[_]u8{ 0xF3, 0xA4 }, // REP MOVSB
    &[_]u8{ 0x66, 0xB8, 0x34, 0x12 }, // MOV AX, imm16
    &[_]u8{0xC3}, // RET
    &[_]u8{ 0xF0, 0xF2, 0xF3, 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0x90 },
    &prefix_run,
    &[_]u8{ 0xB8, 0x78, 0x56 }, // MOV EAX, imm32 cut off mid-immediate
    &[_]u8{0x0F}, // two-byte escape with no second byte
    &[_]u8{0x83}, // opcode that needs a ModR/M it does not have
    &.{},
};

/// Ways a decode can hand the JIT a length it cannot step by.
pub const Failure = error{
    /// `length` runs past the bytes the decoder was given, so the next
    /// fetch starts outside the section.
    LengthPastInput,
    /// `length` is above the 15 bytes one x86 encoding can occupy. The field
    /// is a `u8`, and adding a wrapped length to a section offset stalls the
    /// block scan or panics the cast.
    LengthAboveMax,
    /// The same bytes decoded twice did not decode the same way.
    DecodeNotRepeatable,
};

/// Decode one slice and check the length contract, then decode it again and
/// check the two agree. The decoder keeps no state, so disagreement means it
/// read something other than the slice.
pub fn harness(allocator: std.mem.Allocator, data: []u8) Failure!void {
    _ = allocator;
    const first = decoder.decode(data);
    try check(data, first);
    const second = decoder.decode(data);
    if (!std.meta.eql(first, second)) return error.DecodeNotRepeatable;
}

fn check(data: []const u8, insn: decoder.Instruction) Failure!void {
    if (insn.length > data.len) return error.LengthPastInput;
    if (insn.length > decoder.max_insn_len) return error.LengthAboveMax;
}
