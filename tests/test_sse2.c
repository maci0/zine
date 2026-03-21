/* SSE2 test — validates basic SSE/SSE2 instructions in the interpreter */
#include <stdio.h>
#include <string.h>

static int approx_eq_d(double a, double b) { double d = a - b; return d > -0.01 && d < 0.01; }
static int approx_eq_f(float a, float b) { float d = a - b; return d > -0.001f && d < 0.001f; }

static int test_double_arith(void) {
    volatile double a = 3.14, b = 2.71;
    double sum = a + b;
    double diff = a - b;
    double prod = a * b;
    double quot = a / b;
    int ok = approx_eq_d(sum, 5.85) && approx_eq_d(diff, 0.43) &&
             approx_eq_d(prod, 8.5094) && approx_eq_d(quot, 1.1586);
    if (!ok) printf("  sum=%d diff=%d prod=%d quot=%d\n",
        (int)(sum*100), (int)(diff*100), (int)(prod*100), (int)(quot*10000));
    return ok;
}

static int test_float_arith(void) {
    volatile float a = 1.5f, b = 2.5f;
    float sum = a + b;
    float prod = a * b;
    int ok = approx_eq_f(sum, 4.0f) && approx_eq_f(prod, 3.75f);
    if (!ok) printf("  sum=%d prod=%d\n", (int)(sum*100), (int)(prod*100));
    return ok;
}

static int test_int_convert(void) {
    volatile int i = 42;
    double d = (double)i;
    int back = (int)d;
    volatile double neg = -7.9;
    int trunc = (int)neg;
    int ok = (back == 42) && (trunc == -7);
    if (!ok) printf("  back=%d trunc=%d\n", back, trunc);
    return ok;
}

static int test_memops(void) {
    char src[128], dst[128];
    int i;
    for (i = 0; i < 128; i++) src[i] = (char)(i ^ 0x55);
    memcpy(dst, src, 128);
    memset(src, 0xAA, 64);
    int ok = 1;
    for (i = 0; i < 128; i++) if (dst[i] != (char)(i ^ 0x55)) { ok = 0; break; }
    for (i = 0; i < 64; i++) if ((unsigned char)src[i] != 0xAA) { ok = 0; break; }
    return ok;
}

static int test_compare(void) {
    volatile double a = 1.0, b = 2.0, c = 1.0;
    volatile float fa = 3.0f, fb = 3.0f;
    return (a < b) && (a == c) && !(a > b) && (fa == fb);
}

static int test_precision_convert(void) {
    volatile float f = 1.5f;
    double d = (double)f;
    volatile double d2 = 2.75;
    float f2 = (float)d2;
    return approx_eq_d(d, 1.5) && approx_eq_f(f2, 2.75f);
}

int main(void) {
    int pass = 0, fail = 0;
    printf("=== SSE2 Test Suite ===\n\n");

#define RUN(name, fn) do { \
    printf(name "... "); fflush(stdout); \
    if (fn()) { printf("PASS\n"); pass++; } else { printf("FAIL\n"); fail++; } \
} while(0)

    RUN("1. Double arithmetic ", test_double_arith);
    RUN("2. Float arithmetic  ", test_float_arith);
    RUN("3. Int<->Float cvt   ", test_int_convert);
    RUN("4. Memcpy/memset     ", test_memops);
    RUN("5. Float compare     ", test_compare);
    RUN("6. Precision convert ", test_precision_convert);

    printf("\nResults: %d passed, %d failed\n", pass, fail);
    return fail > 0 ? 1 : 0;
}
