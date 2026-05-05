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

clean:
	rm -f catime catime-x86
	rm -f lib_arm64.o lib_x86.o
	rm -f lib_fixed_arm64.o lib_fixed_x86.o
	rm -rf *.dSYM

.PHONY: all clean lib api
