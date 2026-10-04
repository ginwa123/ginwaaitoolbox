#!/usr/bin/env bash
# scripts/build-vendor-sqlite3-windows.sh
#
# Downloads the SQLite amalgamation + Windows DLL, then generates the
# libsqlite3.a import library via `x86_64-w64-mingw32-dlltool`.
#
# Output:
#   vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/  (C source)
#   vendor/sqlite3/windows-amd64/sqlite3.dll                  (runtime DLL)
#   vendor/sqlite3/windows-amd64/sqlite3.def                  (DLL exports)
#   vendor/sqlite3/windows-amd64/libsqlite3.a                 (import lib)
#
# Idempotent: skips if already built.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PROJECT_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"
AMALG_DIR="${PROJECT_DIR}/vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400"
WIN_DIR="${PROJECT_DIR}/vendor/sqlite3/windows-amd64"

if [[ -f "${AMALG_DIR}/sqlite3.c" && -f "${WIN_DIR}/libsqlite3.a" ]]; then
    echo "Windows sqlite3 artifacts already present; skipping."
    exit 0
fi

SQLITE_VERSION="3.53.4"
SQLITE_VERSION_NUMBER="3530400"
URL="https://sqlite.org/2026/sqlite-amalgamation-${SQLITE_VERSION_NUMBER}.zip"
WIN_DLL_URL="https://sqlite.org/2026/sqlite-dll-win-x64-${SQLITE_VERSION_NUMBER}.zip"

# Need unzip for the amalgamation zip
if ! command -v unzip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: need either 'unzip' or 'python3' to extract SQLite archives." >&2
    exit 1
fi

# Need x86_64-w64-mingw32-dlltool for the import lib
if ! command -v x86_64-w64-mingw32-dlltool >/dev/null 2>&1; then
    echo "ERROR: x86_64-w64-mingw32-dlltool not found on PATH." >&2
    echo "  Install: sudo pacman -S mingw-w64-binutils   # Arch" >&2
    echo "           sudo apt install mingw-w64-tools      # Debian/Ubuntu" >&2
    exit 1
fi

mkdir -p "${AMALG_DIR}" "${WIN_DIR}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pabrik-sqlite-XXXXXX")
trap 'rm -rf "${TMP}"' EXIT

# 1. Download + extract amalgamation
echo "=== Downloading amalgamation ==="
curl -fsSL --retry 3 --connect-timeout 30 "${URL}" -o "${TMP}/amalg.zip"
unzip -j -o "${TMP}/amalg.zip" "*/sqlite3.c" "*/sqlite3.h" "*/sqlite3ext.h" -d "${AMALG_DIR}" >/dev/null
echo "  wrote: ${AMALG_DIR}/sqlite3.{c,h,ext.h}"

# 2. Download Windows DLL
echo "=== Downloading Windows DLL ==="
curl -fsSL --retry 3 --connect-timeout 30 "${WIN_DLL_URL}" -o "${TMP}/win.zip"
unzip -j -o "${TMP}/win.zip" "*/sqlite3.def" "*/sqlite3.dll" -d "${WIN_DIR}" >/dev/null
echo "  wrote: ${WIN_DIR}/sqlite3.{def,dll}"

# 3. Generate import library
echo "=== Generating import library ==="
x86_64-w64-mingw32-dlltool -d "${WIN_DIR}/sqlite3.def" -l "${WIN_DIR}/libsqlite3.a"
echo "  wrote: ${WIN_DIR}/libsqlite3.a"

echo ""
echo "Done. Run scripts/build-vendor-mingw.sh next to regenerate the"
echo "MinGW symlink farm for Windows cross-compile."
