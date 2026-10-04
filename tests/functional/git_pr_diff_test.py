"""Functional wire tests for GET /api/git/pr/diff (generic provider).

Exercises the endpoint the ChatView right panel will call in PR mode,
using pure-git base...head diffs on a fixture repo (no network, no
forge CLI):

  1. Generic diff between main and a feature branch returns hunks.
  2. Unknown head ref → clean 502 JSON (not a crash).
  3. Missing pr_url → 400.

Plus the GitHub-provider path against a fixture whose `origin` publishes
`refs/pull/1/head`: when the forge CLI cannot answer, the handler must fall
back to that ref instead of returning 502.
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


# ---------------------------------------------------------------------------
# Forge CLI failure -> git refspec fallback
# ---------------------------------------------------------------------------
#
# The handler prefers `gh pr diff` whenever `gh` resolves on PATH, and used
# to map ANY nonzero exit to a 502. GitHub refuses to serve `/pulls/{n}`
# beyond `FORGE_MAX_DIFF_FILES` (300) files — a repo-wide rename PR (1285
# files, PR #797) makes the installed CLI exit 1 with `too_large` and the
# whole PR panel went dead with "check PR URL, provider, and auth".
#
# The harness gives the child an isolated HOME, so a real `gh` on the box is
# unauthenticated and exits nonzero for ANY pr_url. That is the same failure
# mode as the 406 (CLI present, cannot answer), so this test exercises the
# fallback rather than the happy CLI path. It stays meaningful when `gh` is
# not installed at all: the refspec path is then the primary strategy.
#
# The fixture is built under pytest's tmp_path (outside the repo) and always
# carries its own `.git` — see the repo-corruption hazard in
# `zig build test` fixtures before reusing this shape elsewhere.


def _build_forge_repo(root: Path, *, pr_files: int = 0, lines_per_file: int = 0) -> Path:
    """A clone whose `origin` publishes `refs/pull/1/head`, like GitHub does.

    `pr_files`/`lines_per_file` inflate the PR diff past the 1MB response cap
    so the oversized-PR path is covered without a network or a real PR.
    """
    origin = root / "origin.git"
    seed = root / "seed"
    subprocess.run(
        ["git", "init", "--quiet", "--bare", str(origin)],
        check=True,
        timeout=30,
    )
    subprocess.run(
        ["git", "init", "--quiet", "--initial-branch=main", str(seed)],
        check=True,
        timeout=30,
    )
    (seed / "base.txt").write_text("keep\nold\n")
    _git(seed, "add", "-A")
    _git(seed, "commit", "--quiet", "-m", "base")
    _git(seed, "checkout", "--quiet", "-b", "feature")
    (seed / "base.txt").write_text("keep\nnew\n")
    (seed / "added.txt").write_text("hello\n")
    if pr_files:
        filler = ("payload line with some length to it\n" * lines_per_file)
        for i in range(pr_files):
            (seed / f"bulk_{i:04d}.txt").write_text(filler)
    _git(seed, "add", "-A")
    _git(seed, "commit", "--quiet", "-m", "feature work")
    _git(seed, "remote", "add", "origin", str(origin))
    _git(seed, "push", "--quiet", "origin", "main", "feature")
    # GitHub's well-known PR ref — the thing `fetchRefRange` asks origin for.
    _git(seed, "push", "--quiet", "origin", "feature:refs/pull/1/head")

    work = root / "work"
    # `-b main`: the handler diffs `main...refs/pabrik-pr/1`, so the clone must
    # carry a LOCAL main. Cloning the default branch (feature) would leave the
    # range unresolvable.
    subprocess.run(
        ["git", "clone", "--quiet", "-b", "main", str(origin), str(work)],
        check=True,
        timeout=30,
    )
    return work


@pytest.fixture
def forge_repo(tmp_path: Path) -> Path:
    return _build_forge_repo(tmp_path / "forge")


def test_github_pr_diff_falls_back_to_refspec_when_cli_cannot_answer(
    harness: FunctionalHarness, forge_repo: Path
) -> None:
    """`gh pr diff` unavailable/oversized -> 200 from origin's pull ref.

    Before the fix this returned 502 "failed to fetch PR diff (check PR URL,
    provider, and auth)".
    """
    r = harness.http(
        "GET",
        "/api/git/pr/diff",
        params={
            "path": str(forge_repo),
            "pr_url": "https://github.com/acme/widgets/pull/1",
            "provider": "github",
        },
        expect=200,
        timeout_s=30.0,
    ).json()
    # Only the refspec path reports base/head — the CLI path leaves them "".
    assert r["head"] == "refs/pabrik-pr/1", f"fallback did not run: {r!r}"
    assert r["base"] == "main", f"fallback did not run: {r!r}"
    assert r["truncated"] is False
    diff = r["diff_content"]
    assert "diff --git a/base.txt b/base.txt" in diff
    assert "-old" in diff and "+new" in diff
    assert "diff --git a/added.txt b/added.txt" in diff


def test_oversized_pr_returns_truncated_diff_not_502(
    harness: FunctionalHarness, tmp_path: Path
) -> None:
    """A PR past the 1MB response cap truncates instead of erroring.

    PR #797's local diff is 3.5MB, so this is the exact shape the user hit:
    the forge cannot serve it, and the refspec fallback must still answer.
    """
    work = _build_forge_repo(tmp_path / "big", pr_files=60, lines_per_file=2000)
    r = harness.http(
        "GET",
        "/api/git/pr/diff",
        params={
            "path": str(work),
            "pr_url": "https://github.com/acme/widgets/pull/1",
            "provider": "github",
        },
        expect=200,
        timeout_s=60.0,
    ).json()
    assert r["truncated"] is True, f"expected the 1MB cap to fire: {r!r}"
    assert len(r["diff_content"].encode("utf-8")) <= 1024 * 1024
    assert r["head"] == "refs/pabrik-pr/1"
    assert "diff --git" in r["diff_content"]


def test_github_pr_diff_502_when_both_strategies_fail(
    harness: FunctionalHarness, tmp_path: Path
) -> None:
    """No usable pull ref anywhere -> 502 naming both strategies."""
    plain = tmp_path / "plain"
    subprocess.run(
        ["git", "init", "--quiet", "--initial-branch=main", str(plain)],
        check=True,
        timeout=30,
    )
    (plain / "a.txt").write_text("x\n")
    _git(plain, "add", "-A")
    _git(plain, "commit", "--quiet", "-m", "base")
    # `origin` does not exist at all, so the refspec fetch cannot succeed.
    r = harness.http(
        "GET",
        "/api/git/pr/diff",
        params={
            "path": str(plain),
            "pr_url": "https://github.com/acme/widgets/pull/1",
            "provider": "github",
        },
        expect=502,
        timeout_s=30.0,
    ).json()
    assert "error" in r, f"got: {r!r}"
    assert "origin" in r["error"], f"message should name the fallback: {r!r}"
