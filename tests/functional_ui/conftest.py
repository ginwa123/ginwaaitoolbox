"""Shared pytest fixtures for the functional UI test suites.

Mirrors the structure of ``tests/functional/conftest.py`` but adds
Playwright fixtures on top of the existing ``UIHarness`` lifecycle.

The fixtures:

* ``default_nalar_bin`` (session-scoped) — resolves the path to a
  built ``nalar`` binary from ``$NALAR_BIN`` or known zig-out paths.
  Reuses the same resolution logic as the parent ``functional/`` suite.

* ``ui_harness`` (function-scoped) — boots a fresh nalar + Vite dev
  server per test against an isolated tmpdir HOME. Teardown runs even
  when the test asserts-fail (the ``try/finally`` block is the second
  line of defense; the first is ``is_safe_tmp`` inside
  ``FunctionalHarness.teardown``).

* ``browser`` (session-scoped) — a single Playwright Chromium browser
  shared across tests for boot speed. Browser launch is ~2s; reusing
  it amortises that across the suite. Each test gets its own
  ``browser_context`` so cookies/cache don't leak between tests.

* ``page`` (function-scoped) — a fresh ``Page`` bound to a fresh
  ``browser_context`` per test. Auto-records a screenshot on test
  failure to ``tests/functional_ui/artifacts/<test_name>/<timestamp>.png``.

* ``artifacts_dir`` (function-scoped) — a per-test directory for
  screenshots and other on-disk artifacts. Created under
  ``tests/functional_ui/artifacts/<test_name>`` and NOT auto-cleaned
  (debug aids, kept across runs).

⛔  Isolation: the harness's tmpdir is rmtree'd by the parent's
teardown. The artifacts dir is a separate, non-harness directory under
``tests/functional_ui/artifacts`` that survives the test run.
"""

from __future__ import annotations

import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

import pytest

from ui_harness import UIHarness, FunctionalHarnessError
from platform_gates import apply_runtime_gates, collect_ignore_for

# Same wiring as tests/functional/conftest.py, reading the same table —
# see tests/platform_gates.py for why a suite that cannot be IMPORTED
# needs collect_ignore rather than a skip marker.
collect_ignore = collect_ignore_for()


def pytest_configure(config: pytest.Config) -> None:
    """Register custom marks so PytestUnknownMarkWarning stays quiet.

    ``no_sse_gate`` is applied to tests that need the SSE emit endpoint
    left disabled (e.g. the gate-off contract test). It's a private mark
    used by the autouse fixture in chatview_sse_stick_ui_test.py to
    decide whether to arm NALAR_TEST_SSE_EMIT=1.
    """
    config.addinivalue_line(
        "markers",
        "no_sse_gate: skip arming NALAR_TEST_SSE_EMIT=1 for this test",
    )


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """Apply the runtime (skip-marker) half of the platform-gate table.

    Delegated to ``platform_gates`` rather than inlined: the hook body is
    the same for both suites, and a copy that has to be kept in agreement
    in two places is a copy that will drift. See
    ``apply_runtime_gates`` for why items are marked rather than ignored.
    """
    apply_runtime_gates(items)


# ─── Session-scoped: resolve the nalar binary once ──────────────────────────


def _resolve_nalar_bin() -> Path:
    """Find the nalar binary in standard locations.

    Same resolution order as ``tests/functional/conftest.py``:
      1. ``$NALAR_BIN`` env var (used by CI)
      2. ``./zig-out/bin/nalar`` (after ``zig build install:linux:system``)
      3. ``./zig-out/bin/nalarcore-linux-x86_64``
      4. ``./zig-out/bin/nalarcore-macos-aarch64``
      5. ``./zig-out/bin/nalarcore-macos-x86_64``
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


# ─── Function-scoped: a fresh UI harness per test ──────────────────────────


@pytest.fixture
def ui_harness(default_nalar_bin: Path) -> Iterator[UIHarness]:
    """Function-scoped: a fresh nalar + Vite per test, isolated tmpdir HOME.

    The ``try/finally`` ensures teardown runs even when the test
    asserts-fail mid-execution. The harness's teardown itself calls
    ``is_safe_tmp`` and refuses to rmtree an unsafe path.
    """
    h = UIHarness.boot(default_nalar_bin)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except FunctionalHarnessError as e:
            # If teardown raises (because the path failed safety
            # validation), report it but don't shadow the test's
            # actual assertion failure.
            pytest.fail(f"ui_harness teardown refused: {e}", pytrace=False)


# ─── Session-scoped: a single Playwright Chromium browser ───────────────────


@pytest.fixture(scope="session")
def browser(default_nalar_bin: Path):  # noqa: ARG001 — implicit dep so we skip if no nalar
    """Session-scoped Playwright Chromium browser.

    Reused across tests for boot speed (~2s amortised). Each test
    gets its own ``browser_context`` (see the ``page`` fixture below)
    so cookies, cache, and IndexedDB don't bleed between tests.

    Skips the test session if Playwright isn't installed or the
    Chromium binary isn't available. See README.md for the one-time
    setup: ``pip install playwright && playwright install chromium``.
    """
    playwright = pytest.importorskip("playwright")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("playwright Python package not installed")

    with sync_playwright() as p:
        try:
            browser_instance = p.chromium.launch(headless=True)
        except Exception as e:
            msg = str(e).lower()
            if "executable" in msg or "chromium" in msg or "browser" in msg:
                pytest.skip(
                    f"Playwright Chromium not installed: {e}. "
                    f"Run `playwright install chromium` first."
                )
            raise
        try:
            yield browser_instance
        finally:
            browser_instance.close()


# ─── Function-scoped: a fresh page per test ────────────────────────────────


@pytest.fixture
def page(browser, request: pytest.FixtureRequest, tmp_path_factory):
    """Function-scoped: a fresh browser context + page per test.

    Each test gets a NEW ``browser.new_context()`` so cookies, cache,
    and IndexedDB are isolated. The page's viewport is set to a
    realistic desktop size (1280x800).

    Auto-records a screenshot on test failure to
    ``tests/functional_ui/artifacts/<test_name>/<timestamp>.png``.
    Screenshots are a debugging aid — they survive the test run.
    """
    context = browser.new_context(viewport={"width": 1280, "height": 800})
    page_instance = context.new_page()
    try:
        yield page_instance
    finally:
        # Auto-screenshot on failure. We hook into the request's
        # ``_outcome`` to detect a failed test and capture the page
        # state at that moment. Skipped for passes (no value).
        outcome = getattr(request, "_outcome", None)
        if outcome is not None and outcome.errors:
            # Save to the artifacts dir under the repo. We don't
            # use the harness's tmpdir here because it's rmtree'd
            # on teardown — artifacts must survive the run.
            artifacts_root = Path(__file__).parent / "artifacts"
            artifacts_root.mkdir(parents=True, exist_ok=True)
            test_dir = artifacts_root / request.node.name
            test_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
            screenshot_path = test_dir / f"{timestamp}.png"
            try:
                page_instance.screenshot(path=str(screenshot_path), full_page=True)
            except Exception:
                # Never let the screenshot failure mask the real
                # test failure. Swallow.
                pass
        context.close()


# ─── Function-scoped: a per-test artifacts dir (test-controlled) ───────────


@pytest.fixture
def artifacts_dir(request: pytest.FixtureRequest) -> Path:
    """Function-scoped: ``tests/functional_ui/artifacts/<test_name>/``.

    Tests can use this to write intermediate files (downloaded
    artifacts, CSV exports, etc.) without polluting the harness's
    tmpdir. Survives the test run by design — these are debug aids.
    """
    artifacts_root = Path(__file__).parent / "artifacts"
    test_dir = artifacts_root / request.node.name
    test_dir.mkdir(parents=True, exist_ok=True)
    return test_dir


# ─── Optional: pyvirtualdisplay for X11-less CI environments ────────────────
#
# If running headless Chromium on a CI runner without an X server,
# Playwright's headless mode is enough. But on Linux CI without a
# display server (and headless=False accidentally set), pyvirtualdisplay
# can spin up Xvfb on the fly. This is a no-op fixture — included as
# a hook for future tests that need a real display.


@pytest.fixture(scope="session")
def virtual_display():
    """No-op fixture. Reserved for future tests that need Xvfb."""
    return None