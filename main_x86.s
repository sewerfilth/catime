// catime — Computational Adjusted Time
// x86_64 / Darwin (Mach-O), AT&T syntax
//
// Pure base-100 time-of-day:
//   100 cat-s = 1 cat-min, 100 cat-m = 1 cat-hr, 100 cat-h = 1 cat-day
//   1 cat-day = 1 real day  (wall-time anchor)
//   ratio: cat = real * 625 / 54
//
// usage:
//   catime-x86 <real_seconds>      forward
//   catime-x86 -r <cat_seconds>    reverse
//   catime-x86 now                 wall-clock now (real & cat)
//   catime-x86 bench               microbenchmarks
//
// ABI: System V x86_64. Variadic calls require %al = vector-arg count
//      (we always set al=0 since no xmm args).
// Clocks: CLOCK_REALTIME=0, CLOCK_MONOTONIC=6 on Darwin.

.section __TEXT,__cstring
fmt_fwd:     .asciz "real:   %lld\ncatime: %lld\n"
fmt_rev:     .asciz "catime: %lld\nreal:   %lld\n"
fmt_now:     .asciz "unix:        %lld\nreal:        %s   (UTC time-of-day)\ncatime:      %s   (base-100)\ncatime_flat: %lld\n"
fmt_hms_kv:  .asciz "flat:  %lld\nh:     %lld\nm:     %lld\ns:     %lld\nhms:   %s\n"
usage_str:   .asciz "usage:\n  catime-x86 <real_seconds>     real -> catime\n  catime-x86 -r <cat_seconds>   catime -> real\n  catime-x86 now                wall-clock now\n  catime-x86 split <flat>       <flat> -> H, M, S\n  catime-x86 pack <H> <M> <S>   H, M, S -> <flat>\n  catime-x86 bench              microbenchmarks\n"
str_bench:   .asciz "bench"
str_now:     .asciz "now"
str_split:   .asciz "split"
str_pack:    .asciz "pack"
str_rev:     .asciz "-r"

bench_hdr:   .asciz "catime microbenchmarks (CLOCK_MONOTONIC, x86_64)\n\n"
fmt_b_a:     .asciz "(a)  conversion (magic-mul)  %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_b:     .asciz "(b)  cat-decompose+fmt       %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_b2:    .asciz "(b') real-decompose+fmt      %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_c:     .asciz "(c)  clock_gettime           %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_c2:    .asciz "(c') mach_absolute_time      %12lld iters  %12lld ns total  %8lld ns/op\n"
fmt_b_sum:   .asciz "\nsteady-state cost of a live clock display:\n  real-clock @ 1.000 Hz       per-tick = %4lld ns   ->  %6lld ns/s   (%6lld ppb of one core)\n  cat-clock  @ 11.574 Hz      per-tick = %4lld ns   ->  %6lld ns/s   (%6lld ppb of one core)\n  cat overhead vs real        %lldx steady-state\n"

.section __TEXT,__const
.p2align 4
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

// ============================================================================
// _now_ns -> %rax : CLOCK_MONOTONIC nanoseconds (bench timing only)
// ============================================================================
.p2align 4
_now_ns:
    pushq %rbp
    movq  %rsp, %rbp
    subq  $16, %rsp                   // ts on stack (16 bytes, aligned)
    movl  $6, %edi                    // CLOCK_MONOTONIC
    movq  %rsp, %rsi
    xorl  %eax, %eax                  // no vector args
    callq _clock_gettime
    movq  (%rsp), %rax                // tv_sec
    movq  8(%rsp), %rdx               // tv_nsec
    imulq $1000000000, %rax, %rax     // sec * 1e9
    addq  %rdx, %rax
    leave
    retq

// ============================================================================
// _fmt_hms : %rdi=buf, %rsi=h, %rdx=m, %rcx=s -> writes 9 bytes "HH:MM:SS\0"
// ============================================================================
.p2align 4
_fmt_hms:
    leaq  digit_pairs(%rip), %r8
    movw  (%r8, %rsi, 2), %ax
    movw  %ax, (%rdi)
    movb  $':', 2(%rdi)
    movw  (%r8, %rdx, 2), %ax
    movw  %ax, 3(%rdi)
    movb  $':', 5(%rdi)
    movw  (%r8, %rcx, 2), %ax
    movw  %ax, 6(%rdi)
    movb  $0, 8(%rdi)
    retq

// ============================================================================
// _main
// ============================================================================
.globl _main
.p2align 4
_main:
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq  $40, %rsp                   // 8 align + 32 scratch (a/b/b'/c ns/op)

    movq  %rdi, %r12                  // argc
    movq  %rsi, %r13                  // argv

    cmpl  $2, %r12d
    jl    Lusage

    movq  8(%r13), %r14               // argv[1]

    // dispatch: "bench"
    movq  %r14, %rdi
    leaq  str_bench(%rip), %rsi
    callq _strcmp
    testl %eax, %eax
    jz    Lbench

    // dispatch: "now"
    movq  %r14, %rdi
    leaq  str_now(%rip), %rsi
    callq _strcmp
    testl %eax, %eax
    jz    Lnow

    // dispatch: "split"
    movq  %r14, %rdi
    leaq  str_split(%rip), %rsi
    callq _strcmp
    testl %eax, %eax
    jz    Lsplit

    // dispatch: "pack"
    movq  %r14, %rdi
    leaq  str_pack(%rip), %rsi
    callq _strcmp
    testl %eax, %eax
    jz    Lpack

    // dispatch: "-r"
    movq  %r14, %rdi
    leaq  str_rev(%rip), %rsi
    callq _strcmp
    testl %eax, %eax
    jnz   Lforward

    // ----- reverse: real = cat * 54 / 625
    cmpl  $3, %r12d
    jl    Lusage
    movq  16(%r13), %rdi
    callq _atoll
    movq  %rax, %r15                  // input
    imulq $54, %rax, %rax
    xorl  %edx, %edx
    movq  $625, %rcx
    divq  %rcx                        // rax = real
    leaq  fmt_rev(%rip), %rdi
    movq  %r15, %rsi                  // cat
    movq  %rax, %rdx                  // real
    xorl  %eax, %eax
    callq _printf
    jmp   Lend_ok

Lforward:
    movq  %r14, %rdi
    callq _atoll
    movq  %rax, %r15
    imulq $625, %rax, %rax
    xorl  %edx, %edx
    movq  $54, %rcx
    divq  %rcx
    leaq  fmt_fwd(%rip), %rdi
    movq  %r15, %rsi                  // real
    movq  %rax, %rdx                  // cat
    xorl  %eax, %eax
    callq _printf
    jmp   Lend_ok

// ============================================================================
// now: read CLOCK_REALTIME, print real & cat time-of-day
//   on-stack frame after subq $48: 0..15=ts, 16..25=real_buf, 32..41=cat_buf
// ============================================================================
Lnow:
    subq  $48, %rsp
    movl  $0, %edi                    // CLOCK_REALTIME
    movq  %rsp, %rsi
    xorl  %eax, %eax
    callq _clock_gettime
    movq  (%rsp), %r15                // unix seconds (UTC since 1970)

    // sec_of_day = unix % 86400
    movq  %r15, %rax
    xorl  %edx, %edx
    movq  $86400, %rcx
    divq  %rcx                        // rax=quot, rdx=rem
    movq  %rdx, %rbx                  // rbx = real sec-of-day

    // real decompose: h = (sec/3600) % 24 ; m = (sec/60) % 60 ; s = sec % 60
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $3600, %rcx
    divq  %rcx
    xorl  %edx, %edx
    movq  $24, %rcx
    divq  %rcx
    movq  %rdx, %r8                   // h_real

    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $60, %rcx
    divq  %rcx
    movq  %rdx, %r10                  // s_real
    xorl  %edx, %edx
    divq  %rcx
    movq  %rdx, %r9                   // m_real

    leaq  16(%rsp), %rdi              // real_buf
    movq  %r8, %rsi
    movq  %r9, %rdx
    movq  %r10, %rcx
    callq _fmt_hms

    // cat_flat = sec-of-day * 625 / 54
    movq  %rbx, %rax
    imulq $625, %rax, %rax
    xorl  %edx, %edx
    movq  $54, %rcx
    divq  %rcx
    movq  %rax, %r14                  // r14 = cat_flat

    // decompose cat (mod 100)
    movq  %r14, %rax
    xorl  %edx, %edx
    movq  $10000, %rcx
    divq  %rcx
    xorl  %edx, %edx
    movq  $100, %rcx
    divq  %rcx
    movq  %rdx, %r8                   // h_cat

    movq  %r14, %rax
    xorl  %edx, %edx
    movq  $100, %rcx
    divq  %rcx
    movq  %rdx, %r10                  // s_cat
    xorl  %edx, %edx
    divq  %rcx
    movq  %rdx, %r9                   // m_cat

    leaq  32(%rsp), %rdi              // cat_buf
    movq  %r8, %rsi
    movq  %r9, %rdx
    movq  %r10, %rcx
    callq _fmt_hms

    // printf(fmt_now, unix, real_buf, cat_buf, cat_flat) — all in regs
    leaq  fmt_now(%rip), %rdi
    movq  %r15, %rsi
    leaq  16(%rsp), %rdx
    leaq  32(%rsp), %rcx
    movq  %r14, %r8
    xorl  %eax, %eax
    callq _printf

    addq  $48, %rsp
    jmp   Lend_ok

// ============================================================================
// split: flat -> h, m, s
// ============================================================================
Lsplit:
    cmpl  $3, %r12d
    jl    Lusage
    movq  16(%r13), %rdi
    callq _atoll
    movq  %rax, %rbx                  // flat

    // h = flat / 10000
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $10000, %rcx
    divq  %rcx
    movq  %rax, %r12                  // h

    // m, s via two divs by 100
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $100, %rcx
    divq  %rcx
    movq  %rdx, %r15                  // s = flat % 100
    xorl  %edx, %edx
    divq  %rcx
    movq  %rdx, %r14                  // m = (flat/100) % 100

    subq  $16, %rsp                   // hms_buf
    movq  %rsp, %rdi
    movq  %r12, %rsi
    movq  %r14, %rdx
    movq  %r15, %rcx
    callq _fmt_hms

    leaq  fmt_hms_kv(%rip), %rdi
    movq  %rbx, %rsi                  // flat
    movq  %r12, %rdx                  // h
    movq  %r14, %rcx                  // m
    movq  %r15, %r8                   // s
    movq  %rsp, %r9                   // hms_buf
    xorl  %eax, %eax
    callq _printf
    addq  $16, %rsp
    jmp   Lend_ok

// ============================================================================
// pack: h, m, s -> flat = ((h*100) + m)*100 + s
// ============================================================================
Lpack:
    cmpl  $5, %r12d
    jl    Lusage
    movq  16(%r13), %rdi
    callq _atoll
    movq  %rax, %rbx                  // h
    movq  24(%r13), %rdi
    callq _atoll
    movq  %rax, %r12                  // m  (argc no longer needed)
    movq  32(%r13), %rdi
    callq _atoll
    movq  %rax, %r14                  // s

    imulq $100, %rbx, %rax            // h*100
    addq  %r12, %rax                  // + m
    imulq $100, %rax, %rax            // *100
    addq  %r14, %rax                  // + s
    movq  %rax, %r15                  // flat

    subq  $16, %rsp                   // hms_buf
    movq  %rsp, %rdi
    movq  %rbx, %rsi
    movq  %r12, %rdx
    movq  %r14, %rcx
    callq _fmt_hms

    leaq  fmt_hms_kv(%rip), %rdi
    movq  %r15, %rsi                  // flat
    movq  %rbx, %rdx                  // h
    movq  %r12, %rcx                  // m
    movq  %r14, %r8                   // s
    movq  %rsp, %r9                   // hms_buf
    xorl  %eax, %eax
    callq _printf
    addq  $16, %rsp
    jmp   Lend_ok

// ============================================================================
// bench
// ============================================================================
Lbench:
    leaq  bench_hdr(%rip), %rdi
    xorl  %eax, %eax
    callq _printf

    // scratch slots (relative to current %rsp): 0=a, 8=b, 16=b', 24=c

    // ----- (a) conversion: 100M iters of x = (x+1) * 625 / 54
    //                       div-by-54 via magic-multiply (mulq + shrq $5)
    callq _now_ns
    movq  %rax, %r15                  // start

    xorq  %rbx, %rbx                  // x
    movq  $100000000, %r12            // iters
.La_loop:
    incq  %rbx
    movq  %rbx, %rax
    imulq $625, %rax, %rax
    movabsq $0x97B425ED097B425F, %rcx // magic for d=54
    mulq  %rcx                        // rdx:rax = rax * rcx
    shrq  $5, %rdx                    // rdx = rax / 54
    movq  %rdx, %rbx
    decq  %r12
    jnz   .La_loop

    callq _now_ns
    subq  %r15, %rax                  // elapsed
    movq  %rax, %r12                  // total ns
    movq  $100000000, %rcx
    xorl  %edx, %edx
    movq  %rax, %rax                  // already in rax
    divq  %rcx                        // rax = ns/op
    movq  %rax, (%rsp)                // a

    leaq  fmt_b_a(%rip), %rdi
    movq  $100000000, %rsi
    movq  %r12, %rdx
    movq  %rax, %rcx
    xorl  %eax, %eax
    callq _printf

    // ----- (b) cat-decompose + fmt: 1M iters
    callq _now_ns
    movq  %rax, %r15

    movq  $1, %rbx                    // value
    movq  $1000000, %r12              // iters
.Lb_loop:
    // h = (x / 10000) % 100
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $10000, %rcx
    divq  %rcx
    xorl  %edx, %edx
    movq  $100, %rcx
    divq  %rcx
    movq  %rdx, %r8                   // h
    // m = (x / 100) % 100
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $100, %rcx
    divq  %rcx
    movq  %rdx, %r10                  // s
    xorl  %edx, %edx
    divq  %rcx
    movq  %rdx, %r9                   // m

    subq  $16, %rsp                   // 9-byte buf padded
    movq  %rsp, %rdi
    movq  %r8, %rsi
    movq  %r9, %rdx
    movq  %r10, %rcx
    callq _fmt_hms
    addq  $16, %rsp

    incq  %rbx
    decq  %r12
    jnz   .Lb_loop

    callq _now_ns
    subq  %r15, %rax
    movq  %rax, %r12
    movq  $1000000, %rcx
    xorl  %edx, %edx
    divq  %rcx
    movq  %rax, 8(%rsp)               // b

    leaq  fmt_b_b(%rip), %rdi
    movq  $1000000, %rsi
    movq  %r12, %rdx
    movq  %rax, %rcx
    xorl  %eax, %eax
    callq _printf

    // ----- (b') real-decompose + fmt: 1M iters
    callq _now_ns
    movq  %rax, %r15

    movq  $1, %rbx
    movq  $1000000, %r12
.Lb2_loop:
    // h = (x / 3600) % 24
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $3600, %rcx
    divq  %rcx
    xorl  %edx, %edx
    movq  $24, %rcx
    divq  %rcx
    movq  %rdx, %r8                   // h
    // m,s
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  $60, %rcx
    divq  %rcx
    movq  %rdx, %r10                  // s
    xorl  %edx, %edx
    divq  %rcx
    movq  %rdx, %r9                   // m

    subq  $16, %rsp
    movq  %rsp, %rdi
    movq  %r8, %rsi
    movq  %r9, %rdx
    movq  %r10, %rcx
    callq _fmt_hms
    addq  $16, %rsp

    incq  %rbx
    decq  %r12
    jnz   .Lb2_loop

    callq _now_ns
    subq  %r15, %rax
    movq  %rax, %r12
    movq  $1000000, %rcx
    xorl  %edx, %edx
    divq  %rcx
    movq  %rax, 16(%rsp)              // b'

    leaq  fmt_b_b2(%rip), %rdi
    movq  $1000000, %rsi
    movq  %r12, %rdx
    movq  %rax, %rcx
    xorl  %eax, %eax
    callq _printf

    // ----- (c) clock_gettime: 1M iters
    callq _now_ns
    movq  %rax, %r15

    movq  $1000000, %r12
.Lc_loop:
    callq _now_ns
    decq  %r12
    jnz   .Lc_loop

    callq _now_ns
    subq  %r15, %rax
    movq  %rax, %r12
    movq  $1000000, %rcx
    xorl  %edx, %edx
    divq  %rcx
    movq  %rax, 24(%rsp)              // c

    leaq  fmt_b_c(%rip), %rdi
    movq  $1000000, %rsi
    movq  %r12, %rdx
    movq  %rax, %rcx
    xorl  %eax, %eax
    callq _printf

    // ----- (c') mach_absolute_time: 1M iters
    callq _now_ns
    movq  %rax, %r15

    movq  $1000000, %r12
.Lc2_loop:
    callq _mach_absolute_time
    decq  %r12
    jnz   .Lc2_loop

    callq _now_ns
    subq  %r15, %rax
    movq  %rax, %r12
    movq  $1000000, %rcx
    xorl  %edx, %edx
    divq  %rcx

    leaq  fmt_b_c2(%rip), %rdi
    movq  $1000000, %rsi
    movq  %r12, %rdx
    movq  %rax, %rcx
    xorl  %eax, %eax
    callq _printf

    // ----- summary
    movq  (%rsp), %r8                 // a
    movq  8(%rsp), %r9                // b
    movq  16(%rsp), %r10              // b'
    movq  24(%rsp), %r11              // c

    // real per-tick = b' + c
    movq  %r10, %rdi                  // staging registers
    addq  %r11, %rdi                  // rdi = real_per_tick (also ns/s, also ppb)

    // cat per-tick = a + b + c
    movq  %r8, %rsi
    addq  %r9, %rsi
    addq  %r11, %rsi                  // rsi = cat_per_tick
    movq  %rsi, %rax
    imulq $625, %rax, %rax
    xorl  %edx, %edx
    movq  $54, %rcx
    divq  %rcx
    movq  %rax, %rbx                  // cat ns/s

    // ratio = cat_ns_per_s / real_ns_per_s
    movq  %rbx, %rax
    xorl  %edx, %edx
    movq  %rdi, %rcx
    divq  %rcx
    movq  %rax, %r12                  // ratio

    // printf(fmt, real_pt, real_ns, real_ppb, cat_pt, cat_ns, cat_ppb, ratio)
    movq  %rdi, %r15                  // real (per-tick == ns/s == ppb)
    movq  %rsi, %r14                  // cat per-tick
    leaq  fmt_b_sum(%rip), %rdi
    movq  %r15, %rsi                  // real per-tick
    movq  %r15, %rdx                  // real ns/s
    movq  %r15, %rcx                  // real ppb
    movq  %r14, %r8                   // cat per-tick
    movq  %rbx, %r9                   // cat ns/s
    // remaining args (cat_ppb, ratio) go on stack
    pushq %r12                        // ratio  (16-byte realign automatically)
    pushq %rbx                        // cat ppb (== cat ns/s)
    xorl  %eax, %eax
    callq _printf
    addq  $16, %rsp

Lend_ok:
    xorl  %eax, %eax
Lreturn:
    addq  $40, %rsp
    popq  %r15
    popq  %r14
    popq  %r13
    popq  %r12
    popq  %rbx
    popq  %rbp
    retq

Lusage:
    leaq  usage_str(%rip), %rdi
    xorl  %eax, %eax
    callq _printf
    movl  $1, %eax
    jmp   Lreturn
