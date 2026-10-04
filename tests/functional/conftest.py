"""Shared pytest fixtures for the functional test suites.

The two most important fixtures:

* ``default_pabrik_bin`` (session-scoped) — resolves the path to a
  built ``pabrik`` binary from ``$PABRIK_BIN`` or known zig-out paths.

* ``harness`` (function-scoped) — boots a fresh ``pabrik`` per test
  against an isolated tmpdir HOME. Teardown runs even when the
  test asserts-fail (the ``try/finally`` block is the second line
  of defense; the first is ``is_safe_tmp`` inside ``teardown``).
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Iterator

import pytest

from harness import FunctionalHarness, FunctionalHarnessError
from platform_gates import apply_runtime_gates, collect_ignore_for

# Suite files this platform cannot even IMPORT (they raise at module scope
# on `import pty` and friends). `collect_ignore` — not a skip marker — is
# the only thing that works: collection dies before any marker is
# evaluated. The table lives in tests/platform_gates.py so the reason is
# written down once for all three suites.
#
# CAVEAT, verified on pytest 8.4: `collect_ignore` applies to DIRECTORY
# collection only. Naming one of these files explicitly on the command line
# collects it anyway, because an explicit arg is not a directory scan. That
# is fine for CI — `zig build functional-test-all` passes
# `tests/functional/` and `tests/functional_ui/`, and a whole-run collection
# on a simulated win32 shows 737 tests with these 5 absent — but a developer
# running `pytest tests/functional/tui_perf_test.py` on Windows gets a real
# ImportError. On a POSIX host it runs, because `pty` exists there; the gate
# only matters where the import genuinely fails.
collect_ignore = collect_ignore_for()


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """Apply the runtime (skip-marker) half of the platform-gate table.

    Delegated to ``platform_gates`` rather than inlined: the hook body is
    the same for both suites, and a copy that has to be kept in agreement
    in two places is a copy that will drift. See
    ``apply_runtime_gates`` for why items are marked rather than ignored.
    """
    apply_runtime_gates(items)


# ─── Session-scoped: resolve the pabrik binary once ─────────────────────────


def _resolve_pabrik_bin() -> Path:
    """Find the pabrik binary in standard locations.

    Resolution order:
      1. ``$PABRIK_BIN`` env var (used by CI)
      2. ``./zig-out/bin/pabrik`` (after ``zig build install:linux:system``)
      3. ``./zig-out/bin/pabrikcore-linux-x86_64`` (cross-target)
      4. ``./zig-out/bin/pabrikcore-macos-aarch64`` (Mac Apple Silicon)
      5. ``./zig-out/bin/pabrikcore-macos-x86_64`` (Mac Intel)
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("PABRIK_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/pabrik"),
        Path("./zig-out/bin/pabrik.exe"),
        Path("./zig-out/bin/pabrikcore-linux-x86_64"),
        Path("./zig-out/bin/pabrikcore-macos-aarch64"),
        Path("./zig-out/bin/pabrikcore-macos-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64.exe"),
    ])
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c.resolve()
    raise FileNotFoundError(
        "No pabrik binary found. Set PABRIK_BIN or run "
        "`zig build install:linux:system` first."
    )


@pytest.fixture(scope="session")
def default_pabrik_bin() -> Path:
    """Session-scoped: the pabrik binary path. Skips the test if missing."""
    try:
        return _resolve_pabrik_bin()
    except FileNotFoundError as e:
        pytest.skip(str(e))


# ─── Function-scoped: a fresh harness per test ────────────────────────────


@pytest.fixture
def harness(default_pabrik_bin: Path) -> Iterator[FunctionalHarness]:
    """Function-scoped: a fresh pabrik per test, isolated tmpdir HOME.

    The ``try/finally`` ensures teardown runs even when the test
    asserts-fail mid-execution. The harness's ``teardown`` itself
    calls ``is_safe_tmp`` and refuses to rmtree an unsafe path.
    """
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except FunctionalHarnessError as e:
            # If teardown raises (because the path failed safety
            # validation), report it but don't shadow the test's
            # actual assertion failure.
            pytest.fail(f"harness teardown refused: {e}", pytrace=False)


# ─── Optional: a directory the test can use for on-disk assets ────────────


@pytest.fixture
def item_workspace_path(harness: FunctionalHarness, tmp_path: Path) -> Path:
    """A per-test tmpdir under pytest's tmp_path (NOT the harness's temp_dir).

    Use this for design item paths, attachment paths, etc. The
    harness's own ``temp_dir`` is the HOME that pabrik uses; this is
    a separate filesystem location the test can point design items
    at.

    Important: this dir is NOT auto-cleaned by the harness (pytest
    handles it via tmp_path's standard teardown). The harness
    guarantees only that ``temp_dir`` is rmtree'd on teardown.
    """
    return tmp_path / "item"
