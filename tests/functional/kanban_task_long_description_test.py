"""Kanban task descriptions are unlimited (no 5000-char cap).

The frontend used to enforce `maxlength=5000` on the description editor
(KanbanDescriptionEditor `maxLength` default + KanbanTaskDetailDialog
`DESCRIPTION_MAX`). The backend never had a length check — the column is
TEXT — so these tests lock in the wire contract: a 20 000-char description
round-trips byte-for-byte through create → single-task GET → update.

Mirrors tests/functional/kanban_task_get_test.py helpers.
"""

from __future__ import annotations

from typing import Any

from harness import FunctionalHarness


def _create_workspace(harness: FunctionalHarness) -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": "kanban-long-desc-ws"}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": "sprint-long-desc"},
        expect=201,
    )
    return r.json()["item"]["id"]


def test_create_task_with_20000_char_description_round_trips(harness: FunctionalHarness) -> None:
    """A description 4x the old 5000 cap persists and reads back intact."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    long_desc = "lorem ipsum dolor sit amet. " * 715  # ~20k chars

    assert len(long_desc) > 5000, "test bug: description must exceed the old cap"

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": "long desc task", "description": long_desc},
        expect=201,
    )
    task_id = r.json()["task"]["id"]

    body = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task_id}",
        expect=200,
    ).json()
    assert body["task"]["description"] == long_desc


def test_update_task_with_20000_char_description_round_trips(harness: FunctionalHarness) -> None:
    """PUT (edit-mode Save) also accepts descriptions past the old cap."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": "update me", "description": "short"},
        expect=201,
    )
    task_id = r.json()["task"]["id"]
    long_desc = "updated body. " * 1400  # ~21k chars
    assert len(long_desc) > 5000, "test bug: description must exceed the old cap"

    harness.http(
        "PUT",
        f"/api/workspaces/tasks/{task_id}",
        json_body={"description": long_desc},
        expect=200,
    )

    body = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task_id}",
        expect=200,
    ).json()
    assert body["task"]["description"] == long_desc
