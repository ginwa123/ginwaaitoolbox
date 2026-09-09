"""Functional wire tests for .gitignore filtering on GET /api/system/folder.

Regression guard for the macOS perf fix (worktree/fix-macos-folder-search):
`searchFiles` + `listDirectory` batch `git check-ignore` to ONE spawn per
directory (was: one spawn per entry). These tests prove the batched form
still respects real .gitignore rules over the HTTP wire:

  1. action=search excludes gitignored files/dirs, keeps visible ones.
  2. action=list excludes gitignored entries (same batch helper).

Fixture cwd (under pytest tmp_path, NOT the harness HOME):
  <cwd>/.git/               (git init — makes check-ignore evaluate rules)
  <cwd>/.gitignore          (*.log + ignored_dir/)
  <cwd>/visible.txt         (must surface)
  <cwd>/debug.log           (ignored via *.log — must NOT surface)
  <cwd>/ignored_dir/secret.txt  (ignored via dir rule — must NOT surface)
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from harness import FunctionalHarness


@pytest.fixture
def gitignore_cwd(tmp_path: Path) -> Path:
    cwd = tmp_path / "gitignore-proj"
    cwd.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--initial-branch=main", "--quiet", str(cwd)],
        check=True,
        timeout=30,
    )
    (cwd / ".gitignore").write_text("*.log\nignored_dir/\n")
    (cwd / "visible.txt").write_text("visible\n")
    (cwd / "debug.log").write_text("ignored via *.log\n")
    ignored_dir = cwd / "ignored_dir"
    ignored_dir.mkdir()
    (ignored_dir / "secret.txt").write_text("ignored via dir rule\n")
    return cwd


def test_search_respects_gitignore_rules(
    harness: FunctionalHarness, gitignore_cwd: Path
) -> None:
    """Batched check-ignore still filters *.log + ignored_dir/ on search."""
    r = harness.http(
        "GET",
        "/api/system/folder",
        params={
            "action": "search",
            "path": str(gitignore_cwd),
            "q": "",
            "limit": 50,
        },
        expect=200,
        timeout_s=15.0,
    )
    names = [e["name"] for e in r.json()["entries"]]
    assert "visible.txt" in names, f"visible.txt missing: {names!r}"
    assert "debug.log" not in names, f"*.log rule violated: {names!r}"
    assert "ignored_dir" not in names, f"dir rule violated: {names!r}"
    assert "secret.txt" not in names, f"nested ignored file leaked: {names!r}"


def test_list_respects_gitignore_rules(
    harness: FunctionalHarness, gitignore_cwd: Path
) -> None:
    """Batched check-ignore still filters on single-level list."""
    r = harness.http(
        "GET",
        "/api/system/folder",
        params={"action": "list", "path": str(gitignore_cwd)},
        expect=200,
        timeout_s=15.0,
    )
    names = {e["name"] for e in r.json()["entries"]}
    assert "visible.txt" in names, f"visible.txt missing: {sorted(names)!r}"
    assert "debug.log" not in names, f"*.log rule violated: {sorted(names)!r}"
    assert "ignored_dir" not in names, f"dir rule violated: {sorted(names)!r}"
