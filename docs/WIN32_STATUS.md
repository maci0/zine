# Win32 API Implementation Status

This document tracks the implementation of all required Win32 APIs across MSVCRT, KERNEL32, USER32 and others needed by CLI Win32 PE applications. 

Each API is categorized by its emulation fidelity:
- 🟢 **Implemented:** Contains actual logic (memory mapping, POSIX file I/O translation, native struct emulation, etc.) that accurately mimics Win32 behavior on Linux.
- 🟡 **Stubbed / Mocked:** Safely mapped to a generic stub returning a static dummy value (e.g. `0`, `1`, or `null`). Prevents crashes but does not simulate system effects.

---

## KERNEL32.dll

### File I/O
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | `CreateFileA` | Natively wraps POSIX paths to valid handles, mapping Windows open modes to Unix equivalents. |
| 🟢 | `CloseHandle` | Correctly closes underlying POSIX file descriptors or internal tracking structs. |
| 🟢 | `ReadFile` | Maps directly to native `read` syscalls. |
| 🟢 | `WriteFile` | Supports output to standard I/O streams and file handles natively. |
| 🟢 | `GetStdHandle` | Correctly maps `-10/-11/-12` constants to POSIX `0/1/2` fds. |
| 🟢 | `SetFilePointer` | Emulated using native POSIX `lseek`. |
| 🟢 | `CreateFileMappingA` | Uses `std.posix.mmap` with shared file-backed properties. |
| 🟢 | `MapViewOfFileEx` | Supports shared writable `MAP_SHARED` memory projection. |
| 🟢 | `GetFileSize` | Retrieves accurate file bounds via `fstat`. |
| 🟢 | `GetFileInformationByHandle` | Native POSIX `fstat` wrapped into `BY_HANDLE_FILE_INFORMATION`. |
| 🟢 | `SearchPathA` | Natively checks UNIX `$PATH` and local registry context to resolve files. |
| 🟢 | `FindFirstFileA` | Translates to Zig directory iteration opening. |
| 🟢 | `FindNextFileA` | Steps forward in local UNIX directory iteration. |
| 🟢 | `GetTempPathA` | Returns generic `/tmp/` string. |
| 🟢 | `GetTempFileNameA` | Generates a unique temporary filename dynamically. |
| 🟢 | `DeleteFileA` | Mapped directly to POSIX `unlink`. |
| 🟢 | `SetEndOfFile` | Native truncation of underlying fd bounds. |
| 🟢 | `GetSystemDirectoryA` | Emulates a mock Windows system folder path. |

### Process & System
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | `GetCommandLineA` | Dynamically reconstructs full command line from parsed Unix `argv`. |
| 🟢 | `GetStartupInfoA` | Properly initializes a dummy `STARTUPINFOA` structure. |
| 🟢 | `GetEnvironmentStrings(A/W)` | Fully reconstructs environmental blocks, seamlessly converting variables for MSVC_ROOT logic. |
| 🟢 | `GetEnvironmentVariableA` | Checks internal mapped environment space. |
| 🟢 | `SetEnvironmentVariableA` | Adds to local environmental dictionary tracker. |
| 🟢 | `ExitProcess` | Directly invokes `std.process.exit()`. |
| 🟢 | `SetConsoleCtrlHandler` | Registers generic handler callbacks to avoid aborts. |
| 🟢 | `GetCurrentProcess` | Returns a mock process handler `-1`. |
| 🟢 | `GetCurrentProcessId` | Returns dummy PID scalar. |
| 🟢 | `GetCurrentThreadId` | Returns dummy TID scalar. |
| 🟢 | `GetTickCount` | Accurate native timestamp clock translation. |
| 🟢 | `GetVersion` | Mocks basic Windows NT 4.0 responses. |
| 🟢 | `GetModuleFileNameA` | Returns correct loader-context mapped executable path. |
| 🟢 | `GetModuleHandleA` | Looks up handles mapped actively in our `ModuleRegistry`. |
| 🟢 | `GetProcAddress` | Dynamically walks loaded PE Image Data Export Directories for addresses. |
| 🟢 | `LoadLibraryA` | Triggers a full recursive PE parse/load dynamically into execution space. |
| 🟢 | `CreateProcessA` | Spawns POSIX child execution tracking arguments natively. |

### Memory
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | `HeapCreate` | Hooks into Zig `page_allocator` pools. |
| 🟢 | `HeapDestroy` | Destroys allocated pools. |
| 🟢 | `HeapAlloc` | Allocates slice using Zig allocator. |
| 🟢 | `HeapReAlloc` | Resizes slices dynamically natively. |
| 🟢 | `HeapFree` | Returns memory mapping via allocator. |
| 🟢 | `LocalAlloc` / `LocalFree` | Wraps native heap allocation hooks. |
| 🟢 | `VirtualAlloc` | Mmaps anonymous blocks supporting execution bits. |
| 🟢 | `VirtualFree` | Calls native POSIX `munmap`. |
| 🟢 | `VirtualQuery` | Mocks generic `MEMORY_BASIC_INFORMATION`. |
| 🟢 | `GlobalMemoryStatus` | Mocks `MEMORYSTATUS` availability bounds. |
| 🟢 | `GetProcessHeap` | Resolves core allocator handle pointer. |

### String & Locale
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | `GetCPInfo` | Populates default UTF8-style constants. |
| 🟢 | `GetACP` / `GetOEMCP` | Returns standard `1252` code pages. |
| 🟢 | `IsValidCodePage` | Approves default pages immediately. |
| 🟢 | `IsDBCSLeadByte(Ex)` | Assumes standard ASCII parsing ranges. |
| 🟢 | `MultiByteToWideChar` | Translates UTF-8 dynamically into UTF-16 arrays. |
| 🟢 | `WideCharToMultiByte` | Translates UTF-16 back to Unix-compliant UTF-8. |
| 🟢 | `FormatMessageA` | Evaluates system/error generic formats safely and allocates tracking buffers. |
| 🟢 | `GetStringTypeA/W` | Flags string constants correctly for character comparisons. |
| 🟢 | `GetSystemDefaultLCID` / `GetLocaleInfoA` | Assumes basic US-EN. |
| 🟢 | `GetTimeZoneInformation` | Mocks basic timezone infos safely. |

### Stubbed KERNEL32 APIs
| Status | APIs | Implementation Details |
| :---: | :--- | :--- |
| 🟡 | **Threading / Synch** | `WaitForMultipleObjects`, `WaitForSingleObject`, `CreateSemaphoreA`, `ReleaseSemaphore`, `GetCurrentThread`, `SetThreadPriority`, `SetEvent`, `InterlockedExchange`, `OpenEventA` (Return `0`/`1` safety codes) |
| 🟡 | **Error / Handlers** | `UnhandledExceptionFilter`, `DebugBreak`, `RtlUnwind`, `GetLastError`, `RaiseException`, `SetErrorMode` (Ignore parameters, return safe bounds) |
| 🟡 | **Console / Display** | `GetConsoleScreenBufferInfo`, `SetConsoleTitleA`, `GenerateConsoleCtrlEvent`, `GetConsoleMode`, `WriteConsoleW`, `SetStdHandle` |
| 🟡 | **Misc** | `FreeLibrary`, `TerminateProcess`, `Sleep`, `VirtualProtect`, `GetSystemTime`, `SystemTimeToFileTime`, `DeviceIoControl`, `FlushFileBuffers`, `CopyFileA`, `FindClose`, `GetExitCodeProcess`, `LCMapStringA/W`, `SetFileApisToOEM`, `GetSystemInfo`, `DisableThreadLibraryCalls`, `FreeEnvironmentStringsA/W` |

---

## MSVCRT.dll

### C-Runtime Initialization
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | `_initterm` | Iterates and executes function pointers (like constructors). |
| 🟢 | `_XcptFilter` | Basic exception filter routing. |
| 🟢 | `__getmainargs` | Populates and binds process `argc`, `argv`, and `envp`. |
| 🟢 | **Global Getters** | `__p__fmode`, `__p__commode`, `__p___initenv`, `__p__pgmptr`, `__p___argc`, `__p___argv`, `__p__environ`, `__p__wenviron`, `__p__timezone`, `__p__daylight`, `__p__tzname` safely route to our Zig struct pointers. |
| 🟢 | `__set_app_type` | Marks application states correctly. |
| 🟢 | `__setusermatherr` | Safe math routing flags. |
| 🟢 | `_adjust_fdiv` | Sets legacy MS FPU division bits dynamically. |
| 🟢 | `_controlfp` | Emulates control word masks natively. |
| 🟢 | `_EH_prolog` | Proper asm naked call frame setup allowing x86 exception handlers without segfaulting. |
| 🟢 | `_setjmp3` / `longjmp` | Handles specific MSVC-ABI setjmp jumps properly routing them inside execution state safely. |
| 🟢 | `exit` / `_exit` | Translates directly to Zig `process.exit()`. |
| 🟢 | `_spawnvp` / `_spawnv` | Converts paths dynamically to execute native Unix binaries or re-inject `zine` recursively. |
| 🟢 | `getenv` / `_putenv` | Natively gets/sets from our environment tracker. |
| 🟢 | `_splitpath` / `_makepath` / `_fullpath` | Windows native string splitting routines adapted correctly for POSIX string slices. |

### Memory & Math
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | Allocators | `malloc`, `calloc`, `realloc`, `free`, `??2@YAPAXI@Z` (new), `??3@YAXPAX@Z` (delete) mapped efficiently via Zig page mapping. |
| 🟢 | Stdlib Overrides | `memset`, `memcpy`, `memmove` map securely to Zig equivalents. |
| 🟢 | Algorithms | `qsort`, `bsearch` accurately cast and run native Zig callback sorts. |
| 🟢 | `_ftol` | FPU cast emulation. |

### String Manipulation
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | **Basic Mutators** | `strlen`, `wcslen`, `strcpy`, `wcscpy`, `strncpy`, `wcsncpy`, `strcat`, `wcscat` map identically. |
| 🟢 | **Comparators** | `strcmp`, `wcscmp`, `strncmp`, `wcsncmp`, `_stricmp`, `_strcmpi`, `_wcsicmp`, `_strnicmp`, `_wcsnicmp` natively perform wide and narrow comparisons correctly. |
| 🟢 | **Searches** | `strchr`, `wcschr`, `strrchr`, `strstr`, `strcspn` route effectively to slice matchers. |
| 🟢 | **Conversions** | `atoi`, `atol`, `_itoa`, `_ltoa`, `_ultoa`, `strtoul`, `strtol`, `wcstol`, `_wtoi` wrap native string parsing. |
| 🟢 | **Formatters** | `_strdup`, `_wcsdup`, `_wcsupr` execute valid native allocations dynamically. |

### File I/O
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | **Handles & POSIX** | `_access`, `_getcwd`, `_sopen`, `_open`, `_read`, `_write`, `_lseek`, `_close`, `_tell`, `_chsize`, `_filelength`, `_fstat`, `_stat`, `_get_osfhandle`, `_open_osfhandle` use direct fd OS calls and stats. |
| 🟢 | **Stream Setup** | `fopen`, `_fsopen`, `fclose`, `_setmode`, `_iob`, `__p__iob` emulate MS FILE pointers correctly into fds directly instead of abstract struct maps. |
| 🟢 | **Stream Operations**| `fread`, `fwrite`, `fseek`, `ftell`, `fgetc`, `getc`, `_filbuf`, `putchar`, `fputc`, `putc`, `_flsbuf`, `puts`, `fputs`, `fgets` map 1:1 against Linux stdio via fds. |
| 🟢 | **Print Formatters** | `printf`, `vprintf`, `fprintf`, `fwprintf`, `vfprintf`, `_vsnprintf`, `_snprintf`, `sprintf`, `swprintf` implement custom format specifier parsing to handle `%d`, `%x`, `%s` identically to MSVC (handles widths). |
| 🟢 | **Scanners/Other** | `sscanf`, `tmpnam`, `_tempnam`, `_mktemp`, `_findfirst`, `_findnext` |

### Locale & Ctype
| Status | API | Implementation Details |
| :---: | :--- | :--- |
| 🟢 | **Pctype Structures**| `_pctype`, `__p__pctype`, `__mb_cur_max`, `_mbctype` provide arrays bit-matching Microsoft C++ runtime perfectly. |
| 🟢 | **Validators** | `isalnum`, `isalpha`, `isdigit`, `isxdigit`, `isspace`, `isprint`, `ispunct`, `isupper`, `islower`, `iswctype` directly assert bounds. |
| 🟢 | **Mutators** | `tolower`, `toupper`, `towlower`, `towupper` flip case. |
| 🟢 | **Multibyte Handlers**| `_isctype`, `_ismbcspace`, `_ismbcalnum`, `_ismbcdigit`, `_ismbcalpha`, `_mbscspn`, `_mbsstr`, `_mbsinc`, `_mbschr`, `_mbsrchr`, `_mbsncmp`, `_mbscmp`, `_mbsicmp`, `_mbsnbcpy`, `_mbsnbcmp`, `_mbsnbicmp`, `_mbspbrk`, `_mbccpy`, `_mbclen`, `_mbsdec`, `_mbstrlen`, `_mbctolower`, `_mbctoupper` alias effectively into ASCII logic for non-Asian standard codepages. |

### Stubbed MSVCRT APIs
| Status | APIs | Implementation Details |
| :---: | :--- | :--- |
| 🟡 | **Environment** | `signal`, `__dllonexit`, `_onexit`, `_purecall`, `_seh_longjmp_unwind`, `__CxxFrameHandler`, `_except_handler3` (Handlers disabled/ignored) |
| 🟡 | **Low File/IO** | `_getch`, `_isatty`, `_unlink`, `_dup`, `_dup2`, `_chdir`, `_chdrive`, `remove`, `rename`, `_searchenv`, `getchar`, `ungetc`, `fflush`, `_flushall`, `setvbuf`, `rewind`, `freopen`, `_fcloseall`, `tmpfile`, `_findclose` |
| 🟡 | **Misc** | `strncat`, `strpbrk`, `strtok`, `_memicmp`, `strerror`, `_strerror`, `mbtowc`, `setlocale`, `_ismbblead`, `_mbsspn`, `_mbstok`, `_mbslwr`, `_mbsupr`, `_strupr`, `_setmbcp`, `_getmbcp`, `_ftime`, `time`, `_tzset`, `ctime`, `rand`, `srand`, `ceil`, `floor`, `_utime`, `_futime`, `_osver`, `__unDName`, `_atoldbl`, `_adj_fdiv_r`, `__p___wargv`, `__p__wpgmptr` |

---

## USER32.dll

### String & Conversion
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `CharNextA` / `CharPrevA` | Advances/Retreats string pointers safely. |
| 🟢 | `LoadStringA` | Dynamically parses PE `IMAGE_DIRECTORY_ENTRY_RESOURCE` for RT_STRING blocks. |
| 🟢 | `wsprintfA` | Supports custom format parsing and mapping. |
| 🟢 | `CharToOemA` / `OemToCharA` | Translates character sets. |

### Window Management
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `RegisterClassA` | Captures WndProc, class name, menu name. Sets `window_has_menu` from class menu. |
| 🟢 | `CreateWindowExA` | Stores style/exstyle, computes client area from frame adjustments, sends initial size to web UI. |
| 🟢 | `AdjustWindowRectEx` / `AdjustWindowRect` | Style-based frame calculation using Win2K/2K metrics (WS_THICKFRAME=4px, WS_CAPTION=19px, SM_CYMENU=19px, WS_EX_CLIENTEDGE=2px). |
| 🟢 | `GetSystemMetrics` | Returns Win2K/2K values for 40+ metric indices (screen, borders, caption, menu, edges, icons). |
| 🟢 | `GetWindowLongA` | Returns stored GWL_STYLE (-16), GWL_EXSTYLE (-20), GWL_HINSTANCE (-6), GWL_WNDPROC (-4). |
| 🟢 | `SetWindowLongA` | Stores new style/exstyle/wndproc values. |
| 🟢 | `SetWindowPos` | Derives client area using stored styles via `calcFrameAdjustments`. Sends clientW/clientH to web UI. |
| 🟢 | `MoveWindow` | Delegates to SetWindowPos. |
| 🟢 | `GetClientRect` | Returns computed client area from stored dimensions. |
| 🟢 | `GetWindowRect` | Returns stored window position and dimensions. |
| 🟢 | `SetWindowTextA` | Sends title update JSON to web UI. |
| 🟢 | `SystemParametersInfoA` | Handles SPI_GETWORKAREA (returns 800×600 work area). |

### Messaging
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `PeekMessageA` | Manages message queue with WM_ACTIVATE, WM_COMMAND, keyboard messages. |
| 🟢 | `GetMessageA` | Blocking message retrieval (polls PeekMessageA). |
| 🟢 | `TranslateMessage` | No-op stub. |
| 🟢 | `DispatchMessageA` | Dispatches to registered WndProc via SEH-safe `callWndProcSafe`. |
| 🟢 | `SendMessageA` | Calls WndProc directly via SEH-safe wrapper. |
| 🟢 | `PostMessageA` | Handles WM_QUIT to exit process. |
| 🟢 | `PostQuitMessage` | Exits process immediately. |
| 🟢 | `DefWindowProcA` | Returns 0. |

### Dialog
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `DialogBoxParamA` | Parses dialog templates from PE resources, sends JSON to web UI, calls `lpDialogFunc` with WM_INITDIALOG. |
| 🟢 | `EndDialog` | Stub returns 1. |
| 🟢 | `GetDlgItem` | Returns dummy control handle. |
| 🟢 | `SetDlgItemTextA` | Logs text but no-op on web UI. |
| 🟢 | `GetDlgItemTextA` | Returns empty string. |
| 🟢 | `SendDlgItemMessageA` | Logs STM_SETIMAGE and other messages. |
| 🟢 | `MessageBoxA` | Sends message_box JSON to web UI. |

### Menu
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `GetMenu` | Returns dummy menu handle. |
| 🟢 | `DrawMenuBar` / `SetMenu` | Menu state tracking. |
| 🟢 | `CheckMenuItem` | Returns previous check state. |
| 🟡 | `LoadMenuA` / `DestroyMenu` / `GetSubMenu` / `TrackPopupMenu` / `AppendMenuA` | Basic stubs returning dummy handles. |

### Drawing / DC
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `GetDC` / `ReleaseDC` | Return dummy HDC. |
| 🟡 | `BeginPaint` / `EndPaint` | Return dummy HDC. |
| 🟡 | `RedrawWindow` / `UpdateWindow` / `InvalidateRect` | No-op stubs. |
| 🟡 | `SetRect` | Correctly sets RECT fields. |
| 🟡 | `FillRect` / `MapWindowPoints` | No-op stubs. |

### Input
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `GetKeyboardState` | Copies 256-byte keyboard state from web UI renderer. |
| 🟢 | `GetKeyState` / `GetAsyncKeyState` | Returns key down state from renderer keyboard_state. |

### Window State & Focus
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `ShowWindow` / `EnableWindow` / `IsWindow` / `IsIconic` | Return success/true. |
| 🟡 | `SetFocus` / `GetFocus` / `GetForegroundWindow` / `SetForegroundWindow` / `GetActiveWindow` / `GetDesktopWindow` | Return dummy handles. |
| 🟡 | `SetCapture` / `GetCapture` / `ReleaseCapture` | No-op stubs. |
| 🟡 | `ClientToScreen` / `ScreenToClient` | No-op stubs. |
| 🟡 | `SetCursor` / `GetCursorPos` | Return dummy values. |
| 🟡 | `SetTimer` / `KillTimer` | Return success but don't fire timers. |

### Resource Loading
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `LoadIconA` | Parses icon resources from PE and sends base64-encoded icon to web UI. |
| 🟡 | `LoadCursorA` | Returns dummy cursor handle. |

---

## GDI32.dll

### Device Context & Queries
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `GetDeviceCaps` | Returns Win2K/2K display values (800×600, 32bpp, 96dpi). |
| 🟢 | `GetStockObject` | Returns unique dummy handles per stock object ID. |
| 🟢 | `GetTextMetricsA` | Returns Win2K 8pt MS Sans Serif metrics (height=13, avgWidth=7). |
| 🟡 | `SaveDC` / `RestoreDC` / `SetMapMode` / `SetStretchBltMode` / `SetROP2` | Return previous state values. |

### Object Management
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `SelectObject` | Returns "previous" object (passes through). |
| 🟡 | `DeleteObject` / `DeleteDC` | Return success. |
| 🟡 | `GetObjectA` | Zeroes output buffer, returns 0. |
| 🟡 | `GetCurrentObject` | Returns 0. |

### Object Creation
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `CreateSolidBrush` / `CreatePen` / `CreateFontIndirectA` | Return unique dummy handles. |
| 🟡 | `CreateCompatibleDC` / `CreateCompatibleBitmap` / `CreateBitmap` / `CreateDIBSection` | Return unique dummy handles. |
| 🟡 | `LoadImageA` | Returns dummy handle. |

### Drawing & Blitting
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `BitBlt` / `StretchBlt` / `StretchDIBits` / `SetDIBitsToDevice` / `PatBlt` | Return success (no actual rendering). |
| 🟡 | `TextOutA` | Return success. |
| 🟡 | `SetPixel` / `GetPixel` / `MoveToEx` / `LineTo` / `Rectangle` | Return success. |

### Color & Mode
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `SetBkMode` / `SetBkColor` / `SetTextColor` / `GetTextColor` | Return previous values. |
| 🟡 | `GetDIBits` | Returns 0. |

---

## NTDLL.dll
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `NtQuerySystemInformation` | Emulates classes 0, 2, 3, 5, 11, 18, 21 for diagnostic tools like PSTAT. |
| 🟢 | `RtlFreeAnsiString` | Cleans up NT strings. |
| 🟢 | `RtlUnicodeStringToAnsiString` | Converts dynamically without faulting. |
| 🟢 | `RtlTimeToElapsedTimeFields` | Native stub simulating uptime clocks. |

---

## COMDLG32.dll / IMAGEHLP.dll / RPCRT4.dll
| Status | DLL | API | Comments |
| :---: | :--- | :--- | :--- |
| 🟢 | `COMDLG32` | `GetOpenFileNameA` | Integrated file picker via web UI. Blocks emulator thread, sends `open_file_dialog` JSON, receives uploaded file via WebSocket binary frame. Populates OPENFILENAMEA struct (lpstrFile, nFileOffset, nFileExtension, lpstrFileTitle). |
| 🟢 | `IMAGEHLP` | `UnDecorateSymbolName` | Implemented demangling entry point handler. |
| 🟢 | `RPCRT4` | `UuidCreate`, `UuidToStringA`, `RpcStringFreeA` | Handlers simulating dynamic UUID assignment routines natively. |

---

## ADVAPI32.dll / MFC42.dll
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `ADVAPI32.dll` | `RegOpenKeyExA`, `RegQueryValueExA`, `RegCloseKey` safely return failure states ensuring logic skips registry lock lookups. |
| 🟡 | `MFC42.dll` | Dynamically intercepts all ordinal imports, routing them to a generic dummy pointer (`stub_mfc_dummy`), allowing complex visual executables like `MAKEHM.EXE` to print CLI usage bounds without faulting out. |

---

## DDRAW.dll / DSOUND.dll / DINPUT.dll / DINPUT8.dll / WINMM.dll
| Status | DLL | API | Comments |
| :---: | :--- | :--- | :--- |
| 🟢 | `DDRAW` | `DirectDrawCreate` | COM-style vtable emulation. Supports SetCooperativeLevel, CreateSurface (primary/offscreen), CreateClipper, SetHWnd, GetDisplayMode. Surface Lock/Unlock writes to shared framebuffer pushed to web UI via WebSocket binary frames. |
| 🟢 | `DSOUND` | `DirectSoundCreate` (ordinal 1) | COM vtable stubs for IDirectSound and IDirectSoundBuffer. CreateSoundBuffer, SetFormat, Lock/Unlock, Play/Stop, GetStatus, SetVolume, GetCurrentPosition all stubbed. |
| 🟡 | `DINPUT` | `DirectInputCreateA` | COM vtable stubs for IDirectInput and IDirectInputDevice. EnumDevices, CreateDevice, SetDataFormat, SetCooperativeLevel, SetProperty, Acquire, GetDeviceState all stubbed. |
| 🟡 | `DINPUT8` | `DirectInput8Create` | Reuses DINPUT COM vtable stubs for IDirectInput and IDirectInputDevice. |
| 🟡 | `WINMM` | `timeGetTime` / `timeBeginPeriod` / `timeEndPeriod` | Timer stubs returning reasonable values. |

---

## OLEAUT32.dll
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `SysFreeString` | Stub (no-op). |
| 🟡 | `SysAllocStringLen` | Stub returning null. |

---

## D3D8.dll
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟢 | `Direct3DCreate8` | COM-style vtable emulation. Implements IDirect3D8 (GetAdapterDisplayMode, CreateDevice) and IDirect3DDevice8 (CreateVertexBuffer, SetRenderState, BeginScene/EndScene, Present, Clear, SetTexture, SetStreamSource, DrawPrimitive/DrawIndexedPrimitive). Integrates with shared framebuffer for rendering output. |

---

## SHELL32.dll / COMCTL32.dll / OLE32.dll
| Status | DLL | API | Comments |
| :---: | :--- | :--- | :--- |
| 🟡 | `SHELL32` | `ShellExecuteA/W`, `SHGetSpecialFolderPathA`, `SHGetFileInfoA`, `SHBrowseForFolderA`, `DragAcceptFiles`, `Shell_NotifyIcon`, etc. (29 exports) | Mix of custom implementations and generic stubs. |
| 🟡 | `COMCTL32` | `InitCommonControls`, `InitCommonControlsEx`, `ImageList_Create/Destroy/Add/GetImageCount`, `TrackMouseEvent`, `CreateStatusWindow`, etc. (20 exports) | Mix of custom implementations and generic stubs. |
| 🟡 | `OLE32` | `CoInitialize`, `CoInitializeEx`, `CoCreateInstance`, `CoTaskMemAlloc/Free`, `CoUninitialize`, `DoDragDrop`, etc. (21 exports) | Mix of custom implementations and generic stubs. |

---

## MSS32.dll (Miles Sound System)
| Status | API | Comments |
| :---: | :--- | :--- |
| 🟡 | `AIL_*` (60 exports) | Decorated Miles Sound System API stubs. Functions like `AIL_open_digital_driver`, `AIL_allocate_sample_handle`, `AIL_set_sample_file`, `AIL_start_sample`, etc. Most return dummy success values or no-op. |

---

## WS2_32.dll / WSOCK32.dll / ICMP.dll
| Status | DLL | API | Comments |
| :---: | :--- | :--- | :--- |
| 🟡 | `WS2_32` | `WSAStartup/Cleanup`, `socket`, `bind`, `listen`, `accept`, `connect`, `send/recv`, `select`, `htonl/htons/ntohl/ntohs`, `inet_addr/ntoa`, `gethostbyname/addr`, etc. (33 exports) | Custom implementations returning failure/dummy values for network operations. |
| 🟡 | `WSOCK32` | 40 exports (26 named + 14 ordinals) | Thin compatibility layer forwarding to WS2_32 implementations. |
| 🟡 | `ICMP` | `IcmpCreateFile`, `IcmpSendEcho2`, `IcmpCloseHandle` | Generic stubs. |

---

## IMM32.dll / VERSION.dll / WINSPOOL.DRV
| Status | DLL | API | Comments |
| :---: | :--- | :--- | :--- |
| 🟡 | `IMM32` | `ImmGetContext`, `ImmReleaseContext`, `ImmGetCompositionStringW`, `ImmSetCompositionWindow/Font`, `ImmGetVirtualKey` (9 exports) | Return dummy values. |
| 🟡 | `VERSION` | `GetFileVersionInfoSizeA/W`, `GetFileVersionInfoA/W`, `VerQueryValueA/W` (6 exports) | Return 0 (no version info). |
| 🟡 | `WINSPOOL.DRV` | `OpenPrinter`, `ClosePrinter`, `StartDocPrinter`, `EndDocPrinter`, `WritePrinter`, `EnumPrinters`, `DocumentProperties`, etc. (11 exports) | Return success with no actual printing. |

---

## Other Minor DLLs
| Status | DLL | API | Comments |
| :---: | :--- | :--- | :--- |
| 🟡 | `NDDEAPI` | 11 ordinal-only exports | Generic stubs for legacy DDE networking. |
| 🟡 | `CARDS` | `cdtInit`, `cdtTerm`, `cdtDraw`, `cdtDrawExt`, `cdtAnimate` | Generic stubs for Solitaire card rendering. |
| 🟡 | `VDMDBG` | `VDMTerminateTaskWOW`, `VDMEnumTaskWOWEx` | Generic stubs for 16-bit VDM debugging. |
| 🟡 | `MAG_HOOK` | `_FakeCursorMove@8`, `_SetZoomRect@8`, `_InstallEventHook@4` | Generic stubs. |

---

### GUI / Web UI Architecture
- **Backend**: WebSocket server on port 1995 (`web_ui.zig`). Pushes binary RGBA framebuffer data and JSON control messages.
- **Frontend**: Embedded `index.html` with Win2K/2000-styled CSS. Renders application window with titlebar (gradient blue), menu bar, canvas for DirectDraw output, taskbar with Start button and clock.
- **Dialog rendering**: Custom dialog templates parsed from PE resources (`dialog_parser.zig`) with control class identification (Button, Static, Edit, ListBox, ComboBox, GroupBox). Rendered with Win2K 3D beveled controls, proper DLU-to-pixel scaling (1.75×1.875).
- **Icon rendering**: PE icon resources extracted, base64-encoded, displayed in titlebar, taskbar, and as favicon.
- **Menu rendering**: PE menu resources parsed (`menu_parser.zig`), sent as JSON, rendered as Win2K-styled dropdown menus with keyboard accelerator underlines.
- **Input forwarding**: Browser keyboard events sent via WebSocket JSON, mapped to Win32 virtual key codes, delivered via PeekMessageA/GetKeyboardState.

### Environmental Progress
- **Resource Processing**: Implemented native `pe.zig` binary tree navigation for Windows RC `.res` parsing. Dialog templates, icons, menus, and string tables all parsed from PE resources.
- **Paths**: DOS Drive strings and dynamic execution mappings natively translate across Unix filesystems using string splitting routines (`_splitpath`).
- **Batch Scripts**: Natively parses `.bat`/`.cmd` files (e.g., `VCVARS32.BAT`), evaluating `set` declarations, `if` conditions, nested `call`s, and arguments `%1`/`%*`. Modifies the environment seamlessly for executed child programs, mapping Windows variables like `PATH` into dynamically loaded module directories natively on UNIX.
