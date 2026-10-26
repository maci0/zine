# Zig 0.17 migration audit

Reviewed the [complete official Zig 0.17 release notes](https://ziglang.org/download/0.17.0/release-notes.html), including language, standard library, build/package management, compiler/linker, and toolchain sections. This port targets exactly 0.17.0; it preserves the guest's 32-bit ABI and the existing native image base and x86 CPU feature exclusions.

| Release-note area | Repository impact and migration |
| --- | --- |
| Array multiplication removed | Replace repeated array initializers with typed `@splat`; flatten repeated byte strings in path-boundary tests without changing their bytes. |
| Reflection and type constructors | Update function parameter types/attributes, pointer attributes, and vtable field-name iteration. Migrate generated function types and integer types using the new builtins. This reaches native, variadic, and WASM thunk paths. |
| `@bitCast` semantics | Audit casts for array/vector and extern aggregate use. Existing guest register and floating-point casts use logical integer representations; supported targets are little endian. Added repetition replacements flatten byte arrays only. Extern aggregate type-punning is not introduced. |
| `@cImport` removed | Generate FLTK and Wasmer bindings in build translation steps and import those modules. The still-supported `Build.Step.TranslateC` is deprecated for removal in 0.18; the external translate-c package is a later migration. |
| Enum/backing-integer builtins, `std.lang`, builtin target aliases | Migrate enum conversions and standard language types; use `builtin.target` fields. |
| Optimization names | Use `debug`, `safe`, `fast`, `small`; retain `safe` as the default, stripping in the other three modes. Update operator docs, benchmark commands, and CI comments. |
| Allocators and formatting | Replace removed sentinel duplication/formatting APIs, use allocator printing, and retain sentinel termination. No DebugAllocator or stack-fallback allocator usage requires replacement. |
| File and Linux process APIs | Update file option types and signed `llseek`/`waitpid` storage. Interpret wait status as unsigned bits when decoding it. |
| Build graph/configuration cache | Read release mode from the graph, use the root Path API, passthrough arguments, and LazyPath formatting inputs. Match host glibc when linking FLTK system libraries and bundle compiler-rt in the Wasmer object for the system linker. Embed the SBOM manifest and declare source-scan/header-directory dependencies so configuration cache hits do not hide changes. |
| Package management | Pin zig-toml's Zig 0.17 branch at immutable commit `4a13e49ce7d19ac2df8b87962d9f23c0f5dd5bdd`, with its verified package hash; update the SBOM identity with it. CI and the local gate read the toolchain pin from the manifest. |
| Other source-breaking changes | No affected `containsAtLeastScalar`, captured `errdefer`, `void{}`, `i0`, removed linkage tags, URI host APIs, ZON parser, packed-int APIs, or removed bit-set constructors were found. The `@hasDecl` check is for a public standard-library declaration. |
| Additive APIs and other backends | New division, SPIR-V, semaphore, allocator, and collection APIs do not require new project features. Other CPU/OS backend changes are outside the four supported build targets. |
| LLVM, native/WASM backends, linkers, C/C++ and runtime headers | Validate generated artifacts and execution rather than changing ABI settings speculatively: retain all four target builds, DLL builds, C/C++ checks, hardening, reproducibility, CLI tests, parser fuzzing, and guest-binary checks. |

The full gate is `bash tests/check.sh`. Optional native guest integration is `bash tests/test_msvc_cli.sh --native`; proprietary fixtures and GUI/runtime dependencies are required. Guest startup smoke checks do not establish complete application or game compatibility.

## Verification results

- The full `tests/check.sh` gate passed with Zig 0.17.0, covering x86, x86_64, wasm32, wasm64, DLLs, embedded/external stubs, C/C++, hardening, reproducibility, unit/CLI tests, and all nine fuzz targets.
- The `-Darch=wasm32 -Djit_host=true` variant compiled; compiled-block execution was not verified. WASM32 CLI tests and a BSTR pointer-output guest fixture passed under Wasmtime. Wasmer host build and native CLI checks passed. Actual Wasmer guest execution traps during WASI startup on both the separately built 0.16 baseline and the 0.17 port, including `--version`; it is not established as working. The FLTK variant builds with host glibc matching and translated bindings.
- All local test-folder executables were exercised on x86. SMYGB loaded a scratch copy of the Pokémon ROM, initialized audio, and produced nonblank game frames. HxD, Notepad2, hgb, Notepad, PuTTY, PuTTYgen, and installed Europa remained running through startup checks. UPX and WinSCP exited normally. Pageant returned 1 without a guest exception; tennisbot is an unsupported 64-bit PE. Standalone Europa still faults when separated from its game assets; the installed copy runs past the reproduced mesh crash.
- Native MSVC integration: 155 passed, two failed because child LINK cannot find `LIBC.lib` (the pre-port run had 153 passes and four failures).
- FLTK runtime smoke: 0/20 passed, with x86_64 compat startup faults. A separately built 0.16 release baseline, with only ignored-return and host-glibc build adjustments, reproduces the SMYGB startup trap. This port does not repair the existing x86_64 compat runtime. GUI binding compilation is covered; working FLTK guest execution is not established.

These checks do not establish full gameplay or complete application compatibility. WASM64 is compile-checked; the installed Wasmtime cannot instantiate its memory64 WASI import signatures.
