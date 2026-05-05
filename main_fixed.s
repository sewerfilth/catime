// catime-fixed (arm64 / Linux ELF, pure syscalls — no libc)
//
// PTP-grade fixed-interval cat-time emitter.
// Spin-locks CLOCK_REALTIME on an absolute grid, emits one line per tick:
//
//   tick=N ptp_ns=N cat_ns=N drift_ns=N\n
//
// usage:   ./catime-fixed <interval_ns> [iters]
// default: iters=10
//
// CLOCK_REALTIME is assumed PTP-disciplined by ptp4l/chrony at the OS level.
// For sub-microsecond precision use a NIC with PHC (e.g. /dev/ptp0) and
// switch the syscall arg from CLOCK_REALTIME to (~ptp_fd << 3) | 3.
//
// Note: spin uses syscall clock_gettime (~500ns/call). Production HFT would
// link vDSO clock_gettime (~25ns) for 20x lower spin overhead.
//
// Linux arm64 syscall ABI: x8=#, x0..x5=args, svc #0, return in x0.

.equ SYS_write,         64
.equ SYS_exit,          93
.equ SYS_clock_gettime, 113

.equ CLOCK_REALTIME,    0
.equ STDOUT,            1

.section .rodata
msg_usage:    .ascii "usage: catime-fixed <interval_ns> [iters]\n"
.equ          msg_usage_len, . - msg_usage

lit_tick:     .ascii "tick="
lit_ptp:      .ascii " ptp_ns="
lit_cat:      .ascii " cat_ns="
lit_drift:    .ascii " drift_ns="
lit_nl:       .ascii "\n"

.section .bss
.lcomm ts,      16              // timespec (tv_sec, tv_nsec)
.lcomm linebuf, 256             // output line scratch

.section .text
.global _start

// ----------------------------------------------------------------------------
// _atoi(x0=str) -> x0 : u64
// Stops at first non-digit. No error handling.
// ----------------------------------------------------------------------------
_atoi:
    mov x9, #0
1:  ldrb w10, [x0]
    sub  w10, w10, #'0'
    cmp  w10, #10
    b.hs 2f
    mov  w11, #10
    madd x9, x9, x11, x10
    add  x0, x0, #1
    b    1b
2:  mov  x0, x9
    ret

// ----------------------------------------------------------------------------
// _u64_str(x0=buf, x1=val) -> x0 : new buf ptr (one past last digit)
// Writes ASCII decimal in place, no terminator.
// ----------------------------------------------------------------------------
_u64_str:
    cbnz x1, 1f
    mov  w9, #'0'
    strb w9, [x0]
    add  x0, x0, #1
    ret
1:
    mov  x9, x0                 // start
    mov  x10, x1                // val
2:  mov  w11, #10
    udiv x12, x10, x11
    msub x13, x12, x11, x10     // digit
    add  w13, w13, #'0'
    strb w13, [x0]
    add  x0, x0, #1
    mov  x10, x12
    cbnz x10, 2b
    // reverse [x9 .. x0)
    sub  x10, x0, #1
3:  cmp  x9, x10
    b.ge 4f
    ldrb w11, [x9]
    ldrb w12, [x10]
    strb w12, [x9]
    strb w11, [x10]
    add  x9, x9, #1
    sub  x10, x10, #1
    b    3b
4:  ret

// ----------------------------------------------------------------------------
// _read_realtime_ns -> x0 : current CLOCK_REALTIME in ns
// Clobbers x8, x1; uses .bss ts.
// ----------------------------------------------------------------------------
_read_realtime_ns:
    mov  x0, #CLOCK_REALTIME
    adrp x1, ts
    add  x1, x1, :lo12:ts
    mov  x8, #SYS_clock_gettime
    svc  #0
    adrp x1, ts
    add  x1, x1, :lo12:ts
    ldr  x9, [x1]
    ldr  x10, [x1, #8]
    movz x11, #0xCA00
    movk x11, #0x3B9A, lsl #16  // 1e9
    madd x0, x9, x11, x10
    ret

// ----------------------------------------------------------------------------
// _write_buf(x0=buf, x1=len) -> writes to stdout
// ----------------------------------------------------------------------------
_write_buf:
    mov  x2, x1                 // len
    mov  x1, x0                 // buf
    mov  x0, #STDOUT
    mov  x8, #SYS_write
    svc  #0
    ret

// ----------------------------------------------------------------------------
// _emit_label(x0=buf, x1=label_addr, x2=label_len) -> x0 : new buf ptr
// memcpy label into buf, return new ptr.
// ----------------------------------------------------------------------------
_emit_label:
    cbz  x2, 2f
1:  ldrb w9, [x1], #1
    strb w9, [x0], #1
    sub  x2, x2, #1
    cbnz x2, 1b
2:  ret

// ----------------------------------------------------------------------------
// _start
//   stack at entry: [sp]=argc, [sp+8]=argv0, [sp+16]=argv1, ...
// ----------------------------------------------------------------------------
_start:
    ldr  x19, [sp]              // argc
    cmp  x19, #2
    b.lt Lusage

    // interval_ns = atoi(argv[1])
    ldr  x0, [sp, #16]
    bl   _atoi
    mov  x20, x0                // x20 = interval_ns

    // iters = atoi(argv[2]) if present, else 10
    cmp  x19, #3
    b.lt 1f
    ldr  x0, [sp, #24]
    bl   _atoi
    mov  x21, x0
    b    2f
1:  mov  x21, #10
2:  // x21 = iters

    // anchor: read CLOCK_REALTIME
    bl   _read_realtime_ns
    mov  x22, x0                // start_ns

    // first target = ceil(start / interval) * interval
    udiv x9, x22, x20
    add  x9, x9, #1
    mul  x23, x9, x20           // x23 = next_target_ns

    mov  x24, #0                // tick counter

.Ltick_loop:
    // spin until current >= target
.Lspin:
    bl   _read_realtime_ns
    cmp  x0, x23
    b.lt .Lspin
    mov  x25, x0                // ptp_ns

    // drift = ptp - target
    sub  x26, x25, x23

    // cat_ns = ptp * 625 / 54
    mov  w9, #625
    mul  x27, x25, x9
    mov  w9, #54
    udiv x27, x27, x9

    // ----- format line into linebuf -----
    adrp x0, linebuf
    add  x0, x0, :lo12:linebuf
    mov  x28, x0                // line start

    // "tick=N"
    adrp x1, lit_tick
    add  x1, x1, :lo12:lit_tick
    mov  x2, #5
    bl   _emit_label
    mov  x1, x24
    bl   _u64_str

    // " ptp_ns=N"
    adrp x1, lit_ptp
    add  x1, x1, :lo12:lit_ptp
    mov  x2, #8
    bl   _emit_label
    mov  x1, x25
    bl   _u64_str

    // " cat_ns=N"
    adrp x1, lit_cat
    add  x1, x1, :lo12:lit_cat
    mov  x2, #8
    bl   _emit_label
    mov  x1, x27
    bl   _u64_str

    // " drift_ns=N"
    adrp x1, lit_drift
    add  x1, x1, :lo12:lit_drift
    mov  x2, #10
    bl   _emit_label
    mov  x1, x26
    bl   _u64_str

    // "\n"
    mov  w9, #'\n'
    strb w9, [x0]
    add  x0, x0, #1

    // write
    sub  x1, x0, x28            // length
    mov  x0, x28
    bl   _write_buf

    // advance
    add  x24, x24, #1
    add  x23, x23, x20          // next target
    cmp  x24, x21
    b.lt .Ltick_loop

    // exit 0
    mov  x0, #0
    mov  x8, #SYS_exit
    svc  #0

Lusage:
    adrp x0, msg_usage
    add  x0, x0, :lo12:msg_usage
    mov  x1, #msg_usage_len
    bl   _write_buf
    mov  x0, #1
    mov  x8, #SYS_exit
    svc  #0
