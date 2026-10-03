"""GET /api/git/pr/conflicts against a real conflicting work tree.

The unit tests in `src/http_handlers/git_pr_conflicts.zig` drive `useCase`
in-process. They cannot see the three things that only exist on the wire:

1. the route is actually registered and reachable under `/api/git/pr/`,
2. the JSON body has the field names the desktop client destructures
   (`conflicting_files`, `count`, `base_ref`, …), and
3. `path` survives URL encoding — repo paths contain slashes and spaces.

So this file builds a repo whose two branches genuinely conflict, boots the
real binary, and asserts the endpoint names the file. Three cases matter and
each has bitten a different implementation:

- a conflict on a *different line* of the same file must NOT be reported
  (git merges those cleanly) — the first draft of the Zig fixture changed
  line 2 on one branch and appended on the other and "passed" while broken;
- a conflicting file outside the PR diff (added on the base side only) must
  still be named — that is exactly the case the client falls back to the
  code editor for;
- a clean branch must answer 200 with an empty list, not an error, because
  the client tells "clean" from "could not determine" by the absence of an
  `error` field.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from harness import FunctionalHarness


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", *args],
        cwd=str(cwd),
        check=True,
        timeout=30,
    )


@pytest.fixture
def conflicting_repo(tmp_path: Path) -> Path:
    """Two branches that conflict in two different ways, plus two that do not.

    - `shared.txt` line 2 rewritten differently on each side → content conflict.
    - `doomed.txt` modified on feature, DELETED on main → modify/delete
      conflict. A file added on one side only (`base_added.txt` in the first
      draft of this fixture) merges cleanly and must NOT be named — that is
      the mistake this fixture exists to prevent.
    - `feature_added.txt` (feature only) and `clean.txt` (rewritten on one
      side only) merge cleanly too, so naming either means the parser leaked
      git's informational section into the answer.
    """
    cwd = tmp_path / "conflict-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / "shared.txt").write_text("a\nb\nc\n")
    (cwd / "doomed.txt").write_text("one\n")
    (cwd / "clean.txt").write_text("same\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "base")

    _git(cwd, "checkout", "--quiet", "-b", "feature")
    (cwd / "shared.txt").write_text("a\nFEATURE\nc\n")
    (cwd / "doomed.txt").write_text("two\n")
    (cwd / "feature_added.txt").write_text("only on the feature branch\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "feature change")

    _git(cwd, "checkout", "--quiet", "main")
    (cwd / "shared.txt").write_text("a\nMAIN\nc\n")
    _git(cwd, "rm", "--quiet", "doomed.txt")
    (cwd / "clean.txt").write_text("moved\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "main change")

    _git(cwd, "checkout", "--quiet", "feature")
    return cwd


PR_URL = "https://github.com/acme/app/pull/4242"


def test_conflicting_files_are_named_on_the_wire(
    conflicting_repo: Path, default_nalar_bin: Path
) -> None:
    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h.http(
            "GET",
            "/api/git/pr/conflicts",
            params={"path": str(conflicting_repo), "pr_url": PR_URL, "provider": "github"},
            expect=200,
            timeout_s=30.0,
        ).json()
    finally:
        h.teardown()

    # git sorts the conflicted-file section; assert on the set plus the count
    # so an added spurious entry fails on content and not on ordering.
    assert set(body["conflicting_files"]) == {"shared.txt", "doomed.txt"}, body
    assert "clean.txt" not in body["conflicting_files"], body
    assert "feature_added.txt" not in body["conflicting_files"], body
    assert body["count"] == len(body["conflicting_files"]), body
    assert body["truncated"] is False, body
    # Provenance: the client renders this next to an empty list, so it must be
    # present and must be the ref we actually merged against.
    assert body["base_ref"] == "main", body
    assert len(body["base_commit"]) >= 7, body
    assert body["pr_url"] == PR_URL, body


def test_path_with_spaces_survives_url_encoding(
    tmp_path: Path, default_nalar_bin: Path
) -> None:
    """Repo paths carry spaces; `%20` in the query must decode to one path."""
    cwd = tmp_path / "a repo with spaces"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / "f.txt").write_text("base\n")
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "base")

    # BOTH sides must rewrite the same line, or git merges this cleanly and
    # the endpoint is right to answer with an empty list.
    _git(cwd, "checkout", "--quiet", "-b", "feature")
    (cwd / "f.txt").write_text("feature\n")
    _git(cwd, "commit", "--quiet", "-am", "feature change")
    _git(cwd, "checkout", "--quiet", "main")
    (cwd / "f.txt").write_text("main\n")
    _git(cwd, "commit", "--quiet", "-am", "main change")
    _git(cwd, "checkout", "--quiet", "feature")

    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h.http(
            "GET",
            "/api/git/pr/conflicts",
            params={"path": str(cwd), "pr_url": PR_URL},
            expect=200,
            timeout_s=30.0,
        ).json()
    finally:
        h.teardown()

    assert body["conflicting_files"] == ["f.txt"], body


def test_clean_merge_is_an_empty_list_not_an_error(
    conflicting_repo: Path, default_nalar_bin: Path
) -> None:
    """A 200 with `conflicting_files: []` is the 'clean' answer.

    The client distinguishes it from a failure by the absence of `error`, so
    this case must not degrade into a 4xx/5xx. Detaching HEAD at the branch
    point makes every one of the changes one-sided, so the merge is clean.
    """
    _git(conflicting_repo, "checkout", "--quiet", "--detach", "main~1")

    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h.http(
            "GET",
            "/api/git/pr/conflicts",
            params={"path": str(conflicting_repo), "pr_url": PR_URL},
            expect=200,
            timeout_s=30.0,
        ).json()
    finally:
        h.teardown()

    assert body["conflicting_files"] == [], body
    assert body["count"] == 0, body
    assert "error" not in body, body


def test_missing_parameters_and_bad_provider_are_rejected(
    conflicting_repo: Path, default_nalar_bin: Path
) -> None:
    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        missing_path = h.http(
            "GET", "/api/git/pr/conflicts", params={"pr_url": PR_URL}, expect=400, timeout_s=15.0
        ).json()
        missing_url = h.http(
            "GET",
            "/api/git/pr/conflicts",
            params={"path": str(conflicting_repo)},
            expect=400,
            timeout_s=15.0,
        ).json()
        bad_provider = h.http(
            "GET",
            "/api/git/pr/conflicts",
            params={"path": str(conflicting_repo), "pr_url": PR_URL, "provider": "bitbucket"},
            expect=400,
            timeout_s=15.0,
        ).json()
        not_a_repo = h.http(
            "GET",
            "/api/git/pr/conflicts",
            params={"path": str(conflicting_repo / ".." / ".."), "pr_url": PR_URL},
            expect=404,
            timeout_s=15.0,
        ).json()
        no_such_base = h.http(
            "GET",
            "/api/git/pr/conflicts",
            params={"path": str(conflicting_repo), "pr_url": PR_URL, "base": "no-such-branch"},
            expect=422,
            timeout_s=15.0,
        ).json()
    finally:
        h.teardown()

    assert "path" in missing_path["error"], missing_path
    assert "pr_url" in missing_url["error"], missing_url
    assert "provider" in bad_provider["error"], bad_provider
    assert not_a_repo["error"] == "not a git repository", not_a_repo
    # 422, not 502: the caller can fix this by fetching, so say what to do.
    assert "git fetch" in no_such_base["error"], no_such_base
