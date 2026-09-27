const std = @import("std");
const builtin = @import("builtin");
const package_version = @import("build.zig.zon").version;

// Debian/Ubuntu install FLTK 1.3 here; the bridge's C++ sources and the
// system libraries it links assume that layout.
const fltk_include_dir = "/usr/include/fltk1.3";
const fltk_lib_dir = "/usr/lib/fltk1.3";

// One warning set for src/gui/fltk_bridge.cpp, shared by the -Dfltk
// executable and the gate's check-cxx step: a check that runs in one and not
// the other means a warning can merge while the gate stays green. The FLTK
// headers reach the compiler as a system include, so their own warnings do
// not fail either compile.
const fltk_bridge_cxx_flags = [_][]const u8{
    "-std=c++11",    "-fno-exceptions",    "-Werror",
    "-Wall",         "-Wextra",            "-Wpedantic",
    "-Wshadow",      "-Wnon-virtual-dtor", "-Woverloaded-virtual",
    "-Wcast-qual",   "-Wundef",            "-Wformat=2",
    "-Wswitch-enum", "-Wnull-dereference", "-I" ++ fltk_include_dir,
};

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
    web_assets: *std.Build.Step.Options,
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

    // DWARF records absolute source paths (DW_AT_comp_dir) and absolute
    // toolchain paths for std, so an unstripped artifact differs per
    // checkout directory and per host. Debug builds keep them.
    exe.root_module.strip = optimize != .Debug;

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
            .flags = &fltk_bridge_cxx_flags,
        });
        exe.root_module.addIncludePath(b.path("src/gui"));
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = fltk_include_dir });
        exe.root_module.addLibraryPath(.{ .cwd_relative = fltk_lib_dir });
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
    exe.root_module.addOptions("web_assets", web_assets);

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
    // Same reason as the native exes: keep checkout and toolchain paths
    // out of the installed module.
    wasm_lib.root_module.strip = optimize != .Debug;
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

/// Every asset the Web UI server precompresses at build time.
const precompressed_web_assets = [_][]const u8{ "app.js", "win2k.css", "index.html", "van.min.js" };

/// The assets the document references by digest. Their bytes cannot change
/// under one URL, so the server caches them without revalidating and a rebuild
/// reaches the browser as a new URL.
const content_hashed_web_assets = [_][]const u8{ "app.js", "win2k.css", "van.min.js" };

/// The document URL the build embeds, as opposed to the one on disk: the
/// assets it names carry their digest, which only this build knows.
const embedded_document_option = "index_html";

/// "/win2k.css" carrying its content digest: "/win2k-<64 hex>.css".
fn hashedAssetUrl(allocator: std.mem.Allocator, name: []const u8, digest: [32]u8) ![]u8 {
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "/{s}-{s}{s}", .{ stem, hex, ext });
}

fn compressedWebAssets(b: *std.Build) !*std.Build.Step.Options {
    const options = b.addOptions();
    const allocator = b.allocator;

    var digests: [precompressed_web_assets.len][32]u8 = undefined;
    inline for (precompressed_web_assets, 0..) |name, i| {
        std.crypto.hash.sha2.Sha256.hash(@embedFile("src/gui/" ++ name), &digests[i], .{});
    }

    // The document is the one asset whose URL cannot be hashed (it is what
    // names the others), so its references are rewritten to the digested form
    // and the rewritten bytes are what the server serves and compresses.
    var document: []const u8 = @embedFile("src/gui/index.html");
    inline for (content_hashed_web_assets) |name| {
        const digest = digests[indexOfAsset(name)];
        document = try std.mem.replaceOwned(
            u8,
            allocator,
            document,
            "/" ++ name,
            try hashedAssetUrl(allocator, name, digest),
        );
    }
    var document_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(document, &document_digest, .{});
    options.addOption([]const u8, embedded_document_option, document);

    inline for (precompressed_web_assets) |name| {
        const is_document = std.mem.eql(u8, name, "index.html");
        const content = if (is_document) document else @embedFile("src/gui/" ++ name);
        var output = try std.Io.Writer.Allocating.initCapacity(allocator, content.len);
        defer output.deinit();
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compressor = try std.compress.flate.Compress.init(&output.writer, &window, .gzip, .best);
        try compressor.writer.writeAll(content);
        try compressor.finish();
        options.addOption([]const u8, name, output.written());
        options.addOption([32]u8, name ++ "_digest", if (is_document) document_digest else digests[indexOfAsset(name)]);
    }
    return options;
}

fn indexOfAsset(name: []const u8) usize {
    for (precompressed_web_assets, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return i;
    }
    unreachable;
}

// The zig-toml revision named below, as a full commit SHA. Every value in the
// SBOM is a transcription of something the tree already records, and the two a
// dependency bump would invalidate (this commit and the package version) are
// re-read from build.zig.zon at build time, so a bump cannot leave the
// inventory describing the dependency the build no longer uses.
const sbom_toml_commit = "a73c9423d88ed413204b39638fab7e9bccdb83fd";
const sbom_toml_version = "0.3.0";

/// CycloneDX 1.5 inventory of the third-party components behind a shipped
/// artifact. Downstream consumers and vulnerability scanners cannot recover
/// this by reading the manifests, so it is generated and installed next to the
/// binaries; `zig build sbom` writes it alone.
///
/// websocket-client is listed with scope "excluded": tests/requirements.txt
/// pins it with hashes, but nothing links it into a shipped artifact. Its
/// license is NOASSERTION because neither the manifest nor the pinned
/// distribution's metadata is recorded in-tree, and a guess would be worse
/// than an admission.
///
/// No timestamp and no serial number: the byte-identical rebuild gate compares
/// two builds of one commit, and a generated identity would differ between
/// them for no informational gain.
///
/// The Zig version is the compiler's own `zig_version_string`, so the
/// inventory names the toolchain that actually produced the bytes rather than
/// the one build.zig.zon asks for. tests/check.sh refuses to run the gate on
/// any other version, so a rebuild only reproduces the artifact when the two
/// agree, and the inventory is what tells a consumer whether it does.
fn addSbom(b: *std.Build) void {
    const zon = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .unlimited) catch
        @panic("cannot read build.zig.zon");
    if (std.mem.indexOf(u8, zon, sbom_toml_commit) == null) {
        std.log.err("build.zig.zon no longer pins zig-toml at {s}; update sbom_toml_commit and the SBOM in build.zig", .{sbom_toml_commit});
        @panic("SBOM dependency pin is stale");
    }
    // The package id in the manifest hash carries the dependency's own version
    // ("toml-0.3.0-<multihash>"), so the pin and the version are both read
    // from the manifest rather than from the fetched tree.
    if (std.mem.indexOf(u8, zon, "toml-" ++ sbom_toml_version ++ "-") == null) {
        std.log.err("build.zig.zon no longer resolves zig-toml {s}; update sbom_toml_version and the SBOM in build.zig", .{sbom_toml_version});
        @panic("SBOM dependency version is stale");
    }

    const zine_ref = "pkg:generic/zine@" ++ package_version;
    const toml_ref = "pkg:github/sam701/zig-toml@" ++ sbom_toml_commit;
    const vanjs_ref = "pkg:npm/vanjs";
    const websocket_ref = "pkg:pypi/websocket-client@1.9.0";

    const document =
        "{\n" ++
        "  \"bomFormat\": \"CycloneDX\",\n" ++
        "  \"specVersion\": \"1.5\",\n" ++
        "  \"version\": 1,\n" ++
        "  \"metadata\": {\n" ++
        "    \"tools\": {\n" ++
        "      \"components\": [\n" ++
        "        { \"type\": \"application\", \"name\": \"zine build\", \"version\": \"" ++ package_version ++ "\" },\n" ++
        "        { \"type\": \"application\", \"name\": \"zig\", \"version\": \"" ++ builtin.zig_version_string ++ "\", \"purl\": \"pkg:generic/zig@" ++ builtin.zig_version_string ++ "\" }\n" ++
        "      ]\n" ++
        "    },\n" ++
        "    \"component\": {\n" ++
        "      \"type\": \"application\",\n" ++
        "      \"bom-ref\": \"" ++ zine_ref ++ "\",\n" ++
        "      \"name\": \"zine\",\n" ++
        "      \"version\": \"" ++ package_version ++ "\",\n" ++
        "      \"purl\": \"" ++ zine_ref ++ "\"\n" ++
        "    }\n" ++
        "  },\n" ++
        "  \"components\": [\n" ++
        // The only Zig package dependency, compiled into every executable.
        "    {\n" ++
        "      \"type\": \"library\",\n" ++
        "      \"bom-ref\": \"" ++ toml_ref ++ "\",\n" ++
        "      \"name\": \"zig-toml\",\n" ++
        "      \"version\": \"" ++ sbom_toml_version ++ "\",\n" ++
        "      \"purl\": \"" ++ toml_ref ++ "\",\n" ++
        "      \"licenses\": [ { \"license\": { \"id\": \"MIT\" } } ],\n" ++
        "      \"externalReferences\": [\n" ++
        "        { \"type\": \"vcs\", \"url\": \"https://github.com/sam701/zig-toml\" },\n" ++
        "        { \"type\": \"distribution\", \"url\": \"https://github.com/sam701/zig-toml/archive/" ++ sbom_toml_commit ++ ".tar.gz\" }\n" ++
        "      ],\n" ++
        "      \"properties\": [\n" ++
        "        { \"name\": \"zine:consumer\", \"value\": \"src/win32/advapi32/registry_config.zig\" },\n" ++
        "        { \"name\": \"zine:licenseFile\", \"value\": \"share/licenses/zine/zig-toml.LICENSE\" }\n" ++
        "      ]\n" ++
        "    },\n" ++
        // Vendored, not fetched: src/gui/van.min.js carries the SPDX header
        // the license expression below is transcribed from, and the file's own
        // comment records that it is a repackaging rather than an upstream
        // artifact. No version: the tree does not record which one.
        "    {\n" ++
        "      \"type\": \"library\",\n" ++
        "      \"bom-ref\": \"" ++ vanjs_ref ++ "\",\n" ++
        "      \"name\": \"vanjs\",\n" ++
        "      \"purl\": \"" ++ vanjs_ref ++ "\",\n" ++
        "      \"licenses\": [ { \"license\": { \"id\": \"MIT\" } } ],\n" ++
        "      \"externalReferences\": [\n" ++
        "        { \"type\": \"website\", \"url\": \"https://vanjs.org\" }\n" ++
        "      ],\n" ++
        "      \"properties\": [\n" ++
        "        { \"name\": \"zine:vendored\", \"value\": \"src/gui/van.min.js\" },\n" ++
        "        { \"name\": \"zine:licenseFile\", \"value\": \"share/licenses/zine/van.LICENSE\" }\n" ++
        "      ]\n" ++
        "    },\n" ++
        // Test-only. The two sha256 values are the ones tests/requirements.txt
        // pins, copied rather than re-fetched.
        "    {\n" ++
        "      \"type\": \"library\",\n" ++
        "      \"scope\": \"excluded\",\n" ++
        "      \"bom-ref\": \"" ++ websocket_ref ++ "\",\n" ++
        "      \"name\": \"websocket-client\",\n" ++
        "      \"version\": \"1.9.0\",\n" ++
        "      \"purl\": \"" ++ websocket_ref ++ "\",\n" ++
        "      \"licenses\": [ { \"license\": { \"id\": \"NOASSERTION\" } } ],\n" ++
        "      \"hashes\": [\n" ++
        "        { \"alg\": \"SHA-256\", \"content\": \"af248a825037ef591efbf6ed20cc5faa03d3b47b9e5a2230a529eeee1c1fc3ef\" },\n" ++
        "        { \"alg\": \"SHA-256\", \"content\": \"9e813624b6eb619999a97dc7958469217c3176312b3a16a4bd1bc7e08a46ec98\" }\n" ++
        "      ],\n" ++
        "      \"properties\": [\n" ++
        "        { \"name\": \"zine:consumer\", \"value\": \"tests/test_msvc_cli.sh\" },\n" ++
        "        { \"name\": \"zine:manifest\", \"value\": \"tests/requirements.txt\" }\n" ++
        "      ]\n" ++
        "    }\n" ++
        "  ],\n" ++
        "  \"dependencies\": [\n" ++
        "    { \"ref\": \"" ++ zine_ref ++ "\", \"dependsOn\": [ \"" ++ toml_ref ++ "\", \"" ++ vanjs_ref ++ "\" ] },\n" ++
        "    { \"ref\": \"" ++ toml_ref ++ "\", \"dependsOn\": [] },\n" ++
        "    { \"ref\": \"" ++ vanjs_ref ++ "\", \"dependsOn\": [] },\n" ++
        "    { \"ref\": \"" ++ websocket_ref ++ "\", \"dependsOn\": [] }\n" ++
        "  ]\n" ++
        "}\n";

    const generated = b.addWriteFiles();
    const document_path = generated.add("zine.cdx.json", document);
    const install_document = b.addInstallFileWithDir(document_path, .prefix, "share/zine/sbom/zine.cdx.json");
    b.getInstallStep().dependOn(&install_document.step);
    const sbom_step = b.step("sbom", "Write the CycloneDX SBOM to the install prefix");
    sbom_step.dependOn(&install_document.step);
}

pub fn build(b: *std.Build) void {
    const web_assets = compressedWebAssets(b) catch @panic("failed to compress Web UI assets");
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture (x86, x86_64, wasm32, or wasm64)");
    const build_all = b.option(bool, "all", "Build all targets (x86 + x86_64 + wasm32 + wasm64)") orelse false;

    const use_fltk = b.option(bool, "fltk", "Enable FLTK native GUI backend (requires -Darch=x86_64)") orelse false;
    const embed_stubs = !(b.option(bool, "external-stubs", "Load Win32 stubs from external DLLs instead of embedding them") orelse false);
    const enable_jit_host = b.option(bool, "jit_host", "Enable JIT host imports (requires zine-host or browser)") orelse false;

    // ReleaseSafe by default: the artifacts `zig build` installs are the ones
    // users run, and Zig's default (Debug) leaves them unoptimized and large.
    // -Doptimize=Debug is still available for a debugging loop, and
    // --release=<mode> keeps its usual meaning.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe)",
    ) orelse switch (b.release_mode) {
        .off, .any, .safe => std.builtin.OptimizeMode.ReleaseSafe,
        .fast => std.builtin.OptimizeMode.ReleaseFast,
        .small => std.builtin.OptimizeMode.ReleaseSmall,
    };
    const cli_test_step = b.step("test-cli", "Check native and wasm32 CLI output (wasm32 requires wasmtime)");

    const archs_to_build: []const std.Target.Cpu.Arch = if (build_all)
        &.{ .x86, .x86_64, .wasm32, .wasm64 }
    else if (arch) |a|
        @as([]const std.Target.Cpu.Arch, &.{a})
    else
        &.{.x86}; // default

    if (use_fltk) {
        if (arch) |a| if (a != .x86_64) {
            std.log.err("-Dfltk needs -Darch=x86_64: the bridge links the 64-bit system FLTK libraries, got -Darch={s}", .{@tagName(a)});
            @panic("unsupported -Dfltk target");
        };
        // The include and library paths below are hardcoded to the Debian
        // layout, so name the missing packages instead of failing later with a
        // C compiler error.
        std.Io.Dir.accessAbsolute(b.graph.io, fltk_include_dir, .{}) catch {
            std.log.err("FLTK headers not found in {s}. Install the system FLTK 1.3 packages: " ++
                "libfltk1.3-dev libx11-dev libxext-dev libxft-dev libfontconfig1-dev " ++
                "libxinerama-dev libxcursor-dev libxrender-dev libxfixes-dev", .{fltk_include_dir});
            @panic("FLTK headers not installed");
        };
    }

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
            // VanJS is vendored into the binary (van.min.js); shipping the full
            // license text alongside it keeps the attribution grant traceable.
            const van_license = b.addInstallFileWithDir(b.path("src/gui/van.LICENSE"), .prefix, "share/licenses/zine/van.LICENSE");
            b.getInstallStep().dependOn(&van_license.step);
            addSbom(b);
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
            } else if (!build_all) {
                // Asking for wasm64 (or wasm32 + jit_host) alone means the CLI
                // suite has nothing it can run. Under -Dall the other targets
                // carry their own tests, so the untestable one is skipped
                // rather than failing the step it is not part of.
                const cli_test = b.addFail("test-cli requires a native or plain wasm32 target; wasm64 and jit_host need a custom runtime");
                cli_test_step.dependOn(&cli_test.step);
            }
        } else {
            // FLTK is only built for x86_64; -Dall also builds x86, which has no
            // FLTK bridge.
            const exe = addNativeExe(b, a, target, optimize, toml_dep.module("toml"), use_fltk and a == .x86_64, embed_stubs, web_assets);
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

        // A name that matches nothing would otherwise build only the default
        // executable and report success, hiding a typo in a DLL name from a
        // release cut. Reject it and list the real names.
        if (!build_all_dlls) {
            for (dll_names) |entry| {
                if (std.mem.eql(u8, arg, entry.name)) break;
            } else {
                var names: [2048]u8 = undefined;
                var stream = std.Io.Writer.fixed(&names);
                for (dll_names, 0..) |entry, i| {
                    stream.print("{s}'{s}'", .{ if (i == 0) "" else ", ", entry.name }) catch break;
                }
                std.log.err("no DLL is named '{s}'. Names: all, {s}", .{ arg, stream.buffered() });
                @panic("unknown -Ddll name");
            }
        }

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
                dll.root_module.strip = optimize != .Debug;

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
    // registry_config.zig is the one consumer of the pinned toml package and
    // src/test_root.zig reaches it, so the test root needs the same import the
    // shipped executables carry. Without it the parse path is unanalyzable
    // under `zig build test`.
    const toml_test_dep = b.dependency("toml", .{
        .target = b.graph.host,
        .optimize = optimize,
    });
    const t = b.addTest(.{
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_test_dep.module("toml") },
            },
        }),
    });
    // runner.zig (and anything importing it) reads build_options; provide
    // defaults matching a plain embedded-stubs native build.
    const test_options = b.addOptions();
    test_options.addOption(bool, "use_fltk", false);
    test_options.addOption(bool, "embed_stubs", true);
    test_options.addOption(bool, "enable_jit_host", false);
    t.root_module.addOptions("build_options", test_options);
    t.root_module.addOptions("web_assets", web_assets);
    test_step.dependOn(&fmt_check.step);
    test_step.dependOn(&b.addRunArtifact(t).step);

    // -----------------------------------------------------------------------
    // C++ check step: src/gui/fltk_bridge.cpp without the FLTK link
    // -----------------------------------------------------------------------
    // The gate compiles the bridge on its own, with the flags and include
    // paths the -Dfltk executable gives it and no link: the FLTK executable
    // pulls in X11, Xft and fontconfig, and a warning in one C++ file must not
    // require a display stack to find. The FLTK development headers are the
    // only requirement, and tests/check.sh check_cxx runs this step both
    // locally and in CI.
    // -----------------------------------------------------------------------
    const check_cxx_step = b.step("check-cxx", "Compile src/gui/fltk_bridge.cpp warning-free");
    const cxx_check = b.addObject(.{
        .name = "fltk_bridge_check",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
            .optimize = optimize,
        }),
    });
    cxx_check.root_module.addCSourceFile(.{
        .file = b.path("src/gui/fltk_bridge.cpp"),
        .flags = &fltk_bridge_cxx_flags,
    });
    cxx_check.root_module.addIncludePath(b.path("src/gui"));
    cxx_check.root_module.addSystemIncludePath(.{ .cwd_relative = fltk_include_dir });
    cxx_check.root_module.link_libc = true;
    cxx_check.root_module.link_libcpp = true;
    check_cxx_step.dependOn(&fmt_check.step);
    check_cxx_step.dependOn(&cxx_check.step);

    // -----------------------------------------------------------------------
    // Fuzz step: mutating fuzzer for the untrusted-input parsers
    // -----------------------------------------------------------------------
    // Each target takes the raw bytes a PE file supplies to the parser. The
    // step is separate from `test` so a normal gate stays fast; CI runs it
    // with a short budget, and the seed corpora are replayed under
    // `zig build test` (src/fuzz/replay.zig), which is where leaks and
    // assertion failures become hard failures.
    // -----------------------------------------------------------------------
    const fuzz_step = b.step("fuzz", "Fuzz the PE header, menu, dialog, and icon parsers and the string-table walk");
    const fuzz_seconds = b.option(u32, "fuzz-seconds", "Seconds each fuzz target runs") orelse 10;
    const fuzz_exe = b.addExecutable(.{
        .name = "zine-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_main.zig"),
            .target = b.graph.host,
            // Debug keeps the safety checks (integer overflow, bounds) that a
            // Release fuzzer would drop.
            .optimize = .Debug,
        }),
    });
    const fuzz_build_options = b.addOptions();
    fuzz_build_options.addOption(u32, "fuzz_seconds", fuzz_seconds);
    fuzz_exe.root_module.addOptions("fuzz_options", fuzz_build_options);
    fuzz_step.dependOn(&fmt_check.step);
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_exe).step);
}
