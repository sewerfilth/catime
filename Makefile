# macOS-native catime tools (arm64 + x86_64 via Rosetta)
all: catime catime-x86

catime: main.s
	clang -arch arm64 -o catime main.s

catime-x86: main_x86.s
	clang -arch x86_64 -o catime-x86 main_x86.s

# Linux ELF cross-compile (catime-fixed library + demo executables)
LINUX_ARM_FLAGS = -target aarch64-linux-gnu -nostdlib
LINUX_X86_FLAGS = -target x86_64-linux-gnu  -nostdlib

lib_fixed_arm64.o: lib_fixed_arm64.s
	clang $(LINUX_ARM_FLAGS) -c $< -o $@

lib_fixed_x86.o: lib_fixed_x86.s
	clang $(LINUX_X86_FLAGS) -c $< -o $@

lib: lib_fixed_arm64.o lib_fixed_x86.o

# macOS Mach-O base API library objects
lib_arm64.o: lib_arm64.s
	clang -arch arm64 -c $< -o $@

lib_x86.o: lib_x86.s
	clang -arch x86_64 -c $< -o $@

api: lib_arm64.o lib_x86.o

# Automated test suite (base API). Runs native arm64 and, via Rosetta, x86_64,
# so both Mach-O library objects are exercised on this host.
test-arm64: lib_arm64.o tests/test_catime.c
	clang -arch arm64 -O2 -o tests/test_catime_arm64 tests/test_catime.c lib_arm64.o
	./tests/test_catime_arm64

test-x86: lib_x86.o tests/test_catime.c
	clang -arch x86_64 -O2 -o tests/test_catime_x86 tests/test_catime.c lib_x86.o
	./tests/test_catime_x86

test: test-arm64 test-x86

# ---------------------------------------------------------------------------
# Native Linux test harness (executes the cf_* ELF objects, not just assembles).
#
# Unlike `test` (macOS-only, Mach-O + `clang -arch`), this target must run ON
# Linux: it assembles the pure-syscall fixed-interval library with the host
# toolchain (gas via `cc`) and links + runs tests/test_catime_linux.c, so the
# conversion kernels, grid math, PHC clockid math and the live clock_gettime
# syscall path are exercised natively on x86_64 and aarch64 Linux.
#
#   x86_64  -> lib_fixed_x86.s
#   aarch64 -> lib_fixed_arm64.s
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
LINUX_FIXED_SRC := lib_fixed_x86.s
else ifeq ($(UNAME_M),aarch64)
LINUX_FIXED_SRC := lib_fixed_arm64.s
else ifeq ($(UNAME_M),arm64)
LINUX_FIXED_SRC := lib_fixed_arm64.s
else
LINUX_FIXED_SRC := lib_fixed_x86.s
endif

# The .s files use `//` line comments, which clang's integrated assembler
# accepts but GNU gas (gcc's default) rejects — so assemble with clang, exactly
# as the `lib` target does. Linking the test driver can use any host cc.
LINUX_CC ?= clang
LINUX_LD ?= cc

# Native ELF fixed-lib object for the host arch.
lib_fixed_native.o: $(LINUX_FIXED_SRC)
	$(LINUX_CC) -c $(LINUX_FIXED_SRC) -o lib_fixed_native.o

test-linux: lib_fixed_native.o tests/test_catime_linux.c
	$(LINUX_LD) -O2 -o tests/test_catime_linux tests/test_catime_linux.c lib_fixed_native.o
	./tests/test_catime_linux

# Measured conversion microbenchmark (native arm64).
bench: lib_arm64.o tests/bench.c
	clang -arch arm64 -O2 -o tests/bench_arm64 tests/bench.c lib_arm64.o
	./tests/bench_arm64

clean:
	rm -f catime catime-x86
	rm -f lib_arm64.o lib_x86.o
	rm -f lib_fixed_arm64.o lib_fixed_x86.o
	rm -f tests/test_catime_arm64 tests/test_catime_x86 tests/bench_arm64
	rm -f lib_fixed_native.o tests/test_catime_linux
	rm -rf *.dSYM

.PHONY: all clean lib api test test-arm64 test-x86 test-linux bench
