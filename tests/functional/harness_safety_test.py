"""Safety tests for the FunctionalHarness.

These tests run WITHOUT a nalar binary. They assert the safety
invariants in harness.py — the guards that prevent the harness from
ever deleting the developer's real $HOME.

If any of these tests fail, the harness has a P0 bug. Do not merge
until they pass.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest

from harness import (
    ALLOWED_TMP_PREFIXES,
    REQUIRED_TMP_SUBSTR,
    FunctionalHarness,
    FunctionalHarnessError,
    is_safe_tmp,
)


# ─── is_safe_tmp ───────────────────────────────────────────────────────────


def test_is_safe_tmp_rejects_empty_string() -> None:
    """Empty path is never safe."""
    assert is_safe_tmp("", "/home/alice") is False
    assert is_safe_tmp("", "") is False


def test_is_safe_tmp_rejects_non_absolute_path() -> None:
    """Relative paths are never safe (could resolve anywhere)."""
    assert is_safe_tmp("nalar-func-xxx", "/home/alice") is False
    assert is_safe_tmp("./tmp/nalar-func-xxx", "/home/alice") is False


def test_is_safe_tmp_rejects_real_home() -> None:
    """The real $HOME is never safe, even with the required substring."""
    fake_home = "/home/alice"
    # Even if the path contains the substring, the validator rejects
    # paths that resolve to the real home.
    assert is_safe_tmp(fake_home, fake_home) is False



def test_is_safe_tmp_rejects_path_without_substring() -> None:
    """A tmpdir without the required namespace substring is rejected."""
    with tempfile.TemporaryDirectory(prefix="not-ours-") as td:
        assert is_safe_tmp(td, "/never") is False


def test_is_safe_tmp_accepts_valid_tmpdir() -> None:
    """A fresh mkdtemp with the required prefix is safe."""
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        fake_home = "/home/nonexistent-for-this-test"
        assert is_safe_tmp(td, fake_home) is True


def test_is_safe_tmp_accepts_pathlib_path() -> None:
    """PathLike inputs work too (not just str)."""
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        p = Path(td)
        assert is_safe_tmp(p, "/home/nonexistent") is True


def test_is_safe_tmp_resolves_symlinks_in_path() -> None:
    """A symlink whose target is the real home is rejected via realpath."""
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        fake_home = "/home/alice"  # doesn't actually exist
        # Create a symlink inside the tempdir that points at fake_home.
        link = Path(td) / "sneaky"
        try:
            link.symlink_to(fake_home)
        except OSError:
            pytest.skip("symlink not supported on this platform")
        # Without resolving, the path IS in /tmp and contains the
        # substring — but its realpath is /home/alice which is NOT
        # in the allow-list, so it must be rejected.
        assert is_safe_tmp(str(link), fake_home) is False


# ─── teardown safety net ──────────────────────────────────────────────────


#: Every env var teardown() restores (harness.py step 1). Tests that
#: call teardown() on a directly-constructed (never-booted) instance
#: must snapshot/restore these: teardown unconditionally writes
#: orig_home into the parent env (and pops the Windows/XDG keys when
#: the instance carries empty originals), so without a restore the
#: leaked values poison every LATER test in the session — e.g.
#: smoke_boot's orig_home assertion, which passed on POSIX only
#: because the leak made both sides of its comparison equal.
_TEARDOWN_ENV_KEYS = (
    "HOME",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
)


def _snapshot_env() -> dict[str, str | None]:
    """Snapshot teardown-touched vars; None means absent."""
    return {k: os.environ.get(k) for k in _TEARDOWN_ENV_KEYS}


def _restore_env(saved: dict[str, str | None]) -> None:
    """Restore a _snapshot_env mapping (removing vars that were absent)."""
    for k, v in saved.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v


def test_teardown_refuses_unsafe_temp_dir() -> None:
    """Constructing a harness with an unsafe temp_dir makes teardown raise.

    This is the ultimate safety net: even if every other guard fails,
    teardown must not delete a path that fails is_safe_tmp.
    """
    from harness import FunctionalHarness as _FH

    # Build a harness instance WITHOUT calling boot (which creates its
    # own tempdir). Use a clearly-unsafe temp_dir: an absolute path
    # that is neither under the tmp prefix nor namespaced — and that
    # EXISTS, so the post-teardown "still exists" assertion is real.
    if os.name == "nt":
        system_root = os.environ.get("SystemRoot", r"C:\Windows")
        unsafe_dir = Path(system_root) / "System32" / "drivers" / "etc" / "hosts"
        if not unsafe_dir.exists():
            pytest.skip(f"expected system file missing: {unsafe_dir}")
        unsafe_home = os.environ.get("USERPROFILE", str(unsafe_dir.parent))
    else:
        unsafe_dir = Path("/etc/passwd")
        unsafe_home = "/home/alice"
    h = _FH(
        port=9999,
        nalar_bin=Path("/nonexistent"),
        temp_dir=unsafe_dir,  # unsafe: not in tmp, no substring
        orig_home=unsafe_home,
        log_path=Path("/dev/null"),
        pid=None,
    )
    # teardown() writes orig_home into the parent env BEFORE the safety
    # check raises — snapshot/restore so the probe values don't leak
    # into later tests in this session (see _TEARDOWN_ENV_KEYS).
    saved_env = _snapshot_env()
    try:
        with pytest.raises(FunctionalHarnessError) as exc:
            h.teardown()
    finally:
        _restore_env(saved_env)
    assert "REFUSING to rmtree" in str(exc.value)
    # And the file MUST still exist.
    assert os.path.exists(unsafe_dir)


def test_teardown_with_safe_temp_dir_runs_rmtree(tmp_path: Path) -> None:
    """A safe temp_dir is actually rmtree'd by teardown."""
    # Use a real sandbox under tmp_path (pytest's tmp_path is itself
    # a tmpdir, but not necessarily matching our safety rules — so
    # we create a subdir that matches).
    safe = tmp_path / "nalar-func-pytest"
    safe.mkdir()
    inner = safe / "marker.txt"
    inner.write_text("exists")
    h = FunctionalHarness(
        port=9999,
        nalar_bin=Path("/nonexistent"),
        temp_dir=safe,
        orig_home="/home/nonexistent",
        log_path=Path("/dev/null"),
        pid=None,
    )
    # teardown should run without raising because:
    # - pytest's tmp_path is on /tmp/... on Linux (or /var/folders/... on macOS)
    # - safe contains the substring
    # - safe != orig_home
    # teardown() leaves orig_home in the parent env by design (step 1
    # restores it for post-test code). This directly-constructed probe
    # never booted, so restore afterwards — otherwise "/home/nonexistent"
    # leaks into later tests in this session (see _TEARDOWN_ENV_KEYS).
    saved_env = _snapshot_env()
    try:
        h.teardown()
    finally:
        _restore_env(saved_env)
    assert not safe.exists()


# ─── constants are sane ───────────────────────────────────────────────────


def test_allowed_tmp_prefixes_contains_gettempdir() -> None:
    """The allow-list must include tempfile.gettempdir() (defensive)."""
    if os.name == "nt":
        # Windows prefixes use native backslashes (see harness.py).
        assert (tempfile.gettempdir().rstrip("\\") + "\\") in ALLOWED_TMP_PREFIXES
    else:
        assert (tempfile.gettempdir() + "/") in ALLOWED_TMP_PREFIXES


def test_required_substring_is_namespaced() -> None:
    """REQUIRED_TMP_SUBSTR must end with a separator-like chunk so
    a path like /tmp/nalar-func / etc. cannot satisfy a substring
    check that includes a separator."""
    assert REQUIRED_TMP_SUBSTR.endswith("-")


def test_orig_home_must_exist_for_boot(monkeypatch: pytest.MonkeyPatch) -> None:
    """boot() refuses if no home can be determined (no path to validate against)."""
    # boot() resolves orig_home as HOME → USERPROFILE (Windows) →
    # Path.home(). Remove both env vars AND break Path.home so every
    # layer fails deterministically on all platforms.
    monkeypatch.delenv("HOME", raising=False)
    monkeypatch.delenv("USERPROFILE", raising=False)
    monkeypatch.setattr(
        Path,
        "home",
        classmethod(lambda cls: (_ for _ in ()).throw(OSError("no home"))),
    )
    with pytest.raises(FunctionalHarnessError) as exc:
        FunctionalHarness.boot()
    assert "HOME not set" in str(exc.value)


# ─── boot() signature: port default must be None (random), not 8080 ────────


def test_boot_signature_accepts_none_port() -> None:
    """``FunctionalHarness.boot(port=None)`` is the documented default.

    Regression guard for the bug where ``port: int = DEFAULT_PORT``
    (=8080) was the default, which then triggered the legacy
    sequential scan even when the caller didn't ask for a port. With
    that signature, a bare ``FunctionalHarness.boot(nalar_bin)`` call
    would always try 8080 first — bypassing the random pool and
    reintroducing the CI pathology the random pool was meant to fix.
    """
    import inspect

    sig = inspect.signature(FunctionalHarness.boot)
    port_param = sig.parameters["port"]
    assert port_param.default is None, (
        f"FunctionalHarness.boot(port=...) default must be None "
        f"(→ random pick), got {port_param.default!r}. With a non-None "
        f"default, callers using the documented `boot(nalar_bin)` shape "
        f"would silently get the legacy sequential scan from that port."
    )
