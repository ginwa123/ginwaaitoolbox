"""Functional wire tests for the crash-class regressions in
GET /api/git/pr/status.

Two production failures lived in the same 30 lines of
`src/http_handlers/git_pr_status.zig`:

  1. `Child.wait` -> `childCleanupPosix` -> `Io.Threaded.closeFd` on a
     pipe the caller still owned. Zig 0.16 turns EBADF into
     `unreachable` in Debug builds, so one request took the whole
     process down with `thread N panic: reached unreachable code`.
  2. stdout was drained to EOF *before* stderr, so a `gh` that wrote
     more than one 64 KiB pipe buffer to stderr blocked in `write(2)`,
     never closed stdout, and the request (plus its worker thread) hung
     forever.

Neither is observable from a unit test: the bug is in the wire path,
under a real HTTP server, on a worker-pool thread. These tests drive
the actual binary through the harness and assert on process liveness
afterwards.
"""

from __future__ import annotations

import concurrent.futures
import os
import stat
import subprocess
from pathlib import Path

import pytest

from harness import FunctionalHarness


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", *args],
        cwd=str(cwd),
        check=True,
        timeout=30,
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    cwd = tmp_path / "pr-status-crash-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / "a.txt").write_text("hi\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "base")
    return cwd


def _install_fake_gh(
    bindir: Path, body: str, monkeypatch, *, exit_code: int = 0
) -> None:
    """Put an executable `gh` stub at the front of PATH.

    The harness boots the server with the parent's environment, so this
    is what makes the backend's `gh pr view` spawn return canned
    output without touching the network.
    """
    bindir.mkdir(parents=True, exist_ok=True)
    fake_gh = bindir / "gh"
    fake_gh.write_text(body)
    fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])


def test_huge_gh_stderr_does_not_hang_the_request(
    repo: Path, tmp_path: Path, monkeypatch, default_pabrik_bin: Path
) -> None:
    """1 MiB of `gh` stderr must still produce a prompt 502.

    Before the fix the handler drained stdout to EOF first: `gh` filled
    the 64 KiB stderr pipe, blocked in `write(2)`, and never closed
    stdout — so the HTTP request never completed and the worker-pool
    thread handling it was wedged for the life of the process. A later
    1 MiB-vs-64 KiB payload is a perfectly ordinary `gh` error (a big
    hook stack trace, a verbose git warning), so this is not exotic.
    """
    _install_fake_gh(
        tmp_path / "fakebin-bigstderr",
        "#!/bin/sh\n"
        "i=0\n"
        "while [ $i -lt 1024 ]; do\n"
        "  i=$((i+1))\n"
        "  dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\\0' 'E' 1>&2\n"
        "done\n"
        "exit 1\n",
        monkeypatch,
    )

    h2 = FunctionalHarness.boot(default_pabrik_bin)
    try:
        # 30s is well past the backend's 20s gh deadline, and well
        # under "forever" — a regression fails the test instead of
        # hanging the suite.
        body = h2.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": "42"},
            expect=502,
            timeout_s=30.0,
        ).json()
        # The process must still be serving after the failure path.
        assert h2.health(), "server died while draining a large gh stderr"
    finally:
        h2.teardown()
    assert "error" in body, f"got: {body!r}"
    # The captured stderr is trimmed to MAX_FETCH_DETAIL (500 bytes).
    assert "E" in body["error"], f"got: {body!r}"


def test_gh_that_never_exits_is_killed_not_awaited_forever(
    repo: Path, tmp_path: Path, monkeypatch, default_pabrik_bin: Path
) -> None:
    """A `gh` blocked forever must time out, not hold a worker thread.

    The handler has a 20s deadline; the assertion budget is 45s so a
    loaded CI box does not flake, but a pre-fix handler (no deadline)
    would never answer at all.
    """
    _install_fake_gh(
        tmp_path / "fakebin-hang",
        "#!/bin/sh\nsleep 600\n",
        monkeypatch,
    )

    h2 = FunctionalHarness.boot(default_pabrik_bin)
    try:
        h2.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": "42"},
            expect=502,
            timeout_s=45.0,
        )
        assert h2.health(), "server died after a hung gh"
    finally:
        h2.teardown()


def test_concurrent_pr_status_calls_keep_the_process_alive(
    repo: Path, tmp_path: Path, monkeypatch, default_pabrik_bin: Path
) -> None:
    """The reported abort only ever happened under concurrency.

    `closeFd` was reached from a worker-pool thread while other threads
    were spawning children of their own, so one request could take the
    whole server down. Fan out a burst of pr-status calls and then
    prove the process is still serving — a SIGABRT here fails the
    `health()` check, not a return value.
    """
    _install_fake_gh(
        tmp_path / "fakebin-concurrent",
        "#!/bin/sh\n"
        "printf '{\"number\":7,\"title\":\"t\",\"url\":\"https://github.com/a/b/pull/7\","
        "\"state\":\"OPEN\",\"author\":{\"login\":\"alice\"}}'\n"
        "printf 'a warning\\n' 1>&2\n",
        monkeypatch,
    )

    h2 = FunctionalHarness.boot(default_pabrik_bin)
    try:

        def one(i: int):
            return h2.http(
                "GET",
                "/api/git/pr/status",
                params={"path": str(repo), "pr": str(1000 + i)},
                expect=200,
                timeout_s=45.0,
            ).status

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            codes = list(pool.map(one, range(24)))
        assert all(c == 200 for c in codes), f"got: {codes!r}"
        assert h2.health(), "server aborted during concurrent pr-status calls"
    finally:
        h2.teardown()
