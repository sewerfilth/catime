// libcatime — x86_64 (base API): Mach-O, ELF and COFF from one source
//
// AT&T syntax, run through the C preprocessor (x64_abi.h: symbol prefix,
// sections, .type, and on Win64 an entry thunk into each SysV body, so the
// public ABI is native on every target). The wall clock is clock_gettime
// (CLOCK_REALTIME) on macOS and Linux, GetSystemTimePreciseAsFileTime on
// Windows. Detached mode (ct_detach/ct_tick/ct_attach) drives a synthetic
// timebase for replay and warp-speed simulation.
//
// Compile:
//   clang -arch x86_64 -c lib_x86_64.S -o lib_x86.o      (macOS)
//   cc -c lib_x86_64.S                                   (Linux, mingw-w64)

#include "x64_abi.h"

#if defined(__APPLE__)
#define V(x) _##x
.section __DATA,__bss
.lcomm _ct_mode,    8           // 0=attached, 1=detached
.lcomm _ct_counter, 8
#define CLOCK_GETTIME _clock_gettime
#else
#define V(x) x
#if !defined(_WIN32)
#define CLOCK_GETTIME clock_gettime@PLT
#endif
    .bss
    .p2align 3
ct_mode:    .quad 0             // 0=attached, 1=detached (file-local)
ct_counter: .quad 0
#endif

#if defined(_WIN32)
// WALL_100NS: rax = wall clock in 100 ns ticks since the Unix epoch. Called
// from a SysV body with rbp pushed (rsp = 0 mod 16): GetSystemTimePrecise-
// AsFileTime is a Win64 function, so 32 bytes of shadow space, arg in rcx.
// It counts 100 ns ticks since 1601-01-01; 11644473600 s separate the epochs.
.macro WALL_100NS
    subq  $48, %rsp                  // 32 shadow + FILETIME at 32(%rsp)
    leaq  32(%rsp), %rcx
    callq *__imp_GetSystemTimePreciseAsFileTime(%rip)
    movq  32(%rsp), %rax
    movabsq $116444736000000000, %rcx
    subq  %rcx, %rax
.endm
#endif

// ----------------------------------------------------------------------------
// uint64_t ct_real_to_cat(uint64_t real)
// ----------------------------------------------------------------------------
FUNC ct_real_to_cat
    imulq $625, %rdi, %rax
    movabsq $0x97B425ED097B425F, %rcx
    mulq  %rcx
    shrq  $5, %rdx
    movq  %rdx, %rax
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_cat_to_real(uint64_t cat)
//   real = round(cat * 54 / 625) — add 625/2 = 312 for round-to-nearest.
//   The (cat*54) mod 625 remainder is integral, so 312.5 is never hit:
//   correctly rounded (r>=313 up, r<=312 down).
// ----------------------------------------------------------------------------
FUNC ct_cat_to_real
    imulq $54, %rdi, %rax
    addq  $312, %rax                 // + 625/2 : round-to-nearest
    xorq  %rdx, %rdx
    movq  $625, %rcx
    divq  %rcx
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_pack(uint64_t h, uint64_t m, uint64_t s)
//   args: rdi=h, rsi=m, rdx=s
// ----------------------------------------------------------------------------
FUNC ct_pack
    imulq $100, %rdi, %rax
    addq  %rsi, %rax
    imulq $100, %rax, %rax
    addq  %rdx, %rax
    retq

// ----------------------------------------------------------------------------
// void ct_split(uint64_t flat, uint64_t *h, uint64_t *m, uint64_t *s)
//   args: rdi=flat, rsi=*h, rdx=*m, rcx=*s
//   move ptrs to scratch regs first since rdx/rcx are clobbered by div
// ----------------------------------------------------------------------------
FUNC ct_split
    movq  %rsi, %r8                  // r8 = *h
    movq  %rdx, %r9                  // r9 = *m
    movq  %rcx, %r10                 // r10 = *s

    // *h = flat / 10000
    movq  %rdi, %rax
    xorq  %rdx, %rdx
    movq  $10000, %rcx
    divq  %rcx
    movq  %rax, (%r8)

    // *s = flat % 100, *m = (flat/100) % 100
    movq  %rdi, %rax
    xorq  %rdx, %rdx
    movq  $100, %rcx
    divq  %rcx
    movq  %rdx, (%r10)               // *s
    xorq  %rdx, %rdx
    divq  %rcx
    movq  %rdx, (%r9)                // *m
    retq

// ----------------------------------------------------------------------------
// void ct_detach(uint64_t start_unix_sec)
// ----------------------------------------------------------------------------
FUNC ct_detach
    movq  %rdi, V(ct_counter)(%rip)
    movq  $1, V(ct_mode)(%rip)
    retq

// ----------------------------------------------------------------------------
// void ct_attach(void)
// ----------------------------------------------------------------------------
FUNC ct_attach
    movq  $0, V(ct_mode)(%rip)
    retq

// ----------------------------------------------------------------------------
// void ct_tick(uint64_t delta_sec)
// ----------------------------------------------------------------------------
FUNC ct_tick
    cmpq  $0, V(ct_mode)(%rip)
    je    1f
    addq  %rdi, V(ct_counter)(%rip)
1:  retq

// ----------------------------------------------------------------------------
// int ct_is_detached(void)
// ----------------------------------------------------------------------------
FUNC ct_is_detached
    movq  V(ct_mode)(%rip), %rax
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_now_unix_sec(void)
//   detached: single load (~1ns)
//   attached: clock_gettime via libc (~22ns under Rosetta)
// ----------------------------------------------------------------------------
FUNC ct_now_unix_sec
    cmpq  $0, V(ct_mode)(%rip)
    je    1f
    movq  V(ct_counter)(%rip), %rax
    retq
1:  pushq %rbp
    movq  %rsp, %rbp
#if defined(_WIN32)
    WALL_100NS                       // rax = 100 ns ticks since 1970
    xorl  %edx, %edx
    movq  $10000000, %rcx
    divq  %rcx                       // seconds
#else
    subq  $16, %rsp
    movl  $0, %edi                   // CLOCK_REALTIME
    movq  %rsp, %rsi
    xorl  %eax, %eax
    callq CLOCK_GETTIME
    movq  (%rsp), %rax               // tv_sec
#endif
    leave
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_now_unix_ns(void)
//   detached: counter * 1e9 (synthetic seconds → ns)
//   attached: tv_sec*1e9 + tv_nsec via clock_gettime
// ----------------------------------------------------------------------------
FUNC ct_now_unix_ns
    cmpq  $0, V(ct_mode)(%rip)
    je    1f
    movq  V(ct_counter)(%rip), %rax
    imulq $1000000000, %rax, %rax
    retq
1:  pushq %rbp
    movq  %rsp, %rbp
#if defined(_WIN32)
    WALL_100NS                       // rax = 100 ns ticks since 1970
    imulq $100, %rax, %rax           // ns
#else
    subq  $16, %rsp
    movl  $0, %edi                   // CLOCK_REALTIME
    movq  %rsp, %rsi
    xorl  %eax, %eax
    callq CLOCK_GETTIME
    movq  (%rsp), %rax               // tv_sec
    imulq $1000000000, %rax, %rax
    addq  8(%rsp), %rax              // + tv_nsec
#endif
    leave
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_now_cat_flat(void)
// ----------------------------------------------------------------------------
FUNC ct_now_cat_flat
    pushq %rbp
    movq  %rsp, %rbp
    callq CALL(ct_now_unix_sec)
    movq  $86400, %rcx
    xorq  %rdx, %rdx
    divq  %rcx                       // rdx = sec_of_day
    movq  %rdx, %rdi
    callq CALL(ct_real_to_cat)
    popq  %rbp
    retq
