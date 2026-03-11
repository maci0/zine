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
    try environment.addBuiltinExport(m, "__p__timezone", @intFromPtr(&process.stub_p_timezone));
    try environment.addBuiltinExport(m, "__p__daylight", @intFromPtr(&process.stub_p_daylight));
    try environment.addBuiltinExport(m, "__p__tzname", @intFromPtr(&process.stub_p_tzname));
    try environment.addBuiltinExport(m, "_adjust_fdiv", @intFromPtr(&msvcrt_adjust_fdiv));
    try environment.addBuiltinExport(m, "__mb_cur_max", @intFromPtr(&msvcrt_mb_cur_max));
    try environment.addBuiltinExport(m, "_iob", @intFromPtr(&io.msvcrt_iob));
    try environment.addBuiltinExport(m, "_acmdln", @intFromPtr(&msvcrt_acmdln));
    try environment.addBuiltinExport(m, "_wcmdln", @intFromPtr(&msvcrt_wcmdln));

    // Process & Startup
    try environment.addBuiltinExport(m, "__wgetmainargs", @intFromPtr(&process.stub_wgetmainargs));
    try environment.addBuiltinExport(m, "__getmainargs", @intFromPtr(&process.stub_getmainargs));
    try environment.addBuiltinExport(m, "exit", @intFromPtr(&process.stub_exit));
    try environment.addBuiltinExport(m, "_exit", @intFromPtr(&process.stub_exit));
    try environment.addBuiltinExport(m, "_XcptFilter", @intFromPtr(&process.stub_XcptFilter));
    try environment.addBuiltinExport(m, "_initterm", @intFromPtr(&process.stub_initterm));
    try environment.addBuiltinExport(m, "_controlfp", @intFromPtr(&math.stub_controlfp));
    try environment.addBuiltinExport(m, "__set_app_type", @intFromPtr(&process.stub_set_app_type));
    try environment.addBuiltinExport(m, "__setusermatherr", @intFromPtr(&math.stub_setusermatherr));
    try environment.addBuiltinExport(m, "__p__fmode", @intFromPtr(&process.stub_p_fmode));
    try environment.addBuiltinExport(m, "__p__commode", @intFromPtr(&process.stub_p_commode));
    try environment.addBuiltinExport(m, "__p___initenv", @intFromPtr(&process.stub_p_initenv));
    try environment.addBuiltinExport(m, "__p__pgmptr", @intFromPtr(&process.stub_p_pgmptr));
    try environment.addBuiltinExport(m, "__p___argc", @intFromPtr(&process.stub_p_argc));
    try environment.addBuiltinExport(m, "__p___argv", @intFromPtr(&process.stub_p_argv));
    try environment.addBuiltinExport(m, "__p__environ", @intFromPtr(&process.stub_p_environ));
    try environment.addBuiltinExport(m, "__p__wenviron", @intFromPtr(&process.stub_p_environ));
    try environment.addBuiltinExport(m, "_spawnvp", @intFromPtr(&process.stub_spawnvp));
    try environment.addBuiltinExport(m, "_spawnv", @intFromPtr(&process.stub_spawnvp));
    try environment.addBuiltinExport(m, "signal", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "__dllonexit", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_onexit", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_purecall", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_seh_longjmp_unwind", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "__CxxFrameHandler", @intFromPtr(&misc.stub_ignore_i32));

    // Memory
    try environment.addBuiltinExport(m, "malloc", @intFromPtr(&mem.stub_malloc));
    try environment.addBuiltinExport(m, "calloc", @intFromPtr(&mem.stub_calloc));
    try environment.addBuiltinExport(m, "realloc", @intFromPtr(&mem.stub_realloc));
    try environment.addBuiltinExport(m, "free", @intFromPtr(&mem.stub_free));
    try environment.addBuiltinExport(m, "??2@YAPAXI@Z", @intFromPtr(&mem.stub_malloc));
    try environment.addBuiltinExport(m, "??3@YAXPAX@Z", @intFromPtr(&mem.stub_free));

    // ANSI String & Memory
    try environment.addBuiltinExport(m, "strlen", @intFromPtr(&string.stub_strlen));
    try environment.addBuiltinExport(m, "strcpy", @intFromPtr(&string.stub_strcpy));
    try environment.addBuiltinExport(m, "strncpy", @intFromPtr(&string.stub_strncpy));
    try environment.addBuiltinExport(m, "strcat", @intFromPtr(&string.stub_strcat));
    try environment.addBuiltinExport(m, "strncat", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "strcmp", @intFromPtr(&string.stub_strcmp));
    try environment.addBuiltinExport(m, "strncmp", @intFromPtr(&string.stub_strncmp));
    try environment.addBuiltinExport(m, "_stricmp", @intFromPtr(&string.stub_stricmp));
    try environment.addBuiltinExport(m, "_strcmpi", @intFromPtr(&string.stub_stricmp));
    try environment.addBuiltinExport(m, "_strnicmp", @intFromPtr(&string.stub_strnicmp));
    try environment.addBuiltinExport(m, "strchr", @intFromPtr(&string.stub_strchr));
    try environment.addBuiltinExport(m, "strrchr", @intFromPtr(&string.stub_strrchr));
    try environment.addBuiltinExport(m, "strstr", @intFromPtr(&string.stub_strstr));
    try environment.addBuiltinExport(m, "strpbrk", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "strcspn", @intFromPtr(&string.stub_strcspn));
    try environment.addBuiltinExport(m, "strtok", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_strdup", @intFromPtr(&string.stub_strdup));
    try environment.addBuiltinExport(m, "_wcsdup", @intFromPtr(&string.stub_wcsdup));
    try environment.addBuiltinExport(m, "memset", @intFromPtr(&mem.stub_memset));
    try environment.addBuiltinExport(m, "memcpy", @intFromPtr(&mem.stub_memcpy));
    try environment.addBuiltinExport(m, "memmove", @intFromPtr(&mem.stub_memmove));
    try environment.addBuiltinExport(m, "memcmp", @intFromPtr(&string.stub_strncmp));
    try environment.addBuiltinExport(m, "_memicmp", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "atoi", @intFromPtr(&string.stub_atoi));
    try environment.addBuiltinExport(m, "atol", @intFromPtr(&string.stub_atoi));
    try environment.addBuiltinExport(m, "_itoa", @intFromPtr(&string.stub_itoa));
    try environment.addBuiltinExport(m, "_ltoa", @intFromPtr(&string.stub_itoa));
    try environment.addBuiltinExport(m, "_ultoa", @intFromPtr(&string.stub_itoa));
    try environment.addBuiltinExport(m, "strtoul", @intFromPtr(&string.stub_strtoul));
    try environment.addBuiltinExport(m, "strtol", @intFromPtr(&string.stub_strtol));
    try environment.addBuiltinExport(m, "strerror", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_strerror", @intFromPtr(&misc.stub_ignore_ptr));

    // Wide String
    try environment.addBuiltinExport(m, "wcslen", @intFromPtr(&string.stub_wcslen));
    try environment.addBuiltinExport(m, "wcscpy", @intFromPtr(&string.stub_wcscpy));
    try environment.addBuiltinExport(m, "wcsncpy", @intFromPtr(&string.stub_wcsncpy));
    try environment.addBuiltinExport(m, "wcscat", @intFromPtr(&string.stub_wcscat));
    try environment.addBuiltinExport(m, "wcscmp", @intFromPtr(&string.stub_wcscmp));
    try environment.addBuiltinExport(m, "wcsncmp", @intFromPtr(&string.stub_wcsncmp));
    try environment.addBuiltinExport(m, "_wcsicmp", @intFromPtr(&string.stub_wcsicmp));
    try environment.addBuiltinExport(m, "_wcsnicmp", @intFromPtr(&string.stub_wcsnicmp));
    try environment.addBuiltinExport(m, "wcschr", @intFromPtr(&string.stub_wcschr));
    try environment.addBuiltinExport(m, "_wcsupr", @intFromPtr(&string.stub_wcsupr));
    try environment.addBuiltinExport(m, "wcstol", @intFromPtr(&string.stub_wcstol));
    try environment.addBuiltinExport(m, "_wtoi", @intFromPtr(&string.stub_wtoi));
    try environment.addBuiltinExport(m, "_wtol", @intFromPtr(&string.stub_wtoi));

    // File I/O
    try environment.addBuiltinExport(m, "_access", @intFromPtr(&misc.stub_access));
    try environment.addBuiltinExport(m, "_getcwd", @intFromPtr(&misc.stub_getcwd));
    try environment.addBuiltinExport(m, "_sopen", @intFromPtr(&misc.stub_sopen));
    try environment.addBuiltinExport(m, "_read", @intFromPtr(&misc.stub_read));
    try environment.addBuiltinExport(m, "_write", @intFromPtr(&misc.stub_write));
    try environment.addBuiltinExport(m, "_lseek", @intFromPtr(&misc.stub_lseek));
    try environment.addBuiltinExport(m, "_close", @intFromPtr(&misc.stub_close));
    try environment.addBuiltinExport(m, "_tell", @intFromPtr(&misc.stub_tell));
    try environment.addBuiltinExport(m, "_chsize", @intFromPtr(&misc.stub_chsize));
    try environment.addBuiltinExport(m, "_filelength", @intFromPtr(&misc.stub_filelength));
    try environment.addBuiltinExport(m, "_fstat", @intFromPtr(&misc.stub_fstat));
    try environment.addBuiltinExport(m, "_getch", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_stat", @intFromPtr(&misc.stub_stat));
    try environment.addBuiltinExport(m, "_get_osfhandle", @intFromPtr(&misc.stub_get_osfhandle));
    try environment.addBuiltinExport(m, "_open_osfhandle", @intFromPtr(&misc.stub_open_osfhandle));
    try environment.addBuiltinExport(m, "_isatty", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_unlink", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_dup", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_dup2", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_chdir", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_chdrive", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "remove", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "rename", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_searchenv", @intFromPtr(&misc.stub_searchenv));
    try environment.addBuiltinExport(m, "_setmode", @intFromPtr(&io.stub_setmode));

    // Stdio forward to io.zig
    try environment.addBuiltinExport(m, "fopen", @intFromPtr(&io.stub_fopen));
    try environment.addBuiltinExport(m, "fclose", @intFromPtr(&io.stub_fclose));
    try environment.addBuiltinExport(m, "fread", @intFromPtr(&io.stub_fread));
    try environment.addBuiltinExport(m, "fwrite", @intFromPtr(&io.stub_fwrite));
    try environment.addBuiltinExport(m, "fseek", @intFromPtr(&io.stub_fseek));
    try environment.addBuiltinExport(m, "ftell", @intFromPtr(&io.stub_ftell));
    try environment.addBuiltinExport(m, "fgetc", @intFromPtr(&io.stub_fgetc));
    try environment.addBuiltinExport(m, "getc", @intFromPtr(&io.stub_fgetc));
    try environment.addBuiltinExport(m, "getchar", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "putchar", @intFromPtr(&io.stub_putchar));
    try environment.addBuiltinExport(m, "fputc", @intFromPtr(&io.stub_fputc));
    try environment.addBuiltinExport(m, "putc", @intFromPtr(&io.stub_fputc));
    try environment.addBuiltinExport(m, "puts", @intFromPtr(&misc.stub_puts));
    try environment.addBuiltinExport(m, "fputs", @intFromPtr(&misc.stub_fputs));
    try environment.addBuiltinExport(m, "ungetc", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "fflush", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_flushall", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "setvbuf", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "rewind", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "freopen", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "fgets", @intFromPtr(&io.stub_fgets));
    try environment.addBuiltinExport(m, "_fsopen", @intFromPtr(&io.stub_fsopen));
    try environment.addBuiltinExport(m, "_fcloseall", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "__p__iob", @intFromPtr(&io.stub_p_iob));

    // Formatted I/O
    try environment.addBuiltinExport(m, "printf", @intFromPtr(&misc.stub_printf));
    try environment.addBuiltinExport(m, "vprintf", @intFromPtr(&misc.stub_vprintf));
    try environment.addBuiltinExport(m, "fprintf", @intFromPtr(&io.stub_fprintf));
    try environment.addBuiltinExport(m, "fwprintf", @intFromPtr(&io.stub_fwprintf));
    try environment.addBuiltinExport(m, "vfprintf", @intFromPtr(&misc.stub_vfprintf));
    try environment.addBuiltinExport(m, "_vsnprintf", @intFromPtr(&misc.stub_vsnprintf));
    try environment.addBuiltinExport(m, "_snprintf", @intFromPtr(&misc.stub_snprintf));
    try environment.addBuiltinExport(m, "sprintf", @intFromPtr(&misc.stub_sprintf));
    try environment.addBuiltinExport(m, "swprintf", @intFromPtr(&misc.stub_swprintf));
    try environment.addBuiltinExport(m, "sscanf", @intFromPtr(&misc.stub_sscanf));
    try environment.addBuiltinExport(m, "_tempnam", @intFromPtr(&misc.stub_tempnam));
    try environment.addBuiltinExport(m, "tmpfile", @intFromPtr(&misc.stub_ignore_ptr));

    // Char Types & Locale
    try environment.addBuiltinExport(m, "_pctype", @intFromPtr(&msvcrt_pctype_ptr));
    try environment.addBuiltinExport(m, "__p__pctype", @intFromPtr(&string.stub_p_pctype));
    try environment.addBuiltinExport(m, "isalnum", @intFromPtr(&string.stub_isalnum));
    try environment.addBuiltinExport(m, "isalpha", @intFromPtr(&string.stub_isalpha));
    try environment.addBuiltinExport(m, "isdigit", @intFromPtr(&string.stub_isdigit));
    try environment.addBuiltinExport(m, "isxdigit", @intFromPtr(&string.stub_isxdigit));
    try environment.addBuiltinExport(m, "isspace", @intFromPtr(&string.stub_isspace));
    try environment.addBuiltinExport(m, "isprint", @intFromPtr(&string.stub_isprint));
    try environment.addBuiltinExport(m, "ispunct", @intFromPtr(&string.stub_ispunct));
    try environment.addBuiltinExport(m, "isupper", @intFromPtr(&string.stub_isupper));
    try environment.addBuiltinExport(m, "islower", @intFromPtr(&string.stub_islower));
    try environment.addBuiltinExport(m, "_open", @intFromPtr(&misc.stub_sopen)); // _open is basically _sopen with 0 shflags
    try environment.addBuiltinExport(m, "tolower", @intFromPtr(&string.stub_tolower));
    try environment.addBuiltinExport(m, "toupper", @intFromPtr(&string.stub_toupper));
    try environment.addBuiltinExport(m, "iswctype", @intFromPtr(&string.stub_iswctype));
    try environment.addBuiltinExport(m, "towlower", @intFromPtr(&string.stub_towlower));
    try environment.addBuiltinExport(m, "towupper", @intFromPtr(&string.stub_towupper));
    try environment.addBuiltinExport(m, "mbtowc", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "setlocale", @intFromPtr(&misc.stub_setlocale));
    try environment.addBuiltinExport(m, "_isctype", @intFromPtr(&string.stub_isctype));

    // Multi-byte String
    try environment.addBuiltinExport(m, "_ismbcspace", @intFromPtr(&string.stub_ismbcspace));
    try environment.addBuiltinExport(m, "_ismbcalnum", @intFromPtr(&string.stub_isalnum));
    try environment.addBuiltinExport(m, "_ismbcdigit", @intFromPtr(&string.stub_isdigit));
    try environment.addBuiltinExport(m, "_ismbcalpha", @intFromPtr(&string.stub_isalpha));
    try environment.addBuiltinExport(m, "_ismbblead", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_mbscspn", @intFromPtr(&string.stub_strcspn));
    try environment.addBuiltinExport(m, "_mbsspn", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_mbsstr", @intFromPtr(&string.stub_strstr));
    try environment.addBuiltinExport(m, "_mbsinc", @intFromPtr(&string.stub_mbsinc));
    try environment.addBuiltinExport(m, "_mbschr", @intFromPtr(&string.stub_strchr));
    try environment.addBuiltinExport(m, "_mbsrchr", @intFromPtr(&string.stub_strrchr));
    try environment.addBuiltinExport(m, "_mbsncmp", @intFromPtr(&string.stub_strncmp));
    try environment.addBuiltinExport(m, "_mbscmp", @intFromPtr(&string.stub_strcmp));
    try environment.addBuiltinExport(m, "_mbsicmp", @intFromPtr(&string.stub_mbsicmp));
    try environment.addBuiltinExport(m, "_mbsnbcpy", @intFromPtr(&string.stub_strncpy));
    try environment.addBuiltinExport(m, "_mbsnbcmp", @intFromPtr(&string.stub_strncmp));
    try environment.addBuiltinExport(m, "_mbsnbicmp", @intFromPtr(&string.stub_strnicmp));
    try environment.addBuiltinExport(m, "_mbspbrk", @intFromPtr(&string.stub_strpbrk));
    try environment.addBuiltinExport(m, "_mbstok", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_mbccpy", @intFromPtr(&string.stub_mbccpy));
    try environment.addBuiltinExport(m, "_mbclen", @intFromPtr(&string.stub_mbclen));
    try environment.addBuiltinExport(m, "_mbsdec", @intFromPtr(&string.stub_mbsdec));
    try environment.addBuiltinExport(m, "_mbstrlen", @intFromPtr(&string.stub_strlen));
    try environment.addBuiltinExport(m, "_mbctolower", @intFromPtr(&string.stub_tolower));
    try environment.addBuiltinExport(m, "_mbctoupper", @intFromPtr(&string.stub_toupper));
    try environment.addBuiltinExport(m, "_mbctype", @intFromPtr(&msvcrt_mbctype[0]));
    try environment.addBuiltinExport(m, "_mbslwr", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_mbsupr", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_strupr", @intFromPtr(&misc.stub_strupr));
    try environment.addBuiltinExport(m, "_setmbcp", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_getmbcp", @intFromPtr(&misc.stub_ignore_i32));

    // Jmp
    try environment.addBuiltinExport(m, "_EH_prolog", @intFromPtr(misc.stub_EH_prolog));
    try environment.addBuiltinExport(m, "_setjmp3", @intFromPtr(misc.stub_setjmp3));
    try environment.addBuiltinExport(m, "longjmp", @intFromPtr(misc.stub_longjmp));

    // Misc
    try environment.addBuiltinExport(m, "qsort", @intFromPtr(&misc.stub_qsort));
    try environment.addBuiltinExport(m, "bsearch", @intFromPtr(&misc.stub_bsearch));
    try environment.addBuiltinExport(m, "tmpnam", @intFromPtr(&misc.stub_tempnam));
    try environment.addBuiltinExport(m, "_tempnam", @intFromPtr(&misc.stub_tempnam));
    try environment.addBuiltinExport(m, "_mktemp", @intFromPtr(&misc.stub_mktemp));
    try environment.addBuiltinExport(m, "_splitpath", @intFromPtr(&misc.stub_splitpath));
    try environment.addBuiltinExport(m, "_makepath", @intFromPtr(&misc.stub_makepath));
    try environment.addBuiltinExport(m, "_fullpath", @intFromPtr(&misc.stub_fullpath));
    try environment.addBuiltinExport(m, "getenv", @intFromPtr(&process.stub_getenv));
    try environment.addBuiltinExport(m, "_putenv", @intFromPtr(&process.stub_putenv));
    try environment.addBuiltinExport(m, "_errno", @intFromPtr(&misc.stub_errno));
    try environment.addBuiltinExport(m, "__doserrno", @intFromPtr(&misc.stub_errno));
    try environment.addBuiltinExport(m, "_except_handler3", @intFromPtr(&misc.stub_except_handler3));
    try environment.addBuiltinExport(m, "_ftime", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "time", @intFromPtr(&misc.stub_time));
    try environment.addBuiltinExport(m, "localtime", @intFromPtr(&misc.stub_localtime));
    try environment.addBuiltinExport(m, "_tzset", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "ctime", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "rand", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "srand", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "ceil", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "floor", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_ftol", @intFromPtr(math.stub_ftol));
    try environment.addBuiltinExport(m, "_flsbuf", @intFromPtr(&io.stub_fputc));
    try environment.addBuiltinExport(m, "_filbuf", @intFromPtr(&io.stub_fgetc));
    try environment.addBuiltinExport(m, "_utime", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_futime", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_osver", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "__unDName", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_atoldbl", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_adj_fdiv_r", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_findfirst", @intFromPtr(&misc.stub_findfirst));
    try environment.addBuiltinExport(m, "_findnext", @intFromPtr(&misc.stub_findnext));
    try environment.addBuiltinExport(m, "_findclose", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "__p___wargv", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "__p__wpgmptr", @intFromPtr(&misc.stub_ignore_ptr));

    // --- Remaining MSVCRT stubs for 100% win2k coverage ---
    try environment.addBuiltinExport(m, "??1type_info@@UAE@XZ", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_CxxThrowException", @intFromPtr(&stub_CxxThrowException));
    try environment.addBuiltinExport(m, "?terminate@@YAXXZ", @intFromPtr(&stub_terminate));
    try environment.addBuiltinExport(m, "_wcsrev", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "wcsspn", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_snwprintf", @intFromPtr(&misc.stub_snprintf));
    try environment.addBuiltinExport(m, "_pclose", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "_popen", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "iswspace", @intFromPtr(&string.stub_iswctype));
    try environment.addBuiltinExport(m, "iswdigit", @intFromPtr(&string.stub_iswctype));
    try environment.addBuiltinExport(m, "wcsrchr", @intFromPtr(&string.stub_wcsrchr));
    try environment.addBuiltinExport(m, "iswalpha", @intFromPtr(&string.stub_iswctype));
    try environment.addBuiltinExport(m, "wcstoul", @intFromPtr(&string.stub_wcstol));
    try environment.addBuiltinExport(m, "iswxdigit", @intFromPtr(&string.stub_iswctype));
    try environment.addBuiltinExport(m, "_pipe", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "swscanf", @intFromPtr(&misc.stub_sscanf));
    try environment.addBuiltinExport(m, "wcsstr", @intFromPtr(&string.stub_wcsstr));
    try environment.addBuiltinExport(m, "_vsnwprintf", @intFromPtr(&misc.stub_vsnprintf));
    try environment.addBuiltinExport(m, "_wcslwr", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_getdcwd", @intFromPtr(&misc.stub_getcwd));
    try environment.addBuiltinExport(m, "_itow", @intFromPtr(&string.stub_itoa));
    try environment.addBuiltinExport(m, "wcstok", @intFromPtr(&misc.stub_ignore_ptr));
    try environment.addBuiltinExport(m, "_ltow", @intFromPtr(&string.stub_itoa));
    try environment.addBuiltinExport(m, "_wsplitpath", @intFromPtr(&misc.stub_splitpath));
    try environment.addBuiltinExport(m, "wcstod", @intFromPtr(&misc.stub_ignore_i32));
    try environment.addBuiltinExport(m, "wcscoll", @intFromPtr(&string.stub_wcscmp));
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
