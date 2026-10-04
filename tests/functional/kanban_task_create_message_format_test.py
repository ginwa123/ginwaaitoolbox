"""Functional tests for the kanban create_and_run message format.

The frontend (KanbanView.handleCreateTaskSave via buildTaskCreateMessage)
formats the create_and_run `queue_message` as:

    Task : <name>
    Description: <description>   <- omitted when empty/whitespace
                                   <- blank line +
    #Notes UseGitWorktree         <- only when the worktree toggle is ON
    Path: <worktreePath>          <- only when the toggle is ON and a
                                     custom path was entered
    Base: <baseBranch>            <- only when the toggle is ON and a base
                                     ref was picked (e.g. origin/main)

The backend passes `queue_message` through verbatim (emit_run_agent →
insertQueueMessage → queue-drain → llm_history user row), so these tests
replay the EXACT wire body the frontend sends and assert the drained
user-role row matches byte-for-byte.

A 4th test locks the create_session scope limit: plain "Create task"
still uses the server-side `name + "\\n\\n" + description` composition
(frontend-only change — the card display shares the description field).

The trailing tests cover `GET /api/git/branches` — the endpoint feeding
the base-branch dropdown — against a throwaway repo created inside the
harness tmpdir. They exist because route order + response JSON shape are
exactly the class of bug a unit test cannot see.

We use the plain `harness` fixture (no stub LLM needed): the worker
drains the queue into the user-role llm_history row BEFORE any LLM
call, so polling for that row works even though the subsequent LLM
turn fails against the isolated tmpdir HOME.
"""

from __future__ import annotations

import subprocess
import time
from pathlib import Path
from typing import Any, Iterator

import pytest

from harness import FunctionalHarness


@pytest.fixture
def worker_harness() -> Iterator[FunctionalHarness]:
    """Own boot with a stub LLM profile so create_and_run workers drain.

    The shared `harness` fixture boots without any LLM profile, so a
    create_and_run worker never starts and the queue never drains.
    With `stub_llm_profile=True` the worker starts, drains the queued
    user message into llm_history, then fails on the stubbed LLM call
    — the user row persists, which is all these tests assert.
    """
    h = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        yield h
    finally:
        h.teardown()


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness) -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": "kanban-fmt-ws"}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": "sprint-fmt"},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
    description: str,
    mode: str,
    queue_message: str | None = None,
) -> dict[str, Any]:
    """POST the exact wire body the frontend sends for each mode."""
    body: dict[str, Any] = {"mode": mode, "name": name, "description": description}
    if queue_message is not None:
        body["queue_message"] = queue_message
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _user_role_messages(harness: FunctionalHarness, session_id: str) -> list[dict[str, Any]]:
    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/messages",
        params={"sort_by": "created_at", "direction": "asc", "limit": 100},
        expect=200,
    )
    msgs = r.json().get("messages")
    assert isinstance(msgs, list), f"expected messages list, got: {r.json()!r}"
    return [m for m in msgs if m.get("role") == "user"]


def _wait_for_user_message(
    harness: FunctionalHarness, session_id: str, timeout_s: float = 20.0
) -> list[dict[str, Any]]:
    """Poll until the queue-drained user row lands (create_and_run is async)."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        msgs = _user_role_messages(harness, session_id)
        if msgs:
            return msgs
        time.sleep(0.2)
    raise AssertionError(f"no user-role row drained within {timeout_s}s for {session_id}")


# ─── Test 1: name + description, toggle OFF ─────────────────────────────────


def test_create_and_run_formats_task_and_description(worker_harness: FunctionalHarness) -> None:
    """queue_message `Task : <name>\\nDescription: <desc>` drains verbatim."""
    ws_id = _create_workspace(worker_harness)
    kanban_id = _create_kanban(worker_harness, ws_id)

    resp = _create_task(
        worker_harness,
        ws_id,
        kanban_id,
        name="Fix login",
        description="blablabla",
        mode="create_and_run",
        queue_message="Task : Fix login\nDescription: blablabla",
    )
    task_id = resp["task"]["id"]

    msgs = _wait_for_user_message(worker_harness, task_id)
    assert msgs[0].get("content") == "Task : Fix login\nDescription: blablabla"


# ─── Test 2: name only, toggle OFF — no Description line ────────────────────


def test_create_and_run_omits_description_line_when_empty(
    worker_harness: FunctionalHarness,
) -> None:
    ws_id = _create_workspace(worker_harness)
    kanban_id = _create_kanban(worker_harness, ws_id)

    resp = _create_task(
        worker_harness,
        ws_id,
        kanban_id,
        name="Title-only task",
        description="",
        mode="create_and_run",
        queue_message="Task : Title-only task",
    )
    task_id = resp["task"]["id"]

    msgs = _wait_for_user_message(worker_harness, task_id)
    content = msgs[0].get("content")
    assert content == "Task : Title-only task", f"unexpected content: {content!r}"
    assert "Description" not in content


# ─── Test 3: toggle ON appends the worktree note ────────────────────────────


def test_create_and_run_appends_worktree_note_when_toggled(
    worker_harness: FunctionalHarness,
) -> None:
    ws_id = _create_workspace(worker_harness)
    kanban_id = _create_kanban(worker_harness, ws_id)

    resp = _create_task(
        worker_harness,
        ws_id,
        kanban_id,
        name="Isolated work",
        description="blablabla",
        mode="create_and_run",
        queue_message="Task : Isolated work\nDescription: blablabla\n\n#Notes UseGitWorktree",
    )
    task_id = resp["task"]["id"]

    msgs = _wait_for_user_message(worker_harness, task_id)
    assert msgs[0].get("content") == (
        "Task : Isolated work\nDescription: blablabla\n\n#Notes UseGitWorktree"
    )


# ─── Test 4: create_session keeps the server-side composition ───────────────


def test_create_session_keeps_server_composition(harness: FunctionalHarness) -> None:
    """Scope lock: plain Create task is untouched by the frontend-only change."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    resp = _create_task(
        harness,
        ws_id,
        kanban_id,
        name="Plain task",
        description="plain desc",
        mode="create_session",
    )
    task_id = resp["task"]["id"]

    msgs = _user_role_messages(harness, task_id)
    assert len(msgs) == 1
    assert msgs[0].get("content") == "Plain task\n\nplain desc"


# ─── Test 5: toggle ON + custom path appends the Path line ────────────────────


def test_create_and_run_appends_worktree_path_when_provided(
    worker_harness: FunctionalHarness,
) -> None:
    """The worktree path input lands as the `Path:` line after the note."""
    ws_id = _create_workspace(worker_harness)
    kanban_id = _create_kanban(worker_harness, ws_id)

    resp = _create_task(
        worker_harness,
        ws_id,
        kanban_id,
        name="Isolated work",
        description="blablabla",
        mode="create_and_run",
        queue_message=(
            "Task : Isolated work\nDescription: blablabla\n\n"
            "#Notes UseGitWorktree\nPath: ~/.config/pabrik/.worktrees/isolated-work"
        ),
    )
    task_id = resp["task"]["id"]

    msgs = _wait_for_user_message(worker_harness, task_id)
    assert msgs[0].get("content") == (
        "Task : Isolated work\nDescription: blablabla\n\n"
        "#Notes UseGitWorktree\nPath: ~/.config/pabrik/.worktrees/isolated-work"
    )


# ─── Test 6: toggle ON + path + base branch appends the Base line ─────────────


def test_create_and_run_appends_worktree_base_branch_when_provided(
    worker_harness: FunctionalHarness,
) -> None:
    """The base-branch picker lands as the `Base:` line after `Path:`.

    This is the wire half of the feature: the agent only knows which ref to
    branch the worktree FROM because this line reaches llm_history verbatim.
    """
    ws_id = _create_workspace(worker_harness)
    kanban_id = _create_kanban(worker_harness, ws_id)

    resp = _create_task(
        worker_harness,
        ws_id,
        kanban_id,
        name="Isolated work",
        description="blablabla",
        mode="create_and_run",
        queue_message=(
            "Task : Isolated work\nDescription: blablabla\n\n"
            "#Notes UseGitWorktree\nPath: /home/you/.config/pabrik/.worktrees/x\n"
            "Base: origin/main"
        ),
    )
    task_id = resp["task"]["id"]

    msgs = _wait_for_user_message(worker_harness, task_id)
    assert msgs[0].get("content") == (
        "Task : Isolated work\nDescription: blablabla\n\n"
        "#Notes UseGitWorktree\nPath: /home/you/.config/pabrik/.worktrees/x\n"
        "Base: origin/main"
    )


def test_create_and_run_without_base_keeps_the_old_message_shape(
    worker_harness: FunctionalHarness,
) -> None:
    """Regression guard: no base ref ⇒ byte-identical to the pre-feature form."""
    ws_id = _create_workspace(worker_harness)
    kanban_id = _create_kanban(worker_harness, ws_id)

    resp = _create_task(
        worker_harness,
        ws_id,
        kanban_id,
        name="Isolated work",
        description="blablabla",
        mode="create_and_run",
        queue_message=(
            "Task : Isolated work\nDescription: blablabla\n\n"
            "#Notes UseGitWorktree\nPath: /tmp/wt/x"
        ),
    )
    task_id = resp["task"]["id"]

    msgs = _wait_for_user_message(worker_harness, task_id)
    assert "Base:" not in msgs[0].get("content", "")


# ─── GET /api/git/branches — the dropdown's data source ───────────────────────


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def _make_repo_with_branches(root: Path) -> Path:
    """Create a throwaway repo with one local branch, two remote-tracking
    refs, and a symbolic `origin/HEAD` (the row the parser must drop)."""
    repo = root / "branches-repo"
    repo.mkdir()
    _git(repo, "init", "--initial-branch=main", "--quiet")
    (repo / "a.txt").write_text("a\n", encoding="utf-8")
    _git(repo, "add", "a.txt")
    _git(
        repo,
        "-c",
        "user.email=test@example.com",
        "-c",
        "user.name=Test",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--quiet",
        "-m",
        "init",
    )
    # Fabricate remote-tracking refs — no network, no `origin` remote needed.
    _git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    _git(repo, "update-ref", "refs/remotes/origin/feature-x", "HEAD")
    _git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    _git(repo, "branch", "local-dev")
    return repo


def test_git_branches_lists_refs_in_picker_order(harness: FunctionalHarness) -> None:
    """Default hoisted, then remotes, then locals; symbolic HEAD dropped."""
    repo = _make_repo_with_branches(harness.temp_dir)

    r = harness.http(
        "GET", "/api/git/branches", params={"path": str(repo)}, expect=200
    )
    data = r.json()

    assert data["is_git_repo"] is True
    assert data["current_branch"] == "main"

    names = [b["name"] for b in data["branches"]]
    assert "origin/main" in names
    assert "origin/feature-x" in names
    assert "local-dev" in names
    # The symbolic ref shortens to a bare `origin` — it must never surface
    # as a selectable base branch.
    assert "origin" not in names
    assert "HEAD" not in names
    # Detected default first, then the other remote-tracking ref, then the
    # local branch.
    assert names[0] == "origin/main"

    by_name = {b["name"]: b for b in data["branches"]}
    assert by_name["origin/main"] == {
        "name": "origin/main",
        "is_remote": True,
        "is_current": False,
        "is_default": True,
    }
    assert by_name["origin/feature-x"]["is_remote"] is True
    assert by_name["origin/feature-x"]["is_default"] is False
    assert by_name["local-dev"] == {
        "name": "local-dev",
        "is_remote": False,
        "is_current": False,
        "is_default": False,
    }
    assert by_name["main"]["is_current"] is True


def test_git_branches_404_when_path_is_not_a_repo(harness: FunctionalHarness) -> None:
    plain = harness.temp_dir / "not-a-repo"
    plain.mkdir(parents=True, exist_ok=True)

    r = harness.http("GET", "/api/git/branches", params={"path": str(plain)}, expect=404)
    assert "not a git repository" in r.json().get("error", "")


def test_git_branches_400_when_path_is_missing(harness: FunctionalHarness) -> None:
    r = harness.http("GET", "/api/git/branches", expect=400)
    assert "error" in r.json()


def test_git_branches_400_when_path_is_not_absolute(harness: FunctionalHarness) -> None:
    """`..` traversal and relative paths are rejected before git is spawned."""
    r = harness.http(
        "GET", "/api/git/branches", params={"path": "relative/repo"}, expect=400
    )
    assert "error" in r.json()
