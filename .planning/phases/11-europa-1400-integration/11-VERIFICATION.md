# Phase 11: Europa 1400 Integration — Verification

**Date:** 2026-03-22
**Status:** human_needed

## Success Criteria (from ROADMAP)

### 1. Europa 1400 Gold progresses past main menu into city gameplay
- [ ] Requires manual testing — run `./zig-out/bin/zine.x86 drive_c/Desktop/Guild/Europa1400Gold.exe`
- [ ] 0x476970 NULL reads are handled by AppCompat (Delphi VCL pattern, ~60/sec, benign)
- [ ] **Real crash**: UnhandledExceptionFilter code 0xC0000005 at **0x47D97E** — triggers on "Load Game" click (~12.8s)

### 2. In-game fonts display correctly (menus, dialogs, HUD)
- [ ] GDI font/text subsystem implemented (Phases 3-4)
- [ ] Requires visual verification during gameplay

### 3. Game audio plays during gameplay sessions
- [ ] DirectSound subsystem implemented (Phase 8)
- [ ] Requires audio verification during gameplay

## human_verification
1. Run Europa 1400 Gold and verify it reaches gameplay
2. Check font rendering in menus and dialogs
3. Check audio playback during gameplay
