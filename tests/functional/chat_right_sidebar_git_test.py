"""Functional wire tests for the ChatView-embedded git-diff sidebar.

The sidebar (SidebarDiffPanel.vue) talks to four REST endpoints and this
file proves the exact wire payloads it consumes:

  1. GET /api/git/changes groups staged / modified / untracked files.
  2. GET /api/git/file/diff returns unified diff_content for a dirty file.
  3. POST /api/git/stage + GET /changes round-trips a file into staged.
  4. POST /api/git/unstage moves it back.

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
    cwd = tmp_path / "sidebar-diff-proj"
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
    # Unstaged modification.
    (cwd / "committed.txt").write_text("keep\nnew\n")
    # Staged modification.
    (cwd / "staged.txt").write_text("keep\nnew\n")
    _git(cwd, "add", "staged.txt")
    # Untracked file.
    (cwd / "new.txt").write_text("hello\n")
    return cwd


def test_changes_groups_files(harness: FunctionalHarness, diff_cwd: Path) -> None:
    """GET /changes splits staged / modified / untracked for the panel."""
    r = harness.http(
        "GET",
        "/api/git/changes",
        params={"path": str(diff_cwd)},
        expect=200,
        timeout_s=15.0,
    )
    body = r.json()
    assert body["is_git_repo"] is True
    assert body["branch"] == "main"
    assert [f["path"] for f in body["staged_files"]] == ["staged.txt"]
    assert [f["path"] for f in body["modified_files"]] == ["committed.txt"]
    assert [f["path"] for f in body["untracked_files"]] == ["new.txt"]


def test_file_diff_content(harness: FunctionalHarness, diff_cwd: Path) -> None:
    """GET /file/diff returns the unified hunk the inline view renders."""
    r = harness.http(
        "GET",
        "/api/git/file/diff",
        params={"path": str(diff_cwd), "file": "committed.txt", "staged": "false"},
        expect=200,
        timeout_s=15.0,
    )
    body = r.json()
    assert body["path"] == "committed.txt"
    assert body["staged"] is False
    assert "-old" in body["diff_content"]
    assert "+new" in body["diff_content"]
    assert "@@" in body["diff_content"]


def test_stage_unstage_round_trip(
    harness: FunctionalHarness, diff_cwd: Path
) -> None:
    """POST /stage|/unstage move committed.txt between groups on the wire."""
    harness.http(
        "POST",
        "/api/git/stage",
        params={"path": str(diff_cwd), "files": "committed.txt"},
        expect=200,
        timeout_s=15.0,
    )
    staged = harness.http(
        "GET",
        "/api/git/changes",
        params={"path": str(diff_cwd)},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert "committed.txt" in [f["path"] for f in staged["staged_files"]]

    harness.http(
        "POST",
        "/api/git/unstage",
        params={"path": str(diff_cwd), "files": "committed.txt"},
        expect=200,
        timeout_s=15.0,
    )
    unstaged = harness.http(
        "GET",
        "/api/git/changes",
        params={"path": str(diff_cwd)},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert "committed.txt" in [f["path"] for f in unstaged["modified_files"]]
    assert "committed.txt" not in [f["path"] for f in unstaged["staged_files"]]
