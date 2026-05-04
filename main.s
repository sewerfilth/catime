// catime — Computational Adjusted Time
// arm64 / Darwin
//
// usage: catime <real_seconds>
//
// real:     M:SS  (60-base)
// adjusted: M:SS  (100-base, same minute boundary)
//
// adjusted_seconds = real_seconds * 100 / 60 = real_seconds * 5 / 3
//
// Note: Darwin arm64 passes variadic args on the stack, not in x1..x7.

.section __TEXT,__cstring
fmt_real:    .asciz "real:     %lld:%02lld\n"
fmt_adj:     .asciz "adjusted: %lld:%02lld\n"
usage_str:   .asciz "usage: catime <real_seconds>\n"

.section __TEXT,__text
.global _main
.align 2
_main:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x29, sp

    cmp w0, #2
    b.lt Lusage

    ldr x0, [x1, #8]
    bl _atoll
    mov x19, x0                 // x19 = total real seconds

    // --- real minutes / seconds ---
    mov x2, #60
    udiv x20, x19, x2           // x20 = real_min
    msub x9, x20, x2, x19       // x9  = real_sec

    sub sp, sp, #16
    stp x20, x9, [sp]           // varargs on stack
    adrp x0, fmt_real@PAGE
    add  x0, x0, fmt_real@PAGEOFF
    bl _printf
    add sp, sp, #16

    // --- adjusted total seconds = real * 5 / 3 ---
    mov x0, x19
    mov x2, #5
    mul x0, x0, x2
    mov x2, #3
    udiv x0, x0, x2

    // adjusted minutes / seconds (100-base)
    mov x2, #100
    udiv x20, x0, x2
    msub x9, x20, x2, x0

    sub sp, sp, #16
    stp x20, x9, [sp]
    adrp x0, fmt_adj@PAGE
    add  x0, x0, fmt_adj@PAGEOFF
    bl _printf
    add sp, sp, #16

    mov w0, #0
Lreturn:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

Lusage:
    adrp x0, usage_str@PAGE
    add  x0, x0, usage_str@PAGEOFF
    bl _printf
    mov w0, #1
    b Lreturn
