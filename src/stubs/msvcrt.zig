const std = @import("std");
const env = @import("../loader/env.zig");
const io = @import("msvcrt/io.zig");
const trace = @import("../trace.zig");

// --- Global State ---

pub var global_argc: i32 = 0;
pub var global_argv: [*]?[*:0]u8 = undefined;
pub var global_envp: [*]const ?[*:0]const u8 = undefined;
pub var global_env_initialized: bool = false;

pub var msvcrt_fmode: u32 = 0;
pub var msvcrt_commode: u16 = 0;
pub var msvcrt_initenv: ?*anyopaque = null;
pub var msvcrt_pgmptr: ?*anyopaque = null;
pub var msvcrt_adjust_fdiv: i32 = 0;
pub var msvcrt_errno_val: i32 = 0;
pub var msvcrt_mb_cur_max: i32 = 1;

// _acmdln / _wcmdln data exports: these are char*/wchar_t* pointers
// Initialized to point to empty strings; main.zig sets _acmdln to the real command line
var acmdln_default: [1]u8 = .{0};
pub var msvcrt_acmdln: usize = 0;
var wcmdln_default: [2]u8 = .{ 0, 0 };
pub var msvcrt_wcmdln: usize = 0;

pub var msvcrt_timezone: i32 = 0;
pub var msvcrt_daylight: i32 = 0;
pub var msvcrt_tzname: [2]?*anyopaque = [_]?*anyopaque{ @ptrCast(@constCast("PST\x00")), @ptrCast(@constCast("PDT\x00")) };

pub var msvcrt_pctype: [257]u16 = [_]u16{0} ** 257;
pub var msvcrt_pctype_ptr: *u16 = &msvcrt_pctype[1];
pub var msvcrt_mbctype: [257]u8 = [_]u8{0} ** 257;
pub var msvcrt_mbctype_ptr: *u8 = &msvcrt_mbctype[1];
pub const EnvVar = struct { key: []const u8, val: []const u8 };
pub var msvcrt_env_vars: std.ArrayListUnmanaged(EnvVar) = .{};

const string = @import("msvcrt/string.zig");
const process = @import("msvcrt/process.zig");
const mem = @import("msvcrt/mem.zig");
const math = @import("msvcrt/math.zig");
const misc = @import("msvcrt/misc.zig");

pub fn register(environment: *env.Environment) !void {
    string.init_pctype();
    // Initialize data export pointers to defaults (can't do at comptime)
    if (msvcrt_acmdln == 0) msvcrt_acmdln = @intFromPtr(&acmdln_default);
    if (msvcrt_wcmdln == 0) msvcrt_wcmdln = @intFromPtr(&wcmdln_default);
    const m = "MSVCRT.dll";

    // Data Exports
    try environment.addBuiltinExport(m, "_timezone", @intFromPtr(&msvcrt_timezone));
    try environment.addBuiltinExport(m, "_daylight", @intFromPtr(&msvcrt_daylight));
    try environment.addBuiltinExport(m, "_tzname", @intFromPtr(&msvcrt_tzname));
    try environment.addBuiltinExportComptime(m, "__p__timezone", process.stub_p_timezone);
    try environment.addBuiltinExportComptime(m, "__p__daylight", process.stub_p_daylight);
    try environment.addBuiltinExportComptime(m, "__p__tzname", process.stub_p_tzname);
    try environment.addBuiltinExport(m, "_adjust_fdiv", @intFromPtr(&msvcrt_adjust_fdiv));
    try environment.addBuiltinExport(m, "__mb_cur_max", @intFromPtr(&msvcrt_mb_cur_max));
    try environment.addBuiltinExport(m, "_iob", @intFromPtr(&io.msvcrt_iob));
    try environment.addBuiltinExport(m, "_acmdln", @intFromPtr(&msvcrt_acmdln));
    try environment.addBuiltinExport(m, "_wcmdln", @intFromPtr(&msvcrt_wcmdln));

    // Process & Startup
    try environment.addBuiltinExportComptime(m, "__wgetmainargs", process.stub_wgetmainargs);
    try environment.addBuiltinExportComptime(m, "__getmainargs", process.stub_getmainargs);
    try environment.addBuiltinExportComptime(m, "exit", process.stub_exit);
    try environment.addBuiltinExportComptime(m, "_exit", process.stub_exit);
    try environment.addBuiltinExportComptime(m, "_XcptFilter", process.stub_XcptFilter);
    try environment.addBuiltinExportComptime(m, "_initterm", process.stub_initterm);
    try environment.addBuiltinExportComptime(m, "_controlfp", math.stub_controlfp);
    try environment.addBuiltinExportComptime(m, "__set_app_type", process.stub_set_app_type);
    try environment.addBuiltinExportComptime(m, "__setusermatherr", math.stub_setusermatherr);
    try environment.addBuiltinExportComptime(m, "__p__fmode", process.stub_p_fmode);
    try environment.addBuiltinExportComptime(m, "__p__commode", process.stub_p_commode);
    try environment.addBuiltinExportComptime(m, "__p___initenv", process.stub_p_initenv);
    try environment.addBuiltinExportComptime(m, "__p__pgmptr", process.stub_p_pgmptr);
    try environment.addBuiltinExportComptime(m, "__p___argc", process.stub_p_argc);
    try environment.addBuiltinExportComptime(m, "__p___argv", process.stub_p_argv);
    try environment.addBuiltinExportComptime(m, "__p__environ", process.stub_p_environ);
    try environment.addBuiltinExportComptime(m, "__p__wenviron", process.stub_p_environ);
    try environment.addBuiltinExportComptime(m, "_spawnvp", process.stub_spawnvp);
    try environment.addBuiltinExportComptime(m, "_spawnv", process.stub_spawnvp);
    try environment.addBuiltinExportComptime(m, "signal", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "__dllonexit", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_onexit", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_purecall", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_seh_longjmp_unwind", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "__CxxFrameHandler", misc.stub_ignore_i32);

    // Memory
    try environment.addBuiltinExportComptime(m, "malloc", mem.stub_malloc);
    try environment.addBuiltinExportComptime(m, "calloc", mem.stub_calloc);
    try environment.addBuiltinExportComptime(m, "realloc", mem.stub_realloc);
    try environment.addBuiltinExportComptime(m, "free", mem.stub_free);
    try environment.addBuiltinExportComptime(m, "??2@YAPAXI@Z", mem.stub_malloc);
    try environment.addBuiltinExportComptime(m, "??3@YAXPAX@Z", mem.stub_free);

    // ANSI String & Memory
    try environment.addBuiltinExportComptime(m, "strlen", string.stub_strlen);
    try environment.addBuiltinExportComptime(m, "strcpy", string.stub_strcpy);
    try environment.addBuiltinExportComptime(m, "strncpy", string.stub_strncpy);
    try environment.addBuiltinExportComptime(m, "strcat", string.stub_strcat);
    try environment.addBuiltinExportComptime(m, "strncat", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "strcmp", string.stub_strcmp);
    try environment.addBuiltinExportComptime(m, "strncmp", string.stub_strncmp);
    try environment.addBuiltinExportComptime(m, "_stricmp", string.stub_stricmp);
    try environment.addBuiltinExportComptime(m, "_strcmpi", string.stub_stricmp);
    try environment.addBuiltinExportComptime(m, "_strnicmp", string.stub_strnicmp);
    try environment.addBuiltinExportComptime(m, "strchr", string.stub_strchr);
    try environment.addBuiltinExportComptime(m, "strrchr", string.stub_strrchr);
    try environment.addBuiltinExportComptime(m, "strstr", string.stub_strstr);
    try environment.addBuiltinExportComptime(m, "strpbrk", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "strcspn", string.stub_strcspn);
    try environment.addBuiltinExportComptime(m, "strtok", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_strdup", string.stub_strdup);
    try environment.addBuiltinExportComptime(m, "_wcsdup", string.stub_wcsdup);
    try environment.addBuiltinExportComptime(m, "memset", mem.stub_memset);
    try environment.addBuiltinExportComptime(m, "memcpy", mem.stub_memcpy);
    try environment.addBuiltinExportComptime(m, "memmove", mem.stub_memmove);
    try environment.addBuiltinExportComptime(m, "memcmp", string.stub_strncmp);
    try environment.addBuiltinExportComptime(m, "_memicmp", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "atoi", string.stub_atoi);
    try environment.addBuiltinExportComptime(m, "atol", string.stub_atoi);
    try environment.addBuiltinExportComptime(m, "_itoa", string.stub_itoa);
    try environment.addBuiltinExportComptime(m, "_ltoa", string.stub_itoa);
    try environment.addBuiltinExportComptime(m, "_ultoa", string.stub_itoa);
    try environment.addBuiltinExportComptime(m, "strtoul", string.stub_strtoul);
    try environment.addBuiltinExportComptime(m, "strtol", string.stub_strtol);
    try environment.addBuiltinExportComptime(m, "strerror", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_strerror", misc.stub_ignore_ptr);

    // Wide String
    try environment.addBuiltinExportComptime(m, "wcslen", string.stub_wcslen);
    try environment.addBuiltinExportComptime(m, "wcscpy", string.stub_wcscpy);
    try environment.addBuiltinExportComptime(m, "wcsncpy", string.stub_wcsncpy);
    try environment.addBuiltinExportComptime(m, "wcscat", string.stub_wcscat);
    try environment.addBuiltinExportComptime(m, "wcscmp", string.stub_wcscmp);
    try environment.addBuiltinExportComptime(m, "wcsncmp", string.stub_wcsncmp);
    try environment.addBuiltinExportComptime(m, "_wcsicmp", string.stub_wcsicmp);
    try environment.addBuiltinExportComptime(m, "_wcsnicmp", string.stub_wcsnicmp);
    try environment.addBuiltinExportComptime(m, "wcschr", string.stub_wcschr);
    try environment.addBuiltinExportComptime(m, "_wcsupr", string.stub_wcsupr);
    try environment.addBuiltinExportComptime(m, "wcstol", string.stub_wcstol);
    try environment.addBuiltinExportComptime(m, "_wtoi", string.stub_wtoi);
    try environment.addBuiltinExportComptime(m, "_wtol", string.stub_wtoi);

    // File I/O
    try environment.addBuiltinExportComptime(m, "_access", misc.stub_access);
    try environment.addBuiltinExportComptime(m, "_getcwd", misc.stub_getcwd);
    try environment.addBuiltinExportComptime(m, "_sopen", misc.stub_sopen);
    try environment.addBuiltinExportComptime(m, "_read", misc.stub_read);
    try environment.addBuiltinExportComptime(m, "_write", misc.stub_write);
    try environment.addBuiltinExportComptime(m, "_lseek", misc.stub_lseek);
    try environment.addBuiltinExportComptime(m, "_close", misc.stub_close);
    try environment.addBuiltinExportComptime(m, "_tell", misc.stub_tell);
    try environment.addBuiltinExportComptime(m, "_chsize", misc.stub_chsize);
    try environment.addBuiltinExportComptime(m, "_filelength", misc.stub_filelength);
    try environment.addBuiltinExportComptime(m, "_fstat", misc.stub_fstat);
    try environment.addBuiltinExportComptime(m, "_getch", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_stat", misc.stub_stat);
    try environment.addBuiltinExportComptime(m, "_get_osfhandle", misc.stub_get_osfhandle);
    try environment.addBuiltinExportComptime(m, "_open_osfhandle", misc.stub_open_osfhandle);
    try environment.addBuiltinExportComptime(m, "_isatty", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_unlink", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_dup", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_dup2", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_chdir", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_chdrive", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "remove", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "rename", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_searchenv", misc.stub_searchenv);
    try environment.addBuiltinExportComptime(m, "_setmode", io.stub_setmode);

    // Stdio forward to io.zig
    try environment.addBuiltinExportComptime(m, "fopen", io.stub_fopen);
    try environment.addBuiltinExportComptime(m, "fclose", io.stub_fclose);
    try environment.addBuiltinExportComptime(m, "fread", io.stub_fread);
    try environment.addBuiltinExportComptime(m, "fwrite", io.stub_fwrite);
    try environment.addBuiltinExportComptime(m, "fseek", io.stub_fseek);
    try environment.addBuiltinExportComptime(m, "ftell", io.stub_ftell);
    try environment.addBuiltinExportComptime(m, "fgetc", io.stub_fgetc);
    try environment.addBuiltinExportComptime(m, "getc", io.stub_fgetc);
    try environment.addBuiltinExportComptime(m, "getchar", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "putchar", io.stub_putchar);
    try environment.addBuiltinExportComptime(m, "fputc", io.stub_fputc);
    try environment.addBuiltinExportComptime(m, "putc", io.stub_fputc);
    try environment.addBuiltinExportComptime(m, "puts", misc.stub_puts);
    try environment.addBuiltinExportComptime(m, "fputs", misc.stub_fputs);
    try environment.addBuiltinExportComptime(m, "ungetc", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "fflush", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_flushall", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "setvbuf", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "rewind", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "freopen", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "fgets", io.stub_fgets);
    try environment.addBuiltinExportComptime(m, "_fsopen", io.stub_fsopen);
    try environment.addBuiltinExportComptime(m, "_fcloseall", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "__p__iob", io.stub_p_iob);

    // Formatted I/O — variadic functions use addBuiltinExportComptimeVA
    // which passes a translated guest stack va_list as the last argument.
    try environment.addBuiltinExportComptimeVA(m, "printf", misc.stub_printf, 1);
    try environment.addBuiltinExportComptime(m, "vprintf", misc.stub_vprintf);
    try environment.addBuiltinExportComptimeVA(m, "fprintf", io.stub_fprintf, 2);
    try environment.addBuiltinExportComptime(m, "fwprintf", io.stub_fwprintf);
    try environment.addBuiltinExportComptime(m, "vfprintf", misc.stub_vfprintf);
    try environment.addBuiltinExportComptime(m, "_vsnprintf", misc.stub_vsnprintf);
    try environment.addBuiltinExportComptimeVA(m, "_snprintf", misc.stub_snprintf, 3);
    try environment.addBuiltinExportComptimeVA(m, "sprintf", misc.stub_sprintf, 2);
    try environment.addBuiltinExportComptimeVA(m, "swprintf", misc.stub_swprintf, 2);
    try environment.addBuiltinExportComptimeVA(m, "sscanf", misc.stub_sscanf, 2);
    try environment.addBuiltinExportComptime(m, "_tempnam", misc.stub_tempnam);
    try environment.addBuiltinExportComptime(m, "tmpfile", misc.stub_ignore_ptr);

    // Char Types & Locale
    try environment.addBuiltinExport(m, "_pctype", @intFromPtr(&msvcrt_pctype_ptr));
    try environment.addBuiltinExportComptime(m, "__p__pctype", string.stub_p_pctype);
    try environment.addBuiltinExportComptime(m, "isalnum", string.stub_isalnum);
    try environment.addBuiltinExportComptime(m, "isalpha", string.stub_isalpha);
    try environment.addBuiltinExportComptime(m, "isdigit", string.stub_isdigit);
    try environment.addBuiltinExportComptime(m, "isxdigit", string.stub_isxdigit);
    try environment.addBuiltinExportComptime(m, "isspace", string.stub_isspace);
    try environment.addBuiltinExportComptime(m, "isprint", string.stub_isprint);
    try environment.addBuiltinExportComptime(m, "ispunct", string.stub_ispunct);
    try environment.addBuiltinExportComptime(m, "isupper", string.stub_isupper);
    try environment.addBuiltinExportComptime(m, "islower", string.stub_islower);
    try environment.addBuiltinExportComptime(m, "_open", misc.stub_sopen); // _open is basically _sopen with 0 shflags
    try environment.addBuiltinExportComptime(m, "tolower", string.stub_tolower);
    try environment.addBuiltinExportComptime(m, "toupper", string.stub_toupper);
    try environment.addBuiltinExportComptime(m, "iswctype", string.stub_iswctype);
    try environment.addBuiltinExportComptime(m, "towlower", string.stub_towlower);
    try environment.addBuiltinExportComptime(m, "towupper", string.stub_towupper);
    try environment.addBuiltinExportComptime(m, "mbtowc", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "setlocale", misc.stub_setlocale);
    try environment.addBuiltinExportComptime(m, "_isctype", string.stub_isctype);

    // Multi-byte String
    try environment.addBuiltinExportComptime(m, "_ismbcspace", string.stub_ismbcspace);
    try environment.addBuiltinExportComptime(m, "_ismbcalnum", string.stub_isalnum);
    try environment.addBuiltinExportComptime(m, "_ismbcdigit", string.stub_isdigit);
    try environment.addBuiltinExportComptime(m, "_ismbcalpha", string.stub_isalpha);
    try environment.addBuiltinExportComptime(m, "_ismbblead", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_mbscspn", string.stub_strcspn);
    try environment.addBuiltinExportComptime(m, "_mbsspn", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_mbsstr", string.stub_strstr);
    try environment.addBuiltinExportComptime(m, "_mbsinc", string.stub_mbsinc);
    try environment.addBuiltinExportComptime(m, "_mbschr", string.stub_strchr);
    try environment.addBuiltinExportComptime(m, "_mbsrchr", string.stub_strrchr);
    try environment.addBuiltinExportComptime(m, "_mbsncmp", string.stub_strncmp);
    try environment.addBuiltinExportComptime(m, "_mbscmp", string.stub_strcmp);
    try environment.addBuiltinExportComptime(m, "_mbsicmp", string.stub_mbsicmp);
    try environment.addBuiltinExportComptime(m, "_mbsnbcpy", string.stub_strncpy);
    try environment.addBuiltinExportComptime(m, "_mbsnbcmp", string.stub_strncmp);
    try environment.addBuiltinExportComptime(m, "_mbsnbicmp", string.stub_strnicmp);
    try environment.addBuiltinExportComptime(m, "_mbspbrk", string.stub_strpbrk);
    try environment.addBuiltinExportComptime(m, "_mbstok", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_mbccpy", string.stub_mbccpy);
    try environment.addBuiltinExportComptime(m, "_mbclen", string.stub_mbclen);
    try environment.addBuiltinExportComptime(m, "_mbsdec", string.stub_mbsdec);
    try environment.addBuiltinExportComptime(m, "_mbstrlen", string.stub_strlen);
    try environment.addBuiltinExportComptime(m, "_mbctolower", string.stub_tolower);
    try environment.addBuiltinExportComptime(m, "_mbctoupper", string.stub_toupper);
    try environment.addBuiltinExport(m, "_mbctype", @intFromPtr(&msvcrt_mbctype));
    try environment.addBuiltinExportComptime(m, "_mbslwr", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_mbsupr", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_strupr", misc.stub_strupr);
    try environment.addBuiltinExportComptime(m, "_setmbcp", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_getmbcp", misc.stub_ignore_i32);

    // Jmp
    try environment.addBuiltinExport(m, "_EH_prolog", @intFromPtr(misc.stub_EH_prolog));
    try environment.addBuiltinExport(m, "_setjmp3", @intFromPtr(misc.stub_setjmp3));
    try environment.addBuiltinExport(m, "longjmp", @intFromPtr(misc.stub_longjmp));

    // Misc
    try environment.addBuiltinExportComptime(m, "qsort", misc.stub_qsort);
    try environment.addBuiltinExportComptime(m, "bsearch", misc.stub_bsearch);
    try environment.addBuiltinExportComptime(m, "tmpnam", misc.stub_tempnam);
    try environment.addBuiltinExportComptime(m, "_tempnam", misc.stub_tempnam);
    try environment.addBuiltinExportComptime(m, "_mktemp", misc.stub_mktemp);
    try environment.addBuiltinExportComptime(m, "_splitpath", misc.stub_splitpath);
    try environment.addBuiltinExportComptime(m, "_makepath", misc.stub_makepath);
    try environment.addBuiltinExportComptime(m, "_fullpath", misc.stub_fullpath);
    try environment.addBuiltinExportComptime(m, "getenv", process.stub_getenv);
    try environment.addBuiltinExportComptime(m, "_putenv", process.stub_putenv);
    try environment.addBuiltinExportComptime(m, "_errno", misc.stub_errno);
    try environment.addBuiltinExportComptime(m, "__doserrno", misc.stub_errno);
    try environment.addBuiltinExportComptime(m, "_except_handler3", misc.stub_except_handler3);
    try environment.addBuiltinExportComptime(m, "_ftime", misc.stub_ftime);
    try environment.addBuiltinExportComptime(m, "time", misc.stub_time);
    try environment.addBuiltinExportComptime(m, "localtime", misc.stub_localtime);
    try environment.addBuiltinExportComptime(m, "_tzset", misc.stub_tzset);
    try environment.addBuiltinExportComptime(m, "ctime", misc.stub_ctime);
    try environment.addBuiltinExportComptime(m, "rand", misc.stub_rand);
    try environment.addBuiltinExportComptime(m, "srand", misc.stub_srand);
    try environment.addBuiltinExportComptime(m, "ceil", math.stub_ceil);
    try environment.addBuiltinExportComptime(m, "floor", math.stub_floor);
    try environment.addBuiltinExport(m, "_ftol", @intFromPtr(math.stub_ftol));
    try environment.addBuiltinExportComptime(m, "_flsbuf", io.stub_fputc);
    try environment.addBuiltinExportComptime(m, "_filbuf", io.stub_fgetc);
    try environment.addBuiltinExportComptime(m, "_utime", misc.stub_utime);
    try environment.addBuiltinExportComptime(m, "_futime", misc.stub_futime);
    try environment.addBuiltinExportComptime(m, "_osver", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "__unDName", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_atoldbl", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_adj_fdiv_r", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_findfirst", misc.stub_findfirst);
    try environment.addBuiltinExportComptime(m, "_findnext", misc.stub_findnext);
    try environment.addBuiltinExportComptime(m, "_findclose", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "__p___wargv", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "__p__wpgmptr", misc.stub_ignore_ptr);

    // --- Remaining MSVCRT stubs for 100% win2k coverage ---
    try environment.addBuiltinExportComptime(m, "??1type_info@@UAE@XZ", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_CxxThrowException", stub_CxxThrowException);
    try environment.addBuiltinExportComptime(m, "?terminate@@YAXXZ", stub_terminate);
    try environment.addBuiltinExportComptime(m, "_wcsrev", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "wcsspn", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_snwprintf", misc.stub_snprintf);
    try environment.addBuiltinExportComptime(m, "_pclose", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_popen", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "iswspace", string.stub_iswctype);
    try environment.addBuiltinExportComptime(m, "iswdigit", string.stub_iswctype);
    try environment.addBuiltinExportComptime(m, "wcsrchr", string.stub_wcsrchr);
    try environment.addBuiltinExportComptime(m, "iswalpha", string.stub_iswctype);
    try environment.addBuiltinExportComptime(m, "wcstoul", string.stub_wcstol);
    try environment.addBuiltinExportComptime(m, "iswxdigit", string.stub_iswctype);
    try environment.addBuiltinExportComptime(m, "_pipe", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "swscanf", misc.stub_sscanf);
    try environment.addBuiltinExportComptime(m, "wcsstr", string.stub_wcsstr);
    try environment.addBuiltinExportComptime(m, "_vsnwprintf", misc.stub_vsnprintf);
    try environment.addBuiltinExportComptime(m, "_wcslwr", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_getdcwd", misc.stub_getcwd);
    try environment.addBuiltinExportComptime(m, "_itow", string.stub_itoa);
    try environment.addBuiltinExportComptime(m, "wcstok", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_ltow", string.stub_itoa);
    try environment.addBuiltinExportComptime(m, "_wsplitpath", misc.stub_splitpath);
    try environment.addBuiltinExportComptime(m, "wcstod", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "wcscoll", string.stub_wcscmp);

    // --- Notepad2 MSVCRT stubs ---
    try environment.addBuiltinExportComptime(m, "abs", misc.stub_abs);
    try environment.addBuiltinExportComptime(m, "clock", misc.stub_clock);
    try environment.addBuiltinExportComptime(m, "_lock", misc.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_unlock", misc.stub_noop1);
    try environment.addBuiltinExportComptime(m, "iscntrl", string.stub_iscntrl);
    try environment.addBuiltinExportComptime(m, "_cexit", misc.stub_noop0);
    try environment.addBuiltinExportComptime(m, "_amsg_exit", misc.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_swab", misc.stub_noop3);
    try environment.addBuiltinExportComptime(m, "mktime", misc.stub_mktime);
    try environment.addBuiltinExportComptime(m, "wcsftime", misc.stub_ignore_i32);
}

// =============================================================================
// Faithful implementations — Tier 6: C++ Exception Handling
// =============================================================================

// _CxxThrowException: C++ throw implementation
// This is called when C++ code does `throw expr;`
// Since we can't handle C++ exceptions, we log and terminate
fn stub_CxxThrowException(pExceptionObject: usize, pThrowInfo: usize) callconv(.c) noreturn {
    _ = pThrowInfo;
    if (trace.enable_tracing) trace.print("MSVCRT: _CxxThrowException(object={x}) — terminating\n", .{pExceptionObject});
    process.stub_exit(3);
}

// ?terminate@@YAXXZ: C++ std::terminate()
// Called when exception handling fails or unexpected exception
fn stub_terminate() callconv(.c) noreturn {
    if (trace.enable_tracing) trace.print("MSVCRT: terminate() — aborting\n", .{});
    process.stub_exit(3);
}
