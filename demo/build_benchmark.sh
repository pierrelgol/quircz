#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/zig-out/bin/quircz-benchmark"}
QUIRCZ_LIB=${2:-"$ROOT/zig-out/lib/libquircz.a"}
OBJDIR=${OUT}.obj

mkdir -p "$(dirname "$OUT")"
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"

PKG_CONFIG_PATH_DEFAULT=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig
if [ -n "${PKG_CONFIG_PATH:-}" ]; then
  export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$PKG_CONFIG_PATH_DEFAULT"
else
  export PKG_CONFIG_PATH="$PKG_CONFIG_PATH_DEFAULT"
fi

OPENCV_CFLAGS=$(pkg-config --cflags opencv4 2>/dev/null || true)
OPENCV_LIBS=$(pkg-config --libs opencv4 2>/dev/null || true)
if [ -z "$OPENCV_CFLAGS" ] || [ -z "$OPENCV_LIBS" ]; then
  OPENCV_CFLAGS=$(pkg-config --cflags opencv 2>/dev/null || true)
  OPENCV_LIBS=$(pkg-config --libs opencv 2>/dev/null || true)
fi
if [ -z "$OPENCV_CFLAGS" ] || [ -z "$OPENCV_LIBS" ]; then
  echo "OpenCV pkg-config metadata not found. Install OpenCV (opencv4/opencv) to build the benchmark." >&2
  exit 1
fi

COMMON_OPT="-Ofast -DNDEBUG -march=native -mtune=native"
COMMON_INC="-I$ROOT/include -I$ROOT/demo/quirc"

cc $COMMON_OPT -std=c11 -Wall -Wextra $COMMON_INC -c "$ROOT/demo/quirc/quirc.c" -o "$OBJDIR/quirc.o"
cc $COMMON_OPT -std=c11 -Wall -Wextra $COMMON_INC -c "$ROOT/demo/quirc/identify.c" -o "$OBJDIR/identify.o"
cc $COMMON_OPT -std=c11 -Wall -Wextra $COMMON_INC -c "$ROOT/demo/quirc/decode.c" -o "$OBJDIR/decode.o"
cc $COMMON_OPT -std=c11 -Wall -Wextra $COMMON_INC -c "$ROOT/demo/quirc/version_db.c" -o "$OBJDIR/version_db.o"
c++ $COMMON_OPT -std=c++17 -Wall -Wextra $COMMON_INC $OPENCV_CFLAGS -c "$ROOT/demo/benchmark.cpp" -o "$OBJDIR/benchmark.o"

exec c++ \
  -no-pie \
  "$OBJDIR/benchmark.o" \
  "$OBJDIR/quirc.o" \
  "$OBJDIR/identify.o" \
  "$OBJDIR/decode.o" \
  "$OBJDIR/version_db.o" \
  "$QUIRCZ_LIB" \
  $OPENCV_LIBS \
  -lm \
  -o "$OUT"
