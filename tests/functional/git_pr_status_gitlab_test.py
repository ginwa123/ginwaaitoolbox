"""Functional wire tests reproducing the GitLab failure of GET /api/git/pr/status.

Reported request (Windows browser DevTools):

    GET /api/git/pr/status
        ?path=/home/ginwa/work/billing-svc-split/billing-svc
        &pr=ibl/feat/iron-11463-split-bill

The repo's origin is `https://git.bluebird.id/ibl-billing/backend/billing-svc.git`
(self-hosted GitLab), yet the handler is GitHub-only and shells out to
`gh pr view <arg> --json ...`. `gh` refuses a repository whose remotes do
not point to a known GitHub host, so the wire answer is HTTP 502 carrying
`gh`'s stderr.

These tests boot a fresh nalar per test through FunctionalHarness
(isolated tmpdir HOME, free port in 8080..8199, never 8081) and replay the
exact query string. No live server and no network access are required.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

from harness import FunctionalHarness

BRANCH = "ibl/feat/iron-11463-split-bill"
GITLAB_REMOTE = "https://git.bluebird.id/ibl-billing/backend/billing-svc.git"
# Exact stderr produced by `gh pr view` inside a repo whose only remote is
# the self-hosted GitLab origin (verified locally with the real gh CLI).
GH_GITLAB_REMOTE_STDERR = (
    "none of the git remotes configured for this repository point to a known "
    "GitHub host. To tell gh about a new GitHub host, please use `gh auth login`"
)


def _make_gitlab_repo(root: Path) -> Path:
    """A git repo whose origin is a self-hosted GitLab URL (no fetch)."""
    repo = root / "billing-svc"
    repo.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--quiet", "--initial-branch=main", str(repo)],
        check=True,
        timeout=30,
    )
    subprocess.run(
        ["git", "-C", str(repo), "remote", "add", "origin", GITLAB_REMOTE],
        check=True,
        timeout=30,
    )
    return repo


def _fake_gh_exact_stderr(bin_dir: Path) -> None:
    """A `gh` stub that reproduces gh's real GitLab-remote failure.

    The handler maps any non-zero `gh` exit whose stderr does not match
    "no pull request" / "could not find" to HTTP 502 with the stderr
    verbatim after the `failed to fetch PR status: ` prefix, so this stub
    proves the wire mapping without contacting github.com.
    """
    bin_dir.mkdir(parents=True)
    gh = bin_dir / "gh"
    gh.write_text(f"#!/bin/sh\necho '{GH_GITLAB_REMOTE_STDERR}' >&2\nexit 1\n")
    gh.chmod(gh.stat().st_mode | stat.S_IEXEC)


def test_gitlab_repo_branch_request_is_502_with_gh_reason(
    default_nalar_bin: Path, tmp_path: Path, monkeypatch
) -> None:
    """The exact reported request: GitLab repo + branch as `pr` → 502.

    The handler only knows `gh pr view`; the branch value is passed
    straight through. There is no `provider=gitlab` path in v1, so the
    answer is the real `gh` failure, not a provider hint.
    """
    repo = _make_gitlab_repo(tmp_path)
    bindir = tmp_path / "fakebin"
    _fake_gh_exact_stderr(bindir)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": BRANCH},
            expect=502,
            timeout_s=15.0,
        ).json()
    finally:
        h.teardown()
    assert body["error"].startswith("failed to fetch PR status: "), f"got: {body!r}"
    assert "known GitHub host" in body["error"], f"got: {body!r}"


def test_explicit_gitlab_provider_is_400_github_only(
    default_nalar_bin: Path, tmp_path: Path, monkeypatch
) -> None:
    """`provider=gitlab` is rejected up front: PR status is GitHub-only."""
    repo = _make_gitlab_repo(tmp_path)
    bindir = tmp_path / "fakebin"
    _fake_gh_exact_stderr(bindir)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": BRANCH, "provider": "gitlab"},
            expect=400,
            timeout_s=15.0,
        ).json()
    finally:
        h.teardown()
    assert "github" in body["error"].lower(), f"got: {body!r}"


def test_gitlab_mr_url_as_pr_is_rejected_before_gh(
    default_nalar_bin: Path, tmp_path: Path, monkeypatch
) -> None:
    """A GitLab MR URL as `pr` is caught by the provider sniff, not by gh.

    `useCase` normalizes a URL-shaped `pr` and refuses anything whose
    detected provider is not github, so a GitLab MR URL never reaches
    `gh`; the 502 carries the explicit "not a GitHub URL" reason.
    """
    repo = _make_gitlab_repo(tmp_path)
    bindir = tmp_path / "fakebin"
    _fake_gh_exact_stderr(bindir)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    mr_url = "https://git.bluebird.id/ibl-billing/backend/billing-svc/-/merge_requests/11463"
    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h.http(
            "GET",
            "/api/git/pr/status",
            params={"path": str(repo), "pr": mr_url},
            expect=502,
            timeout_s=15.0,
        ).json()
    finally:
        h.teardown()
    assert "not a GitHub URL" in body["error"], f"got: {body!r}"
    assert "v1 supports github only" in body["error"], f"got: {body!r}"


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-v"]))
