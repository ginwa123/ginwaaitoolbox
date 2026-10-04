"""Functional regression gate for pabrik-tui's memory leak + input latency.

The 2026-09-13 audit (docs/superpowers/plans/2026-09-13-audit-pabrik-tui-memory-and-latency.md)
found two runtime symptoms that no unit test could see:

  1. the TUI leaked a frame buffer on every redraw (~0.36 MB/keystroke,
     1.76 MB/s while merely idle) because it ran on the process-lifetime
     arena allocator;
  2. every keystroke and wheel notch took ~104 ms because the event loop
     blocked in read() and then slept 100 ms, and because `readSliceShort`
     keeps reading until its whole destination buffer is full.

Both are only reproducible through a real TTY, so these tests drive the binary
inside a pty and assert on RSS growth and on key-to-echo latency.

Skipped (not failed) when `pabrik-tui` has not been built: `zig build
install:tui` produces zig-out/bin/pabrik-tui, and CI's functional-test step only
installs the main `pabrik` binary. Set PABRIK_TUI_BIN to point at any build.

Run locally:
    zig build install:tui
    pytest tests/functional/tui_perf_test.py -v
"""

from __future__ import annotations

import os
import shutil

import pytest

from tui_perf_probe import (
    MAX_IDLE_KB_PER_S,
    MAX_KB_PER_KEY,
    MAX_LATENCY_P50_MS,
    TuiPty,
    measure_idle_growth,
    measure_latency,
    measure_typing_growth,
    percentile,
)


def _binary() -> str:
    candidates = [
        os.environ.get("PABRIK_TUI_BIN"),
        "zig-out/bin/pabrik-tui",
        "zig-out/bin/pabrik-tui.exe",
        shutil.which("pabrik-tui"),
    ]
    for cand in candidates:
        if cand and os.path.exists(cand):
            return cand
    pytest.skip("pabrik-tui not built — run `zig build install:tui` (or set PABRIK_TUI_BIN)")


@pytest.fixture
def tui():
    with TuiPty(_binary()) as probe:
        yield probe


def test_tui_idle_redraws_do_not_leak(tui):
    """Idle = 10 tick redraws/s with zero input. Pre-fix this leaked 1.76 MB/s."""
    kb_per_s = measure_idle_growth(tui, seconds=4.0)
    assert kb_per_s < MAX_IDLE_KB_PER_S, (
        "pabrik-tui leaked %.0f KB/s while idle (limit %d): the model/program "
        "allocator must not be a process-lifetime arena" % (kb_per_s, MAX_IDLE_KB_PER_S)
    )


def test_tui_typing_does_not_leak(tui):
    """Pre-fix each keystroke retained ~364 KB (two whole frame buffers)."""
    kb_per_key = measure_typing_growth(tui, keys=60)
    assert kb_per_key < MAX_KB_PER_KEY, (
        "pabrik-tui leaked %.1f KB per keystroke (limit %d)" % (kb_per_key, MAX_KB_PER_KEY)
    )


def test_tui_keystroke_latency_is_not_blocked_by_the_tick(tui):
    """Pre-fix p50 was ~104 ms: read() + sleep(100 ms), no poll()."""
    lat = measure_latency(tui, keys=12)
    p50 = percentile(lat, 0.5) * 1000
    p90 = percentile(lat, 0.9) * 1000
    assert p50 < MAX_LATENCY_P50_MS, "keystroke latency p50 %.1f ms (limit %d)" % (p50, MAX_LATENCY_P50_MS)
    assert p90 < MAX_LATENCY_P50_MS * 2, "keystroke latency p90 %.1f ms" % p90
