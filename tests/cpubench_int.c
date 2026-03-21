#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DURATION 3

static clock_t bench_start;
static void start_timer(void) { bench_start = clock(); }
static double elapsed_sec(void) { return (double)(clock() - bench_start) / CLOCKS_PER_SEC; }

static long bench_integer(void) {
    long iters = 0; int a = 13, b = 7, c = 31, d;
    start_timer();
    while (elapsed_sec() < DURATION) {
        int i; for (i = 0; i < 10000; i++) {
            d=a*b+c; a=d^b; b=(c+a)>>1; c=d-b+17;
            d=a*b+c; a=d^b; b=(c+a)>>1; c=d-b+17;
        } iters += 20000;
    } return iters;
}
static long bench_memory(void) {
    long iters = 0; char *buf = (char*)malloc(1024*1024);
    if (!buf) return 0;
    start_timer();
    while (elapsed_sec() < DURATION) { memset(buf,0xAA,1024*1024); memcpy(buf+512*1024,buf,512*1024); iters+=2; }
    free(buf); return iters;
}
static long bench_string(void) {
    long iters = 0; char a[256], b[256];
    start_timer();
    while (elapsed_sec() < DURATION) {
        int i; for (i=0;i<10000;i++) {
            strcpy(a,"The quick brown fox jumps over the lazy dog 0123456789");
            strcat(a," ABCDEFGHIJKLMNOPQRSTUVWXYZ"); strcpy(b,a);
            if(strcmp(a,b)!=0) break;
        } iters += 40000;
    } return iters;
}
static long bench_sieve(void) {
    long iters = 0; char flags[8192];
    start_timer();
    while (elapsed_sec() < DURATION) {
        int i, k; memset(flags,1,sizeof(flags));
        for(i=2;i<8192;i++) if(flags[i]) for(k=i+i;k<8192;k+=i) flags[k]=0;
        iters++;
    } return iters;
}
int main(void) {
    long r;
    printf("=== CPU Benchmark (Integer) ===\n");
    printf("Running 4 tests, %d seconds each...\n\n", DURATION);
    printf("1. Integer Arithmetic... "); fflush(stdout);
    r=bench_integer(); printf("%ld Kops/s\n", r/DURATION/1000);
    printf("2. Memory Bandwidth...   "); fflush(stdout);
    r=bench_memory(); printf("%.0f MB/s\n", (double)r*1.5/DURATION);
    printf("3. String Operations...  "); fflush(stdout);
    r=bench_string(); printf("%ld Kops/s\n", r/DURATION/1000);
    printf("4. Sieve (primes)...     "); fflush(stdout);
    r=bench_sieve(); printf("%ld iterations/sec\n", r/DURATION);
    printf("\n=== Done ===\n");
    return 0;
}
