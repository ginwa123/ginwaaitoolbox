"""Functional tests for the create_session user-message fix.

Regression for the bug "create task still not insert user llm history
role" (task_1787213354784_1). Pre-fix, POST
/api/workspaces/:ws/items/:kanban/tasks with `mode='create_session'`
inserted the sessions row but NOT a user-role llm_history row — the
user's typed description was silently dropped, the chatview landed on
an empty session, and the user had no record of what they originally
asked for.

Post-fix, when `mode='create_session'` is used with a non-empty
description, the handler inserts a user-role llm_history row with
content = `name + "\n\n" + description` (mirrors create_and_run's
wire format). Empty descriptions stay on a clean chat — title-only
tasks don't get a stray "name\n\n" bubble.

We use the harness with `stub_llm_profile=True` so the create_and_run
variant of the test doesn't try to call a real LLM (the wire works,
the worker fails silently, we don't care about LLM outcomes).

Plan: docs/superpowers/plans/2026-08-19-kanban-create-task-inits-session.md
Task: task_1787213354784_1
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "kanban-csum-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(
    harness: FunctionalHarness, workspace_id: str, name: str = "sprint-csum"
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_task_via_kanban_endpoint(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
    description: str,
    mode: str,
) -> dict[str, Any]:
    """POST /workspaces/:ws/items/:kanban/kanban/tasks with the given mode.

    Mirrors the frontend's `addKanbanTask(mode, payload)`:
      - mode='create_session'   → plain "Create task" button (the bug)
      - mode='create_and_run'   → "Create task & run agent" button
      - mode='create'           → legacy

    For mode='create_and_run' the backend requires a non-empty
    queue_message (validation lives in kanban_tasks_create.zig:127-135
    — 400 otherwise). The frontend builds this from
    `name + "\n\n" + description` (see KanbanView.handleCreateTaskSave
    line 961-966), so we mirror that contract here.

    Returns the parsed response body: `{ task: {...}, session: {...}? }`.
    """
    body: dict[str, Any] = {
        "mode": mode,
        "name": name,
        "description": description,
    }
    if mode == "create_and_run":
        # The frontend concatenates name + "\n\n" + description into
        # the wire queue_message — same shape the create_session path
        # now persists as the initial user message.
        body["queue_message"] = f"{name}\n\n{description}" if description else name
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _get_session_messages(
    harness: FunctionalHarness, session_id: str
) -> list[dict[str, Any]]:
    """GET /api/llm/session/:id/messages returns the llm_history rows
    (newest first by default; we ask for created_at ASC to mirror the
    chat render order).

    Returns the list of message dicts. Each has at least: id, role,
    content, session_id, created_at.
    """
    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/messages",
        params={"sort_by": "created_at", "direction": "asc", "limit": 100},
        expect=200,
    )
    body = r.json()
    msgs = body.get("messages")
    assert isinstance(msgs, list), f"expected messages list, got: {body!r}"
    return msgs


def _user_role_messages(
    harness: FunctionalHarness, session_id: str
) -> list[dict[str, Any]]:
    """Filter to role='user' rows only (the bug is specifically about
    a missing user-role row)."""
    return [m for m in _get_session_messages(harness, session_id) if m.get("role") == "user"]


# ─── Test 1: create_session WITH description inserts one user-role row ────


def test_create_session_with_description_inserts_user_role_row(
    llm_harness: FunctionalHarness,
) -> None:
    """Regression for task_1787213354784_1.

    When the user clicks the plain "Create task" button (which sends
    mode='create_session' on the wire), the handler must insert a
    user-role llm_history row with content = `name + "\n\n" + description`.
    Pre-fix the row was missing entirely; the chatview landed on an
    empty session and the user's typed description was silently dropped.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    description = "Steps:\n1. Open file\n2. Read code\n3. Find root cause"

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name="Investigate X bug",
        description=description,
        mode="create_session",
    )
    task = resp.get("task")
    assert task is not None, f"create response missing 'task': {resp!r}"
    task_id = task["id"]
    assert task_id.startswith("task_"), f"task id should start with task_, got {task_id!r}"

    # mode='create_session' returns session.status='idle' (vs 'send' for
    # create_and_run — the wire discriminator the frontend uses to
    # distinguish "session exists, no worker" from "session exists,
    # worker started").
    session = resp.get("session")
    assert session is not None, f"create_session response missing 'session': {resp!r}"
    assert session.get("id") == task_id, (
        f"session.id should match task.id (task.id == session.id convention), "
        f"got session.id={session.get('id')!r} vs task.id={task_id!r}"
    )
    assert session.get("status") == "idle", (
        f"create_session should return status='idle' (no agent triggered), "
        f"got {session.get('status')!r}"
    )

    # GET /api/llm/session/:id/messages — the fix's contract is that
    # exactly ONE user-role row exists with content = name\n\ndescription.
    user_msgs = _user_role_messages(llm_harness, task_id)

    assert len(user_msgs) == 1, (
        f"expected exactly 1 user-role llm_history row, got {len(user_msgs)}: "
        f"{user_msgs!r}"
    )

    expected_content = f"Investigate X bug\n\n{description}"
    actual_content = user_msgs[0].get("content")
    assert actual_content == expected_content, (
        f"user-role row content should match wire 'name\\n\\ndescription':\n"
        f"  expected: {expected_content!r}\n"
        f"  actual:   {actual_content!r}"
    )

    # The message must carry the standard llm_history fields — role='user',
    # session_id == task_id (the task.id == session.id convention).
    msg = user_msgs[0]
    assert msg.get("role") == "user"
    assert msg.get("session_id") == task_id


# ─── Test 2: create_session EMPTY description skips the insert ─────────────


def test_create_session_with_empty_description_skips_user_message(
    llm_harness: FunctionalHarness,
) -> None:
    """Title-only tasks (description == '') must NOT get a stray
    'name\n\n' bubble — the chatview should land on a clean empty
    session so the user types the first message.

    The fix has an explicit `if (description.len > 0)` guard. This
    test exercises that guard from the wire: a title-only task with
    no description produces zero user-role llm_history rows.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name="Title-only task",
        description="",
        mode="create_session",
    )
    task_id = resp["task"]["id"]

    # No user message in the chat — clean state for the user to type.
    user_msgs = _user_role_messages(llm_harness, task_id)
    assert len(user_msgs) == 0, (
        f"title-only task should have ZERO user-role rows (gate on "
        f"description.len > 0), got {len(user_msgs)}: {user_msgs!r}"
    )

    # And no assistant/tool rows either — nothing has run yet.
    all_msgs = _get_session_messages(llm_harness, task_id)
    assert len(all_msgs) == 0, (
        f"empty-description create_session should produce NO llm_history "
        f"rows at all, got {len(all_msgs)}: {all_msgs!r}"
    )


# ─── LLM stub fixture (mirror sessions_and_llm_test.py) ────────────────────


@pytest.fixture
def llm_harness(default_nalar_bin: Any) -> Any:
    """A harness booted with the LLM stub profile so create_and_run's
    workflow doesn't try to call a real LLM. The wire works; the LLM
    call fails silently — we don't care about LLM outcomes in this
    suite. We DO care about the user-role row that lands in llm_history
    BEFORE the LLM call fires (that's part of the queue drain in
    agentic_loop/workflow.zig:716-740).
    """
    h = FunctionalHarness.boot(
        default_nalar_bin,
        stub_llm_profile=True,
    )
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass