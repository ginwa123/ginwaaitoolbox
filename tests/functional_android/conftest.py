"""Shared pytest fixtures for the Android functional UI suite.

Three fixtures carry the weight:

* ``default_nalar_bin`` (session-scoped) — resolves the path to a built
  ``nalar`` binary from ``$NALAR_BIN`` or the known ``zig-out`` paths.
* ``android_harness`` (module-scoped) — one real ``nalar`` against one isolated
  tmpdir HOME, with the stub LLM profile written so a session has a profile to
  read.
* ``seed_db`` — the path to that instance's own ``agent.db``, ready for
  ``DbSeed``.

Why module-scoped rather than function-scoped, when ``tests/functional/`` uses
function scope: this suite's per-test cost is a Gradle build + install + device
handshake, not a process boot. A fresh server per assertion would multiply a
two-minute suite by the scenario count for no isolation gain — isolation comes
from giving every scenario its own ``session_id`` and from the instrumented
side clearing the app's own state between tests (see ``ClearAppStateRule``).
The precedent is ``tests/functional/android_chat_sse_contract_test.py``, which
shadows the same fixture to module scope for the same reason.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Iterator

import pytest

from harness import FunctionalHarness, FunctionalHarnessError


# ─── Session-scoped: resolve the nalar binary once ─────────────────────────


def _resolve_nalar_bin() -> Path:
    """Find the nalar binary in standard locations.

    Same resolution order as ``tests/functional/conftest.py`` and
    ``tests/functional_ui/conftest.py`` — duplicated rather than imported
    because a conftest fixture is only visible inside its own directory tree,
    and this suite is a sibling of both rather than a child of either.
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("NALAR_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/nalar"),
        Path("./zig-out/bin/nalar.exe"),
        Path("./zig-out/bin/nalarcore-linux-x86_64"),
        Path("./zig-out/bin/nalarcore-macos-aarch64"),
        Path("./zig-out/bin/nalarcore-macos-x86_64"),
        Path("./zig-out/bin/nalarcore-windows-x86_64"),
        Path("./zig-out/bin/nalarcore-windows-x86_64.exe"),
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


# ─── Module-scoped: one real nalar for the whole module ────────────────────


@pytest.fixture(scope="module")
def android_harness(default_nalar_bin: Path) -> Iterator[FunctionalHarness]:
    """One isolated nalar for the module, on a free port (never 8081).

    ``stub_llm_profile=True`` writes ``<temp_dir>/.config/nalar/config.json``
    with a single profile whose ``base_url`` points at a dead port. It is what
    makes ``GET /api/config/nalar`` return a profile for the composer's model
    picker; it is deliberately not a live model, because no scenario here needs
    a turn to complete (every row is seeded into the DB directly).

    ``boot()`` picks a random port in 20000..32000 and refuses 8081, so this
    never collides with the always-running dev backend.
    """
    h = FunctionalHarness.boot(default_nalar_bin, stub_llm_profile=True)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except FunctionalHarnessError as e:
            # Report it, but do not shadow the test's own assertion failure.
            pytest.fail(f"android_harness teardown refused: {e}", pytrace=False)


@pytest.fixture(scope="module")
def seed_db(android_harness: FunctionalHarness) -> Path:
    """Path to the harness instance's own ``agent.db``.

    ``nalar`` derives this from ``HOME``, which the harness shadowed to its
    tmpdir — so this path is inside ``nalar-func-*`` and nothing here can reach
    the developer's real database. ``DbSeed`` re-validates that with
    ``is_safe_tmp`` before it opens the file, as a second line of defence.
    """
    return android_harness.temp_dir / ".config" / "nalar" / "agent.db"
