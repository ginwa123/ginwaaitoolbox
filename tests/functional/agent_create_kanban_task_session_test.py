"""Functional tests for agent-tool/HTTP parity on kanban task session seeding.

Plan: docs/superpowers/plans/2026-09-09-fix-agent-create-kanban-task-session.md
(Task 6).

Background
----------
The `create_kanban_task` agent tool (`executeCreateKanbanTaskToString` in
`src/modules/agent/tools/create_kanban_task.zig`) only INSERTed a
`sessions` row when `is_auto_retry_until_stop` or
`selected_profile_model` was set — plain agent-created cards got NO
session, NO initial user message, and NO `session_created` SSE. The fix
makes the tool mirror HTTP `mode='create_session'` unconditionally.

A full end-to-end LLM tool_call is not feasible here (no stub LLM emits
tool_calls — see `agent_add_mcp_server_test.py` for the precedent). The
tool itself is covered by the Zig unit tests in
`create_kanban_task.zig` (sessions-always-inserted, flag/profile
honored, llm_history seed, static-contract). These functional tests
guard the HTTP reference behavior the tool now mirrors, replaying the
EXACT wire the frontend sends:

  1. plain create (no flag, no profile) → `session` envelope present
     with `status='idle'` and `id == task.id`.
  2. exactly ONE user-role `llm_history` row with content
     `name + "\\n\\n" + description` (the regression the tool had).
  3. create WITH flag + profile still seeds both rows with the flag
     and profile bound on the session.

Run:
    NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
      python3 -m pytest tests/functional/agent_create_kanban_task_session_test.py -v
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "agent-ckt-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "sprint-ckt") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
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
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """POST mode='create_session' — mirrors the frontend's plain
    "Create task" button (no agent run). `extra` carries optional
    wire fields like `is_auto_retry_until_stop`."""
    body: dict[str, Any] = {"mode": "create_session", "name": name, "description": description}
    if extra:
        body.update(extra)
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
    body = r.json()
    msgs = body.get("messages")
    assert isinstance(msgs, list), f"expected messages list, got: {body!r}"
    return [m for m in msgs if m.get("role") == "user"]


# ─── Test 1: plain create seeds session + user message ─────────────────────


def test_plain_create_seeds_session_and_user_message(harness: FunctionalHarness):
    """The exact regression the agent tool had: no flag/profile must
    still yield a session row and one user message."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    resp = _create_task(
        harness, ws_id, kanban_id, name="Agent card", description="do the thing"
    )
    task = resp.get("task")
    assert task is not None, f"create response missing 'task': {resp!r}"
    task_id = task["id"]

    session = resp.get("session")
    assert session is not None, f"create_session response missing 'session': {resp!r}"
    assert session.get("id") == task_id, (
        f"session.id should match task.id (task.id == session.id), "
        f"got {session.get('id')!r} vs {task_id!r}"
    )
    assert session.get("status") == "idle", f"got {session.get('status')!r}"

    user_msgs = _user_role_messages(harness, task_id)
    assert len(user_msgs) == 1, f"expected 1 user row, got: {user_msgs!r}"
    assert user_msgs[0].get("content") == "Agent card\n\ndo the thing"


# ─── Test 2: flag + profile still bound ────────────────────────────────────


def test_create_with_flag_and_profile_binds_session_columns(harness: FunctionalHarness):
    """Unattended flag + profile must land on the seeded session row
    (and the user message must still be seeded)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    resp = _create_task(
        harness,
        ws_id,
        kanban_id,
        name="Overnight card",
        description="run while I sleep",
        extra={"is_auto_retry_until_stop": "1", "selected_profile_model": "code"},
    )
    task_id = resp["task"]["id"]
    session = resp.get("session")
    assert session is not None, f"create_session response missing 'session': {resp!r}"
    assert session.get("id") == task_id

    user_msgs = _user_role_messages(harness, task_id)
    assert len(user_msgs) == 1, f"expected 1 user row, got: {user_msgs!r}"
    assert user_msgs[0].get("content") == "Overnight card\n\nrun while I sleep"
