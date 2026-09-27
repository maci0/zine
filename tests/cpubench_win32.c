/* Minimal CPU benchmark — uses only KERNEL32.dll (no CRT) */
/* Compiled with: zig cc -target x86-windows-gnu -O2 -nostdlib -lkernel32 */

typedef unsigned long DWORD;
typedef int BOOL;
typedef void* HANDLE;

#define STD_OUTPUT_HANDLE ((DWORD)-11)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD nStdHandle);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
__declspec(dllimport) void __stdcall ExitProcess(DWORD uExitCode);
__declspec(dllimport) void __stdcall GetSystemTime(void* lpSystemTime);

static HANDLE hStdout;

static void print(const char* s) {
    DWORD len = 0, written;
    while (s[len]) len++;
    WriteFile(hStdout, s, len, &written, 0);
}

static void print_num(long n) {
    char buf[20];
    int i = 19;
    int neg = 0;
    if (n < 0) { neg = 1; n = -n; }
    buf[i] = 0;
    if (n == 0) buf[--i] = '0';
    while (n > 0) { buf[--i] = '0' + (char)(n % 10); n /= 10; }
    if (neg) buf[--i] = '-';
    print(&buf[i]);
}

/* Simple millisecond timer using GetSystemTime */
typedef struct { short y,m,dow,d,h,min,s,ms; } SYSTIME;

static long get_ms(void) {
    SYSTIME st;
    GetSystemTime(&st);
    return (long)st.h * 3600000L + (long)st.min * 60000L + (long)st.s * 1000L + (long)st.ms;
}

#define DURATION_MS 3000

static long bench_sieve(void) {
    long iters = 0;
    char flags[8192];
    long start = get_ms();
    while (get_ms() - start < DURATION_MS) {
        int i, k;
        for (i = 0; i < 8192; i++) flags[i] = 1;
        for (i = 2; i < 8192; i++)
            if (flags[i]) for (k = i+i; k < 8192; k += i) flags[k] = 0;
        iters++;
    }
    return iters;
}

static long bench_integer(void) {
    long iters = 0;
    int a = 13, b = 7, c = 31, d;
    long start = get_ms();
    while (get_ms() - start < DURATION_MS) {
        int i;
        for (i = 0; i < 10000; i++) {
            d=a*b+c; a=d^b; b=(c+a)>>1; c=d-b+17;
            d=a*b+c; a=d^b; b=(c+a)>>1; c=d-b+17;
        }
        iters += 20000;
    }
    return iters;
}

static long bench_string(void) {
    long iters = 0;
    char a[256], b[256];
    long start = get_ms();
    while (get_ms() - start < DURATION_MS) {
        int i;
        for (i = 0; i < 10000; i++) {
            /* manual strcpy */
            const char* s = "The quick brown fox jumps over the lazy dog 0123456789";
            int j = 0;
            while (s[j]) { a[j] = s[j]; j++; }
            a[j] = 0;
            /* manual strcat */
            const char* s2 = " ABCDEFGHIJKLMNOPQRSTUVWXYZ";
            int k = 0;
            while (s2[k]) { a[j+k] = s2[k]; k++; }
            a[j+k] = 0;
            /* manual strcpy */
            int l = 0;
            while (a[l]) { b[l] = a[l]; l++; }
            b[l] = 0;
        }
        iters += 40000;
    }
    return iters;
}

static long bench_memory(void) {
    long iters = 0;
    char buf[65536];
    long start = get_ms();
    while (get_ms() - start < DURATION_MS) {
        int i;
        for (i = 0; i < 65536; i++) buf[i] = (char)0xAA;
        for (i = 0; i < 32768; i++) buf[32768+i] = buf[i];
        iters++;
    }
    return iters;
}

/* The mingw entry point: named by the linker, not called from here. */
void mainCRTStartup(void);

void mainCRTStartup(void) {
    hStdout = GetStdHandle(STD_OUTPUT_HANDLE);
    long r;

    print("=== CPU Benchmark ===\n");
    print("3 seconds per test, 4 tests\n\n");

    print("1. Integer Arithmetic... ");
    r = bench_integer();
    print_num(r / 3 / 1000); print(" Kops/s\n");

    print("2. Memory Bandwidth...   ");
    r = bench_memory();
    print_num(r * 64 / 3); print(" KB/s\n");

    print("3. String Operations...  ");
    r = bench_string();
    print_num(r / 3 / 1000); print(" Kops/s\n");

    print("4. Sieve (primes)...     ");
    r = bench_sieve();
    print_num(r / 3); print(" iterations/sec\n");

    print("\n=== Done ===\n");
    ExitProcess(0);
}
