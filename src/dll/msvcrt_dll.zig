//! MSVCRT.dll export definitions

const w32 = @import("win32");
const string = w32.msvcrt.string;
const mem = w32.msvcrt.mem;
const path = w32.msvcrt.path;
const time_mod = w32.msvcrt.time;
const misc = w32.msvcrt.misc;

comptime {
    // Force DllMain linkage
    _ = @import("dll_common.zig");

    // String
    @export(&string.strlen, .{ .name = "strlen" });
    @export(&string.strcpy, .{ .name = "strcpy" });
    @export(&string.strncpy, .{ .name = "strncpy" });
    @export(&string.strcat, .{ .name = "strcat" });
    @export(&string.strcmp, .{ .name = "strcmp" });
    @export(&string.strncmp, .{ .name = "strncmp" });
    @export(&string.stricmp, .{ .name = "_stricmp" });
    @export(&string.strnicmp, .{ .name = "_strnicmp" });
    @export(&string.strchr, .{ .name = "strchr" });
    @export(&string.strrchr, .{ .name = "strrchr" });
    @export(&string.strstr, .{ .name = "strstr" });
    @export(&string.strpbrk, .{ .name = "strpbrk" });
    @export(&string.strcspn, .{ .name = "strcspn" });
    @export(&string.strdup, .{ .name = "_strdup" });
    @export(&string.mbsicmp, .{ .name = "_mbsicmp" });
    @export(&string.itoa, .{ .name = "_itoa" });
    @export(&string.atof, .{ .name = "atof" });
    @export(&string.strtoul, .{ .name = "strtoul" });
    @export(&string.strtol, .{ .name = "strtol" });
    @export(&string.atoi, .{ .name = "atoi" });
    @export(&misc.strupr, .{ .name = "_strupr" });

    // Wide string
    @export(&string.wcslen, .{ .name = "wcslen" });
    @export(&string.wcscpy, .{ .name = "wcscpy" });
    @export(&string.wcsncpy, .{ .name = "wcsncpy" });
    @export(&string.wcscat, .{ .name = "wcscat" });
    @export(&string.wcscmp, .{ .name = "wcscmp" });
    @export(&string.wcsncmp, .{ .name = "wcsncmp" });
    @export(&string.wcsicmp, .{ .name = "_wcsicmp" });
    @export(&string.wcsnicmp, .{ .name = "_wcsnicmp" });
    @export(&string.wcschr, .{ .name = "wcschr" });
    @export(&string.wcsrchr, .{ .name = "wcsrchr" });
    @export(&string.wcsstr, .{ .name = "wcsstr" });
    @export(&string.wcsupr, .{ .name = "_wcsupr" });
    @export(&string.wcsdup, .{ .name = "_wcsdup" });
    @export(&string.wtoi, .{ .name = "_wtoi" });
    @export(&string.wcstol, .{ .name = "wcstol" });

    // Character classification
    @export(&string.isalnum, .{ .name = "isalnum" });
    @export(&string.isalpha, .{ .name = "isalpha" });
    @export(&string.isdigit, .{ .name = "isdigit" });
    @export(&string.isspace, .{ .name = "isspace" });
    @export(&string.isupper, .{ .name = "isupper" });
    @export(&string.islower, .{ .name = "islower" });
    @export(&string.isprint, .{ .name = "isprint" });
    @export(&string.toupper, .{ .name = "toupper" });
    @export(&string.tolower, .{ .name = "tolower" });

    // Memory
    @export(&mem.memset, .{ .name = "memset" });
    @export(&mem.memcpy, .{ .name = "memcpy" });
    @export(&mem.memmove, .{ .name = "memmove" });
    @export(&mem.malloc, .{ .name = "malloc" });
    @export(&mem.calloc, .{ .name = "calloc" });
    @export(&mem.realloc, .{ .name = "realloc" });

    // Path
    @export(&path.splitpath, .{ .name = "_splitpath" });
    @export(&path.makepath, .{ .name = "_makepath" });
    @export(&path.fullpath, .{ .name = "_fullpath" });
    @export(&path.searchenv, .{ .name = "_searchenv" });
    @export(&path.getcwd, .{ .name = "_getcwd" });

    // Time
    @export(&time_mod.time, .{ .name = "time" });
    @export(&time_mod.localtime, .{ .name = "localtime" });
    @export(&time_mod.ctime, .{ .name = "ctime" });
    @export(&time_mod.ftime, .{ .name = "_ftime" });
    @export(&time_mod.mktime, .{ .name = "mktime" });
    @export(&time_mod.clock, .{ .name = "clock" });
    @export(&time_mod.time64, .{ .name = "_time64" });
    @export(&time_mod.tzset, .{ .name = "_tzset" });
}
