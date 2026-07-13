// libcatime_fixed — arm64 / Linux ELF, pure syscalls (no libc deps)
//
// Software-emulated PTP-style fixed-interval timing primitives. The
// underlying clock is whatever the kernel exposes via CLOCK_REALTIME;
// when the host runs ptp4l/chrony with a PHC source, that clock is
// sub-microsecond accurate.
//
// All entry points follow the standard AArch64 PCS C ABI.
//
// Compile:
//   clang -target aarch64-linux-gnu -nostdlib -c lib_fixed_arm64.s
//
// API (see catime_fixed.h):
//   uint64_t cf_now_ns(void);
//   uint64_t cf_to_cat_ns(uint64_t real_ns);
//   uint64_t cf_from_cat_ns(uint64_t cat_ns);
//   uint64_t cf_wait_until_ns(uint64_t target_ns);
//   uint64_t cf_next_grid_ns(uint64_t now_ns, uint64_t interval_ns);

.equ SYS_clock_gettime, 113
.equ SYS_openat,        56          // aarch64 has no bare open(2); use openat
.equ AT_FDCWD,          -100
.equ O_RDONLY,          0
.equ CLOCK_REALTIME,    0

.section .bss
.lcomm cf_ts, 16                    // shared timespec scratch

.section .text

// ----------------------------------------------------------------------------
// uint64_t cf_now_ns(void)
// ----------------------------------------------------------------------------
.global cf_now_ns
.type   cf_now_ns, %function
cf_now_ns:
    mov  x0, #CLOCK_REALTIME
    adrp x1, cf_ts
    add  x1, x1, :lo12:cf_ts
    mov  x8, #SYS_clock_gettime
    svc  #0
    adrp x1, cf_ts
    add  x1, x1, :lo12:cf_ts
    ldr  x9,  [x1]                  // tv_sec
    ldr  x10, [x1, #8]              // tv_nsec
    movz x11, #0xCA00
    movk x11, #0x3B9A, lsl #16      // 1e9
    madd x0, x9, x11, x10
    ret

// ----------------------------------------------------------------------------
// uint64_t cf_to_cat_ns(uint64_t real_ns)
//   cat = real * 625 / 54 (magic-mul for /54)
// ----------------------------------------------------------------------------
.global cf_to_cat_ns
.type   cf_to_cat_ns, %function
cf_to_cat_ns:
    mov   w9, #625
    mul   x0, x0, x9
    movz  x9, #0x425F
    movk  x9, #0x097B, lsl #16
    movk  x9, #0x25ED, lsl #32
    movk  x9, #0x97B4, lsl #48      // magic for d=54
    umulh x0, x0, x9
    lsr   x0, x0, #5
    ret

// ----------------------------------------------------------------------------
// uint64_t cf_from_cat_ns(uint64_t cat_ns)
//   real = round(cat * 54 / 625) — add 625/2 = 312 for round-to-nearest.
//   The remainder (cat*54) mod 625 is integral, so the 312.5 half-point is
//   never hit: correctly rounded (r>=313 up, r<=312 down).
// ----------------------------------------------------------------------------
.global cf_from_cat_ns
.type   cf_from_cat_ns, %function
cf_from_cat_ns:
    mov  w9, #54
    mul  x0, x0, x9
    add  x0, x0, #312               // + 625/2 : round-to-nearest
    mov  w9, #625
    udiv x0, x0, x9
    ret

// ----------------------------------------------------------------------------
// uint64_t cf_wait_until_ns(uint64_t target_ns)
//   Spin on cf_now_ns(); return first sample >= target.
// ----------------------------------------------------------------------------
.global cf_wait_until_ns
.type   cf_wait_until_ns, %function
cf_wait_until_ns:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0                     // target
1:  bl  cf_now_ns
    cmp x0, x19
    b.lt 1b
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ----------------------------------------------------------------------------
// uint64_t cf_next_grid_ns(uint64_t now_ns, uint64_t interval_ns)
//   Smallest k*interval strictly greater than now.
// ----------------------------------------------------------------------------
.global cf_next_grid_ns
.type   cf_next_grid_ns, %function
cf_next_grid_ns:
    udiv x9, x0, x1
    add  x9, x9, #1
    mul  x0, x9, x1
    ret

// ----------------------------------------------------------------------------
// Dynamic PHC (PTP hardware clock) source.
//
// A NIC's PTP hardware clock is exposed as /dev/ptpN. To read it you open the
// device, turn its fd into a dynamic POSIX clockid, and clock_gettime() that.
// Kernel FD_TO_CLOCKID: ((~fd) << 3) | CLOCKFD, with CLOCKFD = 3.
//
//   int      fd  = cf_open_phc("/dev/ptp0");   // negative on error (-errno)
//   int      cid = cf_phc_clockid(fd);
//   uint64_t ns  = cf_now_dynamic_ns(cid);     // PHC time in ns
//
// cf_now_dynamic_ns(CLOCK_REALTIME) is equivalent to cf_now_ns().
// ----------------------------------------------------------------------------

// int cf_open_phc(const char *path)
//   openat(AT_FDCWD, path, O_RDONLY, 0)
.global cf_open_phc
.type   cf_open_phc, %function
cf_open_phc:
    mov  x1, x0                     // path -> arg2
    mov  x0, #AT_FDCWD             // dirfd
    mov  x2, #O_RDONLY            // flags
    mov  x3, #0                    // mode
    mov  x8, #SYS_openat
    svc  #0
    ret

// int cf_phc_clockid(int fd)
//   FD_TO_CLOCKID(fd) = ((~fd) << 3) | 3
.global cf_phc_clockid
.type   cf_phc_clockid, %function
cf_phc_clockid:
    mvn  w0, w0
    lsl  w0, w0, #3
    orr  w0, w0, #3
    sxtw x0, w0                     // clockid_t is signed; sign-extend
    ret

// uint64_t cf_now_dynamic_ns(int clockid)
//   clock_gettime(clockid, &cf_ts) -> tv_sec*1e9 + tv_nsec
.global cf_now_dynamic_ns
.type   cf_now_dynamic_ns, %function
cf_now_dynamic_ns:
    sxtw x0, w0                     // clockid (may be negative for a PHC)
    adrp x1, cf_ts
    add  x1, x1, :lo12:cf_ts
    mov  x8, #SYS_clock_gettime
    svc  #0
    adrp x1, cf_ts
    add  x1, x1, :lo12:cf_ts
    ldr  x9,  [x1]                  // tv_sec
    ldr  x10, [x1, #8]              // tv_nsec
    movz x11, #0xCA00
    movk x11, #0x3B9A, lsl #16      // 1e9
    madd x0, x9, x11, x10
    ret
