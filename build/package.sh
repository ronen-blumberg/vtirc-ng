#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build/package.sh -- release archives
#
#   build/package.sh            builds linux64 + win32 (release) and packs:
#     dist/vtirc-ng-<ver>-linux-x86_64.tar.gz
#     dist/vtirc-ng-<ver>-win32.zip
#   Each contains the program, fonts/ (full Unifont + licence), README.md,
#   CHANGELOG.md, LICENSE and the libvt licence; the Windows zip adds SDL2.dll.
# -----------------------------------------------------------------------------
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=$(sed -n 's/^Const VTIRC_VERSION = "\(.*\)"/\1/p' "$ROOT/src/version.bi")
[ -n "$VER" ] || { echo "cannot read the version from src/version.bi" >&2; exit 1; }

"$ROOT/build/build.sh" all release

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

stage() {   # stage <dir> <binary...>
    local d="$1"; shift
    mkdir -p "$d/fonts"
    cp "$@" "$d/"
    cp "$ROOT/fonts/vtirc-ng.vtuf" "$ROOT/fonts/UNIFONT-LICENSE.txt" "$d/fonts/"
    cp "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/LICENSE" "$d/"
    cp "$ROOT/vt/LICENSE-libvt" "$d/LICENSE-libvt.txt"
}

L="vtirc-ng-$VER-linux-x86_64"
stage "$DIST/$L" "$ROOT/build/out/linux64/vtirc-ng"
(cd "$DIST" && tar -czf "$L.tar.gz" "$L")

W="vtirc-ng-$VER-win32"
stage "$DIST/$W" "$ROOT/build/out/win32/vtirc-ng.exe" "$ROOT/deps/win32/SDL2.dll"
(cd "$DIST" && python3 -m zipfile -c "$W.zip" "$W")

rm -rf "$DIST/$L" "$DIST/$W"
ls -la "$DIST"
