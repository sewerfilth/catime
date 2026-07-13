/*
 * test_catime.c — automated test suite for libcatime (base API, ct_*).
 *
 * Links directly against the Mach-O base-library object (lib_arm64.o /
 * lib_x86.o), so it exercises the real assembly, not a C reimplementation.
 * The ct_* conversion math is byte-identical to the Linux libcatime_fixed
 * cf_to_cat_ns / cf_from_cat_ns paths, so these round-trip/rounding results
 * carry over to the fixed library too.
 *
 * Build+run via `make test`.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* ---- API under test (from lib_{arm64,x86}.s) ---- */
uint64_t ct_real_to_cat(uint64_t real);
uint64_t ct_cat_to_real(uint64_t cat);
uint64_t ct_pack(uint64_t h, uint64_t m, uint64_t s);
void     ct_split(uint64_t flat, uint64_t *h, uint64_t *m, uint64_t *s);
void     ct_detach(uint64_t start_unix_sec);
void     ct_attach(void);
void     ct_tick(uint64_t delta_sec);
int      ct_is_detached(void);
uint64_t ct_now_unix_sec(void);
uint64_t ct_now_unix_ns(void);

/* ---- reference math in 128-bit to avoid intermediate overflow ---- */
static uint64_t ref_real_to_cat(uint64_t r) {      /* floor(r*625/54) */
    return (uint64_t)(((unsigned __int128)r * 625) / 54);
}
static uint64_t ref_cat_to_real_round(uint64_t c) { /* round(c*54/625) */
    return (uint64_t)(((unsigned __int128)c * 54 + 312) / 625);
}
static uint64_t ref_cat_to_real_trunc(uint64_t c) { /* floor(c*54/625) */
    return (uint64_t)(((unsigned __int128)c * 54) / 625);
}

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { failures++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } \
} while (0)

static void test_pack_split(void) {
    printf("[pack/split base-100 vectors]\n");
    /* known vectors: flat = h*10000 + m*100 + s */
    CHECK(ct_pack(0,0,0)       == 0,      "pack(0,0,0)");
    CHECK(ct_pack(12,34,56)    == 123456, "pack(12,34,56)=123456");
    CHECK(ct_pack(99,99,99)    == 999999, "pack(99,99,99)=999999");
    CHECK(ct_pack(0,0,99)      == 99,     "pack(0,0,99)=99");
    CHECK(ct_pack(0,99,0)      == 9900,   "pack(0,99,0)=9900");

    /* split is the exact inverse of pack over the whole base-100 grid */
    for (uint64_t h = 0; h < 100; h++)
        for (uint64_t m = 0; m < 100; m += 7)
            for (uint64_t s = 0; s < 100; s += 11) {
                uint64_t flat = ct_pack(h, m, s), oh, om, os;
                ct_split(flat, &oh, &om, &os);
                CHECK(oh==h && om==m && os==s,
                      "split(pack(%llu,%llu,%llu)) -> (%llu,%llu,%llu)",
                      h,m,s,oh,om,os);
            }
}

static void test_conversion_vectors(void) {
    printf("[known conversion vectors]\n");
    /* One cat-day == one real-day: 86400 s * 625/54 == 1_000_000 exactly */
    CHECK(ct_real_to_cat(86400) == 1000000, "86400 real -> 1e6 cat");
    CHECK(ct_cat_to_real(1000000) == 86400, "1e6 cat -> 86400 real");
    /* 54 real -> 625 cat exactly (the defining ratio) */
    CHECK(ct_real_to_cat(54) == 625, "54 real -> 625 cat");
    CHECK(ct_cat_to_real(625) == 54, "625 cat -> 54 real");
    CHECK(ct_real_to_cat(0) == 0 && ct_cat_to_real(0) == 0, "zero maps to zero");
}

static void test_forward_matches_ref(void) {
    printf("[forward conversion == floor reference]\n");
    for (uint64_t r = 0; r < 200000; r++)
        CHECK(ct_real_to_cat(r) == ref_real_to_cat(r),
              "ct_real_to_cat(%llu)=%llu ref=%llu", r,
              ct_real_to_cat(r), ref_real_to_cat(r));
}

static void test_reverse_is_correctly_rounded(void) {
    printf("[reverse conversion is correctly rounded, not truncated]\n");
    int saw_round_up = 0;
    for (uint64_t c = 0; c < 200000; c++) {
        uint64_t got = ct_cat_to_real(c);
        CHECK(got == ref_cat_to_real_round(c),
              "ct_cat_to_real(%llu)=%llu round-ref=%llu", c, got,
              ref_cat_to_real_round(c));
        if (ref_cat_to_real_round(c) != ref_cat_to_real_trunc(c))
            saw_round_up = 1;   /* prove rounding actually differs from trunc */
    }
    CHECK(saw_round_up, "rounding differs from truncation somewhere in range");
}

static void test_roundtrip_error_bound(void) {
    printf("[real->cat->real round-trip error bound]\n");
    /* With a correctly-rounded reverse step, real->cat->real recovers the
     * original real value to within 1 (the unavoidable slack from the
     * forward truncation over a 625:54 lattice). Track the worst case. */
    int64_t worst = 0;
    for (uint64_t r = 0; r < 500000; r++) {
        uint64_t back = ct_cat_to_real(ct_real_to_cat(r));
        int64_t err = (int64_t)back - (int64_t)r;
        if (err < 0) err = -err;
        if (err > worst) worst = err;
    }
    printf("  worst real->cat->real error over [0,500k): %lld unit(s)\n", (long long)worst);
    CHECK(worst <= 1, "round-trip error <= 1 unit (got %lld)", (long long)worst);

    /* cat->real->cat is intrinsically coarser: a real-second spans 625/54 ~=
     * 11.57 cat-units, so distinct cat values collapse onto the same real and
     * cannot be recovered. The error is bounded by ceil((625/54)/2) = 6 -- a
     * property of the lattice, not of the rounding. (Rounding still minimises
     * it: truncation would push this to ~11.) */
    const int64_t CAT_RT_BOUND = 6;
    int64_t worst2 = 0;
    for (uint64_t c = 0; c < 500000; c++) {
        uint64_t back = ct_real_to_cat(ct_cat_to_real(c));
        int64_t err = (int64_t)back - (int64_t)c;
        if (err < 0) err = -err;
        if (err > worst2) worst2 = err;
    }
    printf("  worst cat->real->cat error over [0,500k): %lld unit(s) (bound %lld)\n",
           (long long)worst2, (long long)CAT_RT_BOUND);
    CHECK(worst2 <= CAT_RT_BOUND, "cat round-trip error <= %lld units (got %lld)",
          (long long)CAT_RT_BOUND, (long long)worst2);
}

static void test_detached_mode(void) {
    printf("[detached virtual-crystal mode]\n");
    CHECK(ct_is_detached() == 0, "starts attached");
    ct_detach(1000);
    CHECK(ct_is_detached() == 1, "detach() switches mode");
    CHECK(ct_now_unix_sec() == 1000, "detached now == anchor");
    CHECK(ct_now_unix_ns() == 1000ull * 1000000000ull, "detached ns == anchor*1e9");
    ct_tick(5);
    CHECK(ct_now_unix_sec() == 1005, "tick advances the counter");
    ct_attach();
    CHECK(ct_is_detached() == 0, "attach() restores wall-clock mode");
    /* tick is a no-op while attached: wall clock keeps moving forward */
    uint64_t a = ct_now_unix_sec();
    ct_tick(9999);
    uint64_t b = ct_now_unix_sec();
    CHECK(b >= a && b < a + 10, "tick is a no-op when attached");
}

int main(void) {
    printf("=== catime base API test suite ===\n");
    test_pack_split();
    test_conversion_vectors();
    test_forward_matches_ref();
    test_reverse_is_correctly_rounded();
    test_roundtrip_error_bound();
    test_detached_mode();
    printf("=== %d checks, %d failures ===\n", checks, failures);
    return failures ? 1 : 0;
}
