"""Tests for the random-port selector in ``FunctionalHarness``.

The functional-test boot story used to scan a sequential 8080..8199
range, which caused two CI failures:

  1. Sequential consumption — long test suites filled the 120-port
     window and later tests errored with "No free port found".
  2. TIME_WAIT saturation — even with ``SO_REUSEADDR``, a CI runner
     holding 100+ TIME_WAITs could collide with the narrow scan range.

This file pins the new contract: ``find_free_port_random()`` picks from
a wide range (20k-32k, clear of the kernel's ephemeral pool), skips
reserved ports, and exhausts gracefully.
The parallel regression for the sequential path (``_find_free_port``
with an explicit ``start=``) lives in ``harness_orphan_reap_test.py``.

These tests run WITHOUT a real nalar binary — they exercise the port-
finder primitives directly.

Run::

    PYTHONPATH=tests/functional:. pytest tests/functional/harness_port_random_test.py -v
"""

from __future__ import annotations

import random
import socket
import time
from typing import Iterator

import pytest

from harness import (
    DEFAULT_PORT,
    FunctionalHarnessError,
    PORT_SCAN_END,
    RANDOM_PORT_ATTEMPTS,
    RANDOM_PORT_END,
    RANDOM_PORT_START,
    RESERVED_PORTS,
    _find_free_port,
    _find_free_port_sequential,
    find_free_port_random,
    port_is_free_with_reuse,
)


# ─── range + reserved-port contract ──────────────────────────────────────────


def test_random_port_constants_are_well_formed() -> None:
    """The random-range constants must form a sensible non-empty interval.

    Guards against a future typo that would corrupt the picker (e.g.
    start=60000, end=40000 — that's a silent no-op loop).
    """
    assert RANDOM_PORT_START < RANDOM_PORT_END, (
        f"RANDOM_PORT_START ({RANDOM_PORT_START}) must be < "
        f"RANDOM_PORT_END ({RANDOM_PORT_END})"
    )
    assert RANDOM_PORT_ATTEMPTS > 0, (
        f"RANDOM_PORT_ATTEMPTS must be > 0, got {RANDOM_PORT_ATTEMPTS}"
    )
    # The range must be wide enough that random selection is meaningful.
    # (20000 ports × 50 attempts means collision probability is tiny.)
    assert (RANDOM_PORT_END - RANDOM_PORT_START) >= 1000, (
        "Random range is too narrow; sequential selection semantics "
        "would dominate and defeat the purpose of randomisation"
    )


def test_reserved_ports_includes_8081_dev_backend() -> None:
    """The reserved-port list must include 8081 (always-on dev backend).

    Per project memory: "Don't ever kill the process port 8081".
    The random picker MUST skip it even if bind() succeeds.
    """
    assert 8081 in RESERVED_PORTS, (
        f"RESERVED_PORTS must include 8081 (dev backend per project "
        f"memory); got {RESERVED_PORTS!r}"
    )


# ─── basic behaviour ────────────────────────────────────────────────────────


def test_find_free_port_random_returns_port_in_default_range() -> None:
    """A single random pick lands in ``[RANDOM_PORT_START, RANDOM_PORT_END]``.

    The contract: callers don't need to validate the return — if we
    return at all it's a port we can bind.
    """
    port = find_free_port_random()
    assert RANDOM_PORT_START <= port <= RANDOM_PORT_END, (
        f"random port {port} fell outside the configured range "
        f"[{RANDOM_PORT_START}, {RANDOM_PORT_END}]"
    )
    # And it must not be a reserved port (bind-or-not, we exclude them).
    assert port not in RESERVED_PORTS, (
        f"random port {port} hit a reserved port {RESERVED_PORTS!r}"
    )


def test_find_free_port_random_respects_custom_range() -> None:
    """A custom ``range_start=`` / ``range_end=`` is honoured exactly.

    Lets callers (e.g. a future test or a debugging harness) narrow the
    window without redeclaring the function.
    """
    port = find_free_port_random(range_start=41000, range_end=41100)
    assert 41000 <= port <= 41100, (
        f"random port {port} fell outside the custom range [41000, 41100]"
    )


def test_find_free_port_random_avoids_reserved_ports() -> None:
    """A call with extra reserved ports never returns them.

    The most important reserved port is 8081 (the dev backend). This
    test pins the contract by reserving a tiny range and confirming the
    picker always lands outside it.
    """
    # Use a tight range and a port in the middle as the only "reserved"
    # value. The picker must skip it.
    port = find_free_port_random(
        range_start=42000, range_end=42002, reserved=(42001,)
    )
    assert port in (42000, 42002), (
        f"random port {port} should have landed in (42000, 42002) "
        f"and skipped the reserved 42001"
    )


def test_find_free_port_random_validates_arguments() -> None:
    """Bad range / attempts arguments raise before any bind() is attempted."""
    # end < start
    with pytest.raises(ValueError):
        find_free_port_random(range_start=50000, range_end=40000)
    # attempts <= 0
    with pytest.raises(ValueError):
        find_free_port_random(attempts=0)
    with pytest.raises(ValueError):
        find_free_port_random(attempts=-1)


# ─── randomness ─────────────────────────────────────────────────────────────


def test_find_free_port_random_usually_varies_across_calls() -> None:
    """Back-to-back random picks usually differ.

    With a 20,000-port range the collision probability per pick is
    ~1/20000 ≈ 5e-5. Across 10 picks it's still ~5e-4 — vanishing.
    If this test ever flakes we'd suspect the random seed has been
    pinned somehow.
    """
    picks = {find_free_port_random() for _ in range(10)}
    assert len(picks) > 1, (
        f"10 random picks returned only {len(picks)} distinct values "
        f"({picks!r}) — randomisation is broken / seed is pinned"
    )


def test_find_free_port_random_distribution_is_uniform() -> None:
    """A small sample distributes roughly evenly across the range.

    We don't assert an exact distribution (chi-squared is overkill for a
    CI test), just that picks aren't all bunched in one quarter of the
    range. A regression here would mean random.randint() semantics
    drifted, which we'd want to know about immediately.
    """
    span = RANDOM_PORT_END - RANDOM_PORT_START
    quarter = span // 4
    picks = [
        find_free_port_random()
        for _ in range(50)  # 50 picks across 4 quarters → expected ~12/quarter
    ]
    in_q1 = sum(1 for p in picks if p < RANDOM_PORT_START + quarter)
    in_q4 = sum(1 for p in picks if p >= RANDOM_PORT_START + 3 * quarter)
    # Loose bounds: between 5 and 35 each quarter. Very permissive —
    # just catches "all picks in one bucket" regressions.
    assert 5 <= in_q1 <= 35, (
        f"unexpected distribution: Q1={in_q1}/50 picks fell in the "
        f"first quarter of [{RANDOM_PORT_START}, {RANDOM_PORT_END}]"
    )
    assert 5 <= in_q4 <= 35, (
        f"unexpected distribution: Q4={in_q4}/50 picks fell in the "
        f"last quarter of [{RANDOM_PORT_START}, {RANDOM_PORT_END}]"
    )


# ─── TIME_WAIT handling ─────────────────────────────────────────────────────


def test_find_free_port_random_can_pick_time_wait_port() -> None:
    """A TIME_WAIT port (reachable only with SO_REUSEADDR) is a valid pick.

    The whole point of ``SO_REUSEADDR`` in the probe is that nalar (or
    vite) can subsequently bind the same port despite lingering server-
    side TIME_WAITs. If the picker rejected TIME_WAIT ports, rapid CI
    runs would still saturate the 20k-port window.
    """
    # Seed a TIME_WAIT on a port inside our random range.
    target_port = None
    for p in range(RANDOM_PORT_START, RANDOM_PORT_START + 1000):
        if p in RESERVED_PORTS or p == 8081:
            continue
        # Try to bind+release to confirm free
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("127.0.0.1", p))
            except OSError:
                continue
            target_port = p
            break
    if target_port is None:
        pytest.skip("no free port available to seed TIME_WAIT")

    # Create a server-side TIME_WAIT: bind, accept, close server-side.
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", target_port))
    srv.listen(1)
    cli = socket.socket()
    cli.connect(("127.0.0.1", target_port))
    conn, _ = srv.accept()
    conn.close()  # server-side close → TIME_WAIT on target_port
    srv.close()
    cli.close()
    time.sleep(0.05)

    # The probe (with SO_REUSEADDR) MUST still report target_port as free.
    assert port_is_free_with_reuse(target_port) is True, (
        f"port_is_free_with_reuse({target_port}) rejected a TIME_WAIT port "
        f"— the SO_REUSEADDR contract is broken"
    )

    # And the random picker, when restricted to a tight range around
    # target_port, MUST be willing to return it on a subsequent call.
    # (With a tight range the picker has limited room and converges
    # quickly on target_port.)
    found = None
    for _ in range(20):
        p = find_free_port_random(
            range_start=target_port - 2, range_end=target_port + 2
        )
        if p == target_port:
            found = p
            break
    assert found == target_port, (
        f"random picker refused to return TIME_WAIT port {target_port}; "
        f"SO_REUSEADDR contract not honoured by find_free_port_random"
    )


# ─── exhaustion behaviour ───────────────────────────────────────────────────


def test_find_free_port_random_raises_after_exhaustion() -> None:
    """When every pick collides, raise FunctionalHarnessError (don't loop forever).

    We synthesise exhaustion by reserving the entire tight range, so
    every pick lands on a reserved port and the loop terminates after
    ``attempts`` iterations with the documented error message.
    """
    start, end = 43000, 43010
    # Reserve every single port in the range — the picker has no escape.
    all_reserved = tuple(range(start, end + 1))
    with pytest.raises(FunctionalHarnessError) as exc:
        find_free_port_random(
            range_start=start,
            range_end=end,
            reserved=all_reserved,
            attempts=5,
        )
    msg = str(exc.value)
    # The error message should hint at the cause (range + attempts) so a
    # maintainer debugging a host with truly pathological occupancy
    # knows what to widen.
    assert "after 5 random picks" in msg or "5 random picks" in msg, (
        f"exhaustion message should mention the attempt count: {msg!r}"
    )
    assert str(start) in msg and str(end) in msg, (
        f"exhaustion message should mention the range so the operator "
        f"knows what to widen: {msg!r}"
    )


# ─── port_is_free_with_reuse (the shared probe helper) ─────────────────────


def test_port_is_free_with_reuse_basic() -> None:
    """A fresh free port returns True; one held by another listener returns False.

    Smoke test for the shared helper — exercised by both the random
    picker and the sequential scan, so it must be correct.
    """
    # Find a port we can keep allocated for the test.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))  # kernel-assigned ephemeral port
        chosen = s.getsockname()[1]
        # While the socket is bound, port_is_free_with_reuse must say False.
        assert port_is_free_with_reuse(chosen) is False
    # After we close, it returns True (the OS may still have it in
    # TIME_WAIT, but our probe sets SO_REUSEADDR so it's reported free).
    assert port_is_free_with_reuse(chosen) is True


def test_port_is_free_with_reuse_handles_explicit_bound_port() -> None:
    """Bind a long-lived listener, confirm the helper reports it busy."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.listen(1)
        try:
            assert port_is_free_with_reuse(port) is False
        finally:
            s.close()


# ─── sequential-path regression gate ────────────────────────────────────────


def test_sequential_path_still_works_via_explicit_start() -> None:
    """``_find_free_port_sequential`` keeps its first-free behaviour in the legacy range.

    The orphan-reap regression test (``harness_orphan_reap_test.py``)
    relies on this — it seeds a TIME_WAIT on ``target_port`` and asserts
    ``_find_free_port(start=target_port) == target_port``. We pin the
    same contract here with a fresh free port (no TIME_WAIT needed) so
    the sequential path is regression-tested independently.

    Note: the legacy sequential scan is bounded to ``[start, PORT_SCAN_END]``
    (``PORT_SCAN_END = 8199``), so the test must pick a start port
    inside the legacy range, not the new wide random range.
    """
    # Walk the legacy range looking for a free port. If 8080-8199 (minus
    # 8081) is fully consumed on a busy box, skip — the test isn't
    # about stress-testing the narrow legacy window.
    candidate = None
    for p in range(DEFAULT_PORT, PORT_SCAN_END + 1):
        if p == 8081:
            continue
        if port_is_free_with_reuse(p):
            candidate = p
            break
    if candidate is None:
        pytest.skip("no free port in the legacy [8080, 8199] range")

    # Sequential scan from ``candidate`` MUST return ``candidate``
    # because (a) the SO_REUSEADDR probe binds it, (b) no port before
    # it in [candidate, PORT_SCAN_END] is "more free".
    assert _find_free_port_sequential(candidate) == candidate


# ─── _find_free_port(None) → random (the production path) ──────────────────


def test_find_free_port_no_args_uses_random() -> None:
    """``_find_free_port()`` with no args picks a random port from the wide range.

    Regression guard for the bug where the old default ``port=DEFAULT_PORT``
    (=8080) was passed through to ``_find_free_port`` and triggered the
    legacy sequential path even when the caller didn't ask for 8080.
    The fix: ``port: int | None = None`` defaults to None, and
    ``_find_free_port(None)`` → random pick.

    We can't easily mock-boot the harness here (no nalar binary in this
    test scope), so we exercise the function directly — but that has
    the same shape as what ``FunctionalHarness.boot()`` calls.
    """
    port = _find_free_port()  # no args → random
    assert RANDOM_PORT_START <= port <= RANDOM_PORT_END, (
        f"_find_free_port() with no args returned {port}, expected a "
        f"random port in [{RANDOM_PORT_START}, {RANDOM_PORT_END}]"
    )


def test_find_free_port_explicit_int_uses_sequential() -> None:
    """``_find_free_port(start)`` with an explicit int triggers the legacy scan.

    Backward-compat contract: callers that pass an explicit port (e.g.
    debugging, deterministic repros) still get the sequential scan from
    that port to PORT_SCAN_END.
    """
    # Find a free port in the legacy range
    candidate = None
    for p in range(DEFAULT_PORT, PORT_SCAN_END + 1):
        if p == 8081:
            continue
        if port_is_free_with_reuse(p):
            candidate = p
            break
    if candidate is None:
        pytest.skip("no free port in the legacy [8080, 8199] range")

    # _find_free_port(candidate) → sequential → returns candidate
    assert _find_free_port(candidate) == candidate

    # _find_free_port(None) → random (regression guard against the
    # bug where port=8080 default was passed through)
    p = _find_free_port(None)
    assert RANDOM_PORT_START <= p <= RANDOM_PORT_END, (
        f"_find_free_port(None) returned {p}, expected a random port "
        f"in [{RANDOM_PORT_START}, {RANDOM_PORT_END}]"
    )


@pytest.fixture
def _seed_random() -> Iterator[None]:
    """Pin the random seed for any test that wants determinism.

    Not auto-used — opt-in via ``@pytest.mark.usefixtures("_seed_random")``.
    This test suite intentionally does NOT pin the seed for the
    randomness tests so they fail fast if random.randint() drifts.
    """
    state = random.getstate()
    random.seed(42)
    try:
        yield
    finally:
        random.setstate(state)
