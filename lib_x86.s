// libcatime — x86_64 / Darwin Mach-O (base API)
//
// AT&T syntax. Links against libc for system-time access.
//
// Compile:
//   clang -arch x86_64 -c lib_x86.s -o lib_x86.o
//
// API: see catime.h

.section __TEXT,__text

// ----------------------------------------------------------------------------
// uint64_t ct_real_to_cat(uint64_t real)
// ----------------------------------------------------------------------------
.global _ct_real_to_cat
.p2align 4
_ct_real_to_cat:
    imulq $625, %rdi, %rax
    movabsq $0x97B425ED097B425F, %rcx
    mulq  %rcx
    shrq  $5, %rdx
    movq  %rdx, %rax
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_cat_to_real(uint64_t cat)
// ----------------------------------------------------------------------------
.global _ct_cat_to_real
.p2align 4
_ct_cat_to_real:
    imulq $54, %rdi, %rax
    xorq  %rdx, %rdx
    movq  $625, %rcx
    divq  %rcx
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_pack(uint64_t h, uint64_t m, uint64_t s)
//   args: rdi=h, rsi=m, rdx=s
// ----------------------------------------------------------------------------
.global _ct_pack
.p2align 4
_ct_pack:
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
.global _ct_split
.p2align 4
_ct_split:
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
// uint64_t ct_now_unix_sec(void)
// ----------------------------------------------------------------------------
.global _ct_now_unix_sec
.p2align 4
_ct_now_unix_sec:
    pushq %rbp
    movq  %rsp, %rbp
    subq  $16, %rsp
    movl  $0, %edi                   // CLOCK_REALTIME
    movq  %rsp, %rsi
    xorl  %eax, %eax
    callq _clock_gettime
    movq  (%rsp), %rax               // tv_sec
    leave
    retq

// ----------------------------------------------------------------------------
// uint64_t ct_now_cat_flat(void)
// ----------------------------------------------------------------------------
.global _ct_now_cat_flat
.p2align 4
_ct_now_cat_flat:
    pushq %rbp
    movq  %rsp, %rbp
    callq _ct_now_unix_sec
    movq  $86400, %rcx
    xorq  %rdx, %rdx
    divq  %rcx                       // rdx = sec_of_day
    movq  %rdx, %rdi
    callq _ct_real_to_cat
    popq  %rbp
    retq
