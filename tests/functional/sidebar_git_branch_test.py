"""Sidebar git branch badge wire contract (kanban parity).

`GET /api/llm/session` must carry the two fields the sidebar's
kanban-style branch badge reads:

  * `git_branch` — current branch of the session's effective cwd
    (bound worktree path when set, else the session cwd), resolved
    per request via `git -C <cwd> symbolic-ref --short HEAD`
    (same helper as the kanban `tasks_list.zig` badge).
    "" when the cwd is not a git repo / HEAD is detached.
  * `git_worktree_cwd` — bound worktree path ("" = none).

The frontend (`ChatsList.vue`) renders an icon-only PR branch badge
with status colors (green = open, violet = merged, red = closed) only
after a pull request is found. Worktree bindings and branches without
a pull request render no git badge.

Run:
    NALAR_BIN=<worktree>/zig-out/bin/nalarcore-linux-x86_64 \\
      python3 -m pytest tests/functional/sidebar_git_branch_test.py -v
"""

from __future__ import annotations

import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


def _git(cwd: Path, *args: str) -> str:
    r = subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", *args],
        cwd=str(cwd),
        check=True,
        timeout=30,
        capture_output=True,
        text=True,
    )
    return r.stdout.strip()


@pytest.fixture
def branch_repo(tmp_path: Path) -> Path:
    """Real git repo on a `worktree/...` branch (NOT the harness HOME)."""
    cwd = tmp_path / "sidebar-branch-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / "readme.txt").write_text("hi\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "base")
    _git(cwd, "checkout", "--quiet", "-b", "worktree/sidebar-badge-test")
    assert _git(cwd, "symbolic-ref", "--short", "HEAD") == "worktree/sidebar-badge-test"
    return cwd


def _create_session(harness: FunctionalHarness, name: str, cwd: str) -> str:
    session_id = f"sess_test_{uuid.uuid4().hex[:24]}"
    r = harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "session_name": name,
            "cwd_session": cwd,
        },
        expect=201,
    )
    assert r.json()["id"] == session_id, f"create echoed {r.json()!r}"
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        r = harness.http("GET", f"/api/llm/session/{session_id}", expect=(200, 404))
        if r.status == 200:
            return session_id
        time.sleep(0.05)
    raise AssertionError(f"session {session_id} did not appear within 5s")


def _list_sessions(harness: FunctionalHarness) -> dict[str, Any]:
    r = harness.http("GET", "/api/llm/session", params={"limit": 50}, expect=200)
    body = r.json()
    assert isinstance(body.get("sessions"), list), f"bad list shape: {body!r}"
    return body


def test_session_list_carries_git_branch_for_git_cwd(
    harness: FunctionalHarness, branch_repo: Path
) -> None:
    """Session whose cwd is a git checkout exposes its branch on the wire."""
    sid = _create_session(harness, "branched chat", str(branch_repo))

    body = _list_sessions(harness)
    row = next(s for s in body["sessions"] if s["session_id"] == sid)
    assert row["git_branch"] == "worktree/sidebar-badge-test", f"wire row: {row!r}"
    assert row["git_worktree_cwd"] == "", f"unbound worktree must be '': {row!r}"
    assert row["cwd"] == str(branch_repo), f"cwd must round-trip: {row!r}"


def test_session_list_empty_branch_for_non_git_cwd(
    harness: FunctionalHarness, tmp_path: Path
) -> None:
    """Non-repo cwd resolves to empty branch (badge omitted, keys present)."""
    plain = tmp_path / "not-a-repo"
    plain.mkdir(parents=True)
    sid = _create_session(harness, "plain chat", str(plain))

    body = _list_sessions(harness)
    row = next(s for s in body["sessions"] if s["session_id"] == sid)
    assert row["git_branch"] == "", f"non-repo must be '': {row!r}"
    assert row["git_worktree_cwd"] == "", f"unbound worktree must be '': {row!r}"
