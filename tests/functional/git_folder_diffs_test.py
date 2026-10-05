"""FOLDER mode of POST /api/git/file/diffs — one call for a whole folder.

LIST mode (covered by git_file_diffs_test.py) still needs the caller to fetch
`GET /api/git/changes` first and then post the file list. FOLDER mode drops
that round trip: the client sends a folder and the server enumerates the
changed paths itself, so a panel can render 50 changed files with ONE request
instead of 50 `GET /api/git/file/diff` calls.

Fixture repo (under pytest tmp_path, NOT the harness HOME):
  <cwd>/src/committed.txt   committed, then modified  → unstaged
  <cwd>/src/staged.txt      committed, modified, added → staged
  <cwd>/src/fresh.txt       untracked INSIDE src/     → synthetic new-file diff
  <cwd>/docs/readme.txt     committed, then modified  → unstaged, OUTSIDE src/
  <cwd>/top.txt             committed, then modified  → unstaged, at the root
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
def folder_cwd(tmp_path: Path) -> Path:
    cwd = tmp_path / "folder-diff-proj"
    (cwd / "src").mkdir(parents=True)
    (cwd / "docs").mkdir(parents=True)
    (cwd / "clean").mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    for rel, body in (
        ("src/committed.txt", "keep\nold\n"),
        ("src/staged.txt", "keep\nold\n"),
        ("docs/readme.txt", "keep\nold\n"),
        ("top.txt", "keep\nold\n"),
        ("clean/untouched.txt", "never touched\n"),
    ):
        (cwd / rel).write_text(body)
    _git(cwd, "add", "-A")
    _git(cwd, "commit", "--quiet", "-m", "base")
    (cwd / "src/committed.txt").write_text("keep\nnew\n")
    (cwd / "src/staged.txt").write_text("keep\nnew\n")
    _git(cwd, "add", "src/staged.txt")
    (cwd / "docs/readme.txt").write_text("keep\nnew\n")
    (cwd / "top.txt").write_text("keep\nnew\n")
    (cwd / "src/fresh.txt").write_text("brand new\n")
    return cwd


def _folder_diffs(harness: FunctionalHarness, cwd: Path, folder: str) -> list[dict]:
    body = harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={"path": str(cwd), "folder": folder},
        expect=200,
        timeout_s=30.0,
    ).json()
    return body["diffs"]


def test_folder_mode_returns_every_changed_file_under_the_folder_in_one_call(
    harness: FunctionalHarness, folder_cwd: Path
) -> None:
    """ONE POST on `folder: "src"` returns staged + unstaged + untracked."""
    diffs = _folder_diffs(harness, folder_cwd, "src")
    by_key = {(d["staged"], d["path"]): d["diff_content"] for d in diffs}

    # The two sides the caller would otherwise have had to enumerate itself.
    assert (False, "src/committed.txt") in by_key, by_key.keys()
    assert (True, "src/staged.txt") in by_key, by_key.keys()
    # Untracked under src/ — git diff shows nothing, so this only works if the
    # server enumerated the path and fell back to the synthetic new-file diff.
    assert (False, "src/fresh.txt") in by_key, by_key.keys()

    assert "+new" in by_key[(False, "src/committed.txt")]
    assert "+new" in by_key[(True, "src/staged.txt")]
    assert "+brand new" in by_key[(False, "src/fresh.txt")]


def test_folder_mode_excludes_files_outside_the_folder(
    harness: FunctionalHarness, folder_cwd: Path
) -> None:
    """`folder: "src"` must not leak sibling or root-level changes."""
    paths = {d["path"] for d in _folder_diffs(harness, folder_cwd, "src")}
    assert paths == {"src/committed.txt", "src/staged.txt", "src/fresh.txt"}


def test_empty_folder_string_means_the_whole_repo(
    harness: FunctionalHarness, folder_cwd: Path
) -> None:
    """`folder: ""` is the whole repo, and reaches docs/ and the root."""
    paths = {d["path"] for d in _folder_diffs(harness, folder_cwd, "")}
    assert paths == {
        "src/committed.txt",
        "src/staged.txt",
        "src/fresh.txt",
        "docs/readme.txt",
        "top.txt",
    }


def test_clean_folder_is_an_empty_list_not_a_400(
    harness: FunctionalHarness, folder_cwd: Path
) -> None:
    """A folder with no changes is a real answer. A 400 would push the client
    into its per-file fallback and restart the request flood."""
    diffs = _folder_diffs(harness, folder_cwd, "clean")
    assert diffs == []


def test_folder_mode_matches_list_mode_content(harness: FunctionalHarness, folder_cwd: Path) -> None:
    """The same file through both modes must produce byte-identical content."""
    folder_diffs = {
        d["path"]: d["diff_content"]
        for d in _folder_diffs(harness, folder_cwd, "")
        if not d["staged"]
    }
    list_diffs = harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={
            "path": str(folder_cwd),
            "files": [
                {"file": "src/committed.txt", "staged": False},
                {"file": "docs/readme.txt", "staged": False},
                {"file": "top.txt", "staged": False},
            ],
        },
        expect=200,
        timeout_s=30.0,
    ).json()["diffs"]
    for d in list_diffs:
        assert d["diff_content"] == folder_diffs[d["path"]]


def test_folder_mode_rejects_a_parent_escaping_path(
    harness: FunctionalHarness, folder_cwd: Path
) -> None:
    """`folder` becomes a git pathspec; `..` would diff outside the repo."""
    harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={"path": str(folder_cwd), "folder": "../.."},
        expect=400,
        timeout_s=15.0,
    )
    harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={"path": str(folder_cwd), "folder": "/etc"},
        expect=400,
        timeout_s=15.0,
    )


def test_sending_neither_files_nor_folder_is_a_400(
    harness: FunctionalHarness, folder_cwd: Path
) -> None:
    harness.http(
        "POST",
        "/api/git/file/diffs",
        json_body={"path": str(folder_cwd)},
        expect=400,
        timeout_s=15.0,
    )