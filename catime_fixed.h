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
 * For nanosecond-level production HFT, read the NIC's PTP hardware clock
 * directly via the dynamic PHC clock API below (cf_open_phc / cf_phc_clockid
 * / cf_now_dynamic_ns) rather than CLOCK_REALTIME.
 */

/* Current CLOCK_REALTIME in nanoseconds since Unix epoch. */
uint64_t cf_now_ns(void);

/*
 * Dynamic PHC (PTP hardware clock) source.
 *
 * A NIC's PTP hardware clock is exposed at /dev/ptpN. Open the device, convert
 * its fd to a dynamic POSIX clockid, then read that clockid. Typical use:
 *
 *   int      fd  = cf_open_phc("/dev/ptp0");   // < 0 on error (-errno)
 *   int      cid = cf_phc_clockid(fd);
 *   uint64_t ns  = cf_now_dynamic_ns(cid);     // PHC time, ns since epoch
 *
 * cf_now_dynamic_ns(CLOCK_REALTIME) is equivalent to cf_now_ns(). These are
 * Linux-only (they issue openat(2)/clock_gettime(2) syscalls directly).
 */

/* openat(AT_FDCWD, path, O_RDONLY). Returns an fd, or a negative errno. */
int cf_open_phc(const char *path);

/* Kernel FD_TO_CLOCKID: ((~fd) << 3) | 3. */
int cf_phc_clockid(int fd);

/* clock_gettime(clockid) in nanoseconds since epoch. */
uint64_t cf_now_dynamic_ns(int clockid);

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
