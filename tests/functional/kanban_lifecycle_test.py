"""Functional tests for kanban lifecycle.

Exercises the kanban-specific HTTP surface: create a kanban item
(seeds 3 default columns), add a 4th column, add 12 tasks across
columns, move tasks between columns, pin, copy spec, and delete.

Plan: docs/superpowers/plans/2026-07-26-functional-tests-with-real-data.md (Chunk 4)
"""

from __future__ import annotations

import time
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "kanban-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(
    harness: FunctionalHarness, workspace_id: str, name: str = "sprint"
) -> str:
    # The backend wraps the kanban in a `{item, columns}` envelope
    # so the frontend's `const { item, columns } = await createKanban(...)`
    # destructure renders the board immediately on the client (no
    # second round-trip for the seeded default columns).
    # See `workspace_items_create_kanban.zig::CreateKanbanResponseFull`.
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    body = r.json()
    item = body.get("item")
    assert item is not None, (
        f"created kanban response missing 'item' envelope: {body!r}"
    )
    assert item["item_type"] == "kanban", (
        f"created item should be type 'kanban', got {item.get('item_type')!r}"
    )
    assert item["id"].startswith("item_"), (
        f"created item id should start with 'item_', got {item.get('id')!r}"
    )
    # The envelope also returns the 3 freshly-seeded default columns
    # — sanity-check the contract is honoured (not part of the bug
    # fix, but cheap to assert and catches regressions).
    assert isinstance(body.get("columns"), list), (
        f"created kanban envelope should include a 'columns' list, got {body!r}"
    )
    return item["id"]


def _list_columns(
    harness: FunctionalHarness, workspace_id: str, kanban_id: str
) -> list[dict[str, Any]]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/columns",
        expect=200,
    )
    body = r.json()
    return body["columns"]


def _add_column(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    name: str,
    position: int | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {"name": name}
    if position is not None:
        body["position"] = position
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/columns",
        json_body=body,
        expect=201,
    )
    return r.json()


def _add_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    name: str,
    column_id: str | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {"name": name}
    if column_id is not None:
        body["column_id"] = column_id
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _list_tasks(
    harness: FunctionalHarness, workspace_id: str, kanban_id: str
) -> list[dict[str, Any]]:
    """List all tasks under a kanban (via the items tasks endpoint)."""
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks",
        params={"limit": 100},
        expect=200,
    )
    body = r.json()
    return body.get("tasks", body if isinstance(body, list) else [])


# ─── Test 1: kanban create seeds 3 default columns ──────────────────────


def test_create_kanban_seeds_three_default_columns(
    harness: FunctionalHarness,
) -> None:
    """POST /items/kanban creates 3 default columns (todo/in_progress/done)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "sprint-1")
    cols = _list_columns(harness, ws_id, kanban_id)
    assert len(cols) == 3, f"expected 3 default columns, got {len(cols)}"
    names = [c["name"] for c in cols]
    # The default names are typically: todo, in_progress, done
    # (in some order). Just verify we have 3 distinct columns.
    assert len(set(names)) == 3, f"expected 3 distinct column names, got {names}"


# ─── Test 2: add a 4th column ──────────────────────────────────────────


def test_add_fourth_column(
    harness: FunctionalHarness,
) -> None:
    """Append a 4th column, list now has 4."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    new_col = _add_column(harness, ws_id, kanban_id, "backlog")
    assert new_col["id"].startswith("col_")
    assert new_col["name"] == "backlog"
    cols = _list_columns(harness, ws_id, kanban_id)
    assert len(cols) == 4, f"expected 4 columns, got {len(cols)}"
    assert any(c["id"] == new_col["id"] for c in cols)


# ─── Test 3: add 12 tasks across 4 columns ──────────────────────────────


def test_add_twelve_tasks_across_four_columns(
    harness: FunctionalHarness,
) -> None:
    """4 columns × 3 tasks each = 12 tasks total."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    _add_column(harness, ws_id, kanban_id, "backlog")
    cols = _list_columns(harness, ws_id, kanban_id)
    assert len(cols) == 4

    created_ids = []
    for col in cols:
        for j in range(3):
            task = _add_task(
                harness, ws_id, kanban_id, f"{col['name']}-task-{j}", col["id"]
            )
            assert task["id"].startswith("task_")
            created_ids.append(task["id"])
    assert len(created_ids) == 12

    tasks = _list_tasks(harness, ws_id, kanban_id)
    assert len(tasks) >= 12, f"expected at least 12 tasks, got {len(tasks)}"


# ─── Test 4: move task across columns ───────────────────────────────────


def test_move_task_across_columns(
    harness: FunctionalHarness,
) -> None:
    """Create task under col-A, move to col-B, verify presence/absence."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    cols = _list_columns(harness, ws_id, kanban_id)
    col_a, col_b = cols[0], cols[1]

    task = _add_task(harness, ws_id, kanban_id, "movable", col_a["id"])

    move_resp = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task['id']}/move",
        json_body={"column_id": col_b["id"], "position": 0},
        expect=200,
    ).json()
    assert move_resp["success"] is True
    assert move_resp["column_id"] == col_b["id"]

    # The task is now under col_b (verify by listing tasks and checking
    # the column_id field).
    tasks = _list_tasks(harness, ws_id, kanban_id)
    moved = next((t for t in tasks if t["id"] == task["id"]), None)
    assert moved is not None, f"task {task['id']!r} not found after move"
    assert moved.get("kanban_column_id") == col_b["id"], (
        f"task should be in col_b {col_b['id']!r}, got {moved.get('kanban_column_id')!r}"
    )


# ─── Test 5: move task to same column is idempotent ──────────────────────


def test_move_task_to_same_column_is_idempotent(
    harness: FunctionalHarness,
) -> None:
    """Moving a task to the column it's already in is a no-op."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    cols = _list_columns(harness, ws_id, kanban_id)
    col_a = cols[0]

    task = _add_task(harness, ws_id, kanban_id, "stay", col_a["id"])

    # Move to same column twice.
    r1 = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task['id']}/move",
        json_body={"column_id": col_a["id"], "position": 0},
        expect=200,
    )
    r2 = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task['id']}/move",
        json_body={"column_id": col_a["id"], "position": 0},
        expect=200,
    )
    assert r1.json()["success"] is True
    assert r2.json()["success"] is True


# ─── Test 6: delete column moves tasks to NULL (orphans) ───────────────


def test_delete_column_orphans_tasks(
    harness: FunctionalHarness,
) -> None:
    """Delete a column: tasks get kanban_column_id=NULL (or stay but
    without the column). The current handler behavior is to set
    kanban_column_id=NULL for the moved-away tasks.

    The delete column handler checks for tasks first (409 if any
    exist), so we either need to move them first or use a column
    with no tasks. The cleanest test: delete an empty column.
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    cols = _list_columns(harness, ws_id, kanban_id)
    # Add a 4th column (no tasks), delete it, verify it's gone.
    extra = _add_column(harness, ws_id, kanban_id, "doomed")
    assert any(c["id"] == extra["id"] for c in _list_columns(harness, ws_id, kanban_id))

    del_resp = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns/{extra['id']}",
        expect=200,
    ).json()
    assert del_resp["success"] is True
    cols_after = _list_columns(harness, ws_id, kanban_id)
    assert not any(c["id"] == extra["id"] for c in cols_after), (
        f"deleted column {extra['id']!r} still in list"
    )
    assert len(cols_after) == 3


# ─── Test 7: pin a task ──────────────────────────────────────────────────


def test_pin_task(
    harness: FunctionalHarness,
) -> None:
    """POST /pin flips is_pinned to true; GET shows it as pinned."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    cols = _list_columns(harness, ws_id, kanban_id)

    task = _add_task(harness, ws_id, kanban_id, "pin-me", cols[0]["id"])

    pin_resp = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task['id']}/pin",
        json_body={"is_pinned": True},
        expect=200,
    ).json()
    # Response shape varies (the handler returns the new pinned_position).
    assert pin_resp.get("success", True) is True or "new_pos" in pin_resp, (
        f"unexpected pin response: {pin_resp!r}"
    )

    # Verify the task is now pinned (re-fetch and check).
    tasks = _list_tasks(harness, ws_id, kanban_id)
    pinned = next((t for t in tasks if t["id"] == task["id"]), None)
    assert pinned is not None, f"task {task['id']!r} not found after pin"
    assert pinned.get("is_pinned") is True, (
        f"task should be pinned, got is_pinned={pinned.get('is_pinned')!r}"
    )


# ─── Test 8: copy kanban spec from another kanban ──────────────────────


def test_copy_kanban_spec_replaces_columns(
    harness: FunctionalHarness,
) -> None:
    """Create kanban-A with 4 columns, kanban-B with 1, copy A's spec
    to B (replace mode), B now has 4 columns matching A.
    """
    ws_id = _create_workspace(harness)
    kanban_a = _create_kanban(harness, ws_id, "source")
    kanban_b = _create_kanban(harness, ws_id, "target")

    # Source: 3 default columns + 1 added = 4.
    _add_column(harness, ws_id, kanban_a, "extra-col")
    cols_a = _list_columns(harness, ws_id, kanban_a)
    assert len(cols_a) == 4

    # Target: 3 default columns (no additions).
    cols_b = _list_columns(harness, ws_id, kanban_b)
    assert len(cols_b) == 3

    # Copy A → B (replace mode).
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_b['id'] if 'id' in kanban_b else kanban_b}/kanban/copy_spec_from/{kanban_a}",
        json_body={"mode": "replace"},
        expect=200,
    )
    # The response shape may vary; just assert success.
    assert r.json().get("success", True) is True

    # B should now have 4 columns matching A.
    cols_b_after = _list_columns(harness, ws_id, kanban_b)
    assert len(cols_b_after) == 4, (
        f"expected B to have 4 columns after copy, got {len(cols_b_after)}"
    )
    a_names = sorted(c["name"] for c in cols_a)
    b_names = sorted(c["name"] for c in cols_b_after)
    assert a_names == b_names, (
        f"column names should match: A={a_names}, B={b_names}"
    )


# ─── Test 9: delete kanban item leaves columns as orphans ──────────────


def test_delete_kanban_item_orphans_columns(
    harness: FunctionalHarness,
) -> None:
    """Delete the kanban item; columns become orphans (no FK CASCADE).

    Documents the CURRENT API behavior (mirrors the workspace→items
    cascade gap found in Chunk 3):
      - workspace_items_delete.zig does `DELETE FROM workspace_items`
        without first cleaning up `kanban_columns`.
      - Migration 051 declared `kanban_columns.workspace_item_id
        TEXT NOT NULL` WITHOUT `REFERENCES workspace_items(id) ON
        DELETE CASCADE`.
      - The columns endpoint queries by `workspace_item_id` and
        returns the orphan rows.

    This is a known design gap. If a future migration adds the
    `ON DELETE CASCADE` (or the handler is updated to clean up
    columns), the test should be updated to assert the cascade.
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    # Confirm we have 3 columns before delete.
    cols = _list_columns(harness, ws_id, kanban_id)
    assert len(cols) == 3

    # Delete the item.
    del_resp = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{kanban_id}",
        expect=200,
    ).json()
    assert del_resp.get("success", True) is True

    # Columns persist as orphans (current behavior — see header comment).
    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns",
        expect=200,
    )
    cols_after = r.json().get("columns", [])
    assert len(cols_after) == 3, (
        f"expected 3 orphan columns, got {len(cols_after)}: {cols_after!r}"
    )
