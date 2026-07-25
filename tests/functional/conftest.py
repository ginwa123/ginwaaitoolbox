"""Shared pytest fixtures for the functional test suites.

The two most important fixtures:

* ``default_nalar_bin`` (session-scoped) — resolves the path to a
  built ``nalar`` binary from ``$NALAR_BIN`` or known zig-out paths.

* ``harness`` (function-scoped) — boots a fresh ``nalar`` per test
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


# ─── Session-scoped: resolve the nalar binary once ─────────────────────────


def _resolve_nalar_bin() -> Path:
    """Find the nalar binary in standard locations.

    Resolution order:
      1. ``$NALAR_BIN`` env var (used by CI)
      2. ``./zig-out/bin/nalar`` (after ``zig build install:linux:system``)
      3. ``./zig-out/bin/nalarcore-linux-x86_64`` (cross-target)
      4. ``./zig-out/bin/nalarcore-macos-aarch64`` (Mac Apple Silicon)
      5. ``./zig-out/bin/nalarcore-macos-x86_64`` (Mac Intel)
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("NALAR_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/nalar"),
        Path("./zig-out/bin/nalarcore-linux-x86_64"),
        Path("./zig-out/bin/nalarcore-macos-aarch64"),
        Path("./zig-out/bin/nalarcore-macos-x86_64"),
    ])
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c.resolve()
    raise FileNotFoundError(
        "No nalar binary found. Set NALAR_BIN or run "
        "`zig build install:linux:system` first."
    )


@pytest.fixture(scope="session")
def default_nalar_bin() -> Path:
    """Session-scoped: the nalar binary path. Skips the test if missing."""
    try:
        return _resolve_nalar_bin()
    except FileNotFoundError as e:
        pytest.skip(str(e))


# ─── Function-scoped: a fresh harness per test ────────────────────────────


@pytest.fixture
def harness(default_nalar_bin: Path) -> Iterator[FunctionalHarness]:
    """Function-scoped: a fresh nalar per test, isolated tmpdir HOME.

    The ``try/finally`` ensures teardown runs even when the test
    asserts-fail mid-execution. The harness's ``teardown`` itself
    calls ``is_safe_tmp`` and refuses to rmtree an unsafe path.
    """
    h = FunctionalHarness.boot(default_nalar_bin)
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
    harness's own ``temp_dir`` is the HOME that nalar uses; this is
    a separate filesystem location the test can point design items
    at.

    Important: this dir is NOT auto-cleaned by the harness (pytest
    handles it via tmp_path's standard teardown). The harness
    guarantees only that ``temp_dir`` is rmtree'd on teardown.
    """
    return tmp_path / "item"
