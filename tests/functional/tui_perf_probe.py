#!/usr/bin/env python3
"""pty-driven performance probe for `pabrik-tui`.

Why a pty and not the HTTP harness: `pabrik-tui` refuses to start unless stdin
is a TTY, and its two reported symptoms are only observable through a real
terminal —

  * **memory leak** — RSS grows per *rendered frame*, so it must be sampled
    from `/proc/<pid>/status` while the app redraws at its own tick rate;
  * **input latency** — the gap between writing one key to the pty and the
    first byte the app writes back. A redraw only costs ~2 ms of CPU, so the
    old ~100 ms floor was pure event-loop latency.

The TUI is pointed at an unreachable server (`http://127.0.0.1:9`) unless
`--server` is given: the leak and the latency are both reproducible with zero
network traffic, which keeps this probe hermetic (no port binding, no backend).

Measured baselines (2026-09-13 audit, 200x50 terminal, before the fix):

    idle            +1.76 MB/s     (10 tick redraws/s, no input at all)
    keystroke       +364 KB/key    (+2.78 MB/key at 400x100)
    keystroke delay p50 104 ms  p90 110 ms
    wheel delay     p50 104 ms

After the fix: idle ~0, ~1 KB/key, p50 ~1 ms.

Usage:
    python3 tests/functional/tui_perf_probe.py --binary zig-out/bin/pabrik-tui
    python3 tests/functional/tui_perf_probe.py --binary ... --json

Exit code is non-zero when a threshold is violated, so this doubles as a
regression gate (see `tui_perf_test.py`). Requires a POSIX pty; skipped by the
pytest wrapper when `pabrik-tui` has not been built (`zig build install:tui`).
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

DEFAULT_ROWS = 50
DEFAULT_COLS = 200

# Thresholds: ~10x margin over the post-fix numbers, but far below the
# pre-fix ones, so a real regression trips them and CI noise does not.
MAX_IDLE_KB_PER_S = 256.0
MAX_KB_PER_KEY = 32.0
MAX_LATENCY_P50_MS = 30.0
MAX_LATENCY_P90_MS = 60.0


def _vm_rss_kb(pid: int) -> int:
    with open("/proc/%d/status" % pid) as fh:
        for line in fh:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    raise RuntimeError("no VmRSS for pid %d" % pid)


class TuiPty:
    """`pabrik-tui` running inside a pty, with a background output drain.

    The drain matters: the app writes its frame diff to the pty, and if nobody
    reads, the pty buffer fills and the app blocks in write() — which would
    freeze RSS and latency measurements at whatever they were.
    """

    def __init__(self, binary: str, server: str = "http://127.0.0.1:9",
                 rows: int = DEFAULT_ROWS, cols: int = DEFAULT_COLS):
        self.master, slave = pty.openpty()
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.proc = subprocess.Popen(
            [binary, "--server", server],
            stdin=slave, stdout=slave, stderr=slave,
            preexec_fn=os.setsid, close_fds=True,
        )
        os.close(slave)
        self._stop = False
        self.bytes_read = 0
        self._thread = threading.Thread(target=self._drain, daemon=True)
        self._thread.start()

    def _drain(self) -> None:
        while not self._stop:
            try:
                data = os.read(self.master, 1 << 20)
            except OSError:
                return
            if not data:
                return
            self.bytes_read += len(data)

    def send(self, payload: bytes) -> None:
        os.write(self.master, payload)

    def drain_pending(self) -> None:
        """Wait for output produced so far to be consumed by the drain thread."""
        deadline = time.time() + 0.2
        while time.time() < deadline:
            time.sleep(0.005)

    def rss_kb(self) -> int:
        return _vm_rss_kb(self.proc.pid)

    def wait_for_output(self, before: int, budget: float = 1.0) -> float:
        """Seconds until `bytes_read` moves past `before` (or `budget`)."""
        t0 = time.time()
        while self.bytes_read == before and time.time() - t0 < budget:
            time.sleep(0.0005)
        return time.time() - t0

    def close(self) -> None:
        self._stop = True
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            os.close(self.master)
        except OSError:
            pass

    def __enter__(self) -> "TuiPty":
        time.sleep(1.5)  # first paint + allocation warm-up
        self.drain_pending()
        return self

    def __exit__(self, *exc) -> None:
        self.close()


def measure_idle_growth(tui: TuiPty, seconds: float = 4.0) -> float:
    """KB/s leaked while the app redraws on its 100 ms tick with no input."""
    base = tui.rss_kb()
    time.sleep(seconds)
    return (tui.rss_kb() - base) / seconds


def measure_typing_growth(tui: TuiPty, keys: int = 100) -> float:
    """KB leaked per keystroke (one redraw each)."""
    base = tui.rss_kb()
    for i in range(keys):
        tui.send(bytes([ord("a") + (i % 26)]))
        time.sleep(0.05)
    return (tui.rss_kb() - base) / keys


def measure_latency(tui: TuiPty, keys: int = 12) -> list:
    """Per-keystroke latency: write one key, time the next output byte.

    `gap` gives the loop a quiet period first, so the measurement is not
    polluted by output the previous key already queued.
    """
    lat = []
    for i in range(keys):
        tui.drain_pending()
        before = tui.bytes_read
        tui.send(bytes([ord("a") + (i % 26)]))
        lat.append(tui.wait_for_output(before))
    return lat


def percentile(values: list, pct: float) -> float:
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(len(ordered) * pct))
    return ordered[idx]


def run(binary: str, server: str, rows: int, cols: int) -> dict:
    with TuiPty(binary, server, rows, cols) as tui:
        idle = measure_idle_growth(tui)
        lat = measure_latency(tui)
        per_key = measure_typing_growth(tui)
        p50 = percentile(lat, 0.5) * 1000
        p90 = percentile(lat, 0.9) * 1000

    violations = []
    if idle > MAX_IDLE_KB_PER_S:
        violations.append("idle leak %.0f KB/s > %d KB/s" % (idle, MAX_IDLE_KB_PER_S))
    if per_key > MAX_KB_PER_KEY:
        violations.append("typing leak %.1f KB/key > %d KB/key" % (per_key, MAX_KB_PER_KEY))
    if p50 > MAX_LATENCY_P50_MS:
        violations.append("keystroke latency p50 %.1f ms > %d ms" % (p50, MAX_LATENCY_P50_MS))
    if p90 > MAX_LATENCY_P90_MS:
        violations.append("keystroke latency p90 %.1f ms > %d ms" % (p90, MAX_LATENCY_P90_MS))

    return {
        "binary": binary,
        "rows": rows,
        "cols": cols,
        "idle_kb_per_s": round(idle, 1),
        "typing_kb_per_key": round(per_key, 2),
        "latency_p50_ms": round(p50, 2),
        "latency_p90_ms": round(p90, 2),
        "latency_max_ms": round(max(lat) * 1000, 2),
        "violations": violations,
        "ok": not violations,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=os.environ.get("PABRIK_TUI_BIN", "zig-out/bin/pabrik-tui"))
    ap.add_argument("--server", default="http://127.0.0.1:9",
                    help="backend URL; keep it unreachable for a hermetic probe")
    ap.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    ap.add_argument("--cols", type=int, default=DEFAULT_COLS)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.exists(args.binary):
        print("probe: %s not found (run `zig build install:tui` first)" % args.binary,
              file=sys.stderr)
        return 2

    result = run(args.binary, args.server, args.rows, args.cols)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print("pabrik-tui perf probe  (%dx%d, %s)" % (result["cols"], result["rows"], result["binary"]))
        print("  idle leak          : %.1f KB/s" % result["idle_kb_per_s"])
        print("  per keystroke      : %.2f KB" % result["typing_kb_per_key"])
        print("  keystroke latency  : p50 %.2f ms  p90 %.2f ms  max %.2f ms"
              % (result["latency_p50_ms"], result["latency_p90_ms"], result["latency_max_ms"]))
        print("  RESULT             : %s" % ("PASS" if result["ok"] else "FAIL"))
        for v in result["violations"]:
            print("    ! %s" % v)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
