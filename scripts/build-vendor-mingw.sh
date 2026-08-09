#!/usr/bin/env bash
# scripts/build-vendor-mingw.sh
#
# Regenerates vendor/sqlite3/libc-windows-amd64/ — the merged MinGW
# include/ + lib/ symlink farm used for Windows cross-compile from Linux.
#
# Without this, `zig build install:windows` fails with "no such file or
# directory" pointing at vendor/sqlite3/libc-windows-amd64/{include,lib}.
#
# Why symlinks (not copies): each header + lib file is named uniquely, so
# a symlink farm is functionally identical to a copy but takes ~50 MB on
# disk instead of duplicating the entire /usr/x86_64-w64-mingw32/ tree in
# the repo. ~2 552 files × ~50 KB avg = 127 MB if copied; ~50 MB if
# symlinked (since we only store the symlinks themselves in the repo).
#
# Idempotent: if the farm already exists, this script is a no-op.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PROJECT_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"
DEST="${PROJECT_DIR}/vendor/sqlite3/libc-windows-amd64"
MINGW_ROOT="/usr/x86_64-w64-mingw32"
SQLITE_HEADER="${PROJECT_DIR}/vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/sqlite3.h"
SQLITE_LIB_DIR="${PROJECT_DIR}/vendor/sqlite3/windows-amd64"

if [[ -d "${DEST}/include" && -d "${DEST}/lib" ]]; then
    echo "vendor/sqlite3/libc-windows-amd64/ already populated; skipping."
    exit 0
fi

if [[ ! -d "${MINGW_ROOT}" ]]; then
    echo "ERROR: ${MINGW_ROOT} not found." >&2
    echo "  Install MinGW: sudo pacman -S mingw-w64-gcc   # Arch" >&2
    echo "                sudo apt install gcc-mingw-w64-x86-64  # Debian/Ubuntu" >&2
    exit 1
fi

mkdir -p "${DEST}/include" "${DEST}/lib"

# Symlink every MinGW header into vendor/.../include/
for f in "${MINGW_ROOT}/include/"*; do
    ln -sf "${f}" "${DEST}/include/$(basename "${f}")"
done

# Override sqlite3.h with the amalgamation header (canonical version)
if [[ -f "${SQLITE_HEADER}" ]]; then
    ln -sf "${SQLITE_HEADER}" "${DEST}/include/sqlite3.h"
fi

# Symlink every MinGW lib into vendor/.../lib/
for f in "${MINGW_ROOT}/lib/"*; do
    ln -sf "${f}" "${DEST}/lib/$(basename "${f}")"
done

# Override libsqlite3.a with our Windows import lib (generated via dlltool
# from sqlite3.def — see scripts/build-vendor-sqlite3-windows.sh)
if [[ -f "${SQLITE_LIB_DIR}/libsqlite3.a" ]]; then
    ln -sf "${SQLITE_LIB_DIR}/libsqlite3.a" "${DEST}/lib/libsqlite3.a"
fi

echo "Built MinGW symlink farm: $(find "${DEST}" -type l | wc -l) symlinks"
