/* x64_abi.h -- object format + calling convention for the x86_64 .S files.
 *
 * Every body is written once, against SysV (args rdi rsi rdx rcx r8 r9, then
 * the stack at 8(%rsp); rbx rbp r12-r15 callee-saved). `FUNC name` opens one.
 *
 *   Mach-O (macOS)  the body is `_name`.
 *   ELF (Linux)     the body is `name`, typed @function; the file gets a
 *                   non-executable-stack note.
 *   COFF (Win64)    `name` is a thunk that saves what Win64 makes callee-saved
 *                   and SysV does not (rdi, rsi, xmm6-15), moves the integer
 *                   arguments into SysV registers (Win64 rcx rdx r8 r9 and
 *                   stack args 5..8) and calls the body, `name_sysv`. Integer
 *                   and pointer arguments only.
 *
 * Calls and jumps between bodies use CALL(name), which reaches the SysV body
 * directly. Same scheme as sillystate's ss_x64_asm.h. */
#ifndef X64_ABI_H
#define X64_ABI_H

#if defined(__APPLE__)
#define CALL(x) _##x
#elif defined(_WIN32)
#define CALL(x) x##_sysv
#else
#define CALL(x) x
#endif

#if defined(_WIN32)
/* COFF: without `.type 32` (function) a symbol is exported as data. */
.macro FUNC name
    .text
    .p2align 4
    .globl \name
    .def \name; .scl 2; .type 32; .endef
\name:
    push    %rdi
    push    %rsi
    sub     $184, %rsp                  /* args 7-8 out, xmm6-15, pad: rsp = 0 mod 16 */
    movdqa  %xmm6, 16(%rsp)
    movdqa  %xmm7, 32(%rsp)
    movdqa  %xmm8, 48(%rsp)
    movdqa  %xmm9, 64(%rsp)
    movdqa  %xmm10, 80(%rsp)
    movdqa  %xmm11, 96(%rsp)
    movdqa  %xmm12, 112(%rsp)
    movdqa  %xmm13, 128(%rsp)
    movdqa  %xmm14, 144(%rsp)
    movdqa  %xmm15, 160(%rsp)
    mov     %rcx, %rdi
    mov     %rdx, %rsi
    mov     %r8, %rdx
    mov     %r9, %rcx
    mov     240(%rsp), %r8              /* the caller's arg 5: entry rsp + 40 */
    mov     248(%rsp), %r9
    mov     256(%rsp), %rax
    mov     %rax, (%rsp)
    mov     264(%rsp), %rax
    mov     %rax, 8(%rsp)
    call    \name\()_sysv
    movdqa  16(%rsp), %xmm6
    movdqa  32(%rsp), %xmm7
    movdqa  48(%rsp), %xmm8
    movdqa  64(%rsp), %xmm9
    movdqa  80(%rsp), %xmm10
    movdqa  96(%rsp), %xmm11
    movdqa  112(%rsp), %xmm12
    movdqa  128(%rsp), %xmm13
    movdqa  144(%rsp), %xmm14
    movdqa  160(%rsp), %xmm15
    add     $184, %rsp
    pop     %rsi
    pop     %rdi
    ret
    .p2align 4
    .globl \name\()_sysv
    .def \name\()_sysv; .scl 2; .type 32; .endef
\name\()_sysv:
.endm
#elif defined(__APPLE__)
.macro FUNC name
    .text
    .p2align 4
    .globl _\name
_\name:
.endm
#else
.macro FUNC name
    .text
    .p2align 4
    .globl \name
    .type \name, @function
\name:
.endm
    .section .note.GNU-stack, "", @progbits
#endif

#endif /* X64_ABI_H */
