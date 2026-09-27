//! In-process fuzzer driver for the untrusted-input parsers.
//!
//! Lives at the src/ root so the harness modules under fuzz/ can reach the
//! parsers with relative imports, the same reason test_root.zig sits here.
//!
//! Run with `zig build fuzz -Dfuzz-seconds=10`. Each target takes the raw
//! bytes a PE file supplies to the parser, so the driver mutates a seed
//! corpus rather than inventing a synthetic structure. Failing inputs are
//! written to `zig-out/fuzz/` for minimization and, once fixed, for a
//! regression test.
//!
//! Coverage-guided fuzzers (libFuzzer, AFL++, honggfuzz) can drive the same
//! harnesses by linking any module under `fuzz/` and calling `harness` per input.

const std = @import("std");
const fuzz_options = @import("fuzz_options");
const mutation = @import("fuzz/mutation.zig");
const dialog_fuzz = @import("fuzz/dialog.zig");
const icon_fuzz = @import("fuzz/icon.zig");
const menu_fuzz = @import("fuzz/menu.zig");
const pe_fuzz = @import("fuzz/pe.zig");

/// Where failing inputs are written, relative to the working directory.
const crash_dir = "zig-out/fuzz";

const Target = struct {
    name: []const u8,
    seeds: []const []const u8,
    run: *const fn (std.mem.Allocator, []u8) anyerror!void,
};

const targets = [_]Target{
    .{ .name = "menu", .seeds = &menu_fuzz.seeds, .run = menu_fuzz.harness },
    .{ .name = "dialog", .seeds = &dialog_fuzz.seeds, .run = dialog_fuzz.harness },
    .{ .name = "icon", .seeds = &icon_fuzz.seeds, .run = icon_fuzz.harness },
    .{ .name = "pe", .seeds = &pe_fuzz.seeds, .run = pe_fuzz.harness },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.next(); // executable name

    // Extra inputs (for example a captured resource) are replayed as-is.
    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    defer extra.deinit(gpa);
    while (args.next()) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(mutation.max_input_len));
        try extra.append(gpa, data);
    }

    std.Io.Dir.cwd().createDirPath(io, crash_dir) catch |err| {
        std.debug.print("fuzz: cannot create {s}: {t}\n", .{ crash_dir, err });
    };

    // One arena reset per input bounds memory without freeing on the error
    // paths; leak detection belongs to the replay tests, which use
    // std.testing.allocator.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var buffer: [mutation.max_input_len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(0, crash_dir));
    const rand = prng.random();

    for (targets) |target| {
        // Each target gets its own window so the first one cannot use up the
        // whole budget.
        const deadline = std.Io.Timestamp.now(io, .real).nanoseconds +
            @as(i128, fuzz_options.fuzz_seconds) * std.time.ns_per_s;
        var cases = try gpa.alloc([]const u8, target.seeds.len + extra.items.len);
        defer gpa.free(cases);
        for (target.seeds, 0..) |seed, i| cases[i] = seed;
        for (extra.items, 0..) |item, i| cases[target.seeds.len + i] = item;

        var executed: u64 = 0;
        var failures: u64 = 0;
        while (std.Io.Timestamp.now(io, .real).nanoseconds < deadline) {
            for (cases) |case| {
                const input = mutation.loadSeed(&buffer, case);
                _ = arena_state.reset(.retain_capacity);
                report(target, input, &failures, io, arena_state.allocator());
                executed += 1;
            }
            for (cases) |seed| {
                const input = mutation.loadSeed(&buffer, seed);
                const len = mutation.apply(rand, input);
                _ = arena_state.reset(.retain_capacity);
                report(target, input[0..len], &failures, io, arena_state.allocator());
                executed += 1;
            }
        }
        std.debug.print("fuzz: {s}: {d} inputs, {d} failures\n", .{ target.name, executed, failures });
    }
}

fn report(
    target: Target,
    input: []u8,
    failures: *u64,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    target.run(allocator, input) catch |err| {
        failures.* += 1;
        // The failure itself is already counted and printed; a crash file is
        // best effort, and nothing after this line can report its absence.
        saveCrash(io, target.name, input, failures.*) catch {};
        std.debug.print("fuzz: {s} failed on {d} bytes: {t}\n", .{ target.name, input.len, err });
    };
}

fn saveCrash(io: std.Io, name: []const u8, input: []const u8, index: u64) !void {
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}-{d}.bin", .{ crash_dir, name, index });
    defer std.heap.page_allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = input });
}
