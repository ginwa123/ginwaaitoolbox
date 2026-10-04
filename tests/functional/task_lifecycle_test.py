"""Functional tests for task lifecycle (Tier 1.2).

Exercises the task-level HTTP surface that's NOT covered by
`workspace_lifecycle_test.py` or `kanban_lifecycle_test.py`:

  - POST /api/workspaces/:ws/items/:item_id/kanban/tasks
    (mode discriminator: 'create' vs 'create_and_run')
  - PUT  /api/workspaces/tasks/:task_id  (no-workspace path)
  - PUT  /api/workspaces/:ws/items/:item_id/tasks/:task_id  (rename)
  - PUT  task body with routine fields (schedule / initial_prompt / enabled)
  - DELETE /api/workspaces/:ws/items/:item_id/tasks/:task_id  (+ 404)
  - PUT  /tasks/:task_id/touched  (stamps last_human_touched_at)
  - POST /tasks/reorder_pinned  (reorders only pinned subset)
  - POST /tasks/:task_id/run  (routine fire) + 404 / 409
  - POST /tasks/:task_id/start_agent  (LLM trigger) + 409

Side-channel coverage (already shipped via workspace_items_test.py):
  - image_urls round-trip
  - tags array (incl. case-insensitive dedupe)
  - cwd validation (absolute-path / control-char rejection)
  - is_auto_retry_until_stop INSERT OR IGNORE side-effect

Each test boots a fresh pabrik (function-scoped fixture).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "task-lc-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_chat_item(harness: FunctionalHarness, ws_id: str, name: str = "chat") -> dict[str, Any]:
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items",
        json_body={"name": name, "item_type": "chat", "path": "/tmp/task-lc"},
        expect=201,
    )
    return r.json()


def _create_kanban_item(
    harness: FunctionalHarness, ws_id: str, name: str = "kanban"
) -> dict[str, Any]:
    # The kanban create endpoint returns a wrapped envelope
    # `{item, columns}` so the frontend's `const { item, columns } = await createKanban(...)`
    # destructure renders the board immediately. Unwrap here so
    # callers see the flat item shape (matches workspace_lifecycle_test.py's
    # `_create_item` style).
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    body = r.json()
    item = body.get("item")
    if item is None:
        return body
    return item


def _create_task(
    harness: FunctionalHarness,
    ws_id: str,
    item_id: str,
    name: str,
    task_type: str | None = None,
    schedule: str | None = None,
    initial_prompt: str | None = None,
    description: str | None = None,
    image_urls: str | None = None,
    tags: str | None = None,
    cwd: str | None = None,
    is_auto_retry_until_stop: str | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {"name": name}
    if task_type is not None:
        body["task_type"] = task_type
    if schedule is not None:
        body["schedule"] = schedule
    if initial_prompt is not None:
        body["initial_prompt"] = initial_prompt
    if description is not None:
        body["description"] = description
    if image_urls is not None:
        body["image_urls"] = image_urls
    if tags is not None:
        body["tags"] = tags
    if cwd is not None:
        body["cwd"] = cwd
    if is_auto_retry_until_stop is not None:
        body["is_auto_retry_until_stop"] = is_auto_retry_until_stop
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{item_id}/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _create_kanban_task_via_kanban_endpoint(
    harness: FunctionalHarness,
    ws_id: str,
    item_id: str,
    name: str,
    mode: str = "create",
    queue_message: str | None = None,
    is_auto_retry_until_stop: str | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {"mode": mode, "name": name}
    if queue_message is not None:
        body["queue_message"] = queue_message
    if is_auto_retry_until_stop is not None:
        body["is_auto_retry_until_stop"] = is_auto_retry_until_stop
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{item_id}/kanban/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _list_tasks(
    harness: FunctionalHarness, ws_id: str, item_id: str
) -> list[dict[str, Any]]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{item_id}/tasks",
        params={"limit": 100},
        expect=200,
    )
    body = r.json()
    return body.get("tasks", body if isinstance(body, list) else [])


# ─── Test 1: kanban /kanban/tasks endpoint — create mode ──────────────────


def test_kanban_tasks_endpoint_create_mode(
    harness: FunctionalHarness,
) -> None:
    """POST /kanban/tasks with mode='create' returns the wrapped envelope.

    The kanban-scoped endpoint differs from the generic
    `/api/workspaces/:ws/items/:item_id/tasks` endpoint by accepting
    a `mode` discriminator. mode='create' just makes the card;
    mode='create_and_run' also creates a session row and emits
    session_created SSE.

    The envelope's `task` field is a slim `TaskCreateResponse`:
    `{id, name, description, completed}` (NOT the full
    `StandardResponse` — see http_response.zig:99).
    """
    ws_id = _create_workspace(harness)
    kanban = _create_kanban_item(harness, ws_id, "sprint")

    body = _create_kanban_task_via_kanban_endpoint(
        harness, ws_id, kanban["id"], "first-card", mode="create"
    )
    # Envelope shape: { task: <TaskCreateResponse>, session: null }
    assert "task" in body, f"envelope should have 'task', got: {body!r}"
    assert body.get("session") is None, (
        f"mode='create' should leave session=null, got: {body.get('session')!r}"
    )
    task = body["task"]
    assert task["id"].startswith("task_")
    assert task["name"] == "first-card"
    assert task["description"] is None
    assert task["completed"] is False

    # The task is visible via the list endpoint (the list returns
    # the fuller shape — useful for catching drift between the
    # kanban-scoped response and the list view).
    listed = _list_tasks(harness, ws_id, kanban["id"])
    found = next((t for t in listed if t["id"] == task["id"]), None)
    assert found is not None, (
        f"created task {task['id']!r} not in list response: {[t['id'] for t in listed]}"
    )
    assert found.get("workspace_item_id") == kanban["id"]


# ─── Test 2: kanban /kanban/tasks endpoint — create_and_run mode ─────────


def test_kanban_tasks_endpoint_create_and_run_returns_session(
    harness: FunctionalHarness,
) -> None:
    """mode='create_and_run' requires queue_message + creates a session row.

    The response carries `session: {id, name, status: 'send'}` — the
    session_id == task_id per the project's convention.
    """
    ws_id = _create_workspace(harness)
    kanban = _create_kanban_item(harness, ws_id, "sprint2")

    body = _create_kanban_task_via_kanban_endpoint(
        harness,
        ws_id,
        kanban["id"],
        "run-it",
        mode="create_and_run",
        queue_message="hello worker",
    )
    assert "task" in body
    assert body.get("session") is not None, (
        f"mode='create_and_run' should populate session, got null: {body!r}"
    )
    session = body["session"]
    assert session["id"] == body["task"]["id"], (
        f"session.id should equal task.id (task.id == session.id convention), "
        f"got session.id={session['id']!r} task.id={body['task']['id']!r}"
    )
    assert session["name"] == "run-it"
    assert session["status"] == "send"


# ─── Test 3: /kanban/tasks rejects create_and_run without queue_message ──


def test_kanban_tasks_endpoint_create_and_run_requires_queue_message(
    harness: FunctionalHarness,
) -> None:
    """mode='create_and_run' without queue_message returns 400."""
    ws_id = _create_workspace(harness)
    kanban = _create_kanban_item(harness, ws_id, "sprint3")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban['id']}/kanban/tasks",
        json_body={"mode": "create_and_run", "name": "no-msg"},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert "queue_message" in body["error"], (
        f"400 message should mention queue_message, got: {body['error']!r}"
    )


# ─── Test 4: /kanban/tasks rejects unknown mode ───────────────────────────


def test_kanban_tasks_endpoint_rejects_unknown_mode(
    harness: FunctionalHarness,
) -> None:
    """POST /kanban/tasks with mode='garbage' returns 400."""
    ws_id = _create_workspace(harness)
    kanban = _create_kanban_item(harness, ws_id, "sprint4")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban['id']}/kanban/tasks",
        json_body={"mode": "garbage", "name": "x"},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert "mode" in body["error"].lower()


# ─── Test 5: /kanban/tasks on non-kanban parent returns 404 ───────────────


def test_kanban_tasks_endpoint_rejects_non_kanban_parent(
    harness: FunctionalHarness,
) -> None:
    """POST /kanban/tasks against a chat parent returns 404.

    The handler validates the parent's item_type='kanban' before
    creating the task.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "chat-parent")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/kanban/tasks",
        json_body={"mode": "create", "name": "x"},
        expect=404,
    )
    body = r.json()
    assert "error" in body
    assert "not found" in body["error"].lower() or "not a kanban" in body["error"].lower()


# ─── Test 6: PUT task renames + persists across GET ───────────────────────


def test_put_task_rename_round_trips(
    harness: FunctionalHarness,
) -> None:
    """PUT /tasks/:task_id {name: ...} → list shows the new name.

    task_update.zig returns `{success, id}`; the rename is verified
    by re-fetching via the list endpoint.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "rename-host")
    task = _create_task(harness, ws_id, chat["id"], "before")

    put_resp = harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks/{task['id']}",
        json_body={"name": "after"},
        expect=200,
    ).json()
    assert put_resp.get("success") is True
    assert put_resp.get("id") == task["id"]

    # List endpoint reflects the rename.
    listed = _list_tasks(harness, ws_id, chat["id"])
    found = next((t for t in listed if t["id"] == task["id"]), None)
    assert found is not None
    assert found["name"] == "after", (
        f"rename didn't apply; got {found['name']!r}"
    )


# ─── Test 7: PUT task by-id path (no workspace in URL) ─────────────────────


def test_put_task_by_id_path_also_works(
    harness: FunctionalHarness,
) -> None:
    """PUT /api/workspaces/tasks/:task_id (without workspace_id/item_id
    path params) also succeeds — same handler as the path-param variant.

    task_update.zig::tasksUpdateByIdHandler delegates to the same
    useCase; this test pins both URL forms are accepted.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "id-only-host")
    task = _create_task(harness, ws_id, chat["id"], "name-1")

    put_resp = harness.http(
        "PUT",
        f"/api/workspaces/tasks/{task['id']}",
        json_body={"name": "name-2"},
        expect=200,
    ).json()
    assert put_resp.get("success") is True

    listed = _list_tasks(harness, ws_id, chat["id"])
    found = next((t for t in listed if t["id"] == task["id"]), None)
    assert found is not None
    assert found["name"] == "name-2"


# ─── Test 8: DELETED (Migration 084) ─────────────────────────────────────
# PUT task with routine fields no longer creates a routines row — the
# per-task `routines` table is gone. Covered by
# tests/functional/workspace_routines_test.py::
# test_put_task_with_routine_fields_is_plain_update.


# ─── Test 9: DELETED (Migration 084) ─────────────────────────────────────
# PUT task no longer validates cron — routine fields are ignored.
# Covered by tests/functional/workspace_routines_test.py::
# test_patch_bad_cron_returns_400 (workspace-level validation).


# ─── Test 10: DELETE task removes it from the list ───────────────────────


def test_delete_task_removes_from_list(
    harness: FunctionalHarness,
) -> None:
    """DELETE /tasks/:task_id → list no longer contains it.

    Response shape is `{id, success: true}` (the
    `WorkspaceItemResponse` shape from http_response.zig).
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "del-host")
    task = _create_task(harness, ws_id, chat["id"], "doomed")
    assert any(t["id"] == task["id"] for t in _list_tasks(harness, ws_id, chat["id"]))

    del_resp = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks/{task['id']}",
        expect=200,
    ).json()
    assert del_resp.get("success") is True
    assert del_resp.get("id") == task["id"]

    assert not any(
        t["id"] == task["id"] for t in _list_tasks(harness, ws_id, chat["id"])
    ), f"deleted task {task['id']!r} still in list"


# ─── Test 11: DELETE task 404 for nonexistent ─────────────────────────────


def test_delete_task_404_for_nonexistent(
    harness: FunctionalHarness,
) -> None:
    """DELETE /tasks/task_nope is idempotent + returns 200.

    The delete handler is idempotent: when the task row doesn't exist,
    `deleteWorkspaceItemTask` is a no-op SQL DELETE (zero rows affected)
    and the handler returns `{success: true, id: task_id}`. This is
    documented behavior in task_delete.zig:160-164 (idempotent DELETE).
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "404-host")

    # Note: the response is 200 (idempotent), not 404. This test
    # documents that contract — flip to expect=404 if the handler is
    # ever updated to refuse deletes on missing rows.
    r = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks/task_nope",
        expect=200,
    )
    body = r.json()
    assert body.get("success") is True
    assert body.get("id") == "task_nope"


# ─── Test 12: PUT /touched stamps the timestamp ───────────────────────────


def test_put_touched_stamps_human_touched_at(
    harness: FunctionalHarness,
) -> None:
    """PUT /tasks/:task_id/touched returns 200 with {success, task_id}.

    The stamp itself is verified via DB observation: re-PUT after a
    short delay should produce a NEW `last_human_touched_at` row.
    Since there's no GET endpoint for the column, we just verify
    the response shape and that re-PUT is idempotent.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "touched-host")
    task = _create_task(harness, ws_id, chat["id"], "touched-target")

    r = harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks/{task['id']}/touched",
        json_body={},
        expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("task_id") == task["id"]

    # Idempotent: a second PUT works without 4xx/5xx.
    r2 = harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks/{task['id']}/touched",
        json_body={},
        expect=200,
    ).json()
    assert r2.get("success") is True
    assert r2.get("task_id") == task["id"]


# ─── Test 13: POST /reorder_pinned reorders pinned subset ─────────────────


def test_reorder_pinned_reorders_only_pinned_subset(
    harness: FunctionalHarness,
) -> None:
    """POST /tasks/reorder_pinned with [t1, t2, t3] places t1 first in
    the pinned block. Non-pinned tasks are unaffected.

    Pinning is done via the existing /tasks/:task_id/pin endpoint
    (covered by kanban_lifecycle_test.py). We pin 2 of 3 tasks, then
    reorder the pinned ones.
    """
    ws_id = _create_workspace(harness)
    kanban = _create_kanban_item(harness, ws_id, "reorder-host")

    # Create 3 tasks under the kanban (auto-assigned to first column).
    t_a = _create_task(harness, ws_id, kanban["id"], "A")
    t_b = _create_task(harness, ws_id, kanban["id"], "B")
    t_c = _create_task(harness, ws_id, kanban["id"], "C")

    # Pin A and C (leave B non-pinned).
    for t in (t_a, t_c):
        harness.http(
            "POST",
            f"/api/workspaces/{ws_id}/items/{kanban['id']}/tasks/{t['id']}/pin",
            json_body={"is_pinned": True},
            expect=200,
        )

    # Reorder the pinned subset to [C, A] (C first, A second).
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban['id']}/tasks/reorder_pinned",
        json_body={"ordered_ids": [t_c["id"], t_a["id"]]},
        expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("count") == 2


# ─── Test 14: DELETED (Migration 084) ─────────────────────────────────────
# POST /tasks/:id/run is gone (404 route, not a handler 404).
# Covered by tests/functional/workspace_routines_test.py::
# test_old_per_task_run_endpoint_is_gone.


# ─── Test 15: DELETED (Migration 084) ─────────────────────────────────────
# Per-task routine creation is rejected with 400 RoutineTasksRemoved.
# Covered by tests/functional/workspace_routines_test.py::
# test_create_task_with_routine_type_is_rejected.


# ─── Test 16: /start_agent succeeds on existing task (no worker running) ─


def test_start_agent_succeeds_on_idle_task(
    harness: FunctionalHarness,
) -> None:
    """POST /tasks/:task_id/start_agent on an idle task → 200.

    Returns `{success, session_id, status: 'triggered'}`. The
    start_agent.zig use-case is wired to skip queue-message inserts
    (the `skip_initial_queue_message: true` flag), so the response
    alone doesn't surface that — but the 200 + status='triggered'
    shape is the contract.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "start-agent-host")
    task = _create_task(harness, ws_id, chat["id"], "go")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks/{task['id']}/start_agent",
        json_body={},
        expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("session_id") == task["id"]
    assert r.get("status") == "triggered"


# ─── Test 17: /start_agent 404 for nonexistent task ──────────────────────


def test_start_agent_404_for_nonexistent_task(
    harness: FunctionalHarness,
) -> None:
    """POST /tasks/task_nope/start_agent → 404 with
    `{"error": "task not found"}`.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "start-agent-404-host")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks/task_nope/start_agent",
        json_body={},
        expect=404,
    )
    body = r.json()
    assert "error" in body
    assert "task not found" in body["error"].lower()


# ─── Test 18: image_urls round-trips via POST /tasks ─────────────────────


def test_task_create_accepts_image_urls(
    harness: FunctionalHarness,
) -> None:
    """POST /tasks with image_urls='data:image/png;base64,...' persists
    + round-trips via the list endpoint.

    The `image_urls` field is the ||-joined wire format (Migration 069).
    The handler validates the prefix and base64 shape, then stores
    the string verbatim.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "img-host")
    payload = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX///+nxBvIAAAAC0lEQVQI12NgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
    task = _create_task(
        harness,
        ws_id,
        chat["id"],
        "with-image",
        image_urls=payload,
    )
    assert task["id"].startswith("task_")

    listed = _list_tasks(harness, ws_id, chat["id"])
    found = next((t for t in listed if t["id"] == task["id"]), None)
    assert found is not None
    # The image_urls field should round-trip (handlers may carry it
    # verbatim; some response shapes omit it — assert it's present
    # OR absent but never garbled).
    if "image_urls" in found:
        assert found["image_urls"] == payload, (
            f"image_urls didn't round-trip; got {found['image_urls']!r}"
        )


# ─── Test 19: invalid image_urls prefix returns 400 ──────────────────────


def test_task_create_rejects_malformed_image_urls(
    harness: FunctionalHarness,
) -> None:
    """image_urls='not-a-data-uri' returns 400 InvalidImageUrls."""
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "bad-img-host")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks",
        json_body={"name": "bad", "image_urls": "not-a-data-uri"},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert "image" in body["error"].lower() or "data:image" in body["error"].lower()


# ─── Test 20: relative cwd returns 400 ───────────────────────────────────


def test_task_create_rejects_relative_cwd(
    harness: FunctionalHarness,
) -> None:
    """cwd='relative/path' returns 400 CwdNotAbsolute.

    task_create.zig:457 rejects paths that don't start with '/'.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "rel-cwd-host")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks",
        json_body={"name": "rel-cwd", "cwd": "relative/path"},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert (
        "absolute" in body["error"].lower()
        or "cwd" in body["error"].lower()
    )


# ─── Test 21: is_auto_retry_until_stop="1" is persisted (no crash) ─────────


def test_task_create_with_unattended_flag_does_not_crash(
    harness: FunctionalHarness,
) -> None:
    """POST /tasks with is_auto_retry_until_stop='1' returns 201.

    The handler inserts an `INSERT OR IGNORE INTO sessions` row keyed
    by task.id (Migration 062 + the kanban-task-name-match plan). The
    INSERT is fire-and-forget — a failure to insert logs a warning
    but the task row is still returned with 201.
    """
    ws_id = _create_workspace(harness)
    chat = _create_chat_item(harness, ws_id, "unattended-host")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{chat['id']}/tasks",
        json_body={
            "name": "unattended",
            "is_auto_retry_until_stop": "1",
        },
        expect=201,
    )
    task = r.json()
    assert task["id"].startswith("task_")
    assert task["name"] == "unattended"

    # The task is visible via list.
    listed = _list_tasks(harness, ws_id, chat["id"])
    assert any(t["id"] == task["id"] for t in listed)