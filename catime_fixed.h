#ifndef CATIME_FIXED_H
#define CATIME_FIXED_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * libcatime_fixed — software-emulated PTP-style fixed-interval timing.
 *
 * Targets: Linux arm64 (lib_fixed_arm64.s) and x86_64 (lib_fixed_x86.s).
 * No libc dependencies; pure-syscall implementation.
 *
 * The wall clock used is CLOCK_REALTIME, which is assumed to be disciplined
 * by an upstream PTP daemon (ptp4l, chrony with PHC source). On a properly
 * synced host this gives sub-microsecond accuracy. Without PTP, the resolution
 * is set by the kernel's NTP discipline (typically tens of microseconds).
 *
 * For nanosecond-level production HFT, swap CLOCK_REALTIME for the dynamic
 * PHC clockid: open /dev/ptpN, then clockid = ((~fd) << 3) | 3.
 */

/* Current CLOCK_REALTIME in nanoseconds since Unix epoch. */
uint64_t cf_now_ns(void);

/* Convert real ns -> cat ns via exact integer ratio 625/54. */
uint64_t cf_to_cat_ns(uint64_t real_ns);

/* Convert cat ns -> real ns via exact integer ratio 54/625. */
uint64_t cf_from_cat_ns(uint64_t cat_ns);

/* Spin on cf_now_ns() until it reaches target_ns; return the actual
 * sample observed at exit. The returned value is >= target_ns and the
 * positive difference is the per-tick "drift" of your spin loop. */
uint64_t cf_wait_until_ns(uint64_t target_ns);

/* Smallest k*interval_ns strictly greater than now_ns. Use to align ticks
 * to an absolute wall-clock grid (so multiple hosts tick in lock-step). */
uint64_t cf_next_grid_ns(uint64_t now_ns, uint64_t interval_ns);

#ifdef __cplusplus
}
#endif

#endif /* CATIME_FIXED_H */
