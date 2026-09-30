"""Safety tests for the FunctionalHarness.

These tests run WITHOUT a nalar binary. They assert the safety
invariants in harness.py — the guards that prevent the harness from
ever deleting the developer's real $HOME.

If any of these tests fail, the harness has a P0 bug. Do not merge
until they pass.
"""

from __future__ import annotations

import os
import re
import shutil
import tempfile
from pathlib import Path

import pytest

# The module object, not just its names: the 8.3 tests below swap
# ALLOWED_TMP_PREFIXES out at runtime, which needs the module binding.
import harness
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


# ─── allow-list prefix spelling: the windows-2022 8.3 bug ──────────────────
#
# `is_safe_tmp` compares the CANDIDATE through `os.path.realpath` against
# the allow-list PREFIXES raw. On Windows realpath also expands 8.3 short
# names, so a candidate under a runner's `%TEMP%` of
# `C:\Users\RUNNER~1\AppData\Local\Temp` canonicalises to
# `C:\Users\runneradmin\...` and stops matching the raw prefix built from
# the same `%TEMP%`. On the windows-2022 cell that rejected the harness's
# OWN tempdir on every test: 548 errors, all one line.
#
# The bug is not "Windows" — it is "the two sides are spelled differently".
# A symlink alias reproduces that on any host, which is what the two tests
# below use, so the regression is guarded on Linux too.


@pytest.fixture
def tmpdir_alias(monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point ALLOWED_TMP_PREFIXES at a SYMLINK ALIAS of the real tmpdir.

    Yields the alias path; removes it on teardown.

    A fixture rather than a helper because the alias is a real filesystem
    entry: a helper that returned it and relied on the caller to unlink
    leaks a symlink into the system tmpdir every time a test fails, which
    is the kind of litter that outlives the branch that made it.

    The alias is deliberately NOT named ``nalar-func-*`` so it cannot
    satisfy the namespace check on its own and mask a broken comparison.
    """
    real_root = Path(tempfile.gettempdir()).resolve()
    alias = real_root / f"tmpalias-{os.getpid()}"
    if alias.is_symlink() or alias.exists():
        alias.unlink()
    try:
        alias.symlink_to(real_root, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("this host cannot create a symlink")
    monkeypatch.setattr(harness, "ALLOWED_TMP_PREFIXES", (str(alias) + os.sep,))
    try:
        yield alias
    finally:
        alias.unlink(missing_ok=True)


def test_allowlist_prefix_spelled_differently_still_matches(
    tmpdir_alias: Path,
) -> None:
    """A prefix naming the tmpdir another way must still match.

    This is the regression guard for the windows-2022 failure: 548 errors
    whose message printed a candidate and a prefix that visibly matched,
    because neither printed string was the one compared.
    """
    real_root = Path(tempfile.gettempdir()).resolve()
    real_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))
    try:
        # The precondition that gives this test teeth: a RAW startswith
        # FAILS here, so only canonicalisation of both sides can rescue
        # it. Remove `_canonical_prefix` and this assertion flips.
        assert not str(real_dir).startswith(str(tmpdir_alias) + os.sep)
        assert str(real_dir).startswith(str(real_root) + os.sep)
        assert is_safe_tmp(str(real_dir), "/home/someone-else") is True
    finally:
        shutil.rmtree(real_dir, ignore_errors=True)


def test_canonicalising_both_sides_does_not_widen_the_allowlist(
    tmpdir_alias: Path,  # noqa: ARG001 — the monkeypatch IS the point
) -> None:
    """The counterpart: the fix must not accept what it previously rejected.

    Canonicalising the allow-list is only safe because the prefix still
    resolves to a tmpdir. A ``nalar-func-`` path somewhere else entirely
    has to stay rejected, or the guard would rmtree wherever it is told.

    The path need not exist — ``is_safe_tmp`` is a spelling + allow-list
    check, not a stat. The first draft of this test built its "outside"
    path with ``tempfile.mkdtemp``, which puts the directory INSIDE the
    allow-listed tmpdir; it then asserted a rejection that only held
    because the namespace substring was missing, not because of the
    directory at all. A test that passes for the wrong reason is worse
    than no test, so the path here is absolute, carries the substring,
    and is under a directory nothing allow-lists.
    """
    outside = os.path.join(os.sep, "not-a-tmpdir-at-all", REQUIRED_TMP_SUBSTR + "probe")
    assert os.path.isabs(outside)
    assert REQUIRED_TMP_SUBSTR in outside
    assert is_safe_tmp(outside, "/home/someone-else") is False


def test_allowlist_prefix_matches_regardless_of_case() -> None:
    """A Windows path comparison is case-insensitive; this now is too.

    ``normcase`` is the half of ``_canonical`` the 8.3 bug did not need.
    It is asserted here so nobody "simplifies" it away as dead code on a
    POSIX box, where normcase is a no-op. Only the WINDOWS branch can
    vary the case, so on POSIX this is a tautology by construction —
    stated plainly rather than dressed up as coverage.
    """
    if os.name != "nt":
        pytest.skip("normcase is a no-op off Windows; covered by the win32 cell")
    shouted = tempfile.gettempdir().upper() + os.sep + REQUIRED_TMP_SUBSTR + "case-probe"
    assert is_safe_tmp(shouted, "/home/someone-else") is True


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


# ─── XDG isolation must not be platform-gated ─────────────────────────────
#
# `getDefaultConfigDir` (Config.zig) resolves $XDG_CONFIG_HOME/nalar
# BEFORE $HOME/.config/nalar on Linux, and the same XDG-first rule is
# hand-duplicated for memories/, skills/ and hooks/. The harness used to
# shadow the XDG vars into the child env only under `if os.name == "nt"`,
# so on the GitHub Actions ubuntu runner (which exports
# XDG_CONFIG_HOME=/home/runner/.config) the nalar child wrote config.json
# into the runner's real home while every test read <temp_dir>/.config.
# That surfaced as 31 failures in run 36582964531 — all on-disk
# assertions reading a file the server had never written — and it made
# results order-dependent, because all harness instances in the job
# shared that one file.
#
# These guards fail if anyone re-gates the XDG shadowing behind a
# platform check. The parent `os.environ` is deliberately NOT asserted
# here: shadowing it on Linux/mac is explicitly out of scope.


_XDG_ENV_ASSIGNMENT = re.compile(r'^\s*env\["XDG_[A-Z_]+"\]\s*=')

# boot() is a method, so its body sits at 8 spaces. Anything deeper is
# nested inside an `if` — which is exactly the bug.
_CHILD_ENV_BODY_INDENT = " " * 8


def _assert_xdg_shadowing_is_ungated(filename: str) -> None:
    """Every `env["XDG_*"] = ...` must sit at method/function body level,
    not nested inside `if os.name == "nt":`."""
    path = Path(__file__).parent / filename
    offenders: list[str] = []
    found = 0
    for lineno, line in enumerate(
        path.read_text().splitlines(), start=1
    ):
        if not _XDG_ENV_ASSIGNMENT.match(line):
            continue
        found += 1
        indent = line[: len(line) - len(line.lstrip())]
        if indent != _CHILD_ENV_BODY_INDENT:
            offenders.append(
                f"{filename}:{lineno} is nested at indent {len(indent)} "
                f"(inside a platform gate?)"
            )
    assert found > 0, (
        f"{filename}: no `env[\"XDG_*\"] = ...` assignment found. If the "
        f"XDG shadowing was renamed or moved, update this guard."
    )
    assert not offenders, (
        "XDG shadowing must apply on every platform, not just Windows:\n  "
        + "\n  ".join(offenders)
        + "\n  On Linux getDefaultConfigDir prefers $XDG_CONFIG_HOME over "
        "$HOME/.config, so a gated shadowing makes the child write into the "
        "real home while tests read the tempdir (see run 36582964531)."
    )


def test_harness_xdg_shadowing_is_not_platform_gated() -> None:
    """FunctionalHarness.boot must shadow XDG for the child on all platforms."""
    _assert_xdg_shadowing_is_ungated("harness.py")


@pytest.mark.parametrize(
    "filename",
    ["config_simplify_test.py", "config_tools_test.py"],
)
def test_private_preboot_fixtures_also_shadow_xdg(filename: str) -> None:
    """These two files re-implement the spawn instead of calling boot().

    They carry their own copy of the child-env block, so the harness fix
    does not cover them — they regressed in lockstep and must be guarded
    separately.
    """
    _assert_xdg_shadowing_is_ungated(filename)
