//! In-process fuzzer driver for the untrusted-input parsers, the batch
//! interpreter, and the PE string-table walk.
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
const bat_fuzz = @import("fuzz/bat.zig");
const dialog_fuzz = @import("fuzz/dialog.zig");
const icon_fuzz = @import("fuzz/icon.zig");
const loadstring_fuzz = @import("fuzz/loadstring.zig");
const menu_fuzz = @import("fuzz/menu.zig");
const pe_fuzz = @import("fuzz/pe.zig");

/// Where failing inputs are written, relative to the working directory.
const crash_dir = "zig-out/fuzz";

/// Mutation seed used when `ZINE_FUZZ_SEED` is unset. A fixed value, not a
/// hash of a constant string: the printed seed is what a failing run is
/// replayed from, so it has to be readable and settable.
const default_seed: u64 = 0x5eed_f022_1ab7_5c0d;

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
    .{ .name = "loadstring", .seeds = &loadstring_fuzz.seeds, .run = loadstring_fuzz.harness },
    .{ .name = "bat", .seeds = &bat_fuzz.seeds, .run = bat_fuzz.harness },
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
    const seed = try mutationSeed(init.environ_map);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    std.debug.print("fuzz: seed 0x{x}\n", .{seed});

    for (targets) |target| {
        // Each target gets its own window so the first one cannot use up the
        // whole budget.
        const deadline = std.Io.Timestamp.now(io, .real).nanoseconds +
            @as(i128, fuzz_options.fuzz_seconds) * std.time.ns_per_s;
        var cases = try gpa.alloc([]const u8, target.seeds.len + extra.items.len);
        defer gpa.free(cases);
        for (target.seeds, 0..) |case_bytes, i| cases[i] = case_bytes;
        for (extra.items, 0..) |item, i| cases[target.seeds.len + i] = item;

        var executed: u64 = 0;
        var failures: u64 = 0;
        while (std.Io.Timestamp.now(io, .real).nanoseconds < deadline) {
            for (cases) |case| {
                const input = mutation.loadSeed(&buffer, case);
                _ = arena_state.reset(.retain_capacity);
                report(target, input, executed, seed, &failures, io, arena_state.allocator());
                executed += 1;
            }
            for (cases) |case_bytes| {
                const input = mutation.loadSeed(&buffer, case_bytes);
                const len = mutation.apply(rand, input);
                _ = arena_state.reset(.retain_capacity);
                report(target, input[0..len], executed, seed, &failures, io, arena_state.allocator());
                executed += 1;
            }
        }
        std.debug.print("fuzz: {s}: {d} inputs, {d} failures\n", .{ target.name, executed, failures });
    }
}

/// The mutation stream's only entropy source. `ZINE_FUZZ_SEED` selects it so a
/// run can be repeated exactly; an unparsable value is rejected rather than
/// silently falling back, which would replay a different stream than the one
/// that failed.
fn mutationSeed(env: *const std.process.Environ.Map) !u64 {
    const text = env.get("ZINE_FUZZ_SEED") orelse return default_seed;
    return std.fmt.parseInt(u64, text, 0) catch error.InvalidFuzzSeed;
}

fn report(
    target: Target,
    input: []u8,
    case_index: u64,
    seed: u64,
    failures: *u64,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    target.run(allocator, input) catch |err| {
        failures.* += 1;
        // The failure itself is already counted and printed; a crash file is
        // best effort, and nothing after this line can report its absence.
        saveCrash(io, target.name, input, failures.*) catch {};
        // The case index and the seed locate the input in the stream: the seed
        // replays the mutations, the index says which one failed. The time
        // budget decides how far the stream runs, so the index, not the wall
        // clock, is what a replay matches on.
        std.debug.print("fuzz: {s} failed on case {d} with seed 0x{x} ({d} bytes): {t}\n", .{ target.name, case_index, seed, input.len, err });
    };
}

fn saveCrash(io: std.Io, name: []const u8, input: []const u8, index: u64) !void {
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}-{d}.bin", .{ crash_dir, name, index });
    defer std.heap.page_allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = input });
}
