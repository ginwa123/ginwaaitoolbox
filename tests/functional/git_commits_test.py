"""Functional wire tests for the read-only commits history endpoints.

The Commits view (GitCommits.vue, embedded in RightSidebar + SidebarDiffPanel)
talks to two REST endpoints and this file proves the exact wire payloads:

  1. GET /api/git/commits lists history newest-first with skip/limit paging.
  2. GET /api/git/commit returns the full message + touched files for a SHA.
  3. Non-repo paths return 200 with is_git_repo=false (git_changes.zig:150
     convention); missing/invalid params return 400.

Fixture repo (under pytest tmp_path, NOT the harness HOME):
  <cwd>/a.txt  committed 3x ("first", 'second "quoted"' + body, "third")
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from harness import FunctionalHarness


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=Test Author", *args],
        cwd=str(cwd),
        check=True,
        timeout=30,
    )


@pytest.fixture
def commits_cwd(tmp_path: Path) -> Path:
    cwd = tmp_path / "commits-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / "a.txt").write_text("one\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "first")
    (cwd / "a.txt").write_text("two\n")
    (cwd / "b.txt").write_text("new\n")
    _git(cwd, "add", "-A")
    _git(
        cwd,
        "commit",
        "--quiet",
        "-m",
        'second "quoted" subject',
        "-m",
        "multi\nline body",
    )
    (cwd / "a.txt").write_text("three\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "third")
    return cwd


def test_commits_list_newest_first(
    harness: FunctionalHarness, commits_cwd: Path
) -> None:
    """GET /commits returns newest-first rows with sha/author/subject."""
    body = harness.http(
        "GET",
        "/api/git/commits",
        params={"path": str(commits_cwd)},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert body["is_git_repo"] is True
    assert body["branch"] == "main"
    assert body["total_count"] == 3
    subjects = [c["subject"] for c in body["commits"]]
    assert subjects == ["third", 'second "quoted" subject', "first"]
    newest = body["commits"][0]
    assert len(newest["sha"]) == 40
    assert newest["short_sha"] == newest["sha"][:7]
    assert newest["author"] == "Test Author"
    assert newest["timestamp"] > 0


def test_commits_pagination(harness: FunctionalHarness, commits_cwd: Path) -> None:
    """skip/limit pages through history for infinite scroll."""
    first = harness.http(
        "GET",
        "/api/git/commits",
        params={"path": str(commits_cwd), "limit": "2", "skip": "0"},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert [c["subject"] for c in first["commits"]] == [
        "third",
        'second "quoted" subject',
    ]
    second = harness.http(
        "GET",
        "/api/git/commits",
        params={"path": str(commits_cwd), "limit": "2", "skip": "2"},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert [c["subject"] for c in second["commits"]] == ["first"]


def test_commit_detail(harness: FunctionalHarness, commits_cwd: Path) -> None:
    """GET /commit returns the full message + touched files for a SHA."""
    listed = harness.http(
        "GET",
        "/api/git/commits",
        params={"path": str(commits_cwd)},
        expect=200,
        timeout_s=15.0,
    ).json()
    sha = listed["commits"][1]["sha"]
    detail = harness.http(
        "GET",
        "/api/git/commit",
        params={"path": str(commits_cwd), "sha": sha},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert detail["sha"] == sha
    assert detail["subject"] == 'second "quoted" subject'
    assert "multi" in detail["body"]
    paths = [f["path"] for f in detail["files"]]
    assert "a.txt" in paths
    assert "b.txt" in paths


def test_commits_non_repo_is_200_not_found(
    harness: FunctionalHarness, tmp_path: Path
) -> None:
    """A non-git path returns 200 with is_git_repo=false (changes convention)."""
    plain = tmp_path / "not-a-repo"
    plain.mkdir()
    body = harness.http(
        "GET",
        "/api/git/commits",
        params={"path": str(plain)},
        expect=200,
        timeout_s=15.0,
    ).json()
    assert body["is_git_repo"] is False
    assert body["commits"] == []


def test_commits_param_validation(harness: FunctionalHarness) -> None:
    """Missing path and non-hex sha are 400s, never a git subprocess."""
    harness.http("GET", "/api/git/commits", params={}, expect=400, timeout_s=15.0)
    harness.http(
        "GET",
        "/api/git/commit",
        params={"path": "/tmp", "sha": "--help"},
        expect=400,
        timeout_s=15.0,
    )
