"""Wire test: a relative `path` query/body value no longer ABORTS the server in
the git file handlers.

Crash class (remote-reachable)
==============================
`GET /api/git/file/read?path=<relative>&file=<x>` joined the two query values and
handed the result to `std.Io.Dir.openFileAbsolute`, whose precondition is
`assert(path.isAbsolute(...))`. In a Debug build that assertion is `unreachable`,
so instead of returning 400/404 the process called `std.process.abort()`:

    /usr/lib/zig/std/Io/Dir.zig:486:11 in openFileAbsolute
        assert(path.isAbsolute(absolute_path));
    src/http_handlers/git_file_diff.zig:63 / :107 in gitFileDiffHandler / gitFileReadHandler
    === CRASH: received signal ABRT (signal number 6) ===

A `catch |err| ...` clause does NOT protect these calls — the panic happens
inside the callee before any error value can be returned — so the handlers now
reject a non-absolute `path` (and an absolute `file`) with 400 BEFORE the join.
The batch endpoint (`POST /api/git/file/diffs`) has the same guard on body.path,
which `syntheticFallback` later feeds to the same API.

These are the exact query strings `src/apps/desktop/src/api/index.ts` builds
(`/git/file/diff?path=…&file=…`, `/git/file/read?path=…&file=…`) and the exact
POST body `SidebarDiffPanel.vue` sends, with the `path` downgraded from the
frontend's absolute cwd to a relative one — the malicious/buggy-client case.

Why a wire test: the failure mode is SIGABRT of the whole process, which only a
real round-trip can observe ("is this PID still answering /health?").

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \\
      python3 -m pytest tests/functional/git_file_relative_path_crash_test.py -v
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from harness import FunctionalHarness

# Substrings that only appear in the process log if the worker aborted.
CRASH_MARKERS = (
    "received signal ABRT",
    "reached unreachable code",
    "openFileAbsolute",
    "panic:",
)

RELATIVE_PATH = "relative/repo"
FILE = "src/main.zig"


@pytest.fixture
def harness(default_pabrik_bin: object) -> FunctionalHarness:
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


def _assert_alive(harness: FunctionalHarness, what: str) -> None:
    log_tail = harness.tail_log(4000)
    assert harness.health(), (
        f"pabrik died while handling {what} — the relative-path abort is back.\n"
        f"--- log tail ---\n{log_tail[-4000:]}"
    )
    for marker in CRASH_MARKERS:
        assert marker not in log_tail, (
            f"{what}: log contains crash marker {marker!r}:\n{log_tail[-4000:]}"
        )


def test_file_read_rejects_relative_path(harness: FunctionalHarness) -> None:
    """`?path=<relative>` must 400, not abort the process."""
    r = harness.http(
        "GET",
        "/api/git/file/read",
        params={"path": RELATIVE_PATH, "file": FILE},
        expect=400,
    )
    assert "absolute" in r.json()["error"], r.json()
    _assert_alive(harness, "GET /api/git/file/read with a relative path")


def test_file_diff_rejects_relative_path(harness: FunctionalHarness) -> None:
    """`GET /api/git/file/diff` shares the same join → same guard."""
    r = harness.http(
        "GET",
        "/api/git/file/diff",
        params={"path": RELATIVE_PATH, "file": FILE, "staged": "false"},
        expect=400,
    )
    assert "absolute" in r.json()["error"], r.json()
    _assert_alive(harness, "GET /api/git/file/diff with a relative path")


def test_file_diffs_batch_rejects_relative_body_path(harness: FunctionalHarness) -> None:
    """The batch endpoint's `path` reaches the same API via syntheticFallback."""
    r = harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={"path": RELATIVE_PATH, "files": [{"file": FILE, "staged": False}]},
        expect=400,
    )
    assert "absolute" in r.json()["error"], r.json()
    _assert_alive(harness, "POST /api/git/file/diffs with a relative body path")


def test_file_read_rejects_absolute_file(harness: FunctionalHarness, tmp_path: Path) -> None:
    """An absolute `file` escapes `path`; the sibling handler rejects it too.

    The absolute probe is built with ``os.path.join`` rather than
    hardcoded as ``/etc/passwd``: the guard under test is "this `file`
    is absolute, so it escapes `path`", and ``/etc/passwd`` is not
    absolute on Windows — the handler would reject it for the OTHER
    reason ("path is not absolute") and the assertion below would fail
    on a message that names a different bug.
    """
    escaping_file = os.path.join(str(tmp_path), os.pardir, "escaped.txt")
    r = harness.http(
        "GET",
        "/api/git/file/read",
        params={"path": str(tmp_path), "file": escaping_file},
        expect=400,
    )
    assert "relative" in r.json()["error"], r.json()
    _assert_alive(harness, "GET /api/git/file/read with an absolute file")


def test_file_read_still_works_for_absolute_paths(harness: FunctionalHarness, tmp_path: Path) -> None:
    """Positive control: the guard must not break the normal (absolute) call.

    If the 400s above were a blanket failure this test would not reach a real
    file read. Reads a fixture under the harness tmpdir and asserts its bytes.
    """
    (tmp_path / "notes.txt").write_text("hello from the wire test\n")
    r = harness.http(
        "GET",
        "/api/git/file/read",
        params={"path": str(tmp_path), "file": "notes.txt"},
        expect=200,
    )
    assert "hello from the wire test" in r.json()["content"], r.json()
    _assert_alive(harness, "GET /api/git/file/read with an absolute path")
