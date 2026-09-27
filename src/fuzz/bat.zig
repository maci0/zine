//! Fuzz harness for the batch script interpreter behind `BatEnv.parseFile`.
//!
//! One input is one batch file's whole text, exactly as the loader reads it
//! from disk. The interpreter walks it line by line, expands `%VAR%`, `%0`
//! to `%9`, `%*` and `%~dp0`, and applies SET, IF/NOT and CALL, so every
//! offset it dereferences comes from the file.

const std = @import("std");
const bat = @import("../bat.zig");

/// Arguments the interpreter is given on every run. They feed `%0`-`%9` and
/// `%*`, so they are part of the input surface.
const args = [_][]const u8{ "vcvars32.bat", "arg one", "%NOT_EXPANDED" };

/// Directory `%~dp0` expands to on every run.
const script_dir = "C:\\tools\\";

/// Seed corpus: an MSVC-style prologue, a script whose only line is an
/// unterminated quote, one with an empty expansion of an undefined variable
/// in front of every statement form, a script made only of comments, and a
/// script whose last line ends inside a `%` expansion.
pub const seeds = [_][]const u8{
    "set VCVARS=32\r\nset PATH=%PATH%;C:\\bin\r\nif \"%VCPROMPT%\"==\"x\" set NOPE=1\r\ncl.exe %* /nologo\n",
    "if \"unterminated\r\n",
    "if %UNDEF%\ncall %UNDEF%\nset %UNDEF%\nset =noName\nset NAME=\nfinal.exe\r\n",
    "@echo off\r\nrem comment only\r\n:label\r\ngoto :label\r\n",
    "set A=%B%\r\nset B=%A%\r\n%0 %1 %2 %9 %* %~dp0\r\n%~dp0%\r\n",
    "call \"%~dp0other.bat\"\r\n",
    "",
    "%",
    "set",
    "if",
    "if not",
    "if not \"\"==\"\"\n",
};

/// Errors that mean the interpreter produced something impossible, rather
/// than rejected the input.
pub const Failure = error{
    /// A returned argument list is used to build a C argv, so it cannot be
    /// empty, its program name cannot be empty, and no token can hold a NUL.
    /// A later argument may be empty, which a program can still be handed.
    ArgvEmpty,
    ArgvProgramNameEmpty,
    ArgvTokenHasNul,
    /// A second run of the same script on a fresh environment must produce
    /// the same argument list: nothing may leak from the previous run.
    RunNotDeterministic,
    /// SET splits at the first `=`, so a name can never contain one, and a
    /// value is never empty (an empty SET removes the variable).
    EnvNameHasEquals,
    EnvNameHasNul,
    EnvValueEmpty,
    /// Reported by the allocator, not by an interpreter contract violation.
    OutOfMemory,
};

/// Free an argument list returned by `runScript`.
fn freeArgv(allocator: std.mem.Allocator, argv: ?[][]const u8) void {
    const args_slice = argv orelse return;
    for (args_slice) |arg| allocator.free(arg);
    allocator.free(args_slice);
}

/// Run the interpreter on one input in a fresh environment and check the
/// contract: the argument list is well formed, the environment it leaves
/// behind is a state an envp can encode, and the run is reproducible.
pub fn harness(allocator: std.mem.Allocator, data: []const u8) Failure!void {
    const first = try run(allocator, data);
    defer freeArgv(allocator, first);
    try checkArgv(first);

    const second = try run(allocator, data);
    defer freeArgv(allocator, second);
    if (!argvEql(first, second)) return error.RunNotDeterministic;
}

/// One interpreter run on its own environment. CALL reads a file, so an
/// unreadable target is the interpreter's documented error, not a contract
/// violation, and the run is abandoned.
fn run(allocator: std.mem.Allocator, data: []const u8) Failure!?[][]const u8 {
    var script_args = args;
    var env = bat.BatEnv{
        .allocator = allocator,
        .env = std.StringHashMap([]const u8).init(allocator),
    };
    defer env.deinit();

    const argv = env.runScript(data, script_dir, &script_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    var it = env.env.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.indexOfScalar(u8, name, '=') != null) return error.EnvNameHasEquals;
        if (std.mem.indexOfScalar(u8, name, 0) != null) return error.EnvNameHasNul;
        if (entry.value_ptr.*.len == 0) return error.EnvValueEmpty;
    }
    return argv;
}

/// Content comparison. `std.meta.eql` would compare the slices by pointer,
/// and the two runs allocate at different addresses.
fn argvEql(a: ?[][]const u8, b: ?[][]const u8) bool {
    const a_list = a orelse return b == null;
    const b_list = b orelse return false;
    if (a_list.len != b_list.len) return false;
    for (a_list, b_list) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn checkArgv(argv: ?[][]const u8) Failure!void {
    const args_slice = argv orelse return;
    if (args_slice.len == 0) return error.ArgvEmpty;
    if (args_slice[0].len == 0) return error.ArgvProgramNameEmpty;
    for (args_slice) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.ArgvTokenHasNul;
    }
}
