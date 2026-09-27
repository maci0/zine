/*
 * Simple CPU Benchmark for Win32
 * Tests integer arithmetic, memory access, and string operations.
 * Produces a composite score in "iterations per second".
 *
 * Designed to compile with MSVC 6.0 (no floating-point globals needed).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Sieve of Eratosthenes - tests integer ops and memory access */
#define SIEVE_SIZE 8192

static int sieve(char *flags, int size)
{
    int i, prime, k, count;

    count = 0;
    for (i = 0; i < size; i++)
        flags[i] = 1;

    for (i = 0; i < size; i++) {
        if (flags[i]) {
            prime = i + i + 3;
            k = i + prime;
            while (k < size) {
                flags[k] = 0;
                k += prime;
            }
            count++;
        }
    }
    return count;
}

/* Integer arithmetic stress test */
static long arith_test(long iterations)
{
    long i, a, b, c, d;
    a = 1; b = 2; c = 3; d = 4;

    for (i = 0; i < iterations; i++) {
        a = a + b * c - d;
        b = (a >> 1) ^ c;
        c = c + (b & 0xFF) - (a & 0xF);
        d = (d * 3 + 1) ^ (a >> 2);
        a = a ^ (d << 1);
        b = b + c - (d >> 3);
        c = (c ^ a) + (b & 0x7F);
        d = d - a + (c * 5);
    }
    /* Return something so optimizer can't remove the loop */
    return a + b + c + d;
}

/* String operations test */
static long string_test(long iterations)
{
    char buf1[128], buf2[128];
    long i, total;

    total = 0;
    for (i = 0; i < iterations; i++) {
        strcpy(buf1, "The quick brown fox jumps over the lazy dog");
        strcpy(buf2, "The quick brown fox jumps over the lazy cat");
        total += strcmp(buf1, buf2);
        total += (long)strlen(buf1);
        /* Reverse copy */
        buf1[0] = buf2[43];
        buf1[43] = buf2[0];
        total += strcmp(buf1, buf2);
    }
    return total;
}

/* Memory copy/set test */
static long memory_test(long iterations)
{
    char block1[4096], block2[4096];
    long i, sum;

    sum = 0;
    for (i = 0; i < iterations; i++) {
        memset(block1, (int)(i & 0xFF), sizeof(block1));
        memcpy(block2, block1, sizeof(block1));
        sum += block2[(size_t)i % sizeof(block2)];
    }
    return sum;
}

int main(int argc, char *argv[])
{
    long t_start, t_end, elapsed;
    long sieve_iters, arith_iters, string_iters, mem_iters;
    long sieve_count, arith_result, string_result, mem_result;
    long total_ops;
    int target_seconds;

    target_seconds = 3;
    if (argc > 1) {
        target_seconds = atoi(argv[1]);
        if (target_seconds < 1) target_seconds = 1;
        if (target_seconds > 60) target_seconds = 60;
    }

    printf("=== Simple CPU Benchmark ===\n");
    printf("Target duration: %d seconds per test\n\n", target_seconds);

    /* --- Sieve Test --- */
    printf("Running Sieve of Eratosthenes...\n");
    {
        char flags[SIEVE_SIZE];
        sieve_iters = 0;
        sieve_count = 0;
        t_start = (long)time(0);
        do {
            sieve_count = sieve(flags, SIEVE_SIZE);
            sieve_iters++;
            t_end = (long)time(0);
        } while (t_end - t_start < target_seconds);
        elapsed = t_end - t_start;
        if (elapsed < 1) elapsed = 1;
        printf("  Sieve: %ld iterations in %ld sec (%ld iter/sec), %ld primes found\n",
               sieve_iters, elapsed, sieve_iters / elapsed, sieve_count);
    }

    /* --- Integer Arithmetic Test --- */
    printf("Running integer arithmetic...\n");
    {
        long batch;
        batch = 100000;
        arith_iters = 0;
        arith_result = 0;
        t_start = (long)time(0);
        do {
            arith_result += arith_test(batch);
            arith_iters += batch;
            t_end = (long)time(0);
        } while (t_end - t_start < target_seconds);
        elapsed = t_end - t_start;
        if (elapsed < 1) elapsed = 1;
        printf("  Arith: %ld iterations in %ld sec (%ld iter/sec)\n",
               arith_iters, elapsed, arith_iters / elapsed);
    }

    /* --- String Operations Test --- */
    printf("Running string operations...\n");
    {
        long batch;
        batch = 50000;
        string_iters = 0;
        string_result = 0;
        t_start = (long)time(0);
        do {
            string_result += string_test(batch);
            string_iters += batch;
            t_end = (long)time(0);
        } while (t_end - t_start < target_seconds);
        elapsed = t_end - t_start;
        if (elapsed < 1) elapsed = 1;
        printf("  String: %ld iterations in %ld sec (%ld iter/sec)\n",
               string_iters, elapsed, string_iters / elapsed);
    }

    /* --- Memory Test --- */
    printf("Running memory operations...\n");
    {
        long batch;
        batch = 10000;
        mem_iters = 0;
        mem_result = 0;
        t_start = (long)time(0);
        do {
            mem_result += memory_test(batch);
            mem_iters += batch;
            t_end = (long)time(0);
        } while (t_end - t_start < target_seconds);
        elapsed = t_end - t_start;
        if (elapsed < 1) elapsed = 1;
        printf("  Memory: %ld iterations in %ld sec (%ld iter/sec)\n",
               mem_iters, elapsed, mem_iters / elapsed);
    }

    /* Composite score */
    total_ops = sieve_iters + arith_iters + string_iters + mem_iters;
    printf("\n=== Results ===\n");
    printf("Total operations: %ld\n", total_ops);
    printf("(checksum: %ld)\n", arith_result + string_result + mem_result + sieve_count);
    printf("=== Benchmark Complete ===\n");

    return 0;
}
