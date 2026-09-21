"""Migration 092 — lightweight task list/get payload + lazy media endpoint.

List/get return only `is_have_image` / `is_have_video` flags so board
fetches stay small; the full `||`-delimited base64 TEXT columns stay
server-side for `GET .../tasks/:task_id/media`, which the frontend
calls only when a flag is true.

These tests replay the EXACT wire bodies the frontend sends:
  1. create (mode='create_session') with image_urls → response carries
     is_have_image=true (no image_urls field); list/get carry the flag;
     the media endpoint returns the persisted column.
  2. PUT /api/workspaces/tasks/:task_id with image_urls → flag flips;
     PUT with '' → flag clears.
"""

from __future__ import annotations

from typing import Any

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


def _get_task(harness: FunctionalHarness, workspace_id: str, kanban_id: str, task_id: str) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks/{task_id}",
        expect=200,
    )
    return r.json()["task"]


def _get_media(harness: FunctionalHarness, workspace_id: str, kanban_id: str, task_id: str) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks/{task_id}/media",
        expect=200,
    )
    return r.json()


# ─── Test 1: create → flags on the wire, media via lazy endpoint ──────────


def test_create_with_image_returns_flag_and_media_endpoint_serves_urls(harness: FunctionalHarness):
    """Create with an image → create/list/get carry is_have_image=true
    (and NO image_urls field — the perf win); the media endpoint
    returns the persisted column."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    resp = _create_task_with_image(harness, ws_id, kanban_id, PNG_DATA_URL)

    task = resp.get("task")
    assert isinstance(task, dict), f"expected task object, got: {resp!r}"
    assert task.get("is_have_image") is True, f"create should flag media, got: {task!r}"
    assert "image_urls" not in task, f"create must not echo base64 payload, got keys: {sorted(task)!r}"
    task_id = task["id"]

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert len(tasks) == 1, f"expected 1 task, got {len(tasks)}"
    assert tasks[0]["is_have_image"] is True
    assert tasks[0].get("is_have_video") is False
    assert "image_urls" not in tasks[0], f"list must stay small, got keys: {sorted(tasks[0])!r}"

    single = _get_task(harness, ws_id, kanban_id, task_id)
    assert single["is_have_image"] is True
    assert "image_urls" not in single

    media = _get_media(harness, ws_id, kanban_id, task_id)
    assert media["image_urls"] == PNG_DATA_URL, f"media endpoint should serve urls, got: {media!r}"
    assert media["video_urls"] == ""


def test_create_with_multiple_images_preserves_order_in_media(harness: FunctionalHarness):
    """Multiple images are stored as the ||-joined string in send order;
    the media endpoint returns them verbatim."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    joined = "||".join([PNG_DATA_URL, JPEG_DATA_URL])
    resp = _create_task_with_image(harness, ws_id, kanban_id, joined)
    task_id = resp["task"]["id"]

    media = _get_media(harness, ws_id, kanban_id, task_id)
    assert media["image_urls"] == joined


def test_create_without_image_reports_no_media(harness: FunctionalHarness):
    """A task created without images reports is_have_image=false and the
    media endpoint returns empty sentinels."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": "no img", "description": ""},
        expect=201,
    )
    assert r.json()["task"]["is_have_image"] is False
    task_id = r.json()["task"]["id"]

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert tasks[0]["is_have_image"] is False

    media = _get_media(harness, ws_id, kanban_id, task_id)
    assert media["image_urls"] == ""
    assert media["video_urls"] == ""


def test_media_endpoint_404_for_unknown_task(harness: FunctionalHarness):
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/no_such_task/media",
        expect=404,
    )


# ─── Test 2: PUT updates + clears the flag ────────────────────────────────


def test_put_image_urls_sets_flag(harness: FunctionalHarness):
    """PUT /api/workspaces/tasks/:task_id with image_urls persists the
    new value and flips the flag (the media endpoint serves it)."""
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
    assert tasks[0]["is_have_image"] is True
    media = _get_media(harness, ws_id, kanban_id, task_id)
    assert media["image_urls"] == JPEG_DATA_URL


def test_put_empty_image_urls_clears_flag(harness: FunctionalHarness):
    """PUT with image_urls='' clears the column and the flag."""
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
    assert tasks[0]["is_have_image"] is False
    media = _get_media(harness, ws_id, kanban_id, task_id)
    assert media["image_urls"] == ""


def test_put_invalid_image_urls_rejected_400(harness: FunctionalHarness):
    """A malformed data URL is rejected with 400 and the stored value
    (and flag) are untouched."""
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
    assert tasks[0]["is_have_image"] is True
    media = _get_media(harness, ws_id, kanban_id, task_id)
    assert media["image_urls"] == PNG_DATA_URL
