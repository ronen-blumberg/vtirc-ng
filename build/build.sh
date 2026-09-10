#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build/build.sh -- build vtirc-ng with FreeBASIC 1.10.1
#
#   build/build.sh [target] [mode]
#     target : linux64 (default) | win32 | all | test
#     mode   : release (default) | debug      (debug = -g -exx runtime checks)
#
# Outputs:
#   build/out/linux64/vtirc-ng
#   build/out/win32/vtirc-ng.exe  (+ SDL2.dll copied next to it)
#   build/out/linux64/test_core   (target "test": headless unit/integration tests)
#
# Environment overrides:
#   FBC        Linux fbc 1.10.1      (default: /usr/local/bin/fbc)
#   FBC_WIN32  Windows fbc32.exe     (default: ~/freebasic/fb_programming/FreeBASIC-1.10.1-winlibs-gcc-9.3.0/fbc32.exe)
#   WINEPREFIX wine prefix for fbc32 (default: ~/.wine-fbc)
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-linux64}
MODE=${2:-release}

FBC=${FBC:-/usr/local/bin/fbc}
FBC_WIN32=${FBC_WIN32:-$HOME/freebasic/fb_programming/FreeBASIC-1.10.1-winlibs-gcc-9.3.0/fbc32.exe}
export WINEPREFIX=${WINEPREFIX:-$HOME/.wine-fbc}

MAIN=vtirc.bas
COMMON=(-w all -gen gcc)
case "$MODE" in
    release) COMMON+=(-O 2) ;;
    debug)   COMMON+=(-g -exx) ;;
    *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac

require_fbc_1101() {
    local ver
    ver=$("$@" -version 2>/dev/null | tr -d '\r' | head -1)
    case "$ver" in
        *"Version 1.10.1"*) ;;
        *) echo "error: need FreeBASIC 1.10.1, got: ${ver:-nothing} ($*)" >&2; exit 1 ;;
    esac
}

build_linux64() {
    require_fbc_1101 "$FBC"
    mkdir -p "$ROOT/build/out/linux64"
    echo "== linux64 ($MODE)"
    (cd "$ROOT" && "$FBC" "$MAIN" "${COMMON[@]}" -arch x86-64 -x build/out/linux64/vtirc-ng)
    ls -la "$ROOT/build/out/linux64/vtirc-ng"
}

build_win32() {
    [ -f "$FBC_WIN32" ] || { echo "error: fbc32.exe not found: $FBC_WIN32" >&2; exit 1; }
    local wine=(env -u LD_PRELOAD WINEDEBUG=-all wine)
    require_fbc_1101 "${wine[@]}" "$FBC_WIN32"
    mkdir -p "$ROOT/build/out/win32"
    echo "== win32 ($MODE)"
    local out deps
    out=$(winepath -w "$ROOT/build/out/win32/vtirc-ng.exe" 2>/dev/null)
    deps=$(winepath -w "$ROOT/deps/win32" 2>/dev/null)
    # SDL2 is linked straight against deps/win32/SDL2.dll (GNU ld accepts DLLs)
    (cd "$ROOT" && "${wine[@]}" "$FBC_WIN32" "$MAIN" "${COMMON[@]}" -s gui -arch 686 \
        -p "$deps" -x "$out" 2>&1 | tr -d '\r')
    [ -f "$ROOT/build/out/win32/vtirc-ng.exe" ] || { echo "error: win32 build failed" >&2; exit 1; }
    cp "$ROOT/deps/win32/SDL2.dll" "$ROOT/build/out/win32/"
    ls -la "$ROOT/build/out/win32/vtirc-ng.exe"
}

build_test() {
    require_fbc_1101 "$FBC"
    mkdir -p "$ROOT/build/out/linux64"
    echo "== tests ($MODE)"
    (cd "$ROOT" && "$FBC" tests/test_core.bas -w all -gen gcc -g -exx -x build/out/linux64/test_core)
    "$ROOT/build/out/linux64/test_core"
}

case "$TARGET" in
    linux64) build_linux64 ;;
    win32)   build_win32 ;;
    all)     build_linux64; build_win32 ;;
    test)    build_test ;;
    *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac
