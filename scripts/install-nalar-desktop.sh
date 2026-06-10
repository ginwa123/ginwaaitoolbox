#!/usr/bin/env bash
# scripts/install-nalar-desktop.sh
#
# Installs nalar and nalar-desktop to /usr/local/bin.
# Requires: zig-built zig-out/bin/nalar and zig-out/bin/nalar-desktop.
#
# Usage: sudo ./scripts/install-nalar-desktop.sh
#
# Idempotent: re-running will overwrite the previous install.

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

# Resolve the script's directory so the script works from any cwd
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PROJECT_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"

if [[ ! -f "${PROJECT_DIR}/zig-out/bin/nalar" ]] || \
   [[ ! -f "${PROJECT_DIR}/zig-out/bin/nalar-desktop" ]]; then
    echo "Run 'zig build install' first to produce zig-out/bin/." >&2
    echo "Expected to find:" >&2
    echo "  ${PROJECT_DIR}/zig-out/bin/nalar" >&2
    echo "  ${PROJECT_DIR}/zig-out/bin/nalar-desktop" >&2
    exit 1
fi

install -m 0755 "${PROJECT_DIR}/zig-out/bin/nalar"         /usr/local/bin/nalar
install -m 0755 "${PROJECT_DIR}/zig-out/bin/nalar-desktop" /usr/local/bin/nalar-desktop

echo "Installed nalar and nalar-desktop to /usr/local/bin/"
echo "Run 'nalar-desktop' to start the desktop wrapper."
echo "  (On Linux: requires webkit2gtk-4.1, gtk-3, libsoup-3.0 system packages)"
echo "  (On macOS: no extra deps; Cocoa + WebKit are system frameworks)"
echo "  (On Windows: requires WebView2 Runtime; preinstalled on Win 10+)"
