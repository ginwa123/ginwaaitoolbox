#!/usr/bin/env bash
# scripts/bootstrap-vendor.sh
#
# One-shot bootstrap script that populates vendored deps from scratch.
# Used by fresh checkouts + CI to get all cross-compile artifacts
# without committing ~73 MB of binary + symlinks to git.
#
# Modules own their own vendor dirs:
#   - src/modules/databases/vendor/sqlite3/        (sqlite3 amalgamation)
#   - src/modules/custom_http_client/vendor/curl/   (prebuilt libcurl.a per target)
#
# Steps:
#   1. SQLite amalgamation (C source) — src/modules/databases/scripts/fetch-vendor-sqlite3.sh
#   2. SQLite prebuilt archives (per target) — scripts/build-vendor-sqlite3-windows.sh
#   3. Curl prebuilt archives (per target, HTTP only) — src/modules/custom_http_client/scripts/build-vendor-curl.sh
#   4. MinGW symlink farm (Windows cross-compile) — scripts/build-vendor-mingw.sh
#
# All scripts are idempotent — re-running is a no-op if artifacts exist.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PROJECT_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"
cd "${PROJECT_DIR}"

echo "============================================================"
echo "Bootstrapping vendored deps for cross-platform builds"
echo "============================================================"

echo ""
echo "Step 1/4: SQLite amalgamation (into src/modules/databases/vendor/sqlite3/)"
bash src/modules/databases/scripts/fetch-vendor-sqlite3.sh

echo ""
echo "Step 2/4: SQLite prebuilt archives (per target)"
bash scripts/build-vendor-sqlite3-windows.sh

echo ""
echo "Step 3/4: MinGW symlink farm (Windows cross-compile)"
bash scripts/build-vendor-mingw.sh

echo ""
echo "Step 4/4: Curl prebuilt archives (per target, HTTP-only)"
bash src/modules/custom_http_client/scripts/build-vendor-curl.sh

echo ""
echo "============================================================"
echo "Done. Vendored deps populated. Now run: zig build"
echo "============================================================"
