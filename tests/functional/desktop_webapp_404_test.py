"""Functional tests for the desktop `--static-dir` 404 bug.

Task: task_1789144501374_7 — "first time open desktop app work but, after a
while use and close and open again its 404".

Reported symptoms were a blank window showing a bare `404 Not Found` page.

Root cause (reproduced live): the desktop extracted its embedded webapp into
a PER-PID temp dir, spawned a DETACHED pabrik with `--static-dir <that dir>`,
and then deleted the dir when the window closed (`extraction.cleanup`). The
daemon outlives the desktop by design, so from then on it served nothing:
`GET /health` was still 200 (an API route, independent of the static dir)
while `GET /` was `404 Not Found`. The next desktop launch probed `/health`,
saw 200, attached to that daemon, and opened the webview onto the 404.

These tests pin the wire behaviour that made the bug invisible to a
health-only check, using a real pabrik process against a real --static-dir:

  Test 1 — `--static-dir` serves the app; deleting the dir behind pabrik's
           back turns `GET /` into 404 while `/health` stays 200 (this IS
           the bug), and restoring the dir makes `/` serve again.
  Test 2 — the fix's invariant: a PERSISTENT static dir survives a pabrik
           restart, so close-and-reopen keeps serving the app.
  Test 3 — a pabrik started with NO `--static-dir` has the same shape
           (health 200, `/` 404) — the shape the desktop must refuse to
           attach to.

The desktop-side counterpart (never attach to a server that 404s `/`) is
locked down in `src/apps/desktop_app/attach_test.zig`; the persistence of
the webapp dir itself in `src/apps/desktop_app/extraction_test.zig`.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from harness import FunctionalHarness

HTML = "<!DOCTYPE html><html><body>pabrik app shell</body></html>"


def _text(resp) -> str:
    """Decode a harness Response body (bytes) for substring asserts."""
    return resp.body.decode("utf-8", errors="replace")


def _make_webapp(root: Path) -> Path:
    """Minimal stand-in for the extracted webapp dir."""
    (root / "assets").mkdir(parents=True, exist_ok=True)
    (root / "index.html").write_text(HTML, encoding="utf-8")
    # The extracted tree always contains a marker file next to the assets.
    (root / ".pabrik-webapp-complete").write_text("test-hash", encoding="utf-8")
    (root / "assets" / "app.js").write_text("console.log('pabrik');", encoding="utf-8")
    return root


@pytest.fixture
def webapp_dir(tmp_path: Path) -> Path:
    return _make_webapp(tmp_path / "desktop-webapp")


def test_static_dir_404s_when_the_dir_is_deleted_health_stays_200(
    webapp_dir: Path,
    default_pabrik_bin: Path,
) -> None:
    """The bug, at the wire level.

    A daemon whose --static-dir was removed keeps answering /health with
    200 while answering / with 404. That asymmetry is why the old
    health-only attach probe let the desktop open a 404 window.
    """
    h = FunctionalHarness.boot(
        default_pabrik_bin,
        stub_llm_profile=True,
        extra_args=("--static-dir", str(webapp_dir)),
    )
    try:
        # 1. Healthy and serving the app.
        r = h.http("GET", "/")
        assert r.status == 200
        assert "pabrik app shell" in _text(r)
        assert h.http("GET", "/index.html").status == 200
        assert h.http("GET", "/assets/app.js").status == 200
        assert h.http("GET", "/health").status == 200

        # 2. Delete the directory out from under the running daemon. This is
        #    exactly what the old desktop did at window close.
        shutil.rmtree(webapp_dir)

        # 3. The app is gone...
        r = h.http("GET", "/", expect=(404,))
        assert r.status == 404
        assert "Not Found" in _text(r)
        assert h.http("GET", "/index.html", expect=(404,)).status == 404

        # ...but health still says everything is fine. This is the trap.
        assert h.http("GET", "/health").status == 200

        # 4. Restoring the dir restores the app (proving the daemon itself
        #    never died — only its static dir went away).
        _make_webapp(webapp_dir)
        r = h.http("GET", "/")
        assert r.status == 200
        assert "pabrik app shell" in _text(r)
    finally:
        h.teardown()


def test_persistent_static_dir_survives_a_restart(
    webapp_dir: Path,
    default_pabrik_bin: Path,
) -> None:
    """The fix's invariant: reopening the app keeps serving it.

    Models two desktop launches against the same persistent webapp dir —
    the dir is never deleted, so the second launch's webview gets the app
    instead of `404 Not Found`.
    """
    first = FunctionalHarness.boot(
        default_pabrik_bin,
        stub_llm_profile=True,
        extra_args=("--static-dir", str(webapp_dir)),
    )
    try:
        assert h_serves_app(first) is True
    finally:
        first.teardown()

    # Close/reopen: the dir must still be there, untouched.
    assert (webapp_dir / "index.html").exists()

    second = FunctionalHarness.boot(
        default_pabrik_bin,
        stub_llm_profile=True,
        extra_args=("--static-dir", str(webapp_dir)),
    )
    try:
        assert h_serves_app(second) is True
    finally:
        second.teardown()


def test_without_static_dir_health_is_200_but_root_is_404(
    default_pabrik_bin: Path,
) -> None:
    """A pabrik with no --static-dir looks identical to the broken daemon.

    Nothing about `/health` distinguishes it, so an attach decision based
    on health alone cannot tell a usable server from a useless one.
    """
    h = FunctionalHarness.boot(default_pabrik_bin, stub_llm_profile=True)
    try:
        assert h.http("GET", "/health").status == 200
        r = h.http("GET", "/", expect=(404,))
        assert r.status == 404
        assert "Not Found" in _text(r)
    finally:
        h.teardown()


def h_serves_app(h: FunctionalHarness) -> bool:
    """True when `/` returns the SPA shell (the desktop's readiness test)."""
    r = h.http("GET", "/", expect=(200, 404))
    return r.status == 200 and "<" in _text(r)
