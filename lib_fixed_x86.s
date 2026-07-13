// libcatime_fixed — x86_64 / Linux ELF, pure syscalls (no libc deps)
//
// AT&T syntax. Linux x86_64 SysV C ABI:
//   args: rdi, rsi, rdx, rcx, r8, r9 ; return: rax
//
// Compile:
//   clang -target x86_64-linux-gnu -nostdlib -c lib_fixed_x86.s
//
// API: see catime_fixed.h.

.equ SYS_clock_gettime, 228
.equ SYS_openat,        257
.equ AT_FDCWD,          -100
.equ O_RDONLY,          0
.equ CLOCK_REALTIME,    0

.section .bss
.lcomm cf_ts, 16

.section .text

// ----------------------------------------------------------------------------
// uint64_t cf_now_ns(void)
// ----------------------------------------------------------------------------
.global cf_now_ns
.type   cf_now_ns, @function
cf_now_ns:
    movq  $CLOCK_REALTIME, %rdi
    leaq  cf_ts(%rip), %rsi
    movq  $SYS_clock_gettime, %rax
    syscall
    movq  cf_ts(%rip),   %rax       // tv_sec
    movq  cf_ts+8(%rip), %rdx       // tv_nsec
    imulq $1000000000, %rax, %rax
    addq  %rdx, %rax
    retq

// ----------------------------------------------------------------------------
// uint64_t cf_to_cat_ns(uint64_t real_ns)
//   cat = real * 625 / 54 (magic-mul for /54)
// ----------------------------------------------------------------------------
.global cf_to_cat_ns
.type   cf_to_cat_ns, @function
cf_to_cat_ns:
    imulq $625, %rdi, %rax
    movabsq $0x97B425ED097B425F, %rcx
    mulq  %rcx                      // rdx:rax = rax * rcx
    shrq  $5, %rdx
    movq  %rdx, %rax
    retq

// ----------------------------------------------------------------------------
// uint64_t cf_from_cat_ns(uint64_t cat_ns)
//   real = round(cat * 54 / 625) — add 625/2 = 312 for round-to-nearest.
//   Remainder (cat*54) mod 625 is integral, so 312.5 is never hit:
//   correctly rounded (r>=313 up, r<=312 down).
// ----------------------------------------------------------------------------
.global cf_from_cat_ns
.type   cf_from_cat_ns, @function
cf_from_cat_ns:
    imulq $54, %rdi, %rax
    addq  $312, %rax                 // + 625/2 : round-to-nearest
    xorq  %rdx, %rdx
    movq  $625, %rcx
    divq  %rcx
    retq

// ----------------------------------------------------------------------------
// uint64_t cf_wait_until_ns(uint64_t target_ns)
// ----------------------------------------------------------------------------
.global cf_wait_until_ns
.type   cf_wait_until_ns, @function
cf_wait_until_ns:
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx
    pushq %rax                      // align
    movq  %rdi, %rbx                // target
1:  callq cf_now_ns
    cmpq  %rbx, %rax
    jl    1b
    addq  $8, %rsp
    popq  %rbx
    popq  %rbp
    retq

// ----------------------------------------------------------------------------
// uint64_t cf_next_grid_ns(uint64_t now_ns, uint64_t interval_ns)
// ----------------------------------------------------------------------------
.global cf_next_grid_ns
.type   cf_next_grid_ns, @function
cf_next_grid_ns:
    movq  %rdi, %rax
    xorq  %rdx, %rdx
    divq  %rsi
    incq  %rax
    mulq  %rsi
    retq

// ----------------------------------------------------------------------------
// Dynamic PHC (PTP hardware clock) source.  See lib_fixed_arm64.s for the
// full API rationale. Kernel FD_TO_CLOCKID: ((~fd) << 3) | 3.
//
//   int      fd  = cf_open_phc("/dev/ptp0");   // negative on error (-errno)
//   int      cid = cf_phc_clockid(fd);
//   uint64_t ns  = cf_now_dynamic_ns(cid);
// ----------------------------------------------------------------------------

// int cf_open_phc(const char *path)  ; rdi = path
.global cf_open_phc
.type   cf_open_phc, @function
cf_open_phc:
    movq  %rdi, %rsi               // path -> arg2
    movq  $AT_FDCWD, %rdi          // dirfd
    xorq  %rdx, %rdx               // flags = O_RDONLY
    xorq  %r10, %r10              // mode = 0
    movq  $SYS_openat, %rax
    syscall
    retq

// int cf_phc_clockid(int fd)  ; edi = fd
.global cf_phc_clockid
.type   cf_phc_clockid, @function
cf_phc_clockid:
    movl   %edi, %eax
    notl   %eax
    shll   $3, %eax
    orl    $3, %eax
    movslq %eax, %rax             // sign-extend clockid_t
    retq

// uint64_t cf_now_dynamic_ns(int clockid)  ; edi = clockid
.global cf_now_dynamic_ns
.type   cf_now_dynamic_ns, @function
cf_now_dynamic_ns:
    movslq %edi, %rdi             // clockid (may be negative for a PHC)
    leaq   cf_ts(%rip), %rsi
    movq   $SYS_clock_gettime, %rax
    syscall
    movq   cf_ts(%rip),   %rax    // tv_sec
    movq   cf_ts+8(%rip), %rdx    // tv_nsec
    imulq  $1000000000, %rax, %rax
    addq   %rdx, %rax
    retq
