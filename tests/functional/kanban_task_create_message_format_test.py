"""Functional tests for the kanban create_and_run message format.

The frontend (KanbanView.handleCreateTaskSave via buildTaskCreateMessage)
formats the create_and_run `queue_message` as:

    Task : <name>
    Description: <description>   <- omitted when empty/whitespace
                                   <- blank line +
    #Notes UseGitWorktree         <- only when the worktree toggle is ON

The backend passes `queue_message` through verbatim (emit_run_agent →
insertQueueMessage → queue-drain → llm_history user row), so these tests
replay the EXACT wire body the frontend sends and assert the drained
user-role row matches byte-for-byte.

A 4th test locks the create_session scope limit: plain "Create task"
still uses the server-side `name + "\\n\\n" + description` composition
(frontend-only change — the card display shares the description field).

We use the plain `harness` fixture (no stub LLM needed): the worker
drains the queue into the user-role llm_history row BEFORE any LLM
call, so polling for that row works even though the subsequent LLM
turn fails against the isolated tmpdir HOME.
"""

from __future__ import annotations

import time
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
