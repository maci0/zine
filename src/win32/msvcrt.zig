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
pub var msvcrt_acmdln_guest: usize = 0; // Guest VA on WASM
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
const path = @import("msvcrt/path.zig");
const except = @import("msvcrt/except.zig");
const time_mod = @import("msvcrt/time.zig");
const file = @import("msvcrt/file.zig");
const fmt = @import("msvcrt/fmt.zig");

pub fn register(environment: *env.Environment) !void {
    string.init_pctype();
    // Initialize data export pointers to defaults (can't do at comptime)
    if (msvcrt_acmdln == 0) msvcrt_acmdln = @intFromPtr(&acmdln_default);
    if (msvcrt_wcmdln == 0) msvcrt_wcmdln = @intFromPtr(&wcmdln_default);
    const m = "MSVCRT.dll";

    // Data Exports
    try environment.addBuiltinDataExport(m, "_timezone", @intFromPtr(&msvcrt_timezone), @sizeOf(@TypeOf(msvcrt_timezone)));
    try environment.addBuiltinDataExport(m, "_daylight", @intFromPtr(&msvcrt_daylight), @sizeOf(@TypeOf(msvcrt_daylight)));
    try environment.addBuiltinDataExport(m, "_tzname", @intFromPtr(&msvcrt_tzname), @sizeOf(@TypeOf(msvcrt_tzname)));
    try environment.addBuiltinExportComptime(m, "__p__timezone", process.p_timezone);
    try environment.addBuiltinExportComptime(m, "__p__daylight", process.p_daylight);
    try environment.addBuiltinExportComptime(m, "__p__tzname", process.p_tzname);
    try environment.addBuiltinDataExport(m, "_adjust_fdiv", @intFromPtr(&msvcrt_adjust_fdiv), @sizeOf(@TypeOf(msvcrt_adjust_fdiv)));
    try environment.addBuiltinDataExport(m, "__mb_cur_max", @intFromPtr(&msvcrt_mb_cur_max), @sizeOf(@TypeOf(msvcrt_mb_cur_max)));
    try environment.addBuiltinDataExport(m, "_iob", @intFromPtr(&io.msvcrt_iob), @sizeOf(@TypeOf(io.msvcrt_iob)));
    try environment.addBuiltinDataExport(m, "_acmdln", @intFromPtr(&msvcrt_acmdln), @sizeOf(@TypeOf(msvcrt_acmdln)));
    try environment.addBuiltinDataExport(m, "_wcmdln", @intFromPtr(&msvcrt_wcmdln), @sizeOf(@TypeOf(msvcrt_wcmdln)));

    // Process & Startup
    try environment.addBuiltinExportComptime(m, "__wgetmainargs", process.wgetmainargs);
    try environment.addBuiltinExportComptime(m, "__getmainargs", process.getmainargs);
    try environment.addBuiltinExportComptime(m, "exit", process.exit);
    try environment.addBuiltinExportComptime(m, "_exit", process.exit);
    try environment.addBuiltinExportComptime(m, "_XcptFilter", process.stub_XcptFilter);
    try environment.addBuiltinExportComptime(m, "_initterm", process.initterm);
    try environment.addBuiltinExportComptime(m, "_controlfp", math.controlfp);
    try environment.addBuiltinExportComptime(m, "__set_app_type", process.stub_set_app_type);
    try environment.addBuiltinExportComptime(m, "__setusermatherr", math.stub_setusermatherr);
    try environment.addBuiltinExportComptime(m, "__p__fmode", process.p_fmode);
    try environment.addBuiltinExportComptime(m, "__p__commode", process.p_commode);
    try environment.addBuiltinExportComptime(m, "__p___initenv", process.p_initenv);
    try environment.addBuiltinExportComptime(m, "__p__pgmptr", process.p_pgmptr);
    try environment.addBuiltinExportComptime(m, "__p___argc", process.p_argc);
    try environment.addBuiltinExportComptime(m, "__p___argv", process.p_argv);
    try environment.addBuiltinExportComptime(m, "__p__environ", process.p_environ);
    try environment.addBuiltinExportComptime(m, "__p__wenviron", process.p_environ);
    try environment.addBuiltinExportComptime(m, "_spawnvp", process.spawnvp);
    try environment.addBuiltinExportComptime(m, "_spawnv", process.spawnvp);
    try environment.addBuiltinExportComptime(m, "signal", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "__dllonexit", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_onexit", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_purecall", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_seh_longjmp_unwind", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "__CxxFrameHandler", misc.stub_ignore_i32);

    // Memory
    try environment.addBuiltinExportComptime(m, "malloc", mem.malloc);
    try environment.addBuiltinExportComptime(m, "calloc", mem.calloc);
    try environment.addBuiltinExportComptime(m, "realloc", mem.realloc);
    try environment.addBuiltinExportComptime(m, "free", mem.stub_free);
    try environment.addBuiltinExportComptime(m, "??2@YAPAXI@Z", mem.malloc);
    try environment.addBuiltinExportComptime(m, "??3@YAXPAX@Z", mem.stub_free);

    // ANSI String & Memory
    try environment.addBuiltinExportComptime(m, "strlen", string.strlen);
    try environment.addBuiltinExportComptime(m, "strcpy", string.strcpy);
    try environment.addBuiltinExportComptime(m, "strncpy", string.strncpy);
    try environment.addBuiltinExportComptime(m, "strcat", string.strcat);
    try environment.addBuiltinExportComptime(m, "strncat", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "strcmp", string.strcmp);
    try environment.addBuiltinExportComptime(m, "strncmp", string.strncmp);
    try environment.addBuiltinExportComptime(m, "_stricmp", string.stricmp);
    try environment.addBuiltinExportComptime(m, "_strcmpi", string.stricmp);
    try environment.addBuiltinExportComptime(m, "_strnicmp", string.strnicmp);
    try environment.addBuiltinExportComptime(m, "strchr", string.strchr);
    try environment.addBuiltinExportComptime(m, "strrchr", string.strrchr);
    try environment.addBuiltinExportComptime(m, "strstr", string.strstr);
    try environment.addBuiltinExportComptime(m, "strpbrk", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "strcspn", string.strcspn);
    try environment.addBuiltinExportComptime(m, "strtok", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_strdup", string.strdup);
    try environment.addBuiltinExportComptime(m, "_wcsdup", string.wcsdup);
    try environment.addBuiltinExportComptime(m, "memset", mem.memset);
    try environment.addBuiltinExportComptime(m, "memcpy", mem.memcpy);
    try environment.addBuiltinExportComptime(m, "memmove", mem.memmove);
    try environment.addBuiltinExportComptime(m, "memcmp", string.strncmp);
    try environment.addBuiltinExportComptime(m, "_memicmp", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "atoi", string.atoi);
    try environment.addBuiltinExportComptime(m, "atol", string.atoi);
    try environment.addBuiltinExportComptime(m, "_itoa", string.itoa);
    try environment.addBuiltinExportComptime(m, "_ltoa", string.itoa);
    try environment.addBuiltinExportComptime(m, "_ultoa", string.itoa);
    try environment.addBuiltinExportComptime(m, "strtoul", string.strtoul);
    try environment.addBuiltinExportComptime(m, "strtol", string.strtol);
    try environment.addBuiltinExportComptime(m, "strerror", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_strerror", misc.stub_ignore_ptr);

    // Wide String
    try environment.addBuiltinExportComptime(m, "wcslen", string.wcslen);
    try environment.addBuiltinExportComptime(m, "wcscpy", string.wcscpy);
    try environment.addBuiltinExportComptime(m, "wcsncpy", string.wcsncpy);
    try environment.addBuiltinExportComptime(m, "wcscat", string.wcscat);
    try environment.addBuiltinExportComptime(m, "wcscmp", string.wcscmp);
    try environment.addBuiltinExportComptime(m, "wcsncmp", string.wcsncmp);
    try environment.addBuiltinExportComptime(m, "_wcsicmp", string.wcsicmp);
    try environment.addBuiltinExportComptime(m, "_wcsnicmp", string.wcsnicmp);
    try environment.addBuiltinExportComptime(m, "wcschr", string.wcschr);
    try environment.addBuiltinExportComptime(m, "_wcsupr", string.wcsupr);
    try environment.addBuiltinExportComptime(m, "wcstol", string.wcstol);
    try environment.addBuiltinExportComptime(m, "_wtoi", string.wtoi);
    try environment.addBuiltinExportComptime(m, "_wtol", string.wtoi);

    // File I/O (fd-based)
    try environment.addBuiltinExportComptime(m, "_access", file.access);
    try environment.addBuiltinExportComptime(m, "_getcwd", path.getcwd);
    try environment.addBuiltinExportComptime(m, "_sopen", file.sopen);
    try environment.addBuiltinExportComptime(m, "_read", file.read);
    try environment.addBuiltinExportComptime(m, "_write", file.write);
    try environment.addBuiltinExportComptime(m, "_lseek", file.lseek);
    try environment.addBuiltinExportComptime(m, "_close", file.close);
    try environment.addBuiltinExportComptime(m, "_tell", file.tell);
    try environment.addBuiltinExportComptime(m, "_chsize", file.chsize);
    try environment.addBuiltinExportComptime(m, "_filelength", file.filelength);
    try environment.addBuiltinExportComptime(m, "_fstat", file.fstat);
    try environment.addBuiltinExportComptime(m, "_getch", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_stat", file.stat);
    try environment.addBuiltinExportComptime(m, "_get_osfhandle", file.get_osfhandle);
    try environment.addBuiltinExportComptime(m, "_open_osfhandle", file.open_osfhandle);
    try environment.addBuiltinExportComptime(m, "_isatty", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_unlink", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_dup", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_dup2", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_chdir", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_chdrive", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "remove", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "rename", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_searchenv", path.searchenv);
    try environment.addBuiltinExportComptime(m, "_setmode", io.stub_setmode);

    // Stdio forward to io.zig
    try environment.addBuiltinExportComptime(m, "fopen", io.fopen);
    try environment.addBuiltinExportComptime(m, "fclose", io.fclose);
    try environment.addBuiltinExportComptime(m, "fread", io.fread);
    try environment.addBuiltinExportComptime(m, "fwrite", io.fwrite);
    try environment.addBuiltinExportComptime(m, "fseek", io.fseek);
    try environment.addBuiltinExportComptime(m, "ftell", io.ftell);
    try environment.addBuiltinExportComptime(m, "fgetc", io.fgetc);
    try environment.addBuiltinExportComptime(m, "getc", io.fgetc);
    try environment.addBuiltinExportComptime(m, "getchar", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "putchar", io.putchar);
    try environment.addBuiltinExportComptime(m, "fputc", io.fputc);
    try environment.addBuiltinExportComptime(m, "putc", io.fputc);
    try environment.addBuiltinExportComptime(m, "puts", fmt.puts);
    try environment.addBuiltinExportComptime(m, "fputs", fmt.fputs);
    try environment.addBuiltinExportComptime(m, "ungetc", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "fflush", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_flushall", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "setvbuf", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "rewind", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "freopen", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "fgets", io.fgets);
    try environment.addBuiltinExportComptime(m, "_fsopen", io.fsopen);
    try environment.addBuiltinExportComptime(m, "_fcloseall", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "__p__iob", io.p_iob);

    // Formatted I/O — variadic functions use addBuiltinExportComptimeVA
    // which passes a translated guest stack va_list as the last argument.
    try environment.addBuiltinExportComptimeVA(m, "printf", fmt.printf, 1);
    try environment.addBuiltinExportComptime(m, "vprintf", fmt.vprintf);
    try environment.addBuiltinExportComptimeVA(m, "fprintf", io.fprintf, 2);
    try environment.addBuiltinExportComptime(m, "fwprintf", io.fwprintf);
    try environment.addBuiltinExportComptime(m, "vfprintf", fmt.vfprintf);
    try environment.addBuiltinExportComptime(m, "_vsnprintf", fmt.vsnprintf);
    try environment.addBuiltinExportComptimeVA(m, "_snprintf", fmt.snprintf, 3);
    try environment.addBuiltinExportComptimeVA(m, "sprintf", fmt.sprintf, 2);
    try environment.addBuiltinExportComptimeVA(m, "swprintf", fmt.swprintf, 2);
    try environment.addBuiltinExportComptimeVA(m, "sscanf", fmt.sscanf, 2);
    try environment.addBuiltinExportComptime(m, "_tempnam", path.tempnam);
    try environment.addBuiltinExportComptime(m, "tmpfile", misc.stub_ignore_ptr);

    // Char Types & Locale
    try environment.addBuiltinDataExport(m, "_pctype", @intFromPtr(&msvcrt_pctype_ptr), @sizeOf(@TypeOf(msvcrt_pctype_ptr)));
    try environment.addBuiltinExportComptime(m, "__p__pctype", string.p_pctype);
    try environment.addBuiltinExportComptime(m, "isalnum", string.isalnum);
    try environment.addBuiltinExportComptime(m, "isalpha", string.isalpha);
    try environment.addBuiltinExportComptime(m, "isdigit", string.isdigit);
    try environment.addBuiltinExportComptime(m, "isxdigit", string.isxdigit);
    try environment.addBuiltinExportComptime(m, "isspace", string.isspace);
    try environment.addBuiltinExportComptime(m, "isprint", string.isprint);
    try environment.addBuiltinExportComptime(m, "ispunct", string.ispunct);
    try environment.addBuiltinExportComptime(m, "isupper", string.isupper);
    try environment.addBuiltinExportComptime(m, "islower", string.islower);
    try environment.addBuiltinExportComptime(m, "_open", file.sopen); // _open is basically _sopen with 0 shflags
    try environment.addBuiltinExportComptime(m, "tolower", string.tolower);
    try environment.addBuiltinExportComptime(m, "toupper", string.toupper);
    try environment.addBuiltinExportComptime(m, "iswctype", string.iswctype);
    try environment.addBuiltinExportComptime(m, "towlower", string.towlower);
    try environment.addBuiltinExportComptime(m, "towupper", string.towupper);
    try environment.addBuiltinExportComptime(m, "mbtowc", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "setlocale", misc.setlocale);
    try environment.addBuiltinExportComptime(m, "_isctype", string.isctype);

    // Multi-byte String
    try environment.addBuiltinExportComptime(m, "_ismbcspace", string.ismbcspace);
    try environment.addBuiltinExportComptime(m, "_ismbcalnum", string.isalnum);
    try environment.addBuiltinExportComptime(m, "_ismbcdigit", string.isdigit);
    try environment.addBuiltinExportComptime(m, "_ismbcalpha", string.isalpha);
    try environment.addBuiltinExportComptime(m, "_ismbblead", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_mbscspn", string.strcspn);
    try environment.addBuiltinExportComptime(m, "_mbsspn", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_mbsstr", string.strstr);
    try environment.addBuiltinExportComptime(m, "_mbsinc", string.mbsinc);
    try environment.addBuiltinExportComptime(m, "_mbschr", string.strchr);
    try environment.addBuiltinExportComptime(m, "_mbsrchr", string.strrchr);
    try environment.addBuiltinExportComptime(m, "_mbsncmp", string.strncmp);
    try environment.addBuiltinExportComptime(m, "_mbscmp", string.strcmp);
    try environment.addBuiltinExportComptime(m, "_mbsicmp", string.mbsicmp);
    try environment.addBuiltinExportComptime(m, "_mbsnbcpy", string.strncpy);
    try environment.addBuiltinExportComptime(m, "_mbsnbcmp", string.strncmp);
    try environment.addBuiltinExportComptime(m, "_mbsnbicmp", string.strnicmp);
    try environment.addBuiltinExportComptime(m, "_mbspbrk", string.strpbrk);
    try environment.addBuiltinExportComptime(m, "_mbstok", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_mbccpy", string.mbccpy);
    try environment.addBuiltinExportComptime(m, "_mbclen", string.mbclen);
    try environment.addBuiltinExportComptime(m, "_mbsdec", string.mbsdec);
    try environment.addBuiltinExportComptime(m, "_mbstrlen", string.strlen);
    try environment.addBuiltinExportComptime(m, "_mbctolower", string.tolower);
    try environment.addBuiltinExportComptime(m, "_mbctoupper", string.toupper);
    try environment.addBuiltinDataExport(m, "_mbctype", @intFromPtr(&msvcrt_mbctype), @sizeOf(@TypeOf(msvcrt_mbctype)));
    try environment.addBuiltinExportComptime(m, "_mbslwr", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_mbsupr", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_strupr", misc.strupr);
    try environment.addBuiltinExportComptime(m, "_setmbcp", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_getmbcp", misc.stub_ignore_i32);

    // Jmp
    try environment.addBuiltinExport(m, "_EH_prolog", @intFromPtr(except.stub_EH_prolog));
    try environment.addBuiltinExport(m, "_setjmp3", @intFromPtr(except.setjmp3));
    try environment.addBuiltinExport(m, "longjmp", @intFromPtr(except.longjmp));

    // Misc
    try environment.addBuiltinExportComptime(m, "qsort", misc.qsort);
    try environment.addBuiltinExportComptime(m, "bsearch", misc.bsearch);
    try environment.addBuiltinExportComptime(m, "tmpnam", path.tempnam);
    try environment.addBuiltinExportComptime(m, "_tempnam", path.tempnam);
    try environment.addBuiltinExportComptime(m, "_mktemp", path.mktemp);
    try environment.addBuiltinExportComptime(m, "_splitpath", path.splitpath);
    try environment.addBuiltinExportComptime(m, "_makepath", path.makepath);
    try environment.addBuiltinExportComptime(m, "_fullpath", path.fullpath);
    try environment.addBuiltinExportComptime(m, "getenv", process.getenv);
    try environment.addBuiltinExportComptime(m, "_putenv", process.putenv);
    try environment.addBuiltinExportComptime(m, "_errno", misc.errno);
    try environment.addBuiltinExportComptime(m, "__doserrno", misc.errno);
    try environment.addBuiltinExportComptime(m, "_except_handler3", except.except_handler3);
    try environment.addBuiltinExportComptime(m, "_ftime", time_mod.ftime);
    try environment.addBuiltinExportComptime(m, "time", time_mod.time);
    try environment.addBuiltinExportComptime(m, "localtime", time_mod.localtime);
    try environment.addBuiltinExportComptime(m, "_tzset", time_mod.tzset);
    try environment.addBuiltinExportComptime(m, "ctime", time_mod.ctime);
    try environment.addBuiltinExportComptime(m, "rand", misc.rand);
    try environment.addBuiltinExportComptime(m, "srand", misc.srand);
    try environment.addBuiltinExportComptime(m, "ceil", math.ceil);
    try environment.addBuiltinExportComptime(m, "floor", math.floor);
    try environment.addBuiltinExport(m, "_ftol", @intFromPtr(math.ftol));
    try environment.addBuiltinExportComptime(m, "_flsbuf", io.fputc);
    try environment.addBuiltinExportComptime(m, "_filbuf", io.fgetc);
    try environment.addBuiltinExportComptime(m, "_utime", time_mod.stub_utime);
    try environment.addBuiltinExportComptime(m, "_futime", time_mod.stub_futime);
    try environment.addBuiltinExportComptime(m, "_osver", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "__unDName", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_atoldbl", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_adj_fdiv_r", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_findfirst", file.stub_findfirst);
    try environment.addBuiltinExportComptime(m, "_findnext", file.stub_findnext);
    try environment.addBuiltinExportComptime(m, "_findclose", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "__p___wargv", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "__p__wpgmptr", misc.stub_ignore_ptr);

    // --- Remaining MSVCRT stubs for 100% win2k coverage ---
    try environment.addBuiltinExportComptime(m, "??1type_info@@UAE@XZ", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_CxxThrowException", CxxThrowException);
    try environment.addBuiltinExportComptime(m, "?terminate@@YAXXZ", terminate);
    try environment.addBuiltinExportComptime(m, "_wcsrev", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "wcsspn", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_snwprintf", fmt.snprintf);
    try environment.addBuiltinExportComptime(m, "_pclose", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "_popen", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "iswspace", string.iswctype);
    try environment.addBuiltinExportComptime(m, "iswdigit", string.iswctype);
    try environment.addBuiltinExportComptime(m, "wcsrchr", string.wcsrchr);
    try environment.addBuiltinExportComptime(m, "iswalpha", string.iswctype);
    try environment.addBuiltinExportComptime(m, "wcstoul", string.wcstol);
    try environment.addBuiltinExportComptime(m, "iswxdigit", string.iswctype);
    try environment.addBuiltinExportComptime(m, "_pipe", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "swscanf", fmt.sscanf);
    try environment.addBuiltinExportComptime(m, "wcsstr", string.wcsstr);
    try environment.addBuiltinExportComptime(m, "_vsnwprintf", fmt.vsnprintf);
    try environment.addBuiltinExportComptime(m, "_wcslwr", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_getdcwd", path.getcwd);
    try environment.addBuiltinExportComptime(m, "_itow", string.itoa);
    try environment.addBuiltinExportComptime(m, "wcstok", misc.stub_ignore_ptr);
    try environment.addBuiltinExportComptime(m, "_ltow", string.itoa);
    try environment.addBuiltinExportComptime(m, "_wsplitpath", path.splitpath);
    try environment.addBuiltinExportComptime(m, "wcstod", misc.stub_ignore_i32);
    try environment.addBuiltinExportComptime(m, "wcscoll", string.wcscmp);

    // --- Notepad2 MSVCRT stubs ---
    try environment.addBuiltinExportComptime(m, "abs", misc.abs);
    try environment.addBuiltinExportComptime(m, "clock", time_mod.clock);
    try environment.addBuiltinExportComptime(m, "_lock", misc.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_unlock", misc.stub_noop1);
    try environment.addBuiltinExportComptime(m, "iscntrl", string.iscntrl);
    try environment.addBuiltinExportComptime(m, "_cexit", misc.stub_noop0);
    try environment.addBuiltinExportComptime(m, "_amsg_exit", misc.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_swab", misc.stub_noop3);
    try environment.addBuiltinExportComptime(m, "mktime", time_mod.mktime);
    try environment.addBuiltinExportComptime(m, "wcsftime", misc.stub_ignore_i32);
}

// =============================================================================
// Faithful implementations — Tier 6: C++ Exception Handling
// =============================================================================

// _CxxThrowException: C++ throw implementation
// This is called when C++ code does `throw expr;`
// Since we can't handle C++ exceptions, we log and terminate
fn CxxThrowException(pExceptionObject: usize, pThrowInfo: usize) callconv(.c) noreturn {
    _ = pThrowInfo;
    if (trace.enable_tracing) trace.print("MSVCRT: _CxxThrowException(object={x}) — terminating\n", .{pExceptionObject});
    process.exit(3);
}

// ?terminate@@YAXXZ: C++ std::terminate()
// Called when exception handling fails or unexpected exception
fn terminate() callconv(.c) noreturn {
    if (trace.enable_tracing) trace.print("MSVCRT: terminate() — aborting\n", .{});
    process.exit(3);
}
