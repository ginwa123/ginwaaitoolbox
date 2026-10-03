"""Functional wire tests for GET /api/git/pr/checks.

The endpoint the Checks tab reads (`gh pr checks` + `gh run view`):

  1. Missing path → 400 (route is registered, validator runs).
  2. Unknown provider → 400 (strict validator).
  3. Non-repo path → 404 (not shadowing, real handler answer).
  4. gitlab → 422, NOT 200-with-zero-checks. A CI panel that answers
     "0 checks" for an unsupported forge reads as "everything passed",
     which is the one answer it must never invent.
  5. Happy path via a fake `gh` on PATH → 200, with the failing job's
     STEPS attached. The steps are the feature; a wire test that only
     proves the job rows would miss the whole point.
  6. `gh pr checks` exiting non-zero with "no checks reported" → 200
     with an empty list, not a 502.
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
    cwd = tmp_path / "pr-checks-proj"
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


def _write_fake_gh(bindir: Path, script: str) -> None:
    bindir.mkdir(parents=True, exist_ok=True)
    fake = bindir / "gh"
    fake.write_text(script)
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)


def test_missing_path_is_400(harness: FunctionalHarness) -> None:
    r = harness.http("GET", "/api/git/pr/checks", expect=400).json()
    assert "error" in r, f"got: {r!r}"


def test_unknown_provider_is_400(harness: FunctionalHarness, repo: Path) -> None:
    r = harness.http(
        "GET",
        "/api/git/pr/checks",
        params={"path": str(repo), "provider": "bitbucket"},
        expect=400,
    ).json()
    assert "error" in r, f"got: {r!r}"


def test_non_repo_is_404(harness: FunctionalHarness, tmp_path: Path) -> None:
    plain = tmp_path / "plain"
    plain.mkdir()
    r = harness.http(
        "GET",
        "/api/git/pr/checks",
        params={"path": str(plain), "pr": "42"},
        expect=404,
    ).json()
    assert "error" in r, f"got: {r!r}"


def test_gitlab_is_422_not_an_empty_200(
    harness: FunctionalHarness, repo: Path
) -> None:
    """`glab` has no `mr checks`. Answering 200 with zero rows would let
    the panel claim a merge request passed CI that never ran."""
    r = harness.http(
        "GET",
        "/api/git/pr/checks",
        params={"path": str(repo), "pr": "42", "provider": "gitlab"},
        expect=422,
    ).json()
    assert "github" in r["error"].lower(), f"got: {r!r}"


CHECKS_ROWS = [
    {
        "bucket": "fail",
        "name": "backend (Windows X64) / build",
        "state": "FAILURE",
        "link": "https://github.com/acme/app/actions/runs/37146940187/job/111273396968",
        "workflow": "ci",
        "startedAt": "2026-10-03T19:14:22Z",
        "completedAt": "2026-10-03T19:31:22Z",
    },
    {
        "bucket": "pass",
        "name": "path filter",
        "state": "SUCCESS",
        "link": "https://github.com/acme/app/actions/runs/37146940187/job/111272741668",
        "workflow": "ci",
        "startedAt": "2026-10-03T19:11:04Z",
        "completedAt": "2026-10-03T19:11:11Z",
    },
]

RUN_JOBS = {
    "jobs": [
        {
            "databaseId": 111273396968,
            "name": "backend (Windows X64) / build",
            "conclusion": "failure",
            "steps": [
                {
                    "name": "Set up job",
                    "number": 1,
                    "conclusion": "success",
                    "status": "completed",
                    "startedAt": "2026-10-03T19:14:23Z",
                    "completedAt": "2026-10-03T19:14:24Z",
                },
                {
                    "name": "zig build test",
                    "number": 3,
                    "conclusion": "failure",
                    "status": "completed",
                    "startedAt": "2026-10-03T19:15:00Z",
                    "completedAt": "2026-10-03T19:31:22Z",
                },
            ],
        },
        {
            "databaseId": 111272741668,
            "name": "path filter",
            "conclusion": "success",
            "steps": [],
        },
    ]
}


def test_failed_job_carries_its_steps(
    repo: Path, tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """The whole point of the endpoint: which PROCESS failed, not just
    which job. A wire test asserting only the job rows would pass even
    if the `gh run view` hop were dropped."""
    bindir = tmp_path / "fakebin-steps"
    # `gh pr checks …` → the job rows. `gh run view …` → the step lists.
    script = (
        "#!/bin/sh\n"
        'case "$1 $2" in\n'
        '  "pr checks") cat <<\'EOF\'\n' + json.dumps(CHECKS_ROWS) + "\nEOF\n    ;;\n"
        '  "run view") cat <<\'EOF\'\n' + json.dumps(RUN_JOBS) + "\nEOF\n    ;;\n"
        "  *) echo \"unexpected argv: $*\" >&2; exit 1 ;;\n"
        "esac\n"
    )
    _write_fake_gh(bindir, script)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h2 = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/checks",
            params={"path": str(repo), "pr": "42"},
            expect=200,
            timeout_s=20.0,
        ).json()
    finally:
        h2.teardown()

    assert body["provider"] == "github"
    assert body["summary"] == {
        "total": 2,
        "passed": 1,
        "failed": 1,
        "pending": 0,
        "skipped": 0,
        "cancelled": 0,
    }
    assert body["steps_truncated"] is False

    by_name = {c["name"]: c for c in body["checks"]}
    failed = by_name["backend (Windows X64) / build"]
    assert failed["bucket"] == "fail"
    assert failed["steps_error"] == ""
    assert [s["name"] for s in failed["steps"]] == ["Set up job", "zig build test"]
    assert failed["steps"][1]["conclusion"] == "failure"

    # A passing job is not drilled into — its steps would be noise.
    assert by_name["path filter"]["steps"] == []


def test_no_checks_reported_is_200_with_an_empty_list(
    repo: Path, tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """`gh pr checks` exits 1 with "no checks reported" on stderr for a
    PR that never ran CI. That is an answer, not a failure — a 502 here
    would paint every brand-new PR red."""
    bindir = tmp_path / "fakebin-none"
    script = (
        "#!/bin/sh\n"
        "echo \"no checks reported on the 'main' branch\" >&2\n"
        "exit 1\n"
    )
    _write_fake_gh(bindir, script)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h2 = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/checks",
            params={"path": str(repo), "pr": "42"},
            expect=200,
            timeout_s=20.0,
        ).json()
    finally:
        h2.teardown()

    assert body["checks"] == []
    assert body["summary"]["total"] == 0


def test_pending_checks_exit_code_8_is_still_200(
    repo: Path, tmp_path: Path, monkeypatch, default_nalar_bin: Path
) -> None:
    """`gh pr checks` exits 8 ("checks pending") WITH a valid payload on
    stdout. Branching on the exit code would 502 the panel for every
    in-flight PR — which is most of them, most of the time."""
    bindir = tmp_path / "fakebin-pending"
    rows = [
        {
            "bucket": "pending",
            "name": "backend (Linux X64) / build",
            "state": "IN_PROGRESS",
            "link": "https://github.com/acme/app/actions/runs/1/job/2",
            "workflow": "ci",
            "startedAt": "2026-10-03T19:14:22Z",
            "completedAt": "0001-01-01T00:00:00Z",
        }
    ]
    script = (
        "#!/bin/sh\ncat <<'EOF'\n" + json.dumps(rows) + "\nEOF\nexit 8\n"
    )
    _write_fake_gh(bindir, script)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])

    h2 = FunctionalHarness.boot(default_nalar_bin)
    try:
        body = h2.http(
            "GET",
            "/api/git/pr/checks",
            params={"path": str(repo), "pr": "42"},
            expect=200,
            timeout_s=20.0,
        ).json()
    finally:
        h2.teardown()

    assert body["summary"]["pending"] == 1
    # gh's zero-time must not reach the wire as year 1.
    assert body["checks"][0]["completed_at"] == ""
