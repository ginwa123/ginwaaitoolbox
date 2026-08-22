"""Safety tests for the UIHarness.

These tests run WITHOUT a nalar binary or a Vite dev server. They
assert the safety invariants in ``ui_harness.py`` — the guards that
prevent the harness from ever deleting the developer's real $HOME,
on macOS, Linux, AND Windows.

If any of these tests fail, the harness has a P0 bug. Do not merge
until they pass.

The tests are deliberately cross-platform: they use ``os.path.normpath``
to construct the expected paths, so the same test passes on every OS.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

from harness import (
    ALLOWED_TMP_PREFIXES,
    REQUIRED_TMP_SUBSTR,
    is_safe_tmp,
)


# ─── Cross-platform is_safe_tmp coverage ─────────────────────────────────────


def test_is_safe_tmp_accepts_fresh_mkdtemp_on_this_os() -> None:
    """A fresh mkdtemp on the current OS is always safe.

    This is the regression test for the Windows bug: before the
    2026-08-21 fix, ``ALLOWED_TMP_PREFIXES`` was hardcoded to POSIX
    paths plus ``tempfile.gettempdir() + "/"`` — which on Windows
    produced a mixed-separator prefix (e.g. ``C:\\Users\\u\\AppData\\Local\\Temp/``)
    that never matched ``realpath``'s backslash output. The fix is
    OS-aware: on Windows the prefix is normalised to native backslashes.
    """
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        # The harness's own validation must accept the OS's native
        # tempdir location. ``orig_home`` is a non-existent path that
        # won't accidentally match ``realpath``.
        assert is_safe_tmp(td, "/this/home/does/not/exist") is True, (
            f"is_safe_tmp rejected a freshly-created tempdir on {sys.platform}. "
            f"This is a Windows path-separator regression — see harness.py "
            f"ALLOWED_TMP_PREFIXES for the OS-aware fix."
        )


def test_is_safe_tmp_accepts_pathlib_path_on_this_os() -> None:
    """PathLike inputs work on the current OS (regression for Windows)."""
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        p = Path(td)
        assert is_safe_tmp(p, "/home/nonexistent") is True


def test_is_safe_tmp_rejects_paths_outside_tempdir() -> None:
    """Paths outside any allowed tmpdir prefix are always rejected."""
    # Use a path that exists but is NOT under any tempdir.
    # /etc/passwd is a standard POSIX path that exists on Linux/macOS.
    # On Windows, fall back to a path that definitely doesn't qualify.
    if sys.platform == "win32":
        bogus = "C:\\Windows\\System32\\drivers\\etc\\hosts"
    else:
        bogus = "/etc/passwd"
    if os.path.exists(bogus):
        assert is_safe_tmp(bogus, "/home/nonexistent") is False


def test_is_safe_tmp_rejects_real_home() -> None:
    """The real $HOME is never safe, even with the required substring."""
    real_home = os.path.expanduser("~")
    assert is_safe_tmp(real_home, real_home) is False, (
        f"is_safe_tmp accepted the real $HOME ({real_home}) — this is a P0 bug"
    )


def test_is_safe_tmp_rejects_relative_path() -> None:
    """Relative paths are never safe (could resolve anywhere)."""
    assert is_safe_tmp(f"./{REQUIRED_TMP_SUBSTR}xyz", "/home/x") is False
    assert is_safe_tmp(REQUIRED_TMP_SUBSTR + "xyz", "/home/x") is False


def test_is_safe_tmp_rejects_empty_path() -> None:
    """Empty path is never safe."""
    assert is_safe_tmp("", "/home/x") is False
    assert is_safe_tmp("", "") is False


# ─── ALLOWED_TMP_PREFIXES cross-platform sanity ──────────────────────────────


def test_allowed_tmp_prefixes_match_realpath_on_this_os() -> None:
    """The allowed prefixes must match ``realpath`` output on the current OS.

    On macOS: prefixes are like ``/tmp/`` and ``/var/folders/``.
    On Linux: prefixes are like ``/tmp/``.
    On Windows: prefixes are like ``C:\\Users\\u\\AppData\\Local\\Temp\\``.
    """
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        real = os.path.realpath(td)
        matched = any(
            real.startswith(prefix) for prefix in ALLOWED_TMP_PREFIXES
        )
        assert matched, (
            f"realpath({td!r}) = {real!r} did not match any of "
            f"ALLOWED_TMP_PREFIXES = {ALLOWED_TMP_PREFIXES!r} on {sys.platform}.\n"
            f"This means the harness would leak the tempdir on "
            f"teardown instead of cleaning it up."
        )


def test_tempfile_gettempdir_is_in_allowed_prefixes() -> None:
    """``tempfile.gettempdir()`` (OS-default temp) must be an allowed prefix.

    This is the test that catches the Windows regression: the previous
    implementation had ``tempfile.gettempdir() + "/"`` which on Windows
    produced a mixed-separator prefix that never matched ``realpath``.
    """
    gettempdir = tempfile.gettempdir()
    # Build the expected prefix the same way the harness does.
    if os.name == "nt":
        expected_prefix = gettempdir.rstrip("\\") + "\\"
    else:
        expected_prefix = gettempdir + "/"
    assert any(
        prefix == expected_prefix for prefix in ALLOWED_TMP_PREFIXES
    ), (
        f"tempfile.gettempdir() = {gettempdir!r} on {sys.platform} is not "
        f"in ALLOWED_TMP_PREFIXES = {ALLOWED_TMP_PREFIXES!r}. "
        f"Expected prefix {expected_prefix!r} to be present."
    )


# ─── npm binary resolution (cross-platform) ──────────────────────────────────


def test_npm_resolves_on_this_os() -> None:
    """``shutil.which('npm')`` (or ``npm.cmd`` on Windows) finds a binary.

    The UI harness uses this resolution so vite can be spawned on
    Windows where ``npm`` is a batch script. If npm is not installed
    on the test host, this test is skipped (it documents the
    expected behaviour rather than failing the suite).
    """
    import shutil

    npm_bin = shutil.which("npm") or shutil.which("npm.cmd")
    if npm_bin is None:
        pytest.skip("npm not installed on this host")
    assert os.path.exists(npm_bin), f"shutil.which('npm') returned {npm_bin!r} but it doesn't exist"
    # On POSIX, npm must be executable. On Windows, .cmd files don't
    # need the executable bit.
    if os.name != "nt":
        assert os.access(npm_bin, os.X_OK), f"npm binary {npm_bin!r} is not executable on POSIX"


# ─── vite port range sanity ─────────────────────────────────────────────────


def test_vite_port_range_avoids_default_5173() -> None:
    """The UI harness's vite port range excludes Vite's default 5173.

    This avoids clashing with a developer's running ``npm run dev``
    session. The convention is captured in the harness constants.
    """
    from ui_harness import VITE_PORT_START, VITE_PORT_END

    assert 5173 < VITE_PORT_START, (
        f"VITE_PORT_START ({VITE_PORT_START}) must be > 5173 to avoid "
        f"clashing with developer dev-runs"
    )
    assert VITE_PORT_END > VITE_PORT_START, "VITE_PORT_END must be > VITE_PORT_START"


def test_vite_port_range_avoids_backend_port_8081() -> None:
    """The vite port range must not include 8081 (the dev backend port)."""
    from ui_harness import VITE_PORT_START, VITE_PORT_END

    assert not (VITE_PORT_START <= 8081 <= VITE_PORT_END), (
        f"vite port range [{VITE_PORT_START}, {VITE_PORT_END}] must not include 8081"
    )
