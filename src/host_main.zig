//! zine-host: native wrapper for running zine.wasm with JIT support.
//!
//! Replaces `wasmtime run` / `wasmer run` by providing WASI + custom JIT
//! imports. Uses the wasmer C API (wasm-c-api standard) to:
//!   1. Load zine.wasm as the main module
//!   2. Provide WASI imports (file I/O, clock, args, env)
//!   3. Add two custom imports in the "jit" namespace:
//!      - jit_compile(wasm_ptr: i32, wasm_len: i32) -> i32
//!      - jit_call(block_id: i32)
//!
//! Build:  zig build -Dhost
//! Usage:  zine-host [options] <zine.wasm> [-- args...]

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
    if (wasm_ptr + wasm_len > mem_size) {
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    }

    // Read WASM bytes from guest memory
    var wasm_bytes: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new(&wasm_bytes, wasm_len, mem_data + wasm_ptr);
    defer c.wasm_byte_vec_delete(&wasm_bytes);

    // Compile the module
    const module = c.wasm_module_new(store, &wasm_bytes) orelse {
        results.*.data[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    // Instantiate with shared memory as the import
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

    // Store in cache
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
/// Calls the "run" export of a previously compiled JIT block.
fn jitCall(args: [*c]const c.wasm_val_vec_t, results: [*c]c.wasm_val_vec_t) callconv(.c) ?*c.wasm_trap_t {
    _ = results;
    const block_id: i32 = args.*.data[0].of.i32;
    if (block_id < 0 or block_id >= jit_block_count) return null;

    const instance = jit_instances[@intCast(block_id)] orelse return null;

    // Get the "run" export (function index 0)
    var exports: c.wasm_extern_vec_t = undefined;
    c.wasm_instance_exports(instance, &exports);
    defer c.wasm_extern_vec_delete(&exports);

    if (exports.size == 0) return null;
    const run_fn = c.wasm_extern_as_func(exports.data[0]) orelse return null;

    // Call it (void -> void)
    var call_args = c.wasm_val_vec_t{ .size = 0, .data = null };
    var call_results = c.wasm_val_vec_t{ .size = 0, .data = null };
    const trap = c.wasm_func_call(run_fn, &call_args, &call_results);
    if (trap) |t| {
        c.wasm_trap_delete(t);
    }
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

    // Parse args
    var sys_args = try init.minimal.args.iterateAllocator(allocator);
    defer sys_args.deinit();
    _ = sys_args.next(); // skip argv[0]

    var wasm_path: ?[]const u8 = null;
    var guest_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer guest_args.deinit(allocator);
    var past_separator = false;

    while (sys_args.next()) |arg| {
        if (!past_separator and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            std.debug.print("{s}", .{
                \\Usage: zine-host [options] <zine.wasm> [-- args...]
                \\
                \\Run zine.wasm with a native WASM runtime and JIT support.
                \\
                \\Options:
                \\  -h, --help          Show this help message
                \\  -v, --version       Show version information
                \\  --                  Stop processing options; remaining args are passed to the guest
                \\
                \\Examples:
                \\  zine-host zine.wasm -- myapp.exe
                \\  zine-host zine.wasm -- --trace myapp.exe
                \\
            });
            std.process.exit(0);
        }
        if (!past_separator and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            std.debug.print("{s}", .{"zine-host " ++ version.string ++ "\n"});
            std.process.exit(0);
        }
        if (!past_separator and std.mem.eql(u8, arg, "--")) {
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

    // Read WASM file
    const wasm_file = std.Io.Dir.cwd().openFile(runtime.io(), wasm_path.?, .{}) catch {
        writeErr("Error: cannot open '");
        writeErr(wasm_path.?);
        writeErr("'.\n");
        std.process.exit(1);
    };
    defer wasm_file.close(runtime.io());
    var file_reader_buf: [4096]u8 = undefined;
    var file_reader = wasm_file.reader(runtime.io(), &file_reader_buf);
    const wasm_data = file_reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024)) catch {
        writeErr("Error: cannot read '");
        writeErr(wasm_path.?);
        writeErr("'.\n");
        std.process.exit(1);
    };
    defer allocator.free(wasm_data);

    // Create wasmer engine + store
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

    // Compile the main module
    var wasm_bytes: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new(&wasm_bytes, wasm_data.len, wasm_data.ptr);
    defer c.wasm_byte_vec_delete(&wasm_bytes);

    const module = c.wasm_module_new(store, &wasm_bytes) orelse {
        writeErr("Error: failed to compile WASM module.\n");
        printWasmerError();
        std.process.exit(1);
    };
    defer c.wasm_module_delete(module);

    // Set up WASI
    const wasi_config = c.wasi_config_new("zine") orelse {
        writeErr("Error: failed to create WASI config.\n");
        std.process.exit(1);
    };

    // Pass guest args
    for (guest_args.items) |arg| {
        c.wasi_config_arg(wasi_config, arg.ptr);
    }

    // Inherit stdio and preopen CWD
    c.wasi_config_inherit_stdin(wasi_config);
    c.wasi_config_inherit_stdout(wasi_config);
    c.wasi_config_inherit_stderr(wasi_config);
    // Preopen directories for WASI filesystem access.
    // preopen_dir opens a host directory as a WASI fd.
    // We need "." for relative paths and "/" for absolute paths.
    {
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = std.process.currentPath(runtime.io(), &cwd_buf) catch 0;
        const cwd = if (cwd_len > 0) cwd_buf[0..cwd_len] else ".";
        const cwd_z = std.heap.page_allocator.dupeZ(u8, cwd) catch ".";
        _ = c.wasi_config_preopen_dir(wasi_config, cwd_z);
        _ = c.wasi_config_preopen_dir(wasi_config, "/");
    }

    // Inherit environment
    const env_iter = init.environ_map;
    var env_it = env_iter.iterator();
    while (env_it.next()) |entry| {
        c.wasi_config_env(wasi_config, entry.key_ptr.*.ptr, entry.value_ptr.*.ptr);
    }

    // Get WASI imports
    const wasi_env = c.wasi_env_new(store, wasi_config) orelse {
        writeErr("Error: failed to create WASI environment.\n");
        printWasmerError();
        std.process.exit(1);
    };
    defer c.wasi_env_delete(wasi_env);

    // Get module imports to know what we need to provide
    var import_types: c.wasm_importtype_vec_t = undefined;
    c.wasm_module_imports(module, &import_types);
    defer c.wasm_importtype_vec_delete(&import_types);

    // Create JIT host functions using the wasm-c-api helpers
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

    // Build imports array matching the module's import list
    // WASI imports are resolved by wasi_get_imports; we patch in JIT functions
    var wasi_imports: c.wasm_extern_vec_t = undefined;
    if (!c.wasi_get_imports(store, wasi_env, module, &wasi_imports)) {
        writeErr("Error: failed to get WASI imports.\n");
        printWasmerError();
        std.process.exit(1);
    }
    defer c.wasm_extern_vec_delete(&wasi_imports);

    // Patch JIT imports into the import vector
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
            }
        }
    }

    // Instantiate
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

    // Capture shared memory for JIT blocks
    {
        var exports: c.wasm_extern_vec_t = undefined;
        c.wasm_instance_exports(instance, &exports);
        defer c.wasm_extern_vec_delete(&exports);

        // Find the memory export
        for (0..exports.size) |i| {
            if (c.wasm_extern_as_memory(exports.data[i])) |mem| {
                shared_memory = mem;
                break;
            }
        }
    }

    // Initialize WASI (set memory on the env)
    if (!c.wasi_env_initialize_instance(wasi_env, store, instance)) {
        writeErr("Error: failed to initialize WASI instance.\n");
        printWasmerError();
        std.process.exit(1);
    }

    // Find and call _start
    const start_func = c.wasi_get_start_function(instance) orelse {
        writeErr("Error: no _start function found in WASM module.\n");
        printWasmerError();
        std.process.exit(1);
    };

    var start_args = c.wasm_val_vec_t{ .size = 0, .data = null };
    var start_results = c.wasm_val_vec_t{ .size = 0, .data = null };
    const start_trap = c.wasm_func_call(start_func, &start_args, &start_results);

    if (start_trap) |t| {
        // Check if it's a proc_exit (normal termination)
        var msg: c.wasm_message_t = undefined;
        c.wasm_trap_message(t, &msg);
        if (msg.size > 0) {
            const s = msg.data[0..msg.size];
            // wasmer encodes proc_exit as a trap message
            if (std.mem.indexOf(u8, s, "exit") == null) {
                writeErr("Error: WASM trap: ");
                writeErr(s);
                writeErr("\n");
            }
            c.wasm_byte_vec_delete(&msg);
        }
        c.wasm_trap_delete(t);
    }

    // Clean up JIT blocks
    for (0..@intCast(jit_block_count)) |i| {
        if (jit_instances[i]) |inst| c.wasm_instance_delete(inst);
        if (jit_modules[i]) |mod| c.wasm_module_delete(mod);
    }
}
