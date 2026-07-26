#!/usr/bin/env bash
#
# scripts/crash_handler_smoke.sh
#
# End-to-end smoke test for src/service/crash_handler.zig.
#
# Compiles src/service/crash_handler_smoke.zig as a standalone binary that uses
# the production crash_handler module, invokes it with a known log path
# + signal name, and asserts the log file ends up with a "=== CRASH:"
# header. Each signal is tested separately so a regression on one signal
# (e.g. a comptime branch accidentally dropping SIGBUS) is isolated.
#
# Usage:
#   ./scripts/crash_handler_smoke.sh               # all 5 signals
#   ./scripts/crash_handler_smoke.sh SEGV ABRT     # specific signals
#
# Exit code:
#   0   all signals produced a CRASH: log entry
#   1   at least one signal did NOT (or compilation failed)
#
# Cross-platform notes:
#   - Linux: SIGBUS exists in std.c.SIG (value 10).
#   - macOS: SIGBUS exists in std.c.SIG (value 10).
#   - Windows: SIGBUS is not defined in libc; the smoke test on Windows
#     skips BUS but still exercises SEGV/ABRT/ILL/FPE.
#   - Windows builds require the Win32 SetUnhandledExceptionFilter
#     path; the crash_handler_smoke.zig must be compiled for the host
#     OS (the script auto-detects via `uname -s`).

set -uo pipefail

# Auto-detect the worktree root from the script's own location so this
# script works regardless of which worktree is checked out. The
# hardcoded path that lived here previously was tied to the original
# crash-handler PR worktree and broke the moment any other worktree
# tried to run the smoke test.
WORKTREE="$(git -C "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" rev-parse --show-toplevel)"
LOG_FILE="/tmp/crash_handler_smoke.log"
SMOKE_BIN="/tmp/crash_handler_smoke"
SMOKE_SRC="${WORKTREE}/src/service/crash_handler_smoke.zig"
SMOKE_DEPS="${WORKTREE}/src/root.zig"
SMOKE_DEPS_DIR="${WORKTREE}/src"

SIGNALS_REQUESTED=("$@")
if [ "${#SIGNALS_REQUESTED[@]}" -eq 0 ]; then
    SIGNALS_REQUESTED=(SEGV ABRT ILL FPE)
    # BUS is Linux/macOS only — skip on Windows.
    if [ "$(uname -s)" != "Windows" ]; then
        SIGNALS_REQUESTED+=(BUS)
    fi
fi

cd "${WORKTREE}"

echo "==> Compiling smoke test binary..."
# Compile as a standalone executable that uses the project's
# nalarcore (root.zig) as a module — smoke.zig does
# `@import("nalarcore").crash_handler` to reach the production module.
if ! zig build-exe \
    --dep nalarcore \
    -Mroot="${SMOKE_SRC}" \
    -Mnalarcore="${SMOKE_DEPS}" \
    -lc \
    --cache-dir .zig-cache-smoke \
    --global-cache-dir /home/ginwa/.cache/zig \
    -femit-bin="${SMOKE_BIN}" 2>&1 | tail -n 20; then
    echo "!! Compilation failed"
    exit 1
fi

# Reset the log file so we read only this run's crash entry.
rm -f "${LOG_FILE}"

PASS=0
FAIL=0
FAILED_SIGNALS=()

for sig in "${SIGNALS_REQUESTED[@]}"; do
    echo ""
    echo "==> Triggering ${sig}..."
    rm -f "${LOG_FILE}"
    "${SMOKE_BIN}" "${LOG_FILE}" "${sig}" 2>&1 | tail -n 5
    EXIT_CODE=$?

    # The signal handler MUST re-raise → process exits with non-zero
    # (killed by the signal). A clean exit (0) means the handler
    # swallowed the signal — that's a bug.
    if [ "${EXIT_CODE}" -eq 0 ]; then
        echo "  FAIL: ${sig} exited cleanly (0) — handler swallowed signal"
        FAIL=$((FAIL + 1))
        FAILED_SIGNALS+=("${sig}")
        continue
    fi

    # The log file MUST contain a CRASH: header.
    if [ ! -f "${LOG_FILE}" ]; then
        echo "  FAIL: ${sig} did NOT write a log file"
        FAIL=$((FAIL + 1))
        FAILED_SIGNALS+=("${sig}")
        continue
    fi

    if ! grep -q "=== CRASH:" "${LOG_FILE}"; then
        echo "  FAIL: ${sig} log file lacks '=== CRASH:' header"
        echo "  log contents:"
        cat "${LOG_FILE}" | head -n 10 | sed 's/^/    /'
        FAIL=$((FAIL + 1))
        FAILED_SIGNALS+=("${sig}")
        continue
    fi

    # The log file MUST mention the signal name (or its synonym).
    case "${sig}" in
        SEGV) SIGNAL_NAME="SEGV" ;;
        ABRT) SIGNAL_NAME="ABRT" ;;
        ILL)  SIGNAL_NAME="ILL" ;;
        FPE)  SIGNAL_NAME="FPE" ;;
        BUS)  SIGNAL_NAME="BUS" ;;
        *)    SIGNAL_NAME="${sig}" ;;
    esac
    if ! grep -q "${SIGNAL_NAME}" "${LOG_FILE}"; then
        echo "  FAIL: ${sig} log file does not mention signal name '${SIGNAL_NAME}'"
        echo "  log contents:"
        cat "${LOG_FILE}" | head -n 10 | sed 's/^/    /'
        FAIL=$((FAIL + 1))
        FAILED_SIGNALS+=("${sig}")
        continue
    fi

    # Bonus: stack trace frames should appear in the log (at least one
    # hex address is sufficient — Zig 0.16 produces raw hex addresses).
    if ! grep -q "0x" "${LOG_FILE}"; then
        echo "  WARN: ${sig} log file has no hex addresses (no stack trace)"
        # Not a hard fail — best-effort logging may legitimately produce
        # an empty trace if stack tracing is disabled.
    fi

    echo "  PASS: ${sig} produced a CRASH: log entry"
    PASS=$((PASS + 1))
done

echo ""
echo "==> Summary: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
    echo "    Failed signals: ${FAILED_SIGNALS[*]}"
    rm -f "${SMOKE_BIN}"
    exit 1
fi

rm -f "${SMOKE_BIN}"
exit 0