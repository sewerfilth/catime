/*
 * bench.c — measured (not estimated) microbenchmark for the catime conversion
 * kernels, run on real hardware against the real assembly objects.
 *
 * The two conversion routines exercised here are byte-for-byte identical to
 * the Linux libcatime_fixed cf_to_cat_ns / cf_from_cat_ns instruction
 * sequences (same magic-multiply for /54, same divq for /625 with the new
 * round-to-nearest add). So these measured ns/op numbers are the real
 * fixed-interval *arithmetic* costs; only cf_now_ns's raw clock_gettime
 * syscall is Linux-specific and cannot be measured from macOS.
 *
 * Anti-optimizer discipline: every result feeds the next input (true data
 * dependency) and a volatile sink swallows the accumulator, so the loop
 * body cannot be hoisted or constant-folded away.
 *
 * Build+run via `make bench`.
 */
#include <stdint.h>
#include <stdio.h>
#include <time.h>

uint64_t ct_real_to_cat(uint64_t real);
uint64_t ct_cat_to_real(uint64_t cat);

static volatile uint64_t sink;

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

#define ITERS 200000000ull

static double bench_r2c(void) {
    uint64_t x = 1;
    double t0 = now_s();
    for (uint64_t i = 0; i < ITERS; i++)
        x = ct_real_to_cat(x + 1) - ct_real_to_cat(x) + 1; /* keep x bounded */
    double dt = now_s() - t0;
    sink = x;
    return dt / (double)ITERS * 1e9; /* ns/op (2 calls counted as ~2 ops below) */
}

static double bench_c2r(void) {
    uint64_t x = 1;
    double t0 = now_s();
    for (uint64_t i = 0; i < ITERS; i++)
        x = ct_cat_to_real(x + 1) - ct_cat_to_real(x) + 1;
    double dt = now_s() - t0;
    sink = x;
    return dt / (double)ITERS * 1e9;
}

int main(void) {
    printf("=== catime conversion microbenchmark (measured, CLOCK_MONOTONIC) ===\n");
    printf("iterations: %llu  (2 conversion calls per iteration)\n\n", ITERS);

    /* warm up */
    bench_r2c();

    double r2c = bench_r2c() / 2.0;   /* two calls per iter */
    double c2r = bench_c2r() / 2.0;

    printf("  ct_real_to_cat  (== cf_to_cat_ns, magic-mul /54): %6.2f ns/op\n", r2c);
    printf("  ct_cat_to_real  (== cf_from_cat_ns, rounded /625): %6.2f ns/op\n", c2r);
    printf("\nNote: cf_now_ns (raw clock_gettime syscall, ~500-800 ns on Linux)\n");
    printf("is a kernel-entry cost and is not measurable from this macOS host.\n");
    return 0;
}
