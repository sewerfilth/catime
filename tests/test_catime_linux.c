/*
 * test_catime_linux.c — native Linux test suite for libcatime_fixed (cf_*).
 *
 * Links directly against the Linux ELF fixed-interval objects
 * (lib_fixed_arm64.o / lib_fixed_x86.o), so it exercises the *real* pure-syscall
 * assembly on Linux x86_64 / aarch64 — not a cross-assembled object that is only
 * ever linked, and not the macOS ct_* reimplementation.
 *
 * This is the Linux counterpart to tests/test_catime.c. It checks the same
 * conversion invariants against the cf_* kernels:
 *   - known conversion vectors (the defining 54:625 ratio, one cat-day),
 *   - forward cf_to_cat_ns == floor(r*625/54),
 *   - reverse cf_from_cat_ns == round(c*54/625) (correctly rounded, not trunc),
 *   - real->cat->real and cat->real->cat round-trip error bounds,
 *   - cf_next_grid_ns absolute-grid alignment,
 *   - cf_phc_clockid FD_TO_CLOCKID bit math.
 *
 * The clock-reading / PHC syscall entry points (cf_now_ns, cf_now_dynamic_ns,
 * cf_open_phc) are always *linked* (so the linker resolves the ELF symbols and
 * the CI proves they are present and callable). cf_now_ns is invoked once at
 * runtime for a sanity check. cf_open_phc / cf_now_dynamic_ns against a real PHC
 * are only executed when /dev/ptp0 exists, because they are environment
 * dependent (a NIC PTP hardware clock is not present in a plain CI runner).
 *
 * Build+run via `make test-linux` (on Linux).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* ---- API under test (from lib_fixed_{arm64,x86}.s / catime_fixed.h) ---- */
uint64_t cf_now_ns(void);
uint64_t cf_to_cat_ns(uint64_t real_ns);
uint64_t cf_from_cat_ns(uint64_t cat_ns);
uint64_t cf_wait_until_ns(uint64_t target_ns);
uint64_t cf_next_grid_ns(uint64_t now_ns, uint64_t interval_ns);
int      cf_open_phc(const char *path);
int      cf_phc_clockid(int fd);
uint64_t cf_now_dynamic_ns(int clockid);

/* ---- reference math in 128-bit to avoid intermediate overflow ---- */
static uint64_t ref_real_to_cat(uint64_t r) {       /* floor(r*625/54) */
    return (uint64_t)(((unsigned __int128)r * 625) / 54);
}
static uint64_t ref_cat_to_real_round(uint64_t c) { /* round(c*54/625) */
    return (uint64_t)(((unsigned __int128)c * 54 + 312) / 625);
}
static uint64_t ref_cat_to_real_trunc(uint64_t c) { /* floor(c*54/625) */
    return (uint64_t)(((unsigned __int128)c * 54) / 625);
}
/* FD_TO_CLOCKID(fd) = sign_extend_32( ((~fd) << 3) | 3 ) */
static int64_t ref_phc_clockid(int fd) {
    int32_t v = (int32_t)(((~fd) << 3) | 3);
    return (int64_t)v;
}

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { failures++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } \
} while (0)

static void test_conversion_vectors(void) {
    printf("[known conversion vectors]\n");
    /* One cat-day == one real-day: 86400 s * 625/54 == 1_000_000 exactly.
     * cf_* operate in nanoseconds, so scale the second-domain vectors by 1e9. */
    CHECK(cf_to_cat_ns(54)  == 625, "54 real -> 625 cat (defining ratio)");
    CHECK(cf_from_cat_ns(625) == 54, "625 cat -> 54 real");
    CHECK(cf_to_cat_ns(86400) == 1000000, "86400 real -> 1e6 cat");
    CHECK(cf_from_cat_ns(1000000) == 86400, "1e6 cat -> 86400 real");
    CHECK(cf_to_cat_ns(0) == 0 && cf_from_cat_ns(0) == 0, "zero maps to zero");
    /* ns-domain: 54e9 real-ns -> 625e9 cat-ns, exact (no overflow: fits u64). */
    CHECK(cf_to_cat_ns(54000000000ull) == 625000000000ull, "54e9 real-ns -> 625e9 cat-ns");
    CHECK(cf_from_cat_ns(625000000000ull) == 54000000000ull, "625e9 cat-ns -> 54e9 real-ns");
}

static void test_forward_matches_ref(void) {
    printf("[forward conversion == floor reference]\n");
    for (uint64_t r = 0; r < 200000; r++)
        CHECK(cf_to_cat_ns(r) == ref_real_to_cat(r),
              "cf_to_cat_ns(%llu)=%llu ref=%llu",
              (unsigned long long)r,
              (unsigned long long)cf_to_cat_ns(r),
              (unsigned long long)ref_real_to_cat(r));
}

static void test_reverse_is_correctly_rounded(void) {
    printf("[reverse conversion is correctly rounded, not truncated]\n");
    int saw_round_up = 0;
    for (uint64_t c = 0; c < 200000; c++) {
        uint64_t got = cf_from_cat_ns(c);
        CHECK(got == ref_cat_to_real_round(c),
              "cf_from_cat_ns(%llu)=%llu round-ref=%llu",
              (unsigned long long)c, (unsigned long long)got,
              (unsigned long long)ref_cat_to_real_round(c));
        if (ref_cat_to_real_round(c) != ref_cat_to_real_trunc(c))
            saw_round_up = 1;   /* prove rounding actually differs from trunc */
    }
    CHECK(saw_round_up, "rounding differs from truncation somewhere in range");
}

static void test_roundtrip_error_bound(void) {
    printf("[real->cat->real round-trip error bound]\n");
    int64_t worst = 0;
    for (uint64_t r = 0; r < 500000; r++) {
        uint64_t back = cf_from_cat_ns(cf_to_cat_ns(r));
        int64_t err = (int64_t)back - (int64_t)r;
        if (err < 0) err = -err;
        if (err > worst) worst = err;
    }
    printf("  worst real->cat->real error over [0,500k): %lld unit(s)\n", (long long)worst);
    CHECK(worst <= 1, "round-trip error <= 1 unit (got %lld)", (long long)worst);

    /* cat->real->cat is intrinsically coarser: a real unit spans 625/54 ~= 11.57
     * cat units, so distinct cat values collapse. Bounded by ceil((625/54)/2)=6. */
    const int64_t CAT_RT_BOUND = 6;
    int64_t worst2 = 0;
    for (uint64_t c = 0; c < 500000; c++) {
        uint64_t back = cf_to_cat_ns(cf_from_cat_ns(c));
        int64_t err = (int64_t)back - (int64_t)c;
        if (err < 0) err = -err;
        if (err > worst2) worst2 = err;
    }
    printf("  worst cat->real->cat error over [0,500k): %lld unit(s) (bound %lld)\n",
           (long long)worst2, (long long)CAT_RT_BOUND);
    CHECK(worst2 <= CAT_RT_BOUND, "cat round-trip error <= %lld units (got %lld)",
          (long long)CAT_RT_BOUND, (long long)worst2);
}

static void test_next_grid(void) {
    printf("[cf_next_grid_ns absolute-grid alignment]\n");
    /* Smallest k*interval strictly greater than now. */
    CHECK(cf_next_grid_ns(0, 1000) == 1000,   "next_grid(0,1000)=1000 (strictly greater)");
    CHECK(cf_next_grid_ns(999, 1000) == 1000, "next_grid(999,1000)=1000");
    CHECK(cf_next_grid_ns(1000, 1000) == 2000,"next_grid(1000,1000)=2000 (strict, not equal)");
    CHECK(cf_next_grid_ns(1001, 1000) == 2000,"next_grid(1001,1000)=2000");
    CHECK(cf_next_grid_ns(2500, 1000) == 3000,"next_grid(2500,1000)=3000");
    /* general property: result is a multiple of interval, and now < result <= now+interval */
    for (uint64_t interval = 1; interval <= 97; interval += 3)
        for (uint64_t now = 0; now < 1000; now += 7) {
            uint64_t g = cf_next_grid_ns(now, interval);
            CHECK(g % interval == 0 && g > now && g <= now + interval,
                  "grid(%llu,%llu)=%llu violates now<g<=now+interval|multiple",
                  (unsigned long long)now, (unsigned long long)interval,
                  (unsigned long long)g);
        }
}

static void test_phc_clockid_math(void) {
    printf("[cf_phc_clockid FD_TO_CLOCKID bit math]\n");
    /* Pure bit manipulation — testable without any PTP hardware. */
    for (int fd = 0; fd < 64; fd++)
        CHECK((int64_t)cf_phc_clockid(fd) == ref_phc_clockid(fd),
              "cf_phc_clockid(%d)=%lld ref=%lld", fd,
              (long long)(int64_t)cf_phc_clockid(fd),
              (long long)ref_phc_clockid(fd));
}

static void test_clock_read_runtime(void) {
    printf("[cf_now_ns live syscall sanity]\n");
    /* Executes the raw clock_gettime(CLOCK_REALTIME) syscall path on Linux. */
    uint64_t a = cf_now_ns();
    uint64_t b = cf_now_ns();
    /* Post-2001 epoch ns; monotone-ish (REALTIME can jump, so allow equal). */
    CHECK(a > 1000000000000000000ull, "cf_now_ns() returns a plausible epoch-ns value (%llu)",
          (unsigned long long)a);
    CHECK(b >= a || (a - b) < 1000000000ull, "cf_now_ns() advances (or REALTIME stepped)");

    /* cf_now_dynamic_ns(CLOCK_REALTIME) is documented equivalent to cf_now_ns(). */
    uint64_t d = cf_now_dynamic_ns(0 /* CLOCK_REALTIME */);
    CHECK(d > 1000000000000000000ull,
          "cf_now_dynamic_ns(CLOCK_REALTIME) plausible epoch-ns (%llu)",
          (unsigned long long)d);
}

static void test_phc_device(void) {
    printf("[dynamic PHC /dev/ptp0 — environment dependent]\n");
    /* Only exercise the real openat/dynamic-clockid path if the device exists;
     * a plain CI runner has no NIC PTP hardware clock. The symbols are already
     * linked (resolved at link time) regardless of this guard. */
    if (access("/dev/ptp0", F_OK) != 0) {
        printf("  SKIP: /dev/ptp0 absent (no PTP hardware clock in this environment)\n");
        return;
    }
    int fd = cf_open_phc("/dev/ptp0");
    if (fd < 0) {
        printf("  SKIP: /dev/ptp0 present but open failed (errno-ish %d) — likely permissions\n", -fd);
        return;
    }
    int cid = cf_phc_clockid(fd);
    CHECK((int64_t)cid == ref_phc_clockid(fd), "phc clockid matches FD_TO_CLOCKID for fd=%d", fd);
    uint64_t t = cf_now_dynamic_ns(cid);
    printf("  PHC time: %llu ns\n", (unsigned long long)t);
    CHECK(t > 0, "cf_now_dynamic_ns(phc) returned nonzero");
}

int main(void) {
    printf("=== catime fixed (cf_*) Linux test suite ===\n");
    test_conversion_vectors();
    test_forward_matches_ref();
    test_reverse_is_correctly_rounded();
    test_roundtrip_error_bound();
    test_next_grid();
    test_phc_clockid_math();
    test_clock_read_runtime();
    test_phc_device();
    printf("=== %d checks, %d failures ===\n", checks, failures);
    return failures ? 1 : 0;
}
