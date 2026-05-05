// catime-fixed (x86_64 / Linux ELF, pure syscalls — no libc)
//
// PTP-grade fixed-interval cat-time emitter.
// Spin-locks CLOCK_REALTIME on an absolute grid, emits one line per tick:
//
//   tick=N ptp_ns=N cat_ns=N drift_ns=N\n
//
// usage:   ./catime-fixed-x86 <interval_ns> [iters]
// default: iters=10
//
// CLOCK_REALTIME is assumed PTP-disciplined by ptp4l/chrony. For sub-μs use
// (~ptp_fd << 3) | 3 as the clockid after opening /dev/ptp0.
//
// Note: spin uses the syscall path (~500ns/call). Production HFT links the
// vDSO __vdso_clock_gettime (~25ns) for 20x lower spin overhead.
//
// Linux x86_64 syscall ABI:
//   rax = #, rdi/rsi/rdx/r10/r8/r9 = args, syscall, return in rax.

.equ SYS_write,         1
.equ SYS_exit,          60
.equ SYS_clock_gettime, 228

.equ CLOCK_REALTIME,    0
.equ STDOUT,            1

.section .rodata
msg_usage:    .ascii "usage: catime-fixed-x86 <interval_ns> [iters]\n"
.equ          msg_usage_len, . - msg_usage

lit_tick:     .ascii "tick="
lit_ptp:      .ascii " ptp_ns="
lit_cat:      .ascii " cat_ns="
lit_drift:    .ascii " drift_ns="

.section .bss
.lcomm ts,      16
.lcomm linebuf, 256

.section .text
.global _start

// ----------------------------------------------------------------------------
// _atoi(rdi=str) -> rax
// ----------------------------------------------------------------------------
_atoi:
    xorq %rax, %rax
1:  movzbl (%rdi), %ecx
    subl  $'0', %ecx
    cmpl  $10, %ecx
    jae   2f
    leaq  (%rax, %rax, 4), %rax     // rax *= 5
    leaq  (%rcx, %rax, 2), %rax     // rax = rax*2 + cx
    incq  %rdi
    jmp   1b
2:  retq

// ----------------------------------------------------------------------------
// _u64_str(rdi=buf, rsi=val) -> rax : new buf ptr
// ----------------------------------------------------------------------------
_u64_str:
    testq %rsi, %rsi
    jnz   1f
    movb  $'0', (%rdi)
    leaq  1(%rdi), %rax
    retq
1:
    movq  %rdi, %r8                  // start
    movq  %rsi, %rax                 // val
    movq  $10, %rcx
2:  xorq  %rdx, %rdx
    divq  %rcx                       // rax /= 10, rdx = digit
    addb  $'0', %dl
    movb  %dl, (%rdi)
    incq  %rdi
    testq %rax, %rax
    jnz   2b
    // reverse [r8 .. rdi)
    leaq  -1(%rdi), %r9
3:  cmpq  %r8, %r9
    jle   4f
    movb  (%r8), %al
    movb  (%r9), %dl
    movb  %dl, (%r8)
    movb  %al, (%r9)
    incq  %r8
    decq  %r9
    jmp   3b
4:  movq  %rdi, %rax
    retq

// ----------------------------------------------------------------------------
// _read_realtime_ns -> rax
// ----------------------------------------------------------------------------
_read_realtime_ns:
    movq  $CLOCK_REALTIME, %rdi
    leaq  ts(%rip), %rsi
    movq  $SYS_clock_gettime, %rax
    syscall
    movq  ts(%rip), %rax             // tv_sec
    movq  ts+8(%rip), %rdx           // tv_nsec
    imulq $1000000000, %rax, %rax
    addq  %rdx, %rax
    retq

// ----------------------------------------------------------------------------
// _write_buf(rdi=buf, rsi=len)
// ----------------------------------------------------------------------------
_write_buf:
    movq  %rsi, %rdx
    movq  %rdi, %rsi
    movq  $STDOUT, %rdi
    movq  $SYS_write, %rax
    syscall
    retq

// ----------------------------------------------------------------------------
// _emit_label(rdi=buf, rsi=label, rdx=len) -> rax : new buf ptr
// ----------------------------------------------------------------------------
_emit_label:
    testq %rdx, %rdx
    jz    2f
1:  movb  (%rsi), %al
    movb  %al, (%rdi)
    incq  %rsi
    incq  %rdi
    decq  %rdx
    jnz   1b
2:  movq  %rdi, %rax
    retq

// ----------------------------------------------------------------------------
// _start
// ----------------------------------------------------------------------------
_start:
    movq  (%rsp), %rbx               // argc
    cmpq  $2, %rbx
    jl    Lusage

    // interval = atoi(argv[1])
    movq  16(%rsp), %rdi
    callq _atoi
    movq  %rax, %r12                 // interval_ns

    // iters = atoi(argv[2]) or 10
    cmpq  $3, %rbx
    jl    1f
    movq  24(%rsp), %rdi
    callq _atoi
    movq  %rax, %r13
    jmp   2f
1:  movq  $10, %r13
2:  // r13 = iters

    // anchor
    callq _read_realtime_ns
    movq  %rax, %r14                 // start_ns

    // first_target = ceil(start / interval) * interval
    movq  %r14, %rax
    xorq  %rdx, %rdx
    divq  %r12                       // rax = start/interval
    incq  %rax
    mulq  %r12                       // rax = (q+1) * interval
    movq  %rax, %r15                 // next_target_ns

    xorq  %rbx, %rbx                 // tick counter (reuse rbx now)

.Ltick_loop:
    // spin until ptp >= target
.Lspin:
    callq _read_realtime_ns
    cmpq  %r15, %rax
    jl    .Lspin
    movq  %rax, %rbp                 // ptp_ns

    // drift = ptp - target
    movq  %rbp, %rax
    subq  %r15, %rax
    pushq %rax                       // stash drift on stack

    // cat_ns = ptp * 625 / 54  (magic-mul for /54)
    movq  %rbp, %rax
    imulq $625, %rax, %rax
    movabsq $0x97B425ED097B425F, %rcx
    mulq  %rcx
    shrq  $5, %rdx                   // rdx = cat_ns
    pushq %rdx

    // format line
    leaq  linebuf(%rip), %rdi
    movq  %rdi, %r8                  // line start (saved in r8 — caller-saved but no calls clobber until we use it)
    // Actually r8 is caller-saved. Better to use a callee-saved. Save linebuf addr on stack:
    pushq %r8                        // line_start

    // "tick="
    leaq  lit_tick(%rip), %rsi
    movq  $5, %rdx
    callq _emit_label
    movq  %rax, %rdi
    movq  %rbx, %rsi                 // tick
    callq _u64_str

    // " ptp_ns="
    movq  %rax, %rdi
    leaq  lit_ptp(%rip), %rsi
    movq  $8, %rdx
    callq _emit_label
    movq  %rax, %rdi
    movq  %rbp, %rsi
    callq _u64_str

    // " cat_ns="
    movq  %rax, %rdi
    leaq  lit_cat(%rip), %rsi
    movq  $8, %rdx
    callq _emit_label
    movq  %rax, %rdi
    movq  8(%rsp), %rsi              // cat_ns from stack (under the saved line_start)
    callq _u64_str

    // " drift_ns="
    movq  %rax, %rdi
    leaq  lit_drift(%rip), %rsi
    movq  $10, %rdx
    callq _emit_label
    movq  %rax, %rdi
    movq  16(%rsp), %rsi             // drift from stack
    callq _u64_str

    // "\n"
    movb  $'\n', (%rax)
    incq  %rax

    // write(stdout, line_start, len)
    movq  (%rsp), %rdi               // line_start
    movq  %rax, %rsi
    subq  %rdi, %rsi                 // len = end - start
    movq  %rdi, %r9                  // save before _write_buf trashes
    callq _write_buf

    addq  $24, %rsp                  // pop line_start, cat_ns, drift

    // advance
    incq  %rbx
    addq  %r12, %r15                 // next target
    cmpq  %r13, %rbx
    jl    .Ltick_loop

    // exit 0
    movq  $0, %rdi
    movq  $SYS_exit, %rax
    syscall

Lusage:
    leaq  msg_usage(%rip), %rdi
    movq  $msg_usage_len, %rsi
    callq _write_buf
    movq  $1, %rdi
    movq  $SYS_exit, %rax
    syscall
