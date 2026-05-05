# catime

**Computational Adjusted Time** — pure base-100 time-of-day, in arm64 + x86_64 asm.

Licensed under [GPL-3.0](LICENSE) — modifications and derivative works
must be released under the same license.

## The idea

Drop 60 and 24 from clock semantics. Slice the day into 100 hours, each hour into 100 minutes, each minute into 100 seconds. The day is the wall-time anchor; everything below it is decimal.

```
  100 cat-s  =  1 cat-min
  100 cat-m  =  1 cat-hr
  100 cat-h  =  1 cat-day
  1 cat-day  =  1 real day      ← anchor
```

A cat time-of-day fits in a 6-digit integer `HHMMSS` that self-segments by base-100. `152030` reads naturally as `15:20:30` cat — no separators required.

## Conversion

Single ratio for the whole system:

```
  cat_seconds  =  real_seconds × 625 / 54
  real_seconds =  cat_seconds  × 54 / 625
```

(From `1 day = 86,400 real s = 1,000,000 cat s`, with `gcd = 1600`.)

## Unit reference

| unit         | real duration       |
|--------------|---------------------|
| 1 cat-day    | 1 real day          |
| 1 cat-hour   | 864 s   (14 min 24 s real) |
| 1 cat-minute | 8.64 s              |
| 1 cat-second | 0.0864 s            |

A cat-minute is shorter than a real minute — that's the cost of slicing a fixed day evenly into base-100. Don't try to map "cat-minute" onto "minute" intuitively; treat the whole thing as `time-of-day × 1,000,000 / 86,400`.

## Usage

```
catime <real_seconds>      # real  → catime
catime -r <cat_seconds>    # catime → real
catime now                 # current wall-clock now (real & cat)
catime bench               # microbenchmarks
```

The same CLI is built for both arm64 (`catime`) and x86_64 (`catime-x86`).
`now` reads `CLOCK_REALTIME` so it inherits NTP corrections and stays
anchored to wall-clock UTC. Bench timing uses `CLOCK_MONOTONIC` so
elapsed measurements aren't perturbed by clock slewing.

Examples:

```
$ ./catime 86400
real:   86400
catime: 1000000

$ ./catime 3600
real:   3600
catime: 41666           # 04:16:66 cat — about 4 cat-hours past midnight

$ ./catime -r 500000
catime: 500000
real:   43200           # noon
```

Integer-only; reverse conversion may lose a fractional cat-second on round-trip.

## Benchmarks

`catime bench` measures four things — three for the cat path, one parallel real-clock decompose so we can compare like-for-like:

| case  | what it measures                                    | typical (Apple Silicon) |
|-------|-----------------------------------------------------|-------------------------|
| (a)   | conversion `cat = real × 625 / 54`                  | ~3 ns/op   |
| (b)   | cat decompose (mod-100 ×3) + `snprintf`             | ~85 ns/op  |
| (b')  | real decompose (mod-60/60/24) + `snprintf`          | ~86 ns/op  |
| (c)   | `clock_gettime(CLOCK_MONOTONIC)`                    | ~19 ns/op  |

(b) and (b') come out identical because `udiv` on arm64 is constant-time regardless of divisor — base-100 isn't faster than base-60.

The summary contrasts a live clock at each system's native cadence:

```
real-clock @ 1.000 Hz      per-tick = b' + c       ≈ 104 ns   →   104 ns/s
cat-clock  @ 11.574 Hz     per-tick = a + b + c    ≈ 106 ns   →  1226 ns/s
```

**Conclusion**: per display update, catime is indistinguishable from a regular wall clock (the `× 625 / 54` is in the noise). The full ~12× steady-state difference is purely the higher tick rate — and even then, a fully native-cadence cat-clock costs ~300 ns per second of CPU (~ppb of one core). The artificial epoch is not a counting bottleneck.

### Optimization notes

Two techniques layered for "good coding" rather than necessity:

1. **Table-based formatter** — replaces `snprintf("%02lld:%02lld:%02lld", ...)` with a 200-byte two-digit-pair lookup + 12 instructions. Cut decompose+format from ~85 ns to ~2 ns (~40×).
2. **Magic-number division** — replaces the `× 625 / 54` `udiv`/`divq` with the corresponding multiply-by-reciprocal sequence (clang `-O3`-derived constants). Cut (a) by ~40% on both arches.
3. **`mach_absolute_time` vs `clock_gettime`** — the (c') bench shows the lower-overhead path, ~5× faster on arm64 and ~3× under Rosetta. Useful if you ever drive a live clock display at high cadence.

## Performance

Measured on Apple M-series (Apple Silicon, macOS arm64 native; x86_64 numbers
are under Rosetta translation — native x86 hardware would be modestly faster).

### Unlimited-interval (conversion-only) — `catime bench`

| metric                       | arm64 native | x86_64 (Rosetta) |
|------------------------------|--------------|------------------|
| (a) magic-mul conversion     | **2 ns/op**  | **2 ns/op**      |
| (b) cat-decompose+fmt        | 2 ns/op      | 2 ns/op          |
| (b') real-decompose+fmt      | 2 ns/op      | 2 ns/op          |
| (c) `clock_gettime`          | 18 ns/op     | 26 ns/op         |
| (c') `mach_absolute_time`    | **5 ns/op**  | 10 ns/op         |
| live cat-clock per-tick      | 22 ns        | 30 ns            |
| live cat-clock steady-state  | 254 ns/s     | 347 ns/s         |
| cost as fraction of one core | 254 ppb      | 347 ppb          |

A live cat-clock running at native cadence (11.574 Hz) burns about a
quarter of a microsecond per real second of CPU. The ratio math itself is
free; `mach_absolute_time` is the lowest-overhead clock read.

### Base API (`libcatime`) — per-call cost

C harness compiled with `-O2`, calling library functions in a tight loop:

| function           | arm64 native | x86_64 (Rosetta) |
|--------------------|--------------|------------------|
| `ct_real_to_cat`   | 1.21 ns      | 1.33 ns          |
| `ct_cat_to_real`   | 0.90 ns      | 1.17 ns          |
| `ct_pack`          | 0.89 ns      | 1.39 ns          |
| `ct_split`         | 2.34 ns      | 2.07 ns          |
| `ct_now_unix_sec`  | 13.48 ns     | 21.88 ns         |
| `ct_now_cat_flat`  | 19.16 ns     | 27.44 ns         |

Pure-arithmetic functions are at the noise floor; only `ct_now_*` actually
costs anything, because they call into libc's `clock_gettime`.

### System vs catime — apples-to-apples

Same workload via stdlib (`clock_gettime` + integer math) vs catime API:

| workload                                        | system (arm64) | catime (arm64) | system (x86) | catime (x86) |
|-------------------------------------------------|----------------|----------------|--------------|--------------|
| read wall clock → integer seconds               | 15.97 ns       | **13.25 ns**   | 31.61 ns     | **23.51 ns** |
| read wall clock + decompose to H:M:S            | **19.39 ns**   | 33.18 ns       | **28.25 ns** | 35.17 ns     |
| pure pack (no syscall)                          | **0.59 ns**    | 0.88 ns        | **0.50 ns**  | 1.37 ns      |

**Takeaway.** For "what's the unix time?" catime is *faster* than the
stdlib path because it pulls `tv_sec` directly without the `struct
timespec` dance. For "what's the time-of-day in HH:MM:SS?" catime is
~10–15 ns slower, because it pays for one extra integer multiply +
divide to convert real → cat before decomposing. The fully-formatted
display delta is small enough to be lost in the next thing you do
(printf, network send, anything).

### Fixed-interval (`libcatime_fixed`) — Linux ELF

Not measured here (cross-compiled from macOS, target is Linux). Expected
shape based on instruction count:

| function              | per-call (estimate)       | notes |
|-----------------------|---------------------------|-------|
| `cf_to_cat_ns`        | ~1–2 ns                   | identical magic-mul |
| `cf_from_cat_ns`      | ~5 ns                     | one `divq` |
| `cf_next_grid_ns`     | ~5 ns                     | one `divq` + `mulq` |
| `cf_now_ns`           | ~500–800 ns               | direct syscall (no vDSO) |
| `cf_wait_until_ns`    | spin × `cf_now_ns` cost   | dominated by clock cost |

To get production HFT performance (~25 ns per `cf_now_ns`), link the host's
vDSO `__vdso_clock_gettime` instead of using the syscall path. The lib is
written to make that a one-instruction swap.

## Build

```
make            # macOS arm64 + x86_64 CLI tools (catime, catime-x86)
make api        # macOS Mach-O base library (lib_arm64.o, lib_x86.o)
make lib        # Linux ELF fixed-interval library (lib_fixed_*.o)
```

CLI tools and base API link against libc. Fixed-interval library is
pure-syscall (no libc), cross-compiled via clang `-target` from
Apple-shipped clang — no extra toolchain.

## libcatime (macOS Mach-O — base API)

Linkable static library object exposing the base catime primitives. See
[catime.h](catime.h):

```c
uint64_t ct_real_to_cat(uint64_t real);
uint64_t ct_cat_to_real(uint64_t cat);
uint64_t ct_pack(uint64_t h, uint64_t m, uint64_t s);
void     ct_split(uint64_t flat, uint64_t *h, uint64_t *m, uint64_t *s);
uint64_t ct_now_unix_sec(void);
uint64_t ct_now_cat_flat(void);
```

Same conversion ratio (625:54) and decomposition rules as the CLI. Works
on any consistent unit (seconds, ms, ns) — the integer ratio doesn't care.
Example link:

```
clang your_app.c lib_arm64.o -o your_app
```

## libcatime_fixed (Linux ELF)

Software-emulated PTP-style fixed-interval timing primitives, shipped as a
linkable static library object for both arm64 and x86_64. See
[catime_fixed.h](catime_fixed.h) for the C API:

```c
uint64_t cf_now_ns(void);
uint64_t cf_to_cat_ns(uint64_t real_ns);
uint64_t cf_from_cat_ns(uint64_t cat_ns);
uint64_t cf_wait_until_ns(uint64_t target_ns);
uint64_t cf_next_grid_ns(uint64_t now_ns, uint64_t interval_ns);
```

Caller-managed state (no globals, no init). The wall clock is
`CLOCK_REALTIME`, which on a properly configured Linux host is
PTP-disciplined by `ptp4l` or `chrony` against a NIC PHC for
sub-microsecond accuracy. For nanosecond HFT use, swap the clockid
constant for the dynamic PHC clockid `((~ptp_fd) << 3) | 3` after
opening `/dev/ptpN`.

Example link (on a Linux box):

```
gcc your_app.c lib_fixed_x86.o -o your_app
```

The bundled demos ([main_fixed.s](main_fixed.s),
[main_x86_fixed.s](main_x86_fixed.s)) are reference implementations of the
spin-tick pattern as standalone Linux ELF — assemble with clang, link with
any ELF linker.
