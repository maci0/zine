const std = @import("std");

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture (x86, x86_64, or wasm32)") orelse .x86;

    const query = switch (arch) {
        .x86 => blk: {
            // Disable SIMD to match legacy 32-bit x86 target and avoid stack alignment
            // issues with Win32 binaries expecting 4-byte aligned stacks.
            const features = std.Target.x86.Feature;
            var disabled_features = std.Target.Cpu.Feature.Set.empty;
            disabled_features.addFeature(@intFromEnum(features.sse));
            disabled_features.addFeature(@intFromEnum(features.sse2));
            disabled_features.addFeature(@intFromEnum(features.avx));
            disabled_features.addFeature(@intFromEnum(features.avx2));

            break :blk std.Target.Query{
                .cpu_arch = .x86,
                .os_tag = .linux,
                .cpu_model = .{ .explicit = &std.Target.x86.cpu.pentium },
                .cpu_features_sub = disabled_features,
            };
        },
        .x86_64 => std.Target.Query{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
        .wasm32 => std.Target.Query{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        },
        else => @panic("Unsupported architecture. Use x86, x86_64, or wasm32."),
    };

    const target = b.resolveTargetQuery(query);

    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    if (arch == .wasm32) {
        // WASM build: produce a .wasm library with exported functions
        const wasm_lib = b.addExecutable(.{
            .name = "zine",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm_main.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "zine", .module = mod },
                },
            }),
        });
        wasm_lib.entry = .disabled;
        wasm_lib.rdynamic = true;
        // 256MB initial, 2GB max
        wasm_lib.initial_memory = 256 * 1024 * 1024;
        wasm_lib.max_memory = 2 * 1024 * 1024 * 1024;
        wasm_lib.export_memory = true;

        b.installArtifact(wasm_lib);
    } else {
        // Native build: produce an executable
        const exe = b.addExecutable(.{
            .name = "zine",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = false,
                .imports = &.{
                    .{ .name = "zine", .module = mod },
                },
            }),
        });

        b.installArtifact(exe);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
}
