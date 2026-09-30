"""Functional wire tests for GET /api/git/pr/status.

Exercises the endpoint the `nalarcli pr-status` command calls
(`gh pr view` wrapper returning open/merged/closed):

  1. Missing path → 400 (route is registered, validator runs).
  2. Unknown provider → 400 (strict validator).
  3. gitlab provider → no longer rejected up front; it reaches the glab
     path (see `git_pr_gitlab_test.py` for the full GitLab coverage).
  4. Non-repo path → 404 (not shadowing, real handler answer).
  5. Happy path via a fake `gh` on PATH → 200 with normalized status.
"""

from __future__ import annotations

import json
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
    cwd = tmp_path / "pr-status-proj"
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


def test_missing_path_is_400(harness: FunctionalHarness) -> None:
    r = harness.http("GET", "/api/git/pr/status", expect=400).json()
    assert "error" in r, f"got: {r!r}"


def test_unknown_provider_is_400(
    harness: FunctionalHarness, repo: Path
) -> None:
    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "provider": "bitbucket"},
        expect=400,
    ).json()
    assert "error" in r, f"got: {r!r}"


def test_gitlab_provider_is_not_rejected_up_front(
    harness: FunctionalHarness, repo: Path
) -> None:
    """`provider=gitlab` used to be a hard 400 before any lookup.

    Now it reaches the glab path. On a box with no `glab` installed the
    honest answer is 422 naming glab — what must NOT happen is a 400
    blaming GitHub, which is what a GitLab user used to get.
    """
    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "provider": "gitlab"},
        expect=(200, 422, 502),
    ).json()
    assert "only the github provider" not in r.get("error", ""), f"got: {r!r}"
    if r.get("error"):
        # Whichever way it failed, the message must be about GitLab.
        assert "glab" in r["error"] or "gitlab" in r["error"].lower(), f"got: {r!r}"
    else:
        assert r["provider"] == "gitlab", f"got: {r!r}"


def test_non_repo_path_is_404(
    harness: FunctionalHarness, tmp_path: Path
) -> None:
    plain = tmp_path / "not-a-repo"
    plain.mkdir(parents=True)
    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(plain), "pr": "42"},
        expect=404,
    ).json()
    assert "error" in r, f"got: {r!r}"


def test_happy_path_via_fake_gh(
    repo: Path, tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """A fake `gh` on PATH proves the 200 wire shape end-to-end.

    The harness boots the server with the parent's PATH, so prepending
    a tmpdir bin with an executable `gh` stub makes the backend's
    `gh pr view --json ...` spawn return canned JSON without network.
    The harness must boot AFTER the PATH patch, so this test takes
    `default_nalar_bin` and boots its own harness instead of the
    function-scoped `harness` fixture.
    """
    bindir = tmp_path / "fakebin"
    bindir.mkdir(parents=True)
    fake_gh = bindir / "gh"
    payload = {
        "number": 42,
        "title": "Fix login",
        "url": "https://github.com/acme/app/pull/42",
        "state": "MERGED",
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "headRefName": "feature",
        "baseRefName": "main",
        "createdAt": "2026-09-01T00:00:00Z",
        "updatedAt": "2026-09-02T00:00:00Z",
        "mergedAt": "2026-09-03T00:00:00Z",
        "closedAt": "",
        "author": {"login": "alice"},
        "additions": 10,
        "deletions": 5,
        "changedFiles": 3,
    }
    fake_gh.write_text(
        "#!/bin/sh\ncat <<'EOF'\n" + json.dumps(payload) + "\nEOF\n"
    )
    fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h2 = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": "42"},
            expect=200,
            timeout_s=15.0,
        ).json()
    finally:
        h2.teardown()
    assert body["number"] == 42
    assert body["state"] == "MERGED"
    assert body["status"] == "merged"
    assert body["title"] == "Fix login"
    assert body["head_ref"] == "feature"
    assert body["base_ref"] == "main"


def test_open_pr_with_null_dates_is_200(
    repo: Path, tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """An OPEN PR's `gh` payload carries `"mergedAt":null,"closedAt":null`.

    The backend struct used to declare those as non-optional strings, so
    JSON parsing failed and every open PR (e.g. #584) returned HTTP 502
    "failed to fetch PR status". Nulls must surface as empty strings.
    """
    bindir = tmp_path / "fakebin-open"
    bindir.mkdir(parents=True)
    fake_gh = bindir / "gh"
    payload = {
        "number": 584,
        "title": "SyncEngine Phase 2",
        "url": "https://github.com/acme/app/pull/584",
        "state": "OPEN",
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "UNSTABLE",
        "headRefName": "worktree/sync-engine-phase2-cached-delta",
        "baseRefName": "main",
        "createdAt": "2026-09-21T08:51:37Z",
        "updatedAt": "2026-09-21T08:51:37Z",
        "mergedAt": None,
        "closedAt": None,
        "author": {"login": "ginwa123"},
        "additions": 286,
        "deletions": 103,
        "changedFiles": 4,
    }
    fake_gh.write_text(
        "#!/bin/sh\ncat <<'EOF'\n" + json.dumps(payload) + "\nEOF\n"
    )
    fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h2 = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": "worktree/sync-engine-phase2-cached-delta"},
            expect=200,
            timeout_s=15.0,
        ).json()
    finally:
        h2.teardown()
    assert body["number"] == 584
    assert body["state"] == "OPEN"
    assert body["status"] == "open"
    assert body["head_ref"] == "worktree/sync-engine-phase2-cached-delta"
    assert body["merged_at"] == ""
    assert body["closed_at"] == ""


def test_fetch_failure_surfaces_gh_stderr(
    repo: Path, tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """A failing `gh` must surface its stderr in the 502 body.

    The handler used to swallow `gh` stderr and return only the generic
    \"failed to fetch PR status (check PR number/URL, provider, and gh
    auth)\" hint, so DevTools never showed WHY it failed (expired auth,
    bad PR number, rate limit). The 502 `error` must now carry the real
    `gh` stderr after the prefix.
    """
    bindir = tmp_path / "fakebin-fail"
    bindir.mkdir(parents=True)
    fake_gh = bindir / "gh"
    fake_gh.write_text(
        "#!/bin/sh\necho 'gh: To authenticate, run: gh auth login' >&2\nexit 1\n"
    )
    fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h2 = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": "42"},
            expect=502,
            timeout_s=15.0,
        ).json()
    finally:
        h2.teardown()
    assert "gh auth login" in body["error"], f"got: {body!r}"
    # The prefix names the forge's own noun ("pull request" on GitHub,
    # "merge request" on GitLab) instead of a hardcoded "PR", so the
    # message matches whichever CLI actually ran.
    assert body["error"].startswith("failed to fetch pull request status: "), (
        f"got: {body!r}"
    )
