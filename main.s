// catime — Computational Adjusted Time
// arm64 / Darwin
//
// Pure base-100 time-of-day:
//   100 cat-s = 1 cat-min, 100 cat-m = 1 cat-hr, 100 cat-h = 1 cat-day
//   1 cat-day = 1 real day  (wall-time anchor)
//   ratio: cat = real * 625 / 54   (gcd(86400, 1_000_000) = 1600)
//
// usage:
//   catime <real_seconds>      forward (real -> catime)
//   catime -r <cat_seconds>    reverse (catime -> real)
//   catime now                 read CLOCK_REALTIME -> print real & cat time-of-day
//   catime bench               microbenchmarks
//
// Notes:
//   - Darwin arm64 ABI: variadic args go on the stack.
//   - CLOCK_REALTIME = 0, CLOCK_MONOTONIC = 6 on Darwin.
//   - Hot-path formatter is a 200-byte two-digit lookup, ~10 instructions
//     (replaces snprintf, ~9x faster).

.section __TEXT,__cstring
fmt_fwd:     .asciz "real:   %lld\ncatime: %lld\n"
fmt_rev:     .asciz "catime: %lld\nreal:   %lld\n"
fmt_now:     .asciz "unix:        %lld\nreal:        %s   (UTC time-of-day)\ncatime:      %s   (base-100)\ncatime_flat: %lld\n"
fmt_hms_kv:  .asciz "flat:  %lld\nh:     %lld\nm:     %lld\ns:     %lld\nhms:   %s\n"
usage_str:   .asciz "usage:\n  catime <real_seconds>     real -> catime\n  catime -r <cat_seconds>   catime -> real\n  catime now                wall-clock now (real & cat)\n  catime split <flat>       <flat> -> H, M, S (base-100)\n  catime pack <H> <M> <S>   H, M, S -> <flat>\n  catime bench              microbenchmarks\n"
str_bench:   .asciz "bench"
str_now:     .asciz "now"
str_split:   .asciz "split"
str_pack:    .asciz "pack"
str_rev:     .asciz "-r"

bench_hdr:   .asciz "catime microbenchmarks (CLOCK_MONOTONIC, arm64)\n\n"
fmt_b_a:     .asciz "(a)  conversion (magic-mul)  %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_b:     .asciz "(b)  cat-decompose+fmt       %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_b2:    .asciz "(b') real-decompose+fmt      %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_c:     .asciz "(c)  clock_gettime           %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_c2:    .asciz "(c') mach_absolute_time      %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_sum:   .asciz "\nsteady-state cost of a live clock display:\n  real-clock @ 1.000 Hz       per-tick = %4lld ns   ->  %6lld ns/s   (%6lld ppb of one core)\n  cat-clock  @ 11.574 Hz      per-tick = %4lld ns   ->  %6lld ns/s   (%6lld ppb of one core)\n  cat overhead vs real        %lldx steady-state\n"

.align 2
digit_pairs:
    .ascii "00010203040506070809"
    .ascii "10111213141516171819"
    .ascii "20212223242526272829"
    .ascii "30313233343536373839"
    .ascii "40414243444546474849"
    .ascii "50515253545556575859"
    .ascii "60616263646566676869"
    .ascii "70717273747576777879"
    .ascii "80818283848586878889"
    .ascii "90919293949596979899"

.section __TEXT,__text
.global _main

// ============================================================================
// _now_ns -> x0 : CLOCK_MONOTONIC in nanoseconds (for benchmarking)
// ============================================================================
.align 2
_now_ns:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov w0, #6                      // CLOCK_MONOTONIC
    add x1, sp, #16
    bl _clock_gettime
    ldr x0, [sp, #16]
    ldr x1, [sp, #24]
    movz x9, #0xCA00
    movk x9, #0x3B9A, lsl #16       // 1e9
    madd x0, x0, x9, x1
    ldp x29, x30, [sp], #32
    ret

// ============================================================================
// _fmt_hms (x0=buf, x1=h, x2=m, x3=s) -> writes 9 bytes "HH:MM:SS\0"
//   no calls; uses x4..x7; preserves x0..x3 as a side-effect since they're
//   read once at top.
// ============================================================================
.align 2
_fmt_hms:
    adrp x4, digit_pairs@PAGE
    add  x4, x4, digit_pairs@PAGEOFF
    mov  w7, #':'
    add  x5, x4, x1, lsl #1
    ldrh w6, [x5]
    strh w6, [x0]
    strb w7, [x0, #2]
    add  x5, x4, x2, lsl #1
    ldrh w6, [x5]
    strh w6, [x0, #3]
    strb w7, [x0, #5]
    add  x5, x4, x3, lsl #1
    ldrh w6, [x5]
    strh w6, [x0, #6]
    strb wzr, [x0, #8]
    ret

// ============================================================================
// _main
// ============================================================================
.align 2
_main:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x29, sp
    mov x19, x0                     // argc
    mov x20, x1                     // argv

    cmp w19, #2
    b.lt Lusage

    ldr x21, [x20, #8]              // argv[1]

    mov x0, x21
    adrp x1, str_bench@PAGE
    add  x1, x1, str_bench@PAGEOFF
    bl _strcmp
    cbz w0, Lbench

    mov x0, x21
    adrp x1, str_now@PAGE
    add  x1, x1, str_now@PAGEOFF
    bl _strcmp
    cbz w0, Lnow

    mov x0, x21
    adrp x1, str_split@PAGE
    add  x1, x1, str_split@PAGEOFF
    bl _strcmp
    cbz w0, Lsplit

    mov x0, x21
    adrp x1, str_pack@PAGE
    add  x1, x1, str_pack@PAGEOFF
    bl _strcmp
    cbz w0, Lpack

    mov x0, x21
    adrp x1, str_rev@PAGE
    add  x1, x1, str_rev@PAGEOFF
    bl _strcmp
    cbnz w0, Lforward

    // ----- reverse
    cmp w19, #3
    b.lt Lusage
    ldr x0, [x20, #16]
    bl _atoll
    mov x22, x0
    mov w9, #54
    mul x0, x22, x9
    mov w9, #625
    udiv x0, x0, x9
    sub sp, sp, #16
    stp x22, x0, [sp]
    adrp x0, fmt_rev@PAGE
    add  x0, x0, fmt_rev@PAGEOFF
    bl _printf
    add sp, sp, #16
    b Lend_ok

Lforward:
    mov x0, x21
    bl _atoll
    mov x22, x0
    mov w9, #625
    mul x0, x22, x9
    mov w9, #54
    udiv x0, x0, x9
    sub sp, sp, #16
    stp x22, x0, [sp]
    adrp x0, fmt_fwd@PAGE
    add  x0, x0, fmt_fwd@PAGEOFF
    bl _printf
    add sp, sp, #16
    b Lend_ok

// ============================================================================
// now: read CLOCK_REALTIME, print real + cat time-of-day
//   layout of frame at sp:
//     [sp+0..15]   ts (tv_sec, tv_nsec)
//     [sp+16..31]  real_buf (10 bytes, padded)
//     [sp+32..47]  cat_buf  (10 bytes, padded)
// ============================================================================
Lnow:
    sub sp, sp, #48
    mov w0, #0                      // CLOCK_REALTIME
    mov x1, sp
    bl _clock_gettime
    ldr x21, [sp]                   // unix seconds since 1970 UTC

    // sec_of_day = unix % 86400
    movz x9, #0x5180
    movk x9, #0x0001, lsl #16       // 86400
    udiv x10, x21, x9
    msub x22, x10, x9, x21          // x22 = real sec-of-day

    // decompose real (mod 60/60/24)
    mov w9, #3600
    udiv x10, x22, x9
    mov w11, #24
    udiv x12, x10, x11
    msub x10, x12, x11, x10         // h
    mov w11, #60
    udiv x12, x22, x11
    udiv x13, x12, x11
    msub x12, x13, x11, x12         // m
    udiv x13, x22, x11
    msub x13, x13, x11, x22         // s

    add x0, sp, #16                 // real_buf
    mov x1, x10
    mov x2, x12
    mov x3, x13
    bl _fmt_hms

    // cat_flat = real_sec_of_day * 625 / 54
    mov w9, #625
    mul x23, x22, x9
    mov w9, #54
    udiv x23, x23, x9               // x23 = cat flat (0..999999)

    // decompose cat (mod 100)
    mov w9, #10000
    udiv x10, x23, x9
    mov w11, #100
    udiv x12, x10, x11
    msub x10, x12, x11, x10         // h
    udiv x12, x23, x11
    udiv x13, x12, x11
    msub x12, x13, x11, x12         // m
    udiv x13, x23, x11
    msub x13, x13, x11, x23         // s

    add x0, sp, #32                 // cat_buf
    mov x1, x10
    mov x2, x12
    mov x3, x13
    bl _fmt_hms

    // printf(fmt_now, unix, real_buf, cat_buf, cat_flat)
    sub sp, sp, #32                 // 4 varargs = 32 bytes
    str x21, [sp]
    add x9, sp, #(32+16)            // real_buf, adjusted for new sp
    str x9, [sp, #8]
    add x9, sp, #(32+32)            // cat_buf
    str x9, [sp, #16]
    str x23, [sp, #24]
    adrp x0, fmt_now@PAGE
    add  x0, x0, fmt_now@PAGEOFF
    bl _printf
    add sp, sp, #32

    add sp, sp, #48
    b Lend_ok

// ============================================================================
// split: flat -> h, m, s (base-100)
//   h = flat / 10000 ; m = (flat / 100) % 100 ; s = flat % 100
// ============================================================================
Lsplit:
    cmp w19, #3
    b.lt Lusage
    ldr x0, [x20, #16]
    bl _atoll
    mov x21, x0                     // flat

    mov w9, #10000
    udiv x22, x21, x9               // h = flat / 10000
    mov w11, #100
    udiv x9, x21, x11               // flat / 100
    udiv x10, x9, x11               // (flat/100) / 100
    msub x23, x10, x11, x9          // m = (flat/100) % 100
    udiv x9, x21, x11
    msub x24, x9, x11, x21          // s = flat % 100

    sub sp, sp, #16                 // hms_buf
    mov x0, sp
    mov x1, x22
    mov x2, x23
    mov x3, x24
    bl _fmt_hms

    sub sp, sp, #48                 // 5 varargs
    str x21, [sp]                   // flat
    str x22, [sp, #8]               // h
    str x23, [sp, #16]              // m
    str x24, [sp, #24]              // s
    add x9, sp, #48
    str x9, [sp, #32]               // hms_buf addr
    adrp x0, fmt_hms_kv@PAGE
    add  x0, x0, fmt_hms_kv@PAGEOFF
    bl _printf
    add sp, sp, #48
    add sp, sp, #16
    b Lend_ok

// ============================================================================
// pack: h, m, s -> flat
//   flat = h * 10000 + m * 100 + s = ((h * 100) + m) * 100 + s
// ============================================================================
Lpack:
    cmp w19, #5
    b.lt Lusage
    ldr x0, [x20, #16]
    bl _atoll
    mov x21, x0                     // h
    ldr x0, [x20, #24]
    bl _atoll
    mov x22, x0                     // m
    ldr x0, [x20, #32]
    bl _atoll
    mov x23, x0                     // s

    mov w11, #100
    madd x24, x21, x11, x22         // h*100 + m
    madd x24, x24, x11, x23         // (h*100 + m)*100 + s = flat

    sub sp, sp, #16
    mov x0, sp
    mov x1, x21
    mov x2, x22
    mov x3, x23
    bl _fmt_hms

    sub sp, sp, #48
    str x24, [sp]                   // flat
    str x21, [sp, #8]               // h
    str x22, [sp, #16]              // m
    str x23, [sp, #24]              // s
    add x9, sp, #48
    str x9, [sp, #32]               // hms_buf
    adrp x0, fmt_hms_kv@PAGE
    add  x0, x0, fmt_hms_kv@PAGEOFF
    bl _printf
    add sp, sp, #48
    add sp, sp, #16
    b Lend_ok

// ============================================================================
// bench
// ============================================================================
Lbench:
    adrp x0, bench_hdr@PAGE
    add  x0, x0, bench_hdr@PAGEOFF
    bl _printf

    sub sp, sp, #32                 // scratch: 0=a 8=b 16=b' 24=c (ns/op)

    // ----- (a) conversion: 100M iters of x = (x+1) * 625 / 54
    //                       div-by-54 via magic-multiply (umulh + lsr #5)
    bl _now_ns
    mov x21, x0
    mov x22, #0
    movz x23, #0xE100
    movk x23, #0x05F5, lsl #16      // 100M
    mov w9,  #625
    // magic for d=54 (clang -O3 derived): 0x97B425ED097B425F
    movz x10, #0x425F
    movk x10, #0x097B, lsl #16
    movk x10, #0x25ED, lsl #32
    movk x10, #0x97B4, lsl #48
.La_loop:
    add   x22, x22, #1
    mul   x22, x22, x9
    umulh x22, x22, x10             // upper 64 of x22 * magic
    lsr   x22, x22, #5              // -> x22 / 54
    subs x23, x23, #1
    b.ne .La_loop
    bl _now_ns
    sub x0, x0, x21
    movz x9, #0xE100
    movk x9, #0x05F5, lsl #16
    udiv x10, x0, x9
    str x10, [sp]                   // a

    sub sp, sp, #32
    stp x9, x0, [sp]
    str x10, [sp, #16]
    adrp x0, fmt_b_a@PAGE
    add  x0, x0, fmt_b_a@PAGEOFF
    bl _printf
    add sp, sp, #32

    // ----- (b) cat decompose + fmt: 1M iters
    bl _now_ns
    mov x21, x0
    mov x22, #1
    movz x23, #0x4240
    movk x23, #0x000F, lsl #16      // 1M
.Lb_loop:
    mov w9, #10000
    udiv x10, x22, x9
    mov w11, #100
    udiv x12, x10, x11
    msub x10, x12, x11, x10         // h
    udiv x12, x22, x11
    udiv x13, x12, x11
    msub x12, x13, x11, x12         // m
    udiv x13, x22, x11
    msub x13, x13, x11, x22         // s

    sub sp, sp, #16                 // 9-byte buf padded to 16
    mov x0, sp
    mov x1, x10
    mov x2, x12
    mov x3, x13
    bl _fmt_hms
    add sp, sp, #16

    add  x22, x22, #1
    subs x23, x23, #1
    b.ne .Lb_loop
    bl _now_ns
    sub x0, x0, x21
    movz x9, #0x4240
    movk x9, #0x000F, lsl #16
    udiv x10, x0, x9
    str x10, [sp, #8]               // b

    sub sp, sp, #32
    stp x9, x0, [sp]
    str x10, [sp, #16]
    adrp x0, fmt_b_b@PAGE
    add  x0, x0, fmt_b_b@PAGEOFF
    bl _printf
    add sp, sp, #32

    // ----- (b') real decompose + fmt: 1M iters
    bl _now_ns
    mov x21, x0
    mov x22, #1
    movz x23, #0x4240
    movk x23, #0x000F, lsl #16
.Lb2_loop:
    mov w9, #3600
    udiv x10, x22, x9
    mov w11, #24
    udiv x12, x10, x11
    msub x10, x12, x11, x10         // h
    mov w11, #60
    udiv x12, x22, x11
    udiv x13, x12, x11
    msub x12, x13, x11, x12         // m
    udiv x13, x22, x11
    msub x13, x13, x11, x22         // s

    sub sp, sp, #16
    mov x0, sp
    mov x1, x10
    mov x2, x12
    mov x3, x13
    bl _fmt_hms
    add sp, sp, #16

    add  x22, x22, #1
    subs x23, x23, #1
    b.ne .Lb2_loop
    bl _now_ns
    sub x0, x0, x21
    movz x9, #0x4240
    movk x9, #0x000F, lsl #16
    udiv x10, x0, x9
    str x10, [sp, #16]              // b'

    sub sp, sp, #32
    stp x9, x0, [sp]
    str x10, [sp, #16]
    adrp x0, fmt_b_b2@PAGE
    add  x0, x0, fmt_b_b2@PAGEOFF
    bl _printf
    add sp, sp, #32

    // ----- (c) clock_gettime: 1M iters
    bl _now_ns
    mov x21, x0
    movz x23, #0x4240
    movk x23, #0x000F, lsl #16
.Lc_loop:
    bl _now_ns
    subs x23, x23, #1
    b.ne .Lc_loop
    bl _now_ns
    sub x0, x0, x21
    movz x9, #0x4240
    movk x9, #0x000F, lsl #16
    udiv x10, x0, x9
    str x10, [sp, #24]              // c

    sub sp, sp, #32
    stp x9, x0, [sp]
    str x10, [sp, #16]
    adrp x0, fmt_b_c@PAGE
    add  x0, x0, fmt_b_c@PAGEOFF
    bl _printf
    add sp, sp, #32

    // ----- (c') mach_absolute_time: 1M iters
    bl _now_ns
    mov x21, x0
    movz x23, #0x4240
    movk x23, #0x000F, lsl #16
.Lc2_loop:
    bl _mach_absolute_time
    subs x23, x23, #1
    b.ne .Lc2_loop
    bl _now_ns
    sub x0, x0, x21
    movz x9, #0x4240
    movk x9, #0x000F, lsl #16
    udiv x10, x0, x9

    sub sp, sp, #32
    stp x9, x0, [sp]
    str x10, [sp, #16]
    adrp x0, fmt_b_c2@PAGE
    add  x0, x0, fmt_b_c2@PAGEOFF
    bl _printf
    add sp, sp, #32

    // ----- summary
    ldr x4, [sp]
    ldr x5, [sp, #8]
    ldr x6, [sp, #16]
    ldr x7, [sp, #24]

    add x10, x6, x7                 // real per-tick = b' + c
    mov x11, x10
    mov x12, x10

    add x13, x4, x5
    add x13, x13, x7                // cat per-tick = a + b + c
    mov w9, #625
    mul x14, x13, x9
    mov w9, #54
    udiv x14, x14, x9               // cat ns/s
    mov x15, x14

    udiv x16, x14, x11              // ratio

    sub sp, sp, #64
    str x10, [sp]
    str x11, [sp, #8]
    str x12, [sp, #16]
    str x13, [sp, #24]
    str x14, [sp, #32]
    str x15, [sp, #40]
    str x16, [sp, #48]
    adrp x0, fmt_b_sum@PAGE
    add  x0, x0, fmt_b_sum@PAGEOFF
    bl _printf
    add sp, sp, #64

    add sp, sp, #32                 // free scratch

Lend_ok:
    mov w0, #0
Lreturn:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

Lusage:
    adrp x0, usage_str@PAGE
    add  x0, x0, usage_str@PAGEOFF
    bl _printf
    mov w0, #1
    b Lreturn
