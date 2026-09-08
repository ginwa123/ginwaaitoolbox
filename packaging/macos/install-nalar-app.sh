#!/usr/bin/env bash
# packaging/macos/install-nalar-app.sh
#
# User-local macOS install: assembles Nalar.app (no admin, no /Applications).
# Both binaries ship together because the desktop auto-spawns the nalar
# service sitting next to itself (Contents/MacOS/nalar); a lone
# nalar-desktop cannot start its backend.
#
# Usage:
#   packaging/macos/install-nalar-app.sh <sourcedir> [destappdir]
#
#   <sourcedir>   dir holding `nalar-desktop` + `nalar`
#                 (e.g. zig-out/bin from `zig build nalar-desktop`).
#   [destappdir]  destination bundle, default ~/Applications/Nalar.app.
#                 CI passes a staging dir (bin-stage-*/Nalar.app) instead.
#
# Post-assembly the script clears the quarantine xattr and applies an
# ad-hoc signature (both best-effort) so a first double-click doesn't
# bounce on Gatekeeper for locally-built binaries.
#
# Idempotent: re-running overwrites the previous bundle.
# NOTE: no custom icon in v1 (only favicon.ico exists; .icns needs macOS
# iconutil) — the bundle still indexes in Spotlight/Launchpad by name.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <sourcedir> [destappdir]" >&2
    exit 1
fi

SRC_DIR="$1"
DEST_APP="${2:-$HOME/Applications/Nalar.app}"

for bin in nalar-desktop nalar; do
    if [[ ! -f "${SRC_DIR}/${bin}" ]]; then
        echo "Required file missing: ${SRC_DIR}/${bin} -- run 'zig build nalar-desktop' first." >&2
        exit 1
    fi
done

# Resolve Info.plist next to this script so the script works from any cwd
# (repo checkout) and from a release-zip layout (script beside Info.plist).
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PLIST_SRC="${SCRIPT_DIR}/Info.plist"
if [[ ! -f "${PLIST_SRC}" ]]; then
    echo "Info.plist missing next to script: ${PLIST_SRC}" >&2
    exit 1
fi

rm -rf "${DEST_APP}"
mkdir -p "${DEST_APP}/Contents/MacOS" "${DEST_APP}/Contents/Resources"

cp "${SRC_DIR}/nalar-desktop" "${DEST_APP}/Contents/MacOS/nalar-desktop"
cp "${SRC_DIR}/nalar"         "${DEST_APP}/Contents/MacOS/nalar"
chmod +x "${DEST_APP}/Contents/MacOS/nalar-desktop" "${DEST_APP}/Contents/MacOS/nalar"
cp "${PLIST_SRC}" "${DEST_APP}/Contents/Info.plist"

# Gatekeeper friendliness for locally-built binaries (best-effort: missing
# tools or hardened runtimes must not fail the install).
xattr -dr com.apple.quarantine "${DEST_APP}" 2>/dev/null || true
codesign --force --deep -s - "${DEST_APP}" 2>/dev/null || true

echo "Installed Nalar.app -> ${DEST_APP}"
echo "Spotlight/Launchpad will index it as 'Nalar' (reindex can take ~1 min on first install)."
