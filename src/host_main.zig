//! zine-host: native wrapper for running zine.wasm with JIT support.
//!
//! Replaces `wasmtime run` / `wasmer run` by providing WASI + custom JIT
//! imports. Uses the wasmer C API (wasm-c-api standard) to:
//!   1. Load zine.wasm as the main module
//!   2. Provide WASI imports (file I/O, clock, args, env)
//!   3. Add three custom imports in the "jit" namespace:
//!      - jit_compile(wasm_ptr: i32, wasm_len: i32) -> i32
//!      - jit_call(block_id: i32)
//!      - jit_reset_blocks()
//!
//! Build:  zig build -Dhost
//! Usage:  zine-host [options] <zine.wasm> [args...]
//!         every argument after the module path is passed to the module

const std = @import("std");
const runtime = @import("runtime.zig");
const version = @import("version.zig");
const c = @cImport({
    @cInclude("wasmer.h");
});

// ---------------------------------------------------------------------------
// JIT block cache
// ---------------------------------------------------------------------------

const MaxBlocks = 4096;
var jit_modules: [MaxBlocks]?*c.wasm_module_t = .{null} ** MaxBlocks;
var jit_instances: [MaxBlocks]?*c.wasm_instance_t = .{null} ** MaxBlocks;
var jit_block_count: i32 = 0;

// Shared memory from the main module — JIT blocks import this.
var shared_memory: ?*c.wasm_memory_t = null;
var shared_store: ?*c.wasm_store_t = null;
// Exports vec of the main instance. wasm_extern_as_memory returns a pointer
// INTO the extern struct, so freeing the vec would dangle shared_memory.
// Keep the vec alive for the whole process and delete it at exit.
var shared_exports: c.wasm_extern_vec_t = undefined;

// ---------------------------------------------------------------------------
// JIT host functions (called from WASM guest)
// ---------------------------------------------------------------------------

/// jit_compile(wasm_ptr: i32, wasm_len: i32) -> i32
/// Reads WASM bytes from guest memory, compiles into a module, instantiates
/// it with shared memory, and returns a block ID (-1 on failure).
fn jitCompile(args: [*c]const c.wasm_val_vec_t, results: [*c]c.wasm_val_vec_t) callconv(.c) ?*c.wasm_trap_t {
    const wasm_ptr: u32 = @bitCast(args.*.data[0].of.i32);
    const wasm_len: u32 = @bitCast(args.*.data[1].of.i32);

    const mem = shared_memory orelse {
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };
    const store = shared_store orelse {
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    const mem_data = c.wasm_memory_data(mem);
    const mem_size = c.wasm_memory_data_size(mem);
    // Widened before the compare: both operands are u32, so the sum wraps
    // for a ptr near 0xFFFFFFFF and the check passes with a range that starts
    // past the end of linear memory.
    if (@as(u64, wasm_ptr) + @as(u64, wasm_len) > mem_size) {
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    }

    var wasm_bytes: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new(&wasm_bytes, wasm_len, mem_data + wasm_ptr);
    defer c.wasm_byte_vec_delete(&wasm_bytes);

    const module = c.wasm_module_new(store, &wasm_bytes) orelse {
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    var imports_arr = [_]?*c.wasm_extern_t{c.wasm_memory_as_extern(mem)};
    var imports = c.wasm_extern_vec_t{ .size = 1, .data = &imports_arr };

    var trap: ?*c.wasm_trap_t = null;
    const instance = c.wasm_instance_new(store, module, &imports, &trap);
    if (instance == null) {
        c.wasm_module_delete(module);
        if (trap) |t| c.wasm_trap_delete(t);
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    }

    const block_id = jit_block_count;
    if (block_id >= MaxBlocks) {
        c.wasm_instance_delete(instance.?);
        c.wasm_module_delete(module);
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    }
    jit_modules[@intCast(block_id)] = module;
    jit_instances[@intCast(block_id)] = instance;
    jit_block_count += 1;

    results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = block_id } };
    return null;
}

/// jit_call(block_id: i32)
/// Runs a previously compiled JIT block. The compiler emits exactly one
/// zero-argument export named "run", so exports.data[0] is it by position
/// rather than by name lookup.
fn jitCall(args: [*c]const c.wasm_val_vec_t, results: [*c]c.wasm_val_vec_t) callconv(.c) ?*c.wasm_trap_t {
    _ = results;
    const block_id: i32 = args.*.data[0].of.i32;
    if (block_id < 0 or block_id >= jit_block_count) return null;

    const instance = jit_instances[@intCast(block_id)] orelse return null;

    var exports: c.wasm_extern_vec_t = undefined;
    c.wasm_instance_exports(instance, &exports);
    defer c.wasm_extern_vec_delete(&exports);

    if (exports.size == 0) return null;
    const run_fn = c.wasm_extern_as_func(exports.data[0]) orelse return null;

    var call_args = c.wasm_val_vec_t{ .size = 0, .data = null };
    var call_results = c.wasm_val_vec_t{ .size = 0, .data = null };
    const trap = c.wasm_func_call(run_fn, &call_args, &call_results);
    if (trap) |t| {
        // The block aborted part-way: its stores landed but the CPU state it
        // would have written back never did, so the interpreter resumes from
        // whatever the block left behind. `jit_call` has no result channel, so
        // the trap text is the only record that this happened at all.
        writeErr("Warning: JIT block ");
        var block_buf: [12]u8 = undefined;
        writeErr(std.fmt.bufPrint(&block_buf, "{d}", .{block_id}) catch "?");
        writeErr(" trapped and did not run to completion: ");
        var msg: c.wasm_message_t = undefined;
        c.wasm_trap_message(t, &msg);
        if (msg.size > 0) {
            writeErr(msg.data[0..msg.size]);
            c.wasm_byte_vec_delete(&msg);
        } else {
            writeErr("(no message)");
        }
        writeErr("\n");
        c.wasm_trap_delete(t);
    }
    return null;
}

/// jit_reset_blocks()
/// Releases every compiled block and resets the id counter, so a long
/// session does not exhaust the fixed block table after a cache flush.
fn jitResetBlocks(_: [*c]const c.wasm_val_vec_t, _: [*c]c.wasm_val_vec_t) callconv(.c) ?*c.wasm_trap_t {
    var i: usize = 0;
    while (i < @as(usize, @intCast(jit_block_count))) : (i += 1) {
        if (jit_instances[i]) |instance| c.wasm_instance_delete(instance);
        jit_instances[i] = null;
        if (jit_modules[i]) |module| c.wasm_module_delete(module);
        jit_modules[i] = null;
    }
    jit_block_count = 0;
    return null;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn writeErr(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}

fn printWasmerError() void {
    const len = c.wasmer_last_error_length();
    if (len > 0) {
        var buf: [4096]u8 = undefined;
        const actual: usize = @intCast(c.wasmer_last_error_message(&buf, buf.len));
        if (actual > 0) {
            writeErr("wasmer error: ");
            writeErr(buf[0 .. actual - 1]);
            writeErr("\n");
        }
    }
}

pub fn main(init: std.process.Init) !void {
    runtime.init(init.io, init.gpa, init.minimal.environ);
    const allocator = init.arena.allocator();

    var sys_args = try init.minimal.args.iterateAllocator(allocator);
    defer sys_args.deinit();
    _ = sys_args.next(); // skip argv[0]

    var wasm_path: ?[]const u8 = null;
    var guest_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer guest_args.deinit(allocator);
    var past_separator = false;

    while (sys_args.next()) |arg| {
        if (!past_separator and wasm_path == null and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            runtime.writeCliOut(
                \\Usage: zine-host [options] <zine.wasm> [args...]
                \\
                \\Run zine.wasm with a native WASM runtime and JIT support.
                \\
                \\Options:
                \\  -h, --help          Show this help message
                \\  -v, --version       Show version information
                \\  --                  Stop processing options; remaining args are passed to the guest
                \\
                \\Arguments:
                \\  zine.wasm           Module to run; every later argument is passed to it
                \\
                \\Environment:
                \\  The host environment is handed to the module unchanged, so the
                \\  ZINE_* settings are read, validated, and listed by the
                \\  module's own --help. This wrapper reads none of them.
                \\
                \\Examples:
                \\  zine-host zine.wasm -- myapp.exe
                \\  zine-host zine.wasm -- --trace myapp.exe
                \\  zine-host zine.wasm --help
                \\
                \\Exit status:
                \\  0  the module ran and reported success
                \\  1  the module could not be loaded or trapped, or the module
                \\     exited with this status
                \\  2  usage error: an unknown option or a missing <zine.wasm>
                \\
            );
            std.process.exit(0);
        }
        if (!past_separator and wasm_path == null and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            runtime.writeCliOut("zine-host " ++ version.string ++ "\n");
            std.process.exit(0);
        }
        if (!past_separator and wasm_path == null and std.mem.eql(u8, arg, "--")) {
            past_separator = true;
            continue;
        }
        if (wasm_path == null and !past_separator and arg.len > 1 and arg[0] == '-') {
            var err_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "Error: unknown option '{s}'.\nTry 'zine-host --help' for more information.\n", .{arg}) catch "Error: unknown option.\n";
            std.debug.print("{s}", .{msg});
            std.process.exit(2);
        }
        if (wasm_path == null) {
            wasm_path = arg;
        } else {
            try guest_args.append(allocator, arg);
        }
    }

    if (wasm_path == null) {
        std.debug.print("{s}", .{"Error: missing required argument <zine.wasm>.\nTry 'zine-host --help' for more information.\n"});
        std.process.exit(2);
    }

    const wasm_file = std.Io.Dir.cwd().openFile(runtime.io(), wasm_path.?, .{}) catch |err| {
        writeErr("Error: cannot open '");
        writeErr(wasm_path.?);
        writeErr("': ");
        writeErr(@errorName(err));
        writeErr(".\n");
        std.process.exit(1);
    };
    defer wasm_file.close(runtime.io());
    var file_reader_buf: [4096]u8 = undefined;
    var file_reader = wasm_file.reader(runtime.io(), &file_reader_buf);
    const wasm_data = file_reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024)) catch |err| {
        writeErr("Error: cannot read '");
        writeErr(wasm_path.?);
        writeErr("': ");
        writeErr(@errorName(err));
        writeErr(".\n");
        std.process.exit(1);
    };
    defer allocator.free(wasm_data);

    const engine = c.wasm_engine_new() orelse {
        writeErr("Error: failed to create wasmer engine.\n");
        std.process.exit(1);
    };
    defer c.wasm_engine_delete(engine);

    const store = c.wasm_store_new(engine) orelse {
        writeErr("Error: failed to create wasmer store.\n");
        std.process.exit(1);
    };
    defer c.wasm_store_delete(store);
    shared_store = store;

    var wasm_bytes: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new(&wasm_bytes, wasm_data.len, wasm_data.ptr);
    defer c.wasm_byte_vec_delete(&wasm_bytes);

    const module = c.wasm_module_new(store, &wasm_bytes) orelse {
        writeErr("Error: failed to compile WASM module.\n");
        printWasmerError();
        std.process.exit(1);
    };
    defer c.wasm_module_delete(module);

    const wasi_config = c.wasi_config_new("zine") orelse {
        writeErr("Error: failed to create WASI config.\n");
        std.process.exit(1);
    };

    for (guest_args.items) |arg| {
        c.wasi_config_arg(wasi_config, arg.ptr);
    }

    // Inherit stdio and preopen CWD
    c.wasi_config_inherit_stdin(wasi_config);
    c.wasi_config_inherit_stdout(wasi_config);
    c.wasi_config_inherit_stderr(wasi_config);
    // Preopen directories for WASI filesystem access.
    // wasmtime maps `--dir=.` to the virtual "." and `--dir=/` to "/"; mirror
    // that with mapdir so relative paths and absolute paths both resolve.
    {
        var cwd_buf: [4096]u8 = undefined;
        var cwd_len: usize = 0;
        if (std.process.currentPath(runtime.io(), &cwd_buf)) |len| {
            cwd_len = len;
        } else |err| {
            writeErr("Warning: cannot read the current directory, preopening '.' instead: ");
            writeErr(@errorName(err));
            writeErr(".\n");
        }
        const cwd = if (cwd_len > 0) cwd_buf[0..cwd_len] else ".";
        // A "." fallback would silently rebind the preopen every relative
        // guest path resolves against, so the run would look like the guest
        // lost its files. Name the failure and stop instead.
        const cwd_z = std.heap.page_allocator.dupeZ(u8, cwd) catch |err| {
            writeErr("Error: cannot copy the current directory '");
            writeErr(cwd);
            writeErr("': ");
            writeErr(@errorName(err));
            writeErr(".\n");
            std.process.exit(1);
        };
        // First preopen = fd 3 = the WASI cwd (Zig's Dir.cwd() on WASI uses
        // fd 3), mirroring wasmtime's `--dir=.`. The "/" preopen then serves
        // absolute paths, mirroring `--dir=/`.
        _ = c.wasi_config_preopen_dir(wasi_config, cwd_z);
        _ = c.wasi_config_preopen_dir(wasi_config, "/");
    }

    // Inherit environment (wasi_config_env needs null-terminated C strings).
    // A variable that cannot be copied would otherwise vanish from the guest's
    // environment with no trace, which reads as the program misbehaving on a
    // setting the host plainly had.
    const env_iter = init.environ_map;
    var env_it = env_iter.iterator();
    while (env_it.next()) |entry| {
        const kz = std.heap.page_allocator.dupeZ(u8, entry.key_ptr.*) catch |err| {
            writeErr("Warning: dropping environment variable, cannot copy its name: ");
            writeErr(entry.key_ptr.*);
            writeErr(" (");
            writeErr(@errorName(err));
            writeErr(").\n");
            continue;
        };
        const vz = std.heap.page_allocator.dupeZ(u8, entry.value_ptr.*) catch |err| {
            writeErr("Warning: dropping environment variable, cannot copy its value: ");
            writeErr(entry.key_ptr.*);
            writeErr(" (");
            writeErr(@errorName(err));
            writeErr(").\n");
            continue;
        };
        c.wasi_config_env(wasi_config, kz.ptr, vz.ptr);
    }

    const wasi_env = c.wasi_env_new(store, wasi_config) orelse {
        writeErr("Error: failed to create WASI environment.\n");
        printWasmerError();
        std.process.exit(1);
    };
    defer c.wasi_env_delete(wasi_env);

    var import_types: c.wasm_importtype_vec_t = undefined;
    c.wasm_module_imports(module, &import_types);
    defer c.wasm_importtype_vec_delete(&import_types);

    // jit_compile: (i32, i32) -> i32
    const compile_functype = blk: {
        var params: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_uninitialized(&params, 2);
        params.data[0] = c.wasm_valtype_new(c.WASM_I32);
        params.data[1] = c.wasm_valtype_new(c.WASM_I32);
        var results: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_uninitialized(&results, 1);
        results.data[0] = c.wasm_valtype_new(c.WASM_I32);
        break :blk c.wasm_functype_new(&params, &results);
    };
    defer c.wasm_functype_delete(compile_functype);
    const compile_func = c.wasm_func_new(store, compile_functype, &jitCompile);

    // jit_call: (i32) -> ()
    const call_functype = blk: {
        var params: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_uninitialized(&params, 1);
        params.data[0] = c.wasm_valtype_new(c.WASM_I32);
        var results: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_empty(&results);
        break :blk c.wasm_functype_new(&params, &results);
    };
    defer c.wasm_functype_delete(call_functype);
    const call_func = c.wasm_func_new(store, call_functype, &jitCall);

    // jit_reset_blocks: () -> ()
    const reset_functype = blk: {
        var params: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_empty(&params);
        var results: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_empty(&results);
        break :blk c.wasm_functype_new(&params, &results);
    };
    defer c.wasm_functype_delete(reset_functype);
    const reset_func = c.wasm_func_new(store, reset_functype, &jitResetBlocks);

    // Build imports array matching the module's import list.
    // wasi_get_imports FAILS on modules with non-WASI imports (it tries to
    // resolve every import, including our custom "jit" ones), so use
    // wasi_get_unordered_imports instead — it only fills the WASI imports as
    // named externs. We then place them in module-import order and patch in
    // the custom JIT functions.
    var named_imports: c.wasmer_named_extern_vec_t = undefined;
    if (!c.wasi_get_unordered_imports(wasi_env, module, &named_imports)) {
        writeErr("Error: failed to get WASI imports.\n");
        printWasmerError();
        std.process.exit(1);
    }
    // NOTE: named_imports and wasi_imports are deliberately NOT freed here.
    // wasm_instance_new consumes the import externs (the instance owns them
    // and frees them when deleted), and wasi_imports borrows the same extern
    // objects from named_imports — freeing either vector would double-free the
    // shared externs. Both are small arrays; leaking them for the process
    // lifetime is harmless in this one-shot CLI.

    var wasi_imports: c.wasm_extern_vec_t = undefined;
    c.wasm_extern_vec_new_uninitialized(&wasi_imports, import_types.size);

    // First pass: fill each module import with the matching named WASI extern
    for (0..named_imports.size) |j| {
        const named = named_imports.data[j];
        const ne_mod = c.wasmer_named_extern_module(named);
        const ne_name = c.wasmer_named_extern_name(named);
        const ne_ext = c.wasmer_named_extern_unwrap(named);

        const ne_mod_slice = ne_mod.*.data[0..ne_mod.*.size];
        const ne_name_slice = ne_name.*.data[0..ne_name.*.size];

        for (0..import_types.size) |i| {
            const imp = import_types.data[i];
            const mod_name = c.wasm_importtype_module(imp);
            const field_name = c.wasm_importtype_name(imp);

            const mod_slice = mod_name.*.data[0..mod_name.*.size];
            const field_slice = field_name.*.data[0..field_name.*.size];

            if (std.mem.eql(u8, mod_slice, ne_mod_slice) and std.mem.eql(u8, field_slice, ne_name_slice)) {
                wasi_imports.data[i] = @constCast(ne_ext);
            }
        }
    }

    // Second pass: patch custom JIT imports into the vector
    for (0..import_types.size) |i| {
        const imp = import_types.data[i];
        const mod_name = c.wasm_importtype_module(imp);
        const field_name = c.wasm_importtype_name(imp);

        const mod_slice = mod_name.*.data[0..mod_name.*.size];
        const field_slice = field_name.*.data[0..field_name.*.size];

        if (std.mem.eql(u8, mod_slice, "jit")) {
            if (std.mem.eql(u8, field_slice, "jit_compile")) {
                wasi_imports.data[i] = c.wasm_func_as_extern(compile_func);
            } else if (std.mem.eql(u8, field_slice, "jit_call")) {
                wasi_imports.data[i] = c.wasm_func_as_extern(call_func);
            } else if (std.mem.eql(u8, field_slice, "jit_reset_blocks")) {
                wasi_imports.data[i] = c.wasm_func_as_extern(reset_func);
            }
        }
    }

    var trap: ?*c.wasm_trap_t = null;
    const instance = c.wasm_instance_new(store, module, &wasi_imports, &trap) orelse {
        writeErr("Error: failed to instantiate WASM module.\n");
        if (trap) |t| {
            var msg: c.wasm_message_t = undefined;
            c.wasm_trap_message(t, &msg);
            if (msg.size > 0) {
                writeErr(msg.data[0..msg.size]);
                writeErr("\n");
                c.wasm_byte_vec_delete(&msg);
            }
            c.wasm_trap_delete(t);
        }
        printWasmerError();
        std.process.exit(1);
    };
    defer c.wasm_instance_delete(instance);

    // Capture shared memory for JIT blocks. The exports vec is kept alive
    // globally: wasm_extern_as_memory borrows into the extern struct, so the
    // vec must outlive the JIT execution (see shared_exports above).
    c.wasm_instance_exports(instance, &shared_exports);

    for (0..shared_exports.size) |i| {
        if (c.wasm_extern_as_memory(shared_exports.data[i])) |mem| {
            shared_memory = mem;
            break;
        }
    }

    // Initialize WASI (set memory on the env)
    if (!c.wasi_env_initialize_instance(wasi_env, store, instance)) {
        writeErr("Error: failed to initialize WASI instance.\n");
        printWasmerError();
        std.process.exit(1);
    }

    const start_func = c.wasi_get_start_function(instance) orelse {
        writeErr("Error: no _start function found in WASM module.\n");
        printWasmerError();
        std.process.exit(1);
    };

    var start_args = c.wasm_val_vec_t{ .size = 0, .data = null };
    var start_results = c.wasm_val_vec_t{ .size = 0, .data = null };
    const start_trap = c.wasm_func_call(start_func, &start_args, &start_results);

    if (start_trap) |t| {
        var msg: c.wasm_message_t = undefined;
        c.wasm_trap_message(t, &msg);
        var exit_code: ?u8 = null;
        if (msg.size > 0) {
            const s = msg.data[0..msg.size];
            // wasmer encodes proc_exit as "WASI exited with code: ExitCode::N"
            if (std.mem.indexOf(u8, s, "WASI exited with code") != null) {
                if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
                    // Message is NUL-terminated; cut at the NUL before parsing.
                    const num = std.mem.trim(u8, std.mem.sliceTo(s[colon + 1 ..], 0), " \r\n");
                    exit_code = std.fmt.parseInt(u8, num, 10) catch null;
                }
            }
            if (exit_code == null) {
                writeErr("Error: WASM trap: ");
                writeErr(std.mem.sliceTo(s, 0));
                writeErr("\n");
            }
        } else {
            writeErr("Error: WASM trap.\n");
        }
        c.wasm_byte_vec_delete(&msg);
        c.wasm_trap_delete(t);
        std.process.exit(exit_code orelse 1);
    }

    for (0..@intCast(jit_block_count)) |i| {
        if (jit_instances[i]) |inst| c.wasm_instance_delete(inst);
        if (jit_modules[i]) |mod| c.wasm_module_delete(mod);
    }
    if (shared_exports.size > 0) {
        c.wasm_extern_vec_delete(&shared_exports);
    }
}
