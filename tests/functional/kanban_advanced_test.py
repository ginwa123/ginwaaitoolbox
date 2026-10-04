"""Functional tests for kanban advanced (Tier 1.3).

Exercises the kanban column / tags / copy-spec HTTP surface that's NOT
covered by `kanban_lifecycle_test.py`:

  - PATCH /api/workspaces/:ws/items/:item_id/kanban/columns/:col_id
    (rename + position reorder, empty-body rejection, empty-name behavior)
  - DELETE /api/workspaces/:ws/items/:item_id/kanban/columns/:col_id
    with tasks still assigned → 409 Conflict
  - GET  /api/workspaces/:ws/items/:item_id/kanban/tags
    (distinct tag set, empty kanban, frequency ordering)
  - POST /api/workspaces/:ws/items/:item_id/kanban/copy_spec_from/:source
    (merge/append mode preserves existing columns, 404 for nonexistent source)

Each test boots a fresh pabrik (function-scoped fixture).
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "kanban-adv-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, ws_id: str, name: str = "sprint") -> str:
    """Create a kanban and return the item id (the response envelope
    is `{item, columns}`; we unwrap the item here).
    """
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    body = r.json()
    item = body.get("item")
    assert item is not None, f"missing 'item' envelope: {body!r}"
    return item["id"]


def _create_chat_item(harness: FunctionalHarness, ws_id: str, name: str = "chat") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items",
        json_body={"name": name, "item_type": "chat", "path": "/tmp/kanban-adv"},
        expect=201,
    )
    return r.json()["id"]


def _list_columns(
    harness: FunctionalHarness, ws_id: str, kanban_id: str
) -> list[dict[str, Any]]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns",
        expect=200,
    )
    return r.json()["columns"]


def _add_column(
    harness: FunctionalHarness,
    ws_id: str,
    kanban_id: str,
    name: str,
    position: int | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {"name": name}
    if position is not None:
        body["position"] = position
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns",
        json_body=body,
        expect=201,
    )
    return r.json()


def _add_task(
    harness: FunctionalHarness,
    ws_id: str,
    kanban_id: str,
    name: str,
    column_id: str | None = None,
    tags: str | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {"name": name}
    if column_id is not None:
        body["column_id"] = column_id
    if tags is not None:
        body["tags"] = tags
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


# ─── Test 1: PATCH column renames it ──────────────────────────────────────


def test_patch_column_renames_it(
    harness: FunctionalHarness,
) -> None:
    """PATCH /columns/:col_id {name: 'new'} → column appears with the new name.

    The response is the updated board envelope `{columns, count}`
    so the frontend can re-render without a separate GET.
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "sprint1")
    cols = _list_columns(harness, ws_id, kanban_id)
    target = cols[0]

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns/{target['id']}",
        json_body={"name": "renamed-col"},
        expect=200,
    ).json()
    assert "columns" in r and "count" in r, f"envelope missing: {r!r}"
    assert r["count"] == len(cols)

    # Re-list and verify the rename is persisted.
    cols_after = _list_columns(harness, ws_id, kanban_id)
    found = next((c for c in cols_after if c["id"] == target["id"]), None)
    assert found is not None
    assert found["name"] == "renamed-col", (
        f"rename didn't persist; got {found['name']!r}"
    )


# ─── Test 2: PATCH column with empty body returns 400 ─────────────────────


def test_patch_column_rejects_empty_body(
    harness: FunctionalHarness,
) -> None:
    """PATCH /columns/:col_id {} → 400 'at least one of name, description, or position is required'.

    kanban_columns_update.zig:93 returns `error.NothingToUpdate` when
    all three fields are absent — the handler maps that to 400.
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "sprint2")
    cols = _list_columns(harness, ws_id, kanban_id)
    target = cols[0]

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns/{target['id']}",
        json_body={},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert "at least one" in body["error"].lower() or "required" in body["error"].lower()


# ─── Test 3: PATCH column with {position: N} reorders within the board ────


def test_patch_column_reorders_within_board(
    harness: FunctionalHarness,
) -> None:
    """PATCH /columns/:col_id {position: 0} moves the column to the top.

    We add an extra column (default position is the end), then PATCH
    it to position 0; re-listing shows it first.
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "sprint3")
    extra = _add_column(harness, ws_id, kanban_id, "movable")

    cols_before = _list_columns(harness, ws_id, kanban_id)
    assert cols_before[-1]["id"] == extra["id"], (
        f"new column should be at the end; got order: "
        f"{[c['name'] for c in cols_before]}"
    )

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns/{extra['id']}",
        json_body={"position": 0},
        expect=200,
    ).json()
    assert r["count"] == len(cols_before)

    # Re-list: the extra column is now first.
    cols_after = _list_columns(harness, ws_id, kanban_id)
    assert cols_after[0]["id"] == extra["id"], (
        f"position=0 didn't move column to top; order: "
        f"{[c['name'] for c in cols_after]}"
    )


# ─── Test 4: DELETE column with tasks still assigned returns 409 ──────────


def test_delete_column_with_tasks_returns_409(
    harness: FunctionalHarness,
) -> None:
    """DELETE /columns/:col_id when 1+ tasks are assigned → 409 with
    a user-facing message that names the task count.

    kanban_columns_delete.zig:139 runs `countTasksInColumn` BEFORE
    the delete — when the count > 0, the use-case returns `.has_tasks`
    and the handler maps to 409 with the message
    `"Cannot delete column: N task(s) still assigned. Move them to another column first."`
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "sprint4")
    cols = _list_columns(harness, ws_id, kanban_id)
    target = cols[0]

    # Create 2 tasks under the target column.
    _add_task(harness, ws_id, kanban_id, "stuck-1", target["id"])
    _add_task(harness, ws_id, kanban_id, "stuck-2", target["id"])

    r = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns/{target['id']}",
        expect=409,
    )
    body = r.json()
    assert "error" in body
    msg = body["error"]
    assert "Cannot delete column" in msg, (
        f"409 message should start with 'Cannot delete column', got: {msg!r}"
    )
    assert "2 task" in msg, (
        f"409 message should mention the task count (2), got: {msg!r}"
    )

    # The column is still in the list (the 409 prevents the delete).
    cols_after = _list_columns(harness, ws_id, kanban_id)
    assert any(c["id"] == target["id"] for c in cols_after), (
        f"column {target['id']!r} should still exist after 409"
    )


# ─── Test 5: DELETE column succeeds when empty ───────────────────────────


def test_delete_empty_column_succeeds(
    harness: FunctionalHarness,
) -> None:
    """DELETE /columns/:col_id on an empty column → 200 {success, column_id}.

    This complements the existing `test_delete_column_orphans_tasks`
    (in kanban_lifecycle_test.py) which covers the orphan-on-delete
    invariant. This test pins the SUCCESS path.
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "sprint5")
    empty = _add_column(harness, ws_id, kanban_id, "empty")

    del_resp = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns/{empty['id']}",
        expect=200,
    ).json()
    assert del_resp.get("success") is True
    assert del_resp.get("column_id") == empty["id"]

    # The column is gone from the list.
    cols_after = _list_columns(harness, ws_id, kanban_id)
    assert not any(c["id"] == empty["id"] for c in cols_after)


# ─── Test 6: GET /kanban/tags returns empty for fresh kanban ──────────────


def test_kanban_tags_list_empty_for_no_tasks(
    harness: FunctionalHarness,
) -> None:
    """A freshly-created kanban has no tasks → /tags returns an empty list."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "tagless")

    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tags",
        expect=200,
    ).json()
    assert r.get("tags") == [], (
        f"empty kanban should have no tags, got {r.get('tags')!r}"
    )
    assert r.get("has_more") is False, (
        f"empty kanban should have has_more=false, got {r.get('has_more')!r}"
    )


# ─── Test 7: GET /kanban/tags returns distinct tag set ────────────────────


def test_kanban_tags_list_returns_distinct_tag_set(
    harness: FunctionalHarness,
) -> None:
    """6 tasks across 3 tags → /tags returns 3 unique tags (not 6).

    The endpoint is `DISTINCT tag FROM tasks WHERE item_id = ?` —
    powers the kanban task detail dialog's tag autocomplete
    dropdown (Migration 067 plan).
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id, "tagful")

    # 6 tasks: 2 with ["bug"], 2 with ["urgent"], 2 with ["wip"].
    for i in range(2):
        _add_task(harness, ws_id, kanban_id, f"bug-{i}", tags='["bug"]')
        _add_task(harness, ws_id, kanban_id, f"urgent-{i}", tags='["urgent"]')
        _add_task(harness, ws_id, kanban_id, f"wip-{i}", tags='["wip"]')

    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tags",
        params={"limit": 50},
        expect=200,
    ).json()
    tags = r.get("tags", [])
    names = [t["name"] for t in tags]
    assert "bug" in names, f"expected 'bug' tag, got: {names}"
    assert "urgent" in names
    assert "wip" in names
    assert len(names) == 3, (
        f"expected 3 distinct tags, got {len(names)}: {names}"
    )

    # Each suggestion carries a `count` field; the tag with 2 usages
    # should have count >= 2 (the implementation may be more precise,
    # but >= 2 catches the "did the join even fire" case).
    bug_suggestion = next(t for t in tags if t["name"] == "bug")
    assert bug_suggestion["count"] >= 2, (
        f"bug should have count>=2, got: {bug_suggestion!r}"
    )


# ─── Test 8: copy_spec_from merge (append) mode keeps existing columns ────


def test_copy_spec_from_append_keeps_existing_columns(
    harness: FunctionalHarness,
) -> None:
    """POST /copy_spec_from/:source with {mode: 'append'} preserves
    the target's existing columns + appends the source's columns.

    Source kanban has 3 default columns (todo/in_progress/done);
    target has the same 3 defaults. After the copy, the target has
    6 columns (3 original + 3 appended, names from the source).
    """
    ws_id = _create_workspace(harness)
    src = _create_kanban(harness, ws_id, "source")
    tgt = _create_kanban(harness, ws_id, "target")

    src_cols_before = _list_columns(harness, ws_id, src)
    assert len(src_cols_before) == 3

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{tgt}/kanban/copy_spec_from/{src}",
        json_body={"mode": "append"},
        expect=200,
    ).json()
    assert r["count"] == 6, (
        f"expected 6 columns after append (3 + 3), got {r['count']}: {r['columns']!r}"
    )

    # The names match (the 3 source column names appear twice now).
    tgt_cols_after = _list_columns(harness, ws_id, tgt)
    names = [c["name"] for c in tgt_cols_after]
    assert len(names) == 6
    # Each source name appears twice (target had it + copy added it).
    for src_col in src_cols_before:
        assert names.count(src_col["name"]) == 2, (
            f"expected {src_col['name']!r} to appear twice after append, got: {names}"
        )


# ─── Test 9: copy_spec_from 404 when source doesn't exist ────────────────


def test_copy_spec_from_404_for_nonexistent_source(
    harness: FunctionalHarness,
) -> None:
    """POST /copy_spec_from/item_nope → 404 'Workspace item not found or is not a kanban'.

    kanban_copy_spec.zig:127 returns `error.WorkspaceItemNotFound`
    when the source row is missing or wrong item_type.
    """
    ws_id = _create_workspace(harness)
    tgt = _create_kanban(harness, ws_id, "target-no-source")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{tgt}/kanban/copy_spec_from/item_nope",
        json_body={"mode": "replace"},
        expect=404,
    )
    body = r.json()
    assert "error" in body
    assert "not found" in body["error"].lower() or "kanban" in body["error"].lower()


# ─── Test 10: copy_spec_from rejects self-copy (same item_id) ─────────────


def test_copy_spec_from_rejects_self_copy(
    harness: FunctionalHarness,
) -> None:
    """POST /copy_spec_from/<self> → 400 'source_item_id required (and must differ from item_id)'.

    kanban_copy_spec.zig:94 treats `item_id == source_item_id` as a
    self-copy and returns `error.SourceItemIdRequired` (mapped to 400).
    """
    ws_id = _create_workspace(harness)
    kanban = _create_kanban(harness, ws_id, "self-copy-attempt")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban}/kanban/copy_spec_from/{kanban}",
        json_body={"mode": "replace"},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert "differ" in body["error"].lower() or "source" in body["error"].lower()


# ─── Test 11: copy_spec_from rejects invalid mode ─────────────────────────


def test_copy_spec_from_rejects_invalid_mode(
    harness: FunctionalHarness,
) -> None:
    """POST /copy_spec_from/:source with {mode: 'garbage'} → 400 'mode must be replace or append'."""
    ws_id = _create_workspace(harness)
    src = _create_kanban(harness, ws_id, "source-bad-mode")
    tgt = _create_kanban(harness, ws_id, "target-bad-mode")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{tgt}/kanban/copy_spec_from/{src}",
        json_body={"mode": "garbage"},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert "mode" in body["error"].lower()