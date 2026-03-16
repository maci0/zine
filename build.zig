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

    const use_fltk = b.option(bool, "fltk", "Enable FLTK native GUI backend") orelse false;

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
        // entry point comes from pub fn main() in wasm_main.zig
        wasm_lib.rdynamic = true;
        // 256MB initial, 2GB max
        wasm_lib.initial_memory = 256 * 1024 * 1024;
        wasm_lib.max_memory = 2 * 1024 * 1024 * 1024;
        wasm_lib.export_memory = true;

        // Pass build options to WASM build (FLTK is never used on WASM)
        const wasm_options = b.addOptions();
        wasm_options.addOption(bool, "use_fltk", false);
        // JIT host imports (extern "jit" functions) are gated behind this flag.
        // When false (default), --jit runs in compile-only mode (validates JIT
        // output but doesn't execute it). When true, the WASM binary requires
        // a host that provides jit_compile/jit_call (zine-host or browser JS).
        const enable_jit_host = b.option(bool, "jit_host", "Enable JIT host imports (requires zine-host or browser)") orelse false;
        wasm_options.addOption(bool, "enable_jit_host", enable_jit_host);
        wasm_lib.root_module.addOptions("build_options", wasm_options);

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

        // On x86 (32-bit), move the host binary to a high address so that
        // the low address space (0x00400000+) is free for guest Win32 PEs.
        // Without this, MAP_FIXED at a PE's ImageBase would overwrite the
        // Zine binary itself.  This is the same approach Wine uses.
        if (arch == .x86) {
            exe.image_base = 0x70000000;
        }

        // FLTK native GUI backend (optional)
        if (use_fltk) {
            exe.root_module.addCSourceFile(.{
                .file = b.path("src/gui/fltk_bridge.cpp"),
                .flags = &.{ "-std=c++11", "-fno-exceptions", "-I/usr/include/fltk1.3" },
            });
            exe.root_module.addIncludePath(b.path("src/gui"));
            // System FLTK 1.3 — add system include/library paths
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/fltk1.3" });
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/fltk1.3" });
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            exe.root_module.linkSystemLibrary("fltk", .{});
            exe.root_module.linkSystemLibrary("fltk_images", .{});
            // X11 dependencies
            exe.root_module.linkSystemLibrary("X11", .{});
            exe.root_module.linkSystemLibrary("Xext", .{});
            exe.root_module.linkSystemLibrary("Xft", .{});
            exe.root_module.linkSystemLibrary("fontconfig", .{});
            exe.root_module.linkSystemLibrary("Xinerama", .{});
            exe.root_module.linkSystemLibrary("Xcursor", .{});
            exe.root_module.linkSystemLibrary("Xrender", .{});
            exe.root_module.linkSystemLibrary("Xfixes", .{});
            exe.root_module.linkSystemLibrary("pthread", .{});
            exe.root_module.link_libc = true;
            exe.root_module.link_libcpp = true;
        }

        // Pass FLTK flag to Zig source
        const options = b.addOptions();
        options.addOption(bool, "use_fltk", use_fltk);
        exe.root_module.addOptions("build_options", options);

        b.installArtifact(exe);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    // -----------------------------------------------------------------------
    // zine-host: native wrapper for running zine.wasm with JIT support
    // Uses the wasmer C API for WASI + custom JIT imports.
    // -----------------------------------------------------------------------
    const build_host = b.option(bool, "host", "Build zine-host (wasmer wrapper with JIT support)") orelse false;
    if (build_host) {
        const host_exe = b.addExecutable(.{
            .name = "zine-host",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/host_main.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        host_exe.root_module.link_libc = true;
        // wasmer's pkg-config may have stale paths; add system paths explicitly
        host_exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        host_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        host_exe.root_module.linkSystemLibrary("wasmer", .{});
        b.installArtifact(host_exe);
    }

    // -----------------------------------------------------------------------
    // Test step: runs all unit tests via a unified root
    // -----------------------------------------------------------------------
    // Using a single test root under src/ ensures that ../foo imports
    // resolve correctly (individual files as module roots can't reach
    // parent directories).
    const test_step = b.step("test", "Run x86 interpreter unit tests");
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(t).step);
}
