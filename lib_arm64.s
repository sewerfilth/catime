// libcatime — arm64 / Darwin Mach-O (base API)
//
// Standard catime conversion + decomposition primitives. Links against libc
// for system-time access (clock_gettime).
//
// Detached mode lets the developer drive a "synthetic timebase" — the
// virtual crystal — at arbitrary frequency for replay, simulation, and
// deterministic testing. See ct_detach / ct_tick / ct_attach.
//
// Compile:
//   clang -arch arm64 -c lib_arm64.s -o lib_arm64.o

.section __DATA,__bss
.lcomm _ct_mode,    8           // 0 = attached, 1 = detached
.lcomm _ct_counter, 8           // detached: current unix-sec value

.section __TEXT,__text

// ----------------------------------------------------------------------------
// uint64_t ct_real_to_cat(uint64_t real)
//   cat = real * 625 / 54   (magic-mul for /54)
// ----------------------------------------------------------------------------
.global _ct_real_to_cat
.align 2
_ct_real_to_cat:
    mov   w9, #625
    mul   x0, x0, x9
    movz  x9, #0x425F
    movk  x9, #0x097B, lsl #16
    movk  x9, #0x25ED, lsl #32
    movk  x9, #0x97B4, lsl #48
    umulh x0, x0, x9
    lsr   x0, x0, #5
    ret

// ----------------------------------------------------------------------------
// uint64_t ct_cat_to_real(uint64_t cat)
//   real = cat * 54 / 625
// ----------------------------------------------------------------------------
.global _ct_cat_to_real
.align 2
_ct_cat_to_real:
    mov  w9, #54
    mul  x0, x0, x9
    mov  w9, #625
    udiv x0, x0, x9
    ret

// ----------------------------------------------------------------------------
// uint64_t ct_pack(uint64_t h, uint64_t m, uint64_t s)
//   flat = ((h * 100) + m) * 100 + s
// ----------------------------------------------------------------------------
.global _ct_pack
.align 2
_ct_pack:
    mov  w9, #100
    madd x0, x0, x9, x1
    madd x0, x0, x9, x2
    ret

// ----------------------------------------------------------------------------
// void ct_split(uint64_t flat, uint64_t *h, uint64_t *m, uint64_t *s)
// ----------------------------------------------------------------------------
.global _ct_split
.align 2
_ct_split:
    mov  w9, #10000
    udiv x10, x0, x9
    str  x10, [x1]                  // *h = flat / 10000
    mov  w11, #100
    udiv x12, x0, x11               // flat / 100
    udiv x13, x12, x11
    msub x14, x13, x11, x12         // *m = (flat/100) % 100
    str  x14, [x2]
    udiv x13, x0, x11
    msub x14, x13, x11, x0          // *s = flat % 100
    str  x14, [x3]
    ret

// ----------------------------------------------------------------------------
// void ct_detach(uint64_t start_unix_sec)
//   switch to detached mode; ct_now_unix_sec() will return the counter.
// ----------------------------------------------------------------------------
.global _ct_detach
.align 2
_ct_detach:
    adrp x9, _ct_counter@PAGE
    add  x9, x9, _ct_counter@PAGEOFF
    str  x0, [x9]
    adrp x9, _ct_mode@PAGE
    add  x9, x9, _ct_mode@PAGEOFF
    mov  x10, #1
    str  x10, [x9]
    ret

// ----------------------------------------------------------------------------
// void ct_attach(void)
//   switch back to wall-clock-anchored mode.
// ----------------------------------------------------------------------------
.global _ct_attach
.align 2
_ct_attach:
    adrp x9, _ct_mode@PAGE
    add  x9, x9, _ct_mode@PAGEOFF
    str  xzr, [x9]
    ret

// ----------------------------------------------------------------------------
// void ct_tick(uint64_t delta_sec)
//   advance the detached counter; no-op when attached.
// ----------------------------------------------------------------------------
.global _ct_tick
.align 2
_ct_tick:
    adrp x9, _ct_mode@PAGE
    add  x9, x9, _ct_mode@PAGEOFF
    ldr  x10, [x9]
    cbz  x10, 1f
    adrp x9, _ct_counter@PAGE
    add  x9, x9, _ct_counter@PAGEOFF
    ldr  x10, [x9]
    add  x10, x10, x0
    str  x10, [x9]
1:  ret

// ----------------------------------------------------------------------------
// int ct_is_detached(void)
// ----------------------------------------------------------------------------
.global _ct_is_detached
.align 2
_ct_is_detached:
    adrp x9, _ct_mode@PAGE
    add  x9, x9, _ct_mode@PAGEOFF
    ldr  x0, [x9]
    ret

// ----------------------------------------------------------------------------
// uint64_t ct_now_unix_sec(void)
//   detached: return the synthetic counter (single load, ~1ns)
//   attached: clock_gettime(CLOCK_REALTIME).tv_sec  (~13ns via libc)
// ----------------------------------------------------------------------------
.global _ct_now_unix_sec
.align 2
_ct_now_unix_sec:
    adrp x9, _ct_mode@PAGE
    add  x9, x9, _ct_mode@PAGEOFF
    ldr  x10, [x9]
    cbz  x10, 1f
    // detached
    adrp x9, _ct_counter@PAGE
    add  x9, x9, _ct_counter@PAGEOFF
    ldr  x0, [x9]
    ret
1:  // attached
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov w0, #0                      // CLOCK_REALTIME
    add x1, sp, #16
    bl _clock_gettime
    ldr x0, [sp, #16]               // tv_sec
    ldp x29, x30, [sp], #32
    ret

// ----------------------------------------------------------------------------
// uint64_t ct_now_cat_flat(void)
//   sec_of_day = unix % 86400 ; cat_flat = sec_of_day * 625 / 54
// ----------------------------------------------------------------------------
.global _ct_now_cat_flat
.align 2
_ct_now_cat_flat:
    stp x29, x30, [sp, #-16]!
    bl _ct_now_unix_sec
    movz x9, #0x5180
    movk x9, #0x0001, lsl #16       // 86400
    udiv x10, x0, x9
    msub x0, x10, x9, x0            // sec_of_day
    bl _ct_real_to_cat
    ldp x29, x30, [sp], #16
    ret
