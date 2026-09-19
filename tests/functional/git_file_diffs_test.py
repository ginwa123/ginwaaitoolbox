"""Functional wire tests for POST /api/git/file/diffs (batch endpoint).

Replaces the SidebarDiffPanel N+1 fan-out (one GET /file/diff per file,
20 parallel git spawns starving the Io pool) with a single POST that
runs at most 2 git processes server-side.

Fixture repo (under pytest tmp_path, NOT the harness HOME):
  <cwd>/committed.txt   (committed, then modified in worktree → unstaged)
  <cwd>/staged.txt      (committed, modified, `git add`ed → staged)
  <cwd>/new.txt         (untracked)
"""

from __future__ import annotations

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
def diff_cwd(tmp_path: Path) -> Path:
    cwd = tmp_path / "batch-diff-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / "committed.txt").write_text("keep\nold\n")
    (cwd / "staged.txt").write_text("keep\nold\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "base")
    (cwd / "committed.txt").write_text("keep\nnew\n")
    (cwd / "staged.txt").write_text("keep\nnew\n")
    _git(cwd, "add", "staged.txt")
    (cwd / "new.txt").write_text("hello\n")
    return cwd


def test_batch_returns_all_three_groups(harness: FunctionalHarness, diff_cwd: Path) -> None:
    """One POST returns staged + unstaged + untracked diffs in order."""
    r = harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={
            "path": str(diff_cwd),
            "files": [
                {"file": "staged.txt", "staged": True},
                {"file": "committed.txt", "staged": False},
                {"file": "new.txt", "staged": False},
            ],
        },
        expect=200,
        timeout_s=15.0,
    )
    body = r.json()
    assert "diffs" in body
    assert len(body["diffs"]) == 3
    # Order preserved.
    assert [d["path"] for d in body["diffs"]] == ["staged.txt", "committed.txt", "new.txt"]
    assert [d["staged"] for d in body["diffs"]] == [True, False, False]
    # Staged + unstaged carry the unified hunk.
    for d in body["diffs"][:2]:
        assert "-old" in d["diff_content"]
        assert "+new" in d["diff_content"]
        assert "@@" in d["diff_content"]
    # Untracked falls back to a synthetic new-file diff.
    assert "+hello" in body["diffs"][2]["diff_content"]


def test_batch_matches_single_file_diff(harness: FunctionalHarness, diff_cwd: Path) -> None:
    """Batch content for one file equals the single-file endpoint."""
    single = harness.http(
        "GET",
        "/api/git/file/diff",
        params={"path": str(diff_cwd), "file": "committed.txt", "staged": "false"},
        expect=200,
        timeout_s=15.0,
    ).json()
    batch = harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={"path": str(diff_cwd), "files": [{"file": "committed.txt", "staged": False}]},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert len(batch["diffs"]) == 1
    assert batch["diffs"][0]["diff_content"] == single["diff_content"]


def test_batch_validation(harness: FunctionalHarness, diff_cwd: Path) -> None:
    """Empty files list is a 400, not a 500."""
    harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={"path": str(diff_cwd), "files": []},
        expect=400,
        timeout_s=15.0,
    )
