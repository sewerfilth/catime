#ifndef CATIME_H
#define CATIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * libcatime — base API.
 *
 * Targets: macOS arm64 (lib_arm64.s) and x86_64 (lib_x86.s).
 * Links against libc for system-time access.
 *
 * For PTP-grade Linux fixed-interval timing, see catime_fixed.h.
 */

/* Convert between real and cat units via the exact 625:54 integer ratio.
 * Works for any consistent unit (seconds, ms, ns) — the ratio is the same. */
uint64_t ct_real_to_cat(uint64_t real);
uint64_t ct_cat_to_real(uint64_t cat);

/* Pack base-100 H:M:S into a flat integer (h*10000 + m*100 + s). */
uint64_t ct_pack(uint64_t h, uint64_t m, uint64_t s);

/* Split a flat integer into base-100 H, M, S components (writes via ptrs). */
void ct_split(uint64_t flat, uint64_t *h, uint64_t *m, uint64_t *s);

/* Current Unix wall-clock seconds (UTC) via CLOCK_REALTIME. */
uint64_t ct_now_unix_sec(void);

/* Current cat time-of-day as flat integer (0..999_999). */
uint64_t ct_now_cat_flat(void);

#ifdef __cplusplus
}
#endif

#endif /* CATIME_H */
