const std = @import("std");
const package_version = @import("build.zig.zon").version;

comptime {
    if (!std.mem.eql(u8, package_version, @import("src/version.zig").string)) {
        @compileError("build.zig.zon version must match src/version.zig");
    }
}

fn queryForArch(arch: std.Target.Cpu.Arch) std.Target.Query {
    return switch (arch) {
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
        .x86_64 => .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            // glibc: the FLTK backend links system (glibc) shared libraries.
            // Zig's default musl ABI would produce a dynamic binary needing
            // /lib/ld-musl-x86_64.so.1, which is absent on glibc hosts.
            .abi = .gnu,
        },
        .wasm32 => .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        },
        .wasm64 => .{
            .cpu_arch = .wasm64,
            .os_tag = .wasi,
        },
        else => @panic("Unsupported architecture. Use x86, x86_64, wasm32, or wasm64."),
    };
}

fn nameForArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86 => "zine.x86",
        .x86_64 => "zine.x86_64",
        .wasm32 => "zine.wasm32",
        .wasm64 => "zine.wasm64",
        else => "zine",
    };
}

fn addNativeExe(
    b: *std.Build,
    arch: std.Target.Cpu.Arch,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    toml_mod: *std.Build.Module,
    use_fltk: bool,
    embed_stubs: bool,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = nameForArch(arch),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = false,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });

    // Move the host binary to a high address so that the low address
    // space (0x00400000+) is free for guest Win32 PEs.
    // On x86: 0x70000000 (same approach Wine uses)
    // On x86_64: 0x70000000 (same as x86, within the low 4GB for MAP_32BIT compat)
    exe.image_base = 0x70000000;

    // FLTK native GUI backend (optional). Originally x86-only because the
    // bridge targets the 32-bit build, but the x86_64 compat build links the
    // same C++ bridge against the system FLTK libs fine — and on 64-bit-only
    // hosts (no i386 FLTK packages) that is the only way to get the FLTK UI.
    if (use_fltk) {
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/gui/fltk_bridge.cpp"),
            // Warnings are errors: the bridge is clean under -Wall -Wextra and
            // should stay that way. System FLTK headers stay non-fatal via the
            // -isystem include added below.
            .flags = &.{ "-std=c++11", "-fno-exceptions", "-Wall", "-Wextra", "-Werror", "-I/usr/include/fltk1.3" },
        });
        exe.root_module.addIncludePath(b.path("src/gui"));
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/fltk1.3" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/fltk1.3" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        exe.root_module.linkSystemLibrary("fltk", .{});
        exe.root_module.linkSystemLibrary("fltk_images", .{});
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

    const options = b.addOptions();
    options.addOption(bool, "use_fltk", use_fltk);
    options.addOption(bool, "embed_stubs", embed_stubs);
    exe.root_module.addOptions("build_options", options);

    return exe;
}

fn addWasmExe(
    b: *std.Build,
    arch: std.Target.Cpu.Arch,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    toml_mod: *std.Build.Module,
    embed_stubs: bool,
    enable_jit_host: bool,
) *std.Build.Step.Compile {
    const wasm_lib = b.addExecutable(.{
        .name = nameForArch(arch),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    wasm_lib.rdynamic = true;
    wasm_lib.initial_memory = 256 * 1024 * 1024;
    wasm_lib.max_memory = 2 * 1024 * 1024 * 1024;
    wasm_lib.export_memory = true;

    const wasm_options = b.addOptions();
    wasm_options.addOption(bool, "use_fltk", false);
    wasm_options.addOption(bool, "enable_jit_host", enable_jit_host);
    wasm_options.addOption(bool, "embed_stubs", embed_stubs);
    wasm_lib.root_module.addOptions("build_options", wasm_options);

    return wasm_lib;
}

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture (x86, x86_64, wasm32, or wasm64)");
    const build_all = b.option(bool, "all", "Build all targets (x86 + x86_64 + wasm32 + wasm64)") orelse false;

    const use_fltk = b.option(bool, "fltk", "Enable FLTK native GUI backend (requires -Darch=x86_64)") orelse false;
    const embed_stubs = !(b.option(bool, "external-stubs", "Load Win32 stubs from external DLLs instead of embedding them") orelse false);
    const enable_jit_host = b.option(bool, "jit_host", "Enable JIT host imports (requires zine-host or browser)") orelse false;

    const optimize = b.standardOptimizeOption(.{});
    const cli_test_step = b.step("test-cli", "Check native and wasm32 CLI output (wasm32 requires wasmtime)");

    const archs_to_build: []const std.Target.Cpu.Arch = if (build_all)
        &.{ .x86, .x86_64, .wasm32, .wasm64 }
    else if (arch) |a|
        @as([]const std.Target.Cpu.Arch, &.{a})
    else
        &.{.x86}; // default

    for (archs_to_build) |a| {
        const query = queryForArch(a);
        const target = b.resolveTargetQuery(query);

        const toml_dep = b.dependency("toml", .{
            .target = target,
            .optimize = optimize,
        });
        if (a == archs_to_build[0]) {
            const toml_license = b.addInstallFileWithDir(toml_dep.path("LICENSE"), .prefix, "share/licenses/zine/zig-toml.LICENSE");
            b.getInstallStep().dependOn(&toml_license.step);
        }

        if (a == .wasm32 or a == .wasm64) {
            const wasm_lib = addWasmExe(b, a, target, optimize, toml_dep.module("toml"), embed_stubs, enable_jit_host);
            b.installArtifact(wasm_lib);
            if (a == .wasm32 and !enable_jit_host) {
                const cli_test = b.addSystemCommand(&.{"bash"});
                cli_test.addFileArg(b.path("tests/test_cli.sh"));
                cli_test.addArgs(&.{ "zine " ++ package_version, "wasmtime", "run" });
                cli_test.addArtifactArg(wasm_lib);
                cli_test_step.dependOn(&cli_test.step);
            } else {
                const cli_test = b.addFail("test-cli requires a native or plain wasm32 target; wasm64 and jit_host need a custom runtime");
                cli_test_step.dependOn(&cli_test.step);
            }
        } else {
            const exe = addNativeExe(b, a, target, optimize, toml_dep.module("toml"), use_fltk, embed_stubs);
            b.installArtifact(exe);
            const cli_test = b.addSystemCommand(&.{"bash"});
            cli_test.addFileArg(b.path("tests/test_cli.sh"));
            cli_test.addArg("zine " ++ package_version);
            cli_test.addArtifactArg(exe);
            cli_test_step.dependOn(&cli_test.step);

            // Only add run step for the default (x86) target
            if (a == .x86 and !build_all) {
                const run_step = b.step("run", "Run the app");
                const run_cmd = b.addRunArtifact(exe);
                run_step.dependOn(&run_cmd.step);
                run_cmd.step.dependOn(b.getInstallStep());
                if (b.args) |args| {
                    run_cmd.addArgs(args);
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // DLL build: compile stubs as standalone Windows DLLs
    // Usage: zig build -Ddll=all     (builds all DLLs into zig-out/bin/dll/)
    //        zig build -Ddll=msvcrt  (builds just MSVCRT.dll)
    // -----------------------------------------------------------------------
    const dll_arg = b.option([]const u8, "dll", "Build Windows DLLs ('all' for all, or a name like 'msvcrt')");
    if (dll_arg) |arg| {
        const dll_target = b.resolveTargetQuery(.{
            .cpu_arch = .x86,
            .os_tag = .windows,
        });

        // Shared win32 module accessible via @import("win32") in DLL sources
        const win32_mod = b.createModule(.{
            .root_source_file = b.path("src/win32_dll_api.zig"),
            .target = dll_target,
            .optimize = optimize,
            .link_libc = true,
        });
        const win32_build_options = b.addOptions();
        win32_build_options.addOption(bool, "use_fltk", false);
        win32_mod.addOptions("build_options", win32_build_options);

        const dll_names = [_]struct { name: []const u8, src: []const u8 }{
            .{ .name = "msvcrt", .src = "src/dll/msvcrt_dll.zig" },
            .{ .name = "kernel32", .src = "src/dll/kernel32_dll.zig" },
            .{ .name = "advapi32", .src = "src/dll/advapi32_dll.zig" },
            .{ .name = "user32", .src = "src/dll/user32_dll.zig" },
            .{ .name = "gdi32", .src = "src/dll/gdi32_dll.zig" },
            .{ .name = "shell32", .src = "src/dll/shell32_dll.zig" },
            .{ .name = "ole32", .src = "src/dll/ole32_dll.zig" },
            .{ .name = "oleaut32", .src = "src/dll/oleaut32_dll.zig" },
            .{ .name = "comctl32", .src = "src/dll/comctl32_dll.zig" },
            .{ .name = "comdlg32", .src = "src/dll/comdlg32_dll.zig" },
            .{ .name = "winmm", .src = "src/dll/winmm_dll.zig" },
            .{ .name = "version", .src = "src/dll/version_dll.zig" },
            .{ .name = "shlwapi", .src = "src/dll/shlwapi_dll.zig" },
            .{ .name = "ntdll", .src = "src/dll/ntdll_dll.zig" },
            .{ .name = "imagehlp", .src = "src/dll/imagehlp_dll.zig" },
            .{ .name = "imm32", .src = "src/dll/imm32_dll.zig" },
            .{ .name = "setupapi", .src = "src/dll/setupapi_dll.zig" },
            .{ .name = "winspool", .src = "src/dll/winspool_dll.zig" },
            .{ .name = "mss32", .src = "src/dll/mss32_dll.zig" },
            .{ .name = "rpcrt4", .src = "src/dll/rpcrt4_dll.zig" },
            .{ .name = "ws2_32", .src = "src/dll/ws2_32_dll.zig" },
            .{ .name = "wsock32", .src = "src/dll/wsock32_dll.zig" },
            .{ .name = "d3d8", .src = "src/dll/d3d8_dll.zig" },
            .{ .name = "ddraw", .src = "src/dll/ddraw_dll.zig" },
            .{ .name = "dinput", .src = "src/dll/dinput_dll.zig" },
            .{ .name = "dinput8", .src = "src/dll/dinput8_dll.zig" },
            .{ .name = "dsound", .src = "src/dll/dsound_dll.zig" },
            .{ .name = "mspdb60", .src = "src/dll/mspdb60_dll.zig" },
            .{ .name = "msvcp60", .src = "src/dll/msvcp60_dll.zig" },
            .{ .name = "rcdll", .src = "src/dll/rcdll_dll.zig" },
            .{ .name = "mfc42", .src = "src/dll/mfc42_dll.zig" },
            .{ .name = "cards", .src = "src/dll/cards_dll.zig" },
            .{ .name = "icmp", .src = "src/dll/icmp_dll.zig" },
            .{ .name = "nddeapi", .src = "src/dll/nddeapi_dll.zig" },
            .{ .name = "vdmdbg", .src = "src/dll/vdmdbg_dll.zig" },
            .{ .name = "mag_hook", .src = "src/dll/mag_hook_dll.zig" },
        };

        const build_all_dlls = std.mem.eql(u8, arg, "true") or std.mem.eql(u8, arg, "all");

        for (dll_names) |entry| {
            if (build_all_dlls or std.mem.eql(u8, arg, entry.name)) {
                const dll = b.addLibrary(.{
                    .name = entry.name,
                    .linkage = .dynamic,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(entry.src),
                        .target = dll_target,
                        .optimize = optimize,
                        .imports = &.{
                            .{ .name = "win32", .module = win32_mod },
                        },
                    }),
                });

                const dll_options = b.addOptions();
                dll_options.addOption(bool, "use_fltk", false);
                dll.root_module.addOptions("build_options", dll_options);

                // Install to bin/dll/ subdirectory
                const install_dll = b.addInstallArtifact(dll, .{
                    .dest_dir = .{ .override = .{ .custom = "bin/dll" } },
                });
                b.getInstallStep().dependOn(&install_dll.step);
            }
        }
    }

    // -----------------------------------------------------------------------
    // zine-host: native wrapper for running zine.wasm with JIT support
    // Uses the wasmer C API for WASI + custom JIT imports.
    // -----------------------------------------------------------------------
    const build_host = b.option(bool, "host", "Build zine-host (wasmer wrapper with JIT support)") orelse false;
    if (build_host) {
        // Zig 0.16's lld rejects the .sframe relocations in GCC 16's crt1.o
        // ("unhandled relocation type R_X86_64_PC64"), so compile host_main.zig
        // to an object with Zig and do the final link with the system cc.
        const host_obj = b.addObject(.{
            .name = "zine-host-obj",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/host_main.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        host_obj.root_module.link_libc = true;
        // wasmer's pkg-config has stale build-machine paths (-L/build/.wasmer/lib
        // which doesn't exist here), so do NOT linkSystemLibrary("wasmer") on the
        // object — lld then fails on the missing library dir. The object only
        // needs the header (wasmer.h lives in /usr/include); the final link with
        // -lwasmer happens in the cc step below.
        host_obj.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });

        const host_link = b.addSystemCommand(&.{ "cc", "-o" });
        const host_out = host_link.addOutputFileArg("zine-host");
        host_link.addArtifactArg(host_obj);
        host_link.addArgs(&.{ "-lwasmer", "-lc" });
        const install_host = b.addInstallFileWithDir(host_out, .{ .custom = "bin" }, "zine-host");
        install_host.step.dependOn(&host_link.step);
        b.getInstallStep().dependOn(&install_host.step);
        const cli_test = b.addSystemCommand(&.{"bash"});
        cli_test.addFileArg(b.path("tests/test_cli.sh"));
        cli_test.addArg("zine-host " ++ package_version);
        cli_test.addFileArg(host_out);
        cli_test_step.dependOn(&cli_test.step);
    }

    // -----------------------------------------------------------------------
    // Test step: runs all unit tests via a unified root
    // -----------------------------------------------------------------------
    // Using a single test root under src/ ensures that ../foo imports
    // resolve correctly (individual files as module roots can't reach
    // parent directories).
    // -----------------------------------------------------------------------
    // Format check: fails any build/test while the tree deviates from
    // canonical zig fmt output. zig fmt is the language's de-facto formatter;
    // wiring its --check mode into install + test keeps unformatted code from
    // compiling anywhere (there is no other CI gate for this).
    // -----------------------------------------------------------------------
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = true,
    });
    b.getInstallStep().dependOn(&fmt_check.step);
    cli_test_step.dependOn(&fmt_check.step);

    const test_step = b.step("test", "Run unit tests");
    const test_filter = b.option([]const u8, "test-filter", "Run unit tests whose names contain this substring");
    const t = b.addTest(.{
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    // runner.zig (and anything importing it) reads build_options; provide
    // defaults matching a plain embedded-stubs native build.
    const test_options = b.addOptions();
    test_options.addOption(bool, "use_fltk", false);
    test_options.addOption(bool, "embed_stubs", true);
    test_options.addOption(bool, "enable_jit_host", false);
    t.root_module.addOptions("build_options", test_options);
    test_step.dependOn(&fmt_check.step);
    test_step.dependOn(&b.addRunArtifact(t).step);
}
