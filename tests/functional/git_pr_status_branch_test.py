"""Branch-name and URL round-trips for GET /api/git/pr/status.

The kanban card sends `pr=<git_branch>` where worktree branches contain
slashes (`worktree/foo-123`). This proves the value survives URL encoding
(frontend `URLSearchParams` / `urllib urlencode` emit `%2F`) + server query
parsing intact, all the way into the `gh pr view` argv — using a fake `gh`
that records what it received.

It also proves a full PR URL resolves with NO `path` at all (the backend
skips its repo check in URL mode), so the badge keeps working when the
local worktree/path was deleted.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
from pathlib import Path
from typing import Any

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
    cwd = tmp_path / "pr-branch-proj"
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


def _canned_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "number": 577,
        "title": "Color git icon",
        "url": "https://github.com/acme/app/pull/577",
        "state": "MERGED",
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "headRefName": "worktree/feature-x-123",
        "baseRefName": "main",
        "createdAt": "2026-09-01T00:00:00Z",
        "updatedAt": "2026-09-02T00:00:00Z",
        "mergedAt": "2026-09-03T00:00:00Z",
        "closedAt": "",
        "author": {"login": "alice"},
        "additions": 1,
        "deletions": 0,
        "changedFiles": 1,
    }
    payload.update(overrides)
    return payload


def _boot_with_fake_gh(
    tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> tuple[FunctionalHarness, Path]:
    """Boot a harness whose `gh` records argv then returns canned MERGED."""
    bindir = tmp_path / "fakebin"
    bindir.mkdir(parents=True, exist_ok=True)
    args_file = tmp_path / "gh-args.txt"
    fake_gh = bindir / "gh"
    fake_gh.write_text(
        "#!/bin/sh\n"
        'for a in "$@"; do printf \'%s\\n\' "$a"; done > "$GH_ARGS_FILE"\n'
        "cat <<'EOF'\n" + json.dumps(_canned_payload()) + "\nEOF\n"
    )
    fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])
    monkeypatch.setenv("GH_ARGS_FILE", str(args_file))
    return FunctionalHarness.boot(default_nalar_bin), args_file


def test_branch_with_slashes_reaches_gh_intact(
    repo: Path, tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """`pr=worktree/feature-x-123` must arrive at `gh` as one intact arg."""
    h2, args_file = _boot_with_fake_gh(tmp_path, monkeypatch, default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": "worktree/feature-x-123"},
            expect=200,
            timeout_s=15.0,
        ).json()
    finally:
        h2.teardown()
    assert body["status"] == "merged"
    assert body["head_ref"] == "worktree/feature-x-123"

    argv = args_file.read_text().splitlines()
    assert "worktree/feature-x-123" in argv, f"gh received mangled argv: {argv!r}"
    assert not any("%2F" in a or "%2f" in a for a in argv), (
        f"gh received percent-encoded branch: {argv!r}"
    )


def test_url_without_path_returns_200(
    tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """A full PR URL needs no `path` (deleted worktree still resolves)."""
    h2, args_file = _boot_with_fake_gh(tmp_path, monkeypatch, default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/status",
            params={"pr": "https://github.com/acme/app/pull/577"},
            expect=200,
            timeout_s=15.0,
        ).json()
    finally:
        h2.teardown()
    assert body["status"] == "merged"
    assert body["number"] == 577

    argv = args_file.read_text().splitlines()
    assert "https://github.com/acme/app/pull/577" in argv, (
        f"gh received mangled argv: {argv!r}"
    )
