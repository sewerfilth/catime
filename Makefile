catime: main.s
	clang -arch arm64 -o catime main.s

clean:
	rm -f catime
	rm -rf catime.dSYM

.PHONY: clean
