# General TODOs

This document tracks unimplemented features and tasks for Zine, extracted from the codebase.

## Guest Interaction & Hooks
- [ ] Implement mouse message posting (L223 in `src/win32/user32.zig`)
- [ ] Fix zine-host WASI filesystem preopening (guest can't open files via wasmer C API)
- [ ] Implement zine-host JIT block execution end-to-end test

## Registry & Configuration
- [ ] Move hardcoded registry settings to an external JSON configuration file (suggested improvement)
