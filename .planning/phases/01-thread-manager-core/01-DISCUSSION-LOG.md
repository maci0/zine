# Phase 1: Thread Manager Core - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-21
**Phase:** 01-thread-manager-core
**Areas discussed:** Interpreter per thread, CPU state isolation, Thread lifecycle

---

## Interpreter Per Thread

| Option | Description | Selected |
|--------|-------------|----------|
| (agent's discretion) | User defers to agent | ✓ |

**User's choice:** "i dunno"
**Notes:** Key gap identified: `threadWrapper` calls start function as native call via `@ptrFromInt`. Guest threads need their own interpreter loop.

---

## CPU State Isolation

| Option | Description | Selected |
|--------|-------------|----------|
| Win32 behavior (shared memory, per-thread registers) | Each thread owns Cpu, shares GuestMemory | ✓ |
| Fully isolated | Each thread has own memory view | |

**User's choice:** "i want the same behaviour as on win32"
**Notes:** Standard Win32 model: registers/stack/TEB per thread, memory and modules shared.

---

## Thread Lifecycle

| Option | Description | Selected |
|--------|-------------|----------|
| Win32 behavior (joinable, ExitThread terminates) | Thread handles trackable for WaitForSingleObject | ✓ |
| Fire and forget | No join support | |

**User's choice:** "same as on win32"
**Notes:** Requires upgrading thread handle tracking from simple counter to actual state tracking.

---

## Agent's Discretion

- Interpreter-per-thread plumbing approach
- Guest stack allocation strategy

## Deferred Ideas

None
