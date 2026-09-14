"""Functional tests for the stable `--static-dir` alias (`<base>/current`).

The desktop materialises its embedded webapp into content-addressed
`<base>/<hash>` dirs but hands the daemon a single stable symlink
`<base>/current -> <hash>`, so `ps` always shows one path no matter how
many versioned dirs sit behind the link.

Wire behaviour pinned here (real nalar, real --static-dir, isolated HOME):

  Test 1 — serving THROUGH the stable symlink works: boot with
           `--static-dir <base>/current`, `GET /` serves the app.
  Test 2 — flipping the link (an upgrade) never 404s the running daemon:
           it stays pinned to its boot version (the server canonicalizes
           via realPath at startup), while a fresh boot on the same stable
           string picks up the new version.
"""

from __future__ import annotations

import os
from pathlib import Path

from harness import FunctionalHarness


def _text(resp) -> str:
    """Decode a harness Response body (bytes) for substring asserts."""
    return resp.body.decode("utf-8", errors="replace")


def _make_version(root: Path, body: str) -> Path:
    """Minimal stand-in for one versioned webapp dir."""
    (root / "assets").mkdir(parents=True, exist_ok=True)
    (root / "index.html").write_text(
        f"<!DOCTYPE html><html><body>{body}</body></html>", encoding="utf-8"
    )
    (root / "assets" / "app.js").write_text("console.log('nalar');", encoding="utf-8")
    return root


def _point_link(link: Path, target: Path) -> None:
    """Atomically point `link` at `target` (same dance as extraction.zig)."""
    tmp = link.with_name(f"{link.name}.tmp-{os.getpid()}")
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(target.name)
    os.replace(tmp, link)


def test_stable_symlink_serves_the_app(
    default_nalar_bin: Path, tmp_path: Path
) -> None:
    """Booting with `--static-dir <base>/current` serves the app."""
    base = tmp_path / "desktop-webapp"
    base.mkdir()
    v1 = _make_version(base / "hash-v1", "stable shell v1")
    stable = base / "current"
    stable.symlink_to(v1.name)

    h = FunctionalHarness.boot(
        default_nalar_bin,
        stub_llm_profile=True,
        extra_args=("--static-dir", str(stable)),
    )
    try:
        r = h.http("GET", "/")
        assert r.status == 200
        assert "stable shell v1" in _text(r)
        assert h.http("GET", "/health").status == 200
    finally:
        h.teardown()


def test_flipping_the_stable_link_never_404s_the_running_daemon(
    default_nalar_bin: Path, tmp_path: Path
) -> None:
    """An upgrade flip keeps the old daemon on its boot version (no 404
    window), while a fresh boot on the same stable string gets the new one.
    """
    base = tmp_path / "desktop-webapp"
    base.mkdir()
    v1 = _make_version(base / "hash-v1", "stable shell v1")
    v2 = _make_version(base / "hash-v2", "stable shell v2")
    stable = base / "current"
    stable.symlink_to(v1.name)

    first = FunctionalHarness.boot(
        default_nalar_bin,
        stub_llm_profile=True,
        extra_args=("--static-dir", str(stable)),
    )
    try:
        assert "stable shell v1" in _text(first.http("GET", "/"))

        # Upgrade: flip the stable link. The running daemon stays pinned
        # to its boot version — critically, it must NOT 404 in between.
        _point_link(stable, v2)
        r = first.http("GET", "/")
        assert r.status == 200
        assert "stable shell v1" in _text(r)

        # A fresh boot on the SAME stable string picks up the new version.
        second = FunctionalHarness.boot(
            default_nalar_bin,
            stub_llm_profile=True,
            extra_args=("--static-dir", str(stable)),
        )
        try:
            r2 = second.http("GET", "/")
            assert r2.status == 200
            assert "stable shell v2" in _text(r2)
        finally:
            second.teardown()
    finally:
        first.teardown()
