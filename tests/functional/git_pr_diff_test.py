"""Functional wire tests for GET /api/git/pr/diff (generic provider).

Exercises the endpoint the ChatView right panel will call in PR mode,
using pure-git base...head diffs on a fixture repo (no network, no
forge CLI):

  1. Generic diff between main and a feature branch returns hunks.
  2. Unknown head ref → clean 502 JSON (not a crash).
  3. Missing pr_url → 400.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from urllib.parse import quote

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
def pr_cwd(tmp_path: Path) -> Path:
    cwd = tmp_path / "pr-diff-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / "base.txt").write_text("keep\nold\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "base")
    _git(cwd, "checkout", "--quiet", "-b", "feature")
    (cwd / "base.txt").write_text("keep\nnew\n")
    (cwd / "added.txt").write_text("hello\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "feature work")
    return cwd


def _pr_diff(
    harness: FunctionalHarness, cwd: Path, extra: dict | None = None
) -> dict:
    params = {
        "path": str(cwd),
        "pr_url": "https://git.example.com/o/r/pull/1",
        "provider": "generic",
        "base": "main",
        "head": "feature",
    }
    if extra:
        params.update(extra)
    return harness.http(
        "GET", "/api/git/pr/diff", params=params, expect=200, timeout_s=15.0
    ).json()


def test_generic_pr_diff_returns_hunks(
    harness: FunctionalHarness, pr_cwd: Path
) -> None:
    """base...head diff surfaces both the modified and the new file."""
    body = _pr_diff(harness, pr_cwd)
    assert body["truncated"] is False
    assert body["base"] == "main"
    assert body["head"] == "feature"
    diff = body["diff_content"]
    assert "diff --git a/base.txt b/base.txt" in diff
    assert "-old" in diff and "+new" in diff
    assert "diff --git a/added.txt b/added.txt" in diff


def test_generic_pr_diff_unknown_head_is_clean_502(
    harness: FunctionalHarness, pr_cwd: Path
) -> None:
    """Unknown head ref → 502 JSON (covers the DiffFailed wire mode)."""
    params = {
        "path": str(pr_cwd),
        "pr_url": "https://git.example.com/o/r/pull/1",
        "provider": "generic",
        "base": "main",
        "head": "no-such-branch",
    }
    r = harness.http(
        "GET", "/api/git/pr/diff", params=params, expect=502, timeout_s=15.0
    ).json()
    assert "error" in r, f"got: {r!r}"


def test_pr_diff_missing_pr_url_is_400(
    harness: FunctionalHarness, pr_cwd: Path
) -> None:
    """Missing pr_url → 400 (covers the validator wire mode)."""
    r = harness.http(
        "GET",
        "/api/git/pr/diff",
        params={"path": str(pr_cwd)},
        expect=400,
        timeout_s=15.0,
    ).json()
    assert "error" in r, f"got: {r!r}"


def test_pr_diff_unknown_provider_is_400(
    harness: FunctionalHarness, pr_cwd: Path
) -> None:
    """Unknown provider → 400 (covers the strict-validator wire mode)."""
    r = harness.http(
        "GET",
        "/api/git/pr/diff",
        params={
            "path": str(pr_cwd),
            "pr_url": "https://git.example.com/o/r/pull/1",
            "provider": "bitbucket",
        },
        expect=400,
        timeout_s=15.0,
    ).json()
    assert "error" in r, f"got: {r!r}"
