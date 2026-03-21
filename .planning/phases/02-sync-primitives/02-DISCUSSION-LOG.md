# Phase 2: Sync Primitives - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-21
**Phase:** 02-sync-primitives
**Areas discussed:** Event implementation, Mutex implementation, WaitForMultipleObjects

---

## Event Implementation

| Option | Description | Selected |
|--------|-------------|----------|
| std.Thread.Condition + Mutex | Idiomatic Zig, proper blocking | ✓ |
| Atomic spin-wait | Simpler but CPU-hungry | |

**User's choice:** "whatever is the proper zig idiomatic way"
**Notes:** Both auto-reset and manual-reset events required.

---

## Mutex Implementation

| Option | Description | Selected |
|--------|-------------|----------|
| Win32 behavior (named, recursive) | Full Win32 semantics | ✓ |
| Simple unnamed only | Lighter but incomplete | |

**User's choice:** "follow win32 behaviour"

---

## WaitForMultipleObjects

| Option | Description | Selected |
|--------|-------------|----------|
| Full Win32 (bWaitAll TRUE + FALSE) | Complete implementation | ✓ |
| bWaitAll=FALSE only | Common case only | |

**User's choice:** "follow win32"

---

## Agent's Discretion

- Handle registry design for kernel objects
- WASM fallback behavior
- Whether to include semaphores

## Deferred Ideas

None
