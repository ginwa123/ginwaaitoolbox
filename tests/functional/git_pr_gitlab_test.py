"""Functional wire tests for GitLab support on the git PR/MR endpoints.

The Zig unit tests drive `runView` / `createPullRequestUseCaseWith` against
fixture scripts, which proves the argv and the JSON parsing. They cannot see
three things that only exist on the wire, and all three were GitHub-only in a
way a GitLab user hits immediately:

  1. `GET /api/git/pr/status?provider=gitlab` was a hard 400 ("only the github
     provider is supported for PR status in v1").
  2. `GitPrStatusResponse` had no `provider` field, so the frontend could not
     tell a merge request from a pull request and labelled it "PR".
  3. `POST /api/git/pr` took no `provider`, so it always ran `gh pr create`.

That third one was a bug this file found and the unit tests structurally
could not: `createPullRequestUseCase` passed the `gh` program for EVERY
provider, so `provider: "gitlab"` spawned `gh mr create` and gh replied
`unknown command "mr"`. Only running the real handler surfaces it.

## Why the fake CLIs are installed by an autouse fixture

The harness snapshots `os.environ` when it boots the server, and pytest
instantiates the function-scoped `harness` fixture BEFORE the fixtures a test
lists as arguments. Setting PATH inside a per-test fixture therefore lands too
late — the server has already captured the old PATH, silently runs whatever
real `gh` the host has (possibly making authenticated network calls), and
reports "glab CLI not found".

An `autouse` fixture is instantiated before explicitly-requested fixtures of
the same scope, so this one always wins the race. Each fake reads its stdout
from a sibling `.payload` file, which lets a test choose the CLI's output
after the server is already up.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Iterator

import pytest

from harness import FunctionalHarness

# Prints whatever the test wrote into <bindir>/<name>.payload, so the same
# installed binary serves every test's payload. `$0`-relative so it needs no
# env cooperation with the already-booted server.
_FAKE_CLI = """#!/bin/sh
d=$(dirname "$0")
if [ -f "$d/{name}.payload" ]; then cat "$d/{name}.payload"; fi
"""


@pytest.fixture(autouse=True)
def fake_forge_clis() -> Iterator[Path]:
    """Install fake `gh` + `glab` on PATH before the harness boots.

    Yields the bin dir. Write `<bindir>/gh.payload` or
    `<bindir>/glab.payload` to control what the fake prints; leave the file
    absent and it prints nothing (which the handlers treat as a failure).
    """
    base = Path(tempfile.mkdtemp(prefix="nalar-fake-forge-"))
    bindir = base / "bin"
    bindir.mkdir(parents=True)
    for name in ("gh", "glab"):
        p = bindir / name
        p.write_text(_FAKE_CLI.format(name=name))
        p.chmod(p.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    old_path = os.environ.get("PATH", "")
    os.environ["PATH"] = f"{bindir}{os.pathsep}{old_path}" if old_path else str(bindir)
    try:
        yield bindir
    finally:
        os.environ["PATH"] = old_path
        shutil.rmtree(base, ignore_errors=True)


def _write_payload(bindir: Path, name: str, payload: str) -> None:
    (bindir / f"{name}.payload").write_text(payload)


def _make_repo(tmp_path: Path, remote: str | None = None) -> Path:
    cwd = tmp_path / "forge-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    if remote:
        subprocess.run(
            ["git", "-C", str(cwd), "remote", "add", "origin", remote],
            check=True,
            timeout=30,
        )
    (cwd / "a.txt").write_text("hi\n")
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    subprocess.run(["git", "-C", str(cwd), "add", "-A"], check=True,
                   timeout=30, env={**os.environ, **env})
    subprocess.run(["git", "-C", str(cwd), "commit", "--quiet", "-m", "base"],
                   check=True, timeout=30, env={**os.environ, **env})
    return cwd


OPEN_MR_JSON = json.dumps(
    {
        "id": 11463,
        "iid": 7,
        "title": "Add GitLab support",
        "description": "body",
        "state": "opened",
        "created_at": "2026-09-28T10:00:00.000Z",
        "updated_at": "2026-09-29T11:30:00.000Z",
        "merged_at": None,
        "closed_at": None,
        "author": {"id": 42, "name": "Ginwa", "username": "ginwa123"},
        "source_branch": "worktree/gitlab-support",
        "target_branch": "main",
        "web_url": "https://gitlab.com/group/sub/repo/-/merge_requests/7",
        "merge_status": "can_be_merged",
        "detailed_merge_status": "mergeable",
        # GitLab's REST API reports this as a numeric STRING.
        "changes_count": "4",
    },
    separators=(",", ":"),
)

OPEN_PR_JSON = json.dumps(
    {
        "number": 42,
        "title": "Add GitLab support",
        "url": "https://github.com/acme/app/pull/42",
        "state": "OPEN",
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "headRefName": "worktree/gitlab-support",
        "baseRefName": "main",
        "author": {"login": "ginwa123"},
        "additions": 10,
        "deletions": 2,
        "changedFiles": 3,
    },
    separators=(",", ":"),
)

MR_URL = "https://gitlab.com/group/sub/repo/-/merge_requests/7"
PR_URL = "https://github.com/acme/app/pull/42"


# ── GET /api/git/pr/status ────────────────────────────────────────────────


def test_gitlab_provider_is_no_longer_rejected(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    """THE regression: provider=gitlab used to be a hard 400."""
    _write_payload(fake_forge_clis, "glab", OPEN_MR_JSON)
    repo = _make_repo(tmp_path, remote="git@gitlab.com:group/sub/repo.git")

    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "provider": "gitlab"},
        expect=200,
    ).json()
    assert r["provider"] == "gitlab", f"got: {r!r}"
    assert r["number"] == 7, f"iid must map to number (not id=11463): {r!r}"
    assert r["status"] == "open", f"gitlab 'opened' must normalize: {r!r}"
    assert r["state"] == "opened", f"raw forge state must pass through: {r!r}"
    assert r["pr_url"] == MR_URL, f"web_url must map to pr_url: {r!r}"
    assert r["head_ref"] == "worktree/gitlab-support", f"got: {r!r}"
    assert r["base_ref"] == "main", f"got: {r!r}"
    assert r["author"] == "ginwa123", f"got: {r!r}"
    assert r["mergeable"] == "mergeable", f"got: {r!r}"
    assert r["merged_at"] == "", f"JSON null must be an empty string: {r!r}"
    assert r["changed_files"] == 4, f"string counter must coerce: {r!r}"


def test_a_gitlab_mr_url_routes_to_glab_with_no_provider_param(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    """The frontend passes the MR URL; detection must pick glab."""
    _write_payload(fake_forge_clis, "glab", OPEN_MR_JSON)
    repo = _make_repo(tmp_path, remote="git@gitlab.com:group/sub/repo.git")

    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "pr": MR_URL},
        expect=200,
    ).json()
    assert r["provider"] == "gitlab", f"got: {r!r}"
    assert r["title"] == "Add GitLab support", f"got: {r!r}"


def test_the_origin_remote_selects_glab_with_no_params_at_all(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    """The board-badge path calls this with only `path` + a branch name."""
    _write_payload(fake_forge_clis, "glab", OPEN_MR_JSON)
    # scp-style remote: the shape a real GitLab clone has.
    repo = _make_repo(tmp_path, remote="git@gitlab.com:group/sub/repo.git")

    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "pr": "worktree/gitlab-support"},
        expect=200,
    ).json()
    assert r["provider"] == "gitlab", f"got: {r!r}"


def test_github_status_still_reports_provider_github(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    """GitLab support must not regress GitHub."""
    _write_payload(fake_forge_clis, "gh", OPEN_PR_JSON)
    repo = _make_repo(tmp_path, remote="git@github.com:acme/app.git")

    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "provider": "github"},
        expect=200,
    ).json()
    assert r["provider"] == "github", f"got: {r!r}"
    assert r["status"] == "open", f"got: {r!r}"
    assert r["number"] == 42, f"got: {r!r}"
    assert r["pr_url"] == PR_URL, f"got: {r!r}"


def test_generic_provider_is_rejected_with_a_reason(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    """`generic` has no forge CLI, so status cannot answer — and must say so."""
    repo = _make_repo(tmp_path)

    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "provider": "generic"},
        expect=502,
    ).json()
    assert "forge CLI" in r["error"], f"got: {r!r}"


def test_a_missing_glab_is_reported_as_glab_not_gh(
    harness: FunctionalHarness, tmp_path: Path, monkeypatch
) -> None:
    """A GitLab user with no glab must not be told to install gh."""
    # Remove the fake glab for this test only, keeping gh on PATH.
    bin_dir = Path(os.environ["PATH"].split(os.pathsep)[0])
    for name in ("gh", "glab"):
        p = bin_dir / name
        if p.exists():
            p.unlink()
    repo = _make_repo(tmp_path, remote="git@gitlab.com:group/sub/repo.git")

    r = harness.http(
        "GET",
        "/api/git/pr/status",
        params={"path": str(repo), "provider": "gitlab"},
        expect=422,
    ).json()
    assert "glab" in r["error"], f"must name glab: {r!r}"
    assert "gh CLI" not in r["error"], f"must not blame gh: {r!r}"


# ── POST /api/git/pr ──────────────────────────────────────────────────────


def test_create_accepts_a_provider_and_returns_it(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    """POST /api/git/pr must honour `provider` and echo it back.

    This is the test that caught the real bug: with `gh` hardcoded as the
    program for every provider, this returned
    `unknown command "mr" for "gh"`.
    """
    # glab prints a banner before the link, exactly like the real CLI.
    _write_payload(
        fake_forge_clis,
        "glab",
        "Creating merge request for worktree/gitlab-support on gitlab.com\n\n"
        f"{MR_URL}\n",
    )
    repo = _make_repo(tmp_path, remote="git@gitlab.com:group/sub/repo.git")

    r = harness.http(
        "POST",
        "/api/git/pr",
        json_body={
            "worktree_path": str(repo),
            "base": "main",
            "title": "Add GitLab support",
            "body": "body",
            "provider": "gitlab",
        },
        expect=200,
    ).json()
    assert r["success"] is True, f"got: {r!r}"
    assert r["provider"] == "gitlab", f"got: {r!r}"
    # The banner must not leak into pr_url, or the frontend hands a
    # non-URL to set_pull_request, which rejects it as unparseable.
    assert r["pr_url"] == MR_URL, f"banner leaked into pr_url: {r!r}"


def test_create_rejects_an_unknown_provider(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    repo = _make_repo(tmp_path)
    r = harness.http(
        "POST",
        "/api/git/pr",
        json_body={
            "worktree_path": str(repo),
            "base": "main",
            "title": "T",
            "body": "",
            "provider": "bitbucket",
        },
        expect=400,
    ).json()
    assert "provider" in r["error"], f"got: {r!r}"


def test_github_create_is_unchanged(
    harness: FunctionalHarness, fake_forge_clis: Path, tmp_path: Path
) -> None:
    """The pre-existing GitHub create path must not regress."""
    _write_payload(fake_forge_clis, "gh", f"{PR_URL}\n")
    repo = _make_repo(tmp_path, remote="git@github.com:acme/app.git")

    r = harness.http(
        "POST",
        "/api/git/pr",
        json_body={
            "worktree_path": str(repo),
            "base": "main",
            "title": "T",
            "body": "B",
            "provider": "github",
        },
        expect=200,
    ).json()
    assert r["success"] is True, f"got: {r!r}"
    assert r["provider"] == "github", f"got: {r!r}"
    assert r["pr_url"] == PR_URL, f"got: {r!r}"
