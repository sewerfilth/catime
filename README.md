# catime

**Computational Adjusted Time** — small arm64 asm utility that converts real seconds into a 100-base "adjusted" minute.

## The idea

A regular clock uses 60 seconds per minute. CAT keeps the **minute boundary** intact but reslices the inside of it into 100 adjusted seconds. So:

- 1 adjusted minute  ≡ 1 real minute (same wall-clock duration)
- 100 adjusted seconds = 60 real seconds
- 1 adjusted second   = 0.6 real seconds
- ratio: real:adjusted = 60:100 = 3:5

The point is to drop the awkward 60-base inside the minute and just do clean decimal, without ever desyncing from real minutes/hours. Conversion is a single ratio.

## Usage

```
./catime <real_seconds>
```

Example:

```
$ ./catime 90
real:     1:30
adjusted: 1:50

$ ./catime 30
real:     0:30
adjusted: 0:50
```

## Build

Apple Silicon macOS:

```
make
```

Pure arm64 asm linked against libc (`atoll`, `printf`).
