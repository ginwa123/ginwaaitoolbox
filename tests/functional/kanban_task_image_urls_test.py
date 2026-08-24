"""Functional wire round-trip for the kanban task image_urls read path.

Plan: docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
(Task 5).

The bug: images attached in the "New task" dialog were PERSISTED
correctly (workspace_item_tasks.image_urls) but never returned by the
read path — the paginated task lister didn't SELECT the column, the
wire response struct had no field, and the create response didn't echo
it. So the task detail dialog's gallery was always empty after a
refetch, and image edits via PUT were silently dropped.

These tests replay the EXACT wire bodies the frontend sends:
  1. create (mode='create_session') with image_urls → response echoes
     image_urls AND the list endpoint returns it.
  2. PUT /api/workspaces/tasks/:task_id with image_urls → persisted;
     PUT with '' → cleared.
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness

# Tiny valid PNG header (1x1 transparent pixel, base64). Small enough
# to keep the wire payload trivial but a real `data:image/png;base64,`
# prefix so image_urls_validation accepts it.
PNG_DATA_URL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
JPEG_DATA_URL = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD//2Q=="


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "kanban-img-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "sprint-img") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_task_with_image(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    image_urls_joined: str,
) -> dict[str, Any]:
    """POST mode='create_session' with image_urls — mirrors the frontend's
    "Create task" button with an attached image (api/index.ts joins the
    array with '||' before sending)."""
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body={
            "mode": "create_session",
            "name": "img task",
            "description": "",
            "image_urls": image_urls_joined,
        },
        expect=201,
    )
    return r.json()


def _list_tasks(harness: FunctionalHarness, workspace_id: str, kanban_id: str) -> list[dict[str, Any]]:
    """GET the paginated task list (the endpoint the kanban board uses)."""
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks",
        params={"limit": "10"},
        expect=200,
    )
    body = r.json()
    tasks = body.get("tasks")
    assert isinstance(tasks, list), f"expected tasks list, got: {body!r}"
    return tasks


# ─── Test 1: create echoes image_urls + list returns them ─────────────────


def test_create_with_image_then_list_returns_image_urls(harness: FunctionalHarness):
    """The full read-path round trip: create with an image → the create
    response echoes image_urls AND the list endpoint returns the
    persisted column (pre-fix the list returned no image_urls field at
    all, so the detail dialog gallery was always empty)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    resp = _create_task_with_image(harness, ws_id, kanban_id, PNG_DATA_URL)

    # Create response echoes image_urls (optimistic gallery contract).
    task = resp.get("task")
    assert isinstance(task, dict), f"expected task object, got: {resp!r}"
    assert task.get("image_urls") == PNG_DATA_URL, (
        f"create response should echo image_urls, got: {task!r}"
    )

    # List endpoint returns the persisted column.
    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert len(tasks) == 1, f"expected 1 task, got {len(tasks)}"
    assert tasks[0]["image_urls"] == PNG_DATA_URL, (
        f"list should return the persisted image_urls, got: {tasks[0]!r}"
    )


def test_create_with_multiple_images_preserves_order(harness: FunctionalHarness):
    """Multiple images are stored as the ||-joined string in send order;
    the list returns them verbatim (the frontend splits on '|' and
    renders the first as the card thumbnail)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    joined = "||".join([PNG_DATA_URL, JPEG_DATA_URL])
    _create_task_with_image(harness, ws_id, kanban_id, joined)

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert tasks[0]["image_urls"] == joined


def test_create_without_image_omits_empty_sentinel(harness: FunctionalHarness):
    """A task created without images carries image_urls as the empty
    string (the canonical "no images" sentinel — NOT NULL DEFAULT '')."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id_placeholder(ws_id)}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": "no img", "description": ""},
        expect=201,
    )
    assert r.json()["task"]["image_urls"] == ""

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert tasks[0]["image_urls"] == ""


def workspace_id_placeholder(ws_id: str) -> str:
    # (helper kept trivial — the URL just needs the workspace id)
    return ws_id


# ─── Test 2: PUT updates + clears image_urls ──────────────────────────────


def test_put_image_urls_updates_row(harness: FunctionalHarness):
    """PUT /api/workspaces/tasks/:task_id with image_urls persists the
    new value (pre-fix the PUT parsed the field but had no UPDATE
    branch — edits were silently dropped)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    resp = _create_task_with_image(harness, ws_id, kanban_id, PNG_DATA_URL)
    task_id = resp["task"]["id"]

    harness.http(
        "PUT",
        f"/api/workspaces/tasks/{task_id}",
        json_body={"image_urls": JPEG_DATA_URL},
        expect=200,
    )

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert tasks[0]["image_urls"] == JPEG_DATA_URL


def test_put_empty_image_urls_clears_row(harness: FunctionalHarness):
    """PUT with image_urls='' clears the column (the canonical "no
    images" sentinel is persisted, not skipped)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    resp = _create_task_with_image(harness, ws_id, kanban_id, PNG_DATA_URL)
    task_id = resp["task"]["id"]

    harness.http(
        "PUT",
        f"/api/workspaces/tasks/{task_id}",
        json_body={"image_urls": ""},
        expect=200,
    )

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert tasks[0]["image_urls"] == ""


def test_put_invalid_image_urls_rejected_400(harness: FunctionalHarness):
    """A malformed data URL is rejected with 400 (InvalidImageUrls) and
    the stored value is untouched."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    resp = _create_task_with_image(harness, ws_id, kanban_id, PNG_DATA_URL)
    task_id = resp["task"]["id"]

    harness.http(
        "PUT",
        f"/api/workspaces/tasks/{task_id}",
        json_body={"image_urls": "not-a-data-url"},
        expect=(400, 413),
    )

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert tasks[0]["image_urls"] == PNG_DATA_URL
