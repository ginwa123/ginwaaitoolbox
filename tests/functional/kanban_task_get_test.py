"""Functional tests for the single-task GET endpoint.

Plan: docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md
(Task 2).

The bug: opening the kanban Task details dialog refetched the WHOLE
task list (`GET .../tasks?limit=100`) and plucked one task — on a
270+ task board that means every task's routine JOINs, tags, and
base64 image_urls cross the wire to update one row.

The fix: `GET /api/workspaces/:ws/items/:item/tasks/:task_id` returns
`{ task: {...} }` (same WorkspaceItemTaskResponse shape as the list
endpoint). These tests replay the wire round-trip against a real
binary:

  1. create a task → GET it by id → 200 with the full task shape.
  2. unknown task_id → 404 `task not found`.
  3. task under a DIFFERENT item → 404 (item scoping).
  4. empty task_id in the path → 400 (empty-slice-as-NULL guard).
  5. the list route still works (route-order shadowing guard).
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "kanban-get-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "sprint-get") -> str:
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
    name: str = "detail task",
) -> dict[str, Any]:
    """POST mode='create_session' — mirrors the frontend's "Create task"
    button (no agent run)."""
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": name, "description": "desc"},
        expect=201,
    )
    return r.json()


def _get_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    task_id: str,
    expect: int = 200,
) -> Any:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks/{task_id}",
        expect=expect,
    )
    return r.json()


# ─── Test 1: happy path — full task shape ─────────────────────────────────


def test_get_task_by_id_returns_full_task(harness: FunctionalHarness):
    """Create → GET by id → 200 `{ task }` with the fields the detail
    dialog reads (name, description, tags, unattended flag, images)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    created = _create_task(harness, ws_id, kanban_id, name="my task")
    task_id = created["task"]["id"]

    body = _get_task(harness, ws_id, kanban_id, task_id)
    task = body.get("task")
    assert isinstance(task, dict), f"expected task object, got: {body!r}"
    assert task["id"] == task_id
    assert task["name"] == "my task"
    assert task["description"] == "desc"
    assert task["workspace_item_id"] == kanban_id
    # Fields the dialog renders — must be present in the single-task
    # response exactly as in the list response.
    assert "tags" in task
    assert "is_auto_retry_until_stop" in task
    assert "kanban_column_id" in task
    assert "needs_human_review" in task
    # media-flags change: the task body is flag-only. The full
    # `||`-delimited strings moved to the lazy
    # `GET .../tasks/:task_id/media` route so a board fetch of 50 tasks
    # does not carry 50 sets of base64 data URLs. Assert the flags ARE
    # here and the payload is NOT — that is the contract, and it is what
    # this test was silently violating with `assert "image_urls" in task`.
    assert "is_have_image" in task
    assert "is_have_video" in task
    assert "image_urls" not in task, sorted(task)
    assert "video_urls" not in task, sorted(task)


def test_get_task_media_endpoint_returns_lazy_payloads(
    harness: FunctionalHarness,
):
    """The lazy `/media` route carries the full strings the task body dropped."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    created = _create_task(harness, ws_id, kanban_id, name="my task")
    task_id = created["task"]["id"]

    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task_id}/media",
        expect=200,
    )
    media = r.json()
    assert set(media) == {"image_urls", "video_urls"}, media
    # No media was ever attached, so both are the empty string — not null
    # and not a 404. A task row must always exist before the media route
    # is asked about it.
    assert media["image_urls"] == "", media
    assert media["video_urls"] == "", media


def test_get_task_media_unknown_id_returns_404(harness: FunctionalHarness):
    """`/media` for a task that does not exist → 404, same as the task route."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    body = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/task_does_not_exist/media",
        expect=404,
    ).json()
    assert "task not found" in body.get("error", ""), f"got: {body!r}"


# ─── Test 2: unknown task → 404 ────────────────────────────────────────────


def test_get_task_unknown_id_returns_404(harness: FunctionalHarness):
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    body = _get_task(harness, ws_id, kanban_id, "task_does_not_exist", expect=404)
    assert "task not found" in body.get("error", ""), f"got: {body!r}"


# ─── Test 3: item scoping — task under another kanban → 404 ───────────────


def test_get_task_scoped_to_parent_item(harness: FunctionalHarness):
    """A task under kanban B must NOT be readable through kanban A's
    path — the DB fn scopes by BOTH workspace_item_id and task id."""
    ws_id = _create_workspace(harness)
    kanban_a = _create_kanban(harness, ws_id, name="board-a")
    kanban_b = _create_kanban(harness, ws_id, name="board-b")

    created = _create_task(harness, ws_id, kanban_b, name="on board b")
    task_id = created["task"]["id"]

    # Wrong item in the path → 404.
    body = _get_task(harness, ws_id, kanban_a, task_id, expect=404)
    assert "task not found" in body.get("error", "")

    # Correct item → 200.
    body = _get_task(harness, ws_id, kanban_b, task_id, expect=200)
    assert body["task"]["id"] == task_id


# ─── Test 4: empty task_id → 400 (empty-slice-as-NULL guard) ──────────────


def test_get_task_empty_id_returns_400(harness: FunctionalHarness):
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    # A trailing-slash URL yields an empty :task_id capture; the
    # handler must 400 BEFORE any DB call (SqliteBackend binds "" as
    # SQL NULL).
    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/",
        expect=400,
    )
    assert "task_id required" in r.json().get("error", "")


# ─── Test 5: list route still works (route-order shadowing guard) ─────────


def test_list_route_not_shadowed_by_single_task_route(harness: FunctionalHarness):
    """matchRoute walks routes in registration order — the list route
    must still match after the single-task route was registered."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    _create_task(harness, ws_id, kanban_id, name="t1")
    _create_task(harness, ws_id, kanban_id, name="t2")

    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks",
        params={"limit": "100"},
        expect=200,
    )
    tasks = r.json()["tasks"]
    assert len(tasks) == 2, f"expected 2 tasks from list route, got {len(tasks)}"
