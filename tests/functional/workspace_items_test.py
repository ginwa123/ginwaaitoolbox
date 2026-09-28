"""Functional tests for workspace items full CRUD.

Exercises the workspace + item HTTP surface that's NOT covered by
`workspace_lifecycle_test.py`:

  - GET  /api/workspaces/:id                (single workspace fetch + 404)
  - GET  /api/workspaces/:ws/items/:id      (single item fetch + 404)
  - PUT  /api/workspaces/:ws/items/:id      (rename + empty-name rejection
                                             + path updates + absent-body
                                             rejection + 404)
  - DELETE /api/workspaces/:ws/items/:id    (item removal + cascade-removes
                                             on-disk .nalar/design/ for
                                             design items + 404)
  - POST /api/workspaces/:ws/items/reorder  (reorder of mixed item types)

Each test boots a fresh nalar (function-scoped fixture). Real-data
shapes: 3+ items per workspace; for the cascade test, a design item
with 3 pages × 2 elements so we have on-disk state worth deleting.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "items-crud-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_item(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str,
    item_type: str = "chat",
    path: str = "/tmp/nalar-items-crud",
) -> dict[str, Any]:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items",
        json_body={"name": name, "item_type": item_type, "path": path},
        expect=201,
    )
    return r.json()


def _create_design_item(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str,
    path: Path,
) -> dict[str, Any]:
    """Create a design item pointing at an on-disk path.

    Design items need a real path so the on-disk design_io folder
    `<path>/.nalar/design/` can be created on demand. The path is
    created by the conftest's `item_workspace_path` fixture.
    """
    return _create_item(harness, workspace_id, name, "design", str(path))


def _get_item(
    harness: FunctionalHarness, workspace_id: str, item_id: str
) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{item_id}",
        expect=200,
    )
    return r.json()


def _list_items(harness: FunctionalHarness, workspace_id: str) -> list[dict[str, Any]]:
    r = harness.http(
        "GET", f"/api/workspaces/{workspace_id}/items", expect=200
    )
    body = r.json()
    if isinstance(body, dict) and "items" in body:
        return body["items"]
    if isinstance(body, list):
        return body
    raise AssertionError(f"unexpected items response shape: {body!r}")


def _create_design_page(
    harness: FunctionalHarness,
    workspace_id: str,
    design_id: str,
    name: str = "Page",
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{design_id}/design/pages",
        json_body={"name": name, "width": 1440, "height": 1024},
        expect=201,
    )
    return r.json()["id"]


def _add_design_element(
    harness: FunctionalHarness,
    workspace_id: str,
    design_id: str,
    page_id: str,
    name: str,
    html: str = "<div>x</div>",
) -> dict[str, Any]:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{design_id}/design/pages/{page_id}/elements",
        json_body={
            "name": name,
            "type": "rectangle",
            "html": html,
            "fill": "#000000",
            "x": 0,
            "y": 0,
            "width": 100,
            "height": 100,
        },
        expect=201,
    )
    return r.json()


# ─── Test 1: GET /api/workspaces/:id round-trips the created fields ──────


def test_get_workspace_by_id_returns_full_record(
    harness: FunctionalHarness,
) -> None:
    """POST then GET-by-id; assert name, id, and timestamps round-trip.

    The handler returns `{"id":..., "name":..., "created_at":...,
    "updated_at":...}` (workspace_get.zig:97-103). `created_at` and
    `updated_at` come from SQLite's `datetime('now')` and are
    non-empty ISO-8601-ish strings.

    Regression guard for the 0xAA-byte bug: the prior implementation
    of `workspace_get.zig::useCase` returned slice headers into the
    SQLite row's arena, but `defer row.deinit(allocator)` fired
    before the handler's `std.fmt.allocPrint` consumed them — the
    JSON body ended up with `0xAA` bytes (Zig debug allocator's free
    fill) where the id/name should be. The fix dupes the strings in
    useCase before the defer fires. See
    `zig-slice-headers-across-defer-lifetimes` skill.
    """
    ws_id = _create_workspace(harness, "get-by-id")

    r = harness.http("GET", f"/api/workspaces/{ws_id}", expect=200)
    body = r.json()

    # The body must contain real workspace data, not 0xAA bytes
    # (the classic symptom of a use-after-free on the row's arena).
    body_str = r.body.decode("utf-8", errors="replace")
    assert "\xaa" not in body_str, (
        f"GET workspace body contains 0xAA bytes (use-after-free in "
        f"workspace_get.zig::useCase):\n  body = {body_str!r}"
    )

    assert body["id"] == ws_id, (
        f"id should round-trip, got {body.get('id')!r} (expected {ws_id!r})"
    )
    assert body["name"] == "get-by-id", (
        f"name should round-trip, got {body.get('name')!r}"
    )
    # Timestamps come back as non-empty strings (datetime('now') default).
    assert isinstance(body.get("created_at"), str) and body["created_at"], (
        f"created_at should be a non-empty string, got: {body.get('created_at')!r}"
    )
    assert isinstance(body.get("updated_at"), str) and body["updated_at"], (
        f"updated_at should be a non-empty string, got: {body.get('updated_at')!r}"
    )


# ─── Test 2: GET /api/workspaces/:id returns 404 with consistent body shape ─


def test_get_workspace_by_id_404_for_nonexistent(
    harness: FunctionalHarness,
) -> None:
    """GET ws_nope returns 404 with body `{"error": "..."}`.

    workspace_get.zig:104-108 sends `{"error":"Workspace not found"}`.
    """
    r = harness.http("GET", "/api/workspaces/ws_nope", expect=404)
    body = r.json()
    assert "error" in body, (
        f"404 should include an 'error' field, got: {body!r}"
    )
    assert "Workspace not found" in body["error"], (
        f"404 error message should mention 'Workspace not found', got: {body['error']!r}"
    )


# ─── Test 3: GET item-by-id returns the right item_type + path for each ──


def test_get_item_by_id_returns_mixed_item_types(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """Create chat + kanban + design; GET each by id; verify item_type.

    The wire shape is `WorkspaceItemGetResponse` — fields are all
    nullable except `id, workspace_id, item_type`. `name`, `path`,
    `created_at`, `updated_at` come from the DB row.
    """
    ws_id = _create_workspace(harness)
    base = str(item_workspace_path)

    chat = _create_item(harness, ws_id, "chat-item", "chat", base)
    kanban = _create_item(harness, ws_id, "kanban-item", "kanban", base)
    design = _create_design_item(harness, ws_id, "design-item", item_workspace_path)

    for item, expected_type in [
        (chat, "chat"),
        (kanban, "kanban"),
        (design, "design"),
    ]:
        got = _get_item(harness, ws_id, item["id"])
        assert got["id"] == item["id"]
        assert got["item_type"] == expected_type, (
            f"item_type mismatch for {item['id']}: "
            f"expected {expected_type!r}, got {got['item_type']!r}"
        )
        assert got["workspace_id"] == ws_id
        # The path round-trips (the create handler persists it for
        # all three types — chat/kanban typically ignore it client-
        # side but the column accepts it).
        assert got.get("path") == base, (
            f"path round-trip mismatch for {expected_type}: "
            f"expected {base!r}, got {got.get('path')!r}"
        )


# ─── Test 4: GET item-by-id 404 for nonexistent ──────────────────────────


def test_get_item_by_id_404_for_nonexistent(
    harness: FunctionalHarness,
) -> None:
    """GET item_nope returns 404 with `{"error": "..."}`.

    workspace_items_get.zig:64-77 maps `WorkspaceItemNotFound` → 404
    with message "Workspace item not found".
    """
    ws_id = _create_workspace(harness)
    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/item_nope",
        expect=404,
    )
    body = r.json()
    assert "error" in body
    assert "Workspace item not found" in body["error"]


# ─── Test 5: PUT item renames it; name round-trips through GET ────────────


def test_update_item_name_round_trips(
    harness: FunctionalHarness,
) -> None:
    """PUT {name: "new"} → GET returns the new name; DB column updated.

    workspace_items_update.zig:1-7 documents the path-update branch,
    but the most common caller is the rename flow (PUT {name: ...}).

    The PUT response intentionally omits `name` (and `path`,
    `created_at`, `updated_at`) — those are always `null` in the
    response, even when the body updated them. The pattern is
    `WorkspaceItemGetResponse` with `name: ?[]const u8 = null`
    (http_response.zig:77). The contract is "the frontend re-fetches
    via GET to see the freshly-updated DB row"; the test mirrors
    that and asserts the rename via GET, not via the PUT response.
    """
    ws_id = _create_workspace(harness)
    item = _create_item(harness, ws_id, "before-rename", "chat", "/tmp/nalar-items-crud")

    put_body = harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{item['id']}",
        json_body={"name": "after-rename"},
        expect=200,
    ).json()
    # The PUT response is the same `WorkspaceItemGetResponse` shape.
    assert put_body["id"] == item["id"]
    # The PUT response does NOT echo the new `name` value — the
    # handler always returns `name: null` (the field is defaulted
    # on the response struct). We document the contract here so a
    # future refactor that breaks it surfaces as a clean test failure.
    assert put_body.get("name") is None, (
        f"PUT response should leave name as null (the frontend re-fetches "
        f"via GET), got {put_body.get('name')!r}"
    )

    # GET-by-id reflects the rename.
    got = _get_item(harness, ws_id, item["id"])
    assert got["name"] == "after-rename", (
        f"GET should show the new name, got {got['name']!r}"
    )

    # The list endpoint also reflects the rename.
    items = _list_items(harness, ws_id)
    found = next((i for i in items if i["id"] == item["id"]), None)
    assert found is not None, f"item {item['id']!r} missing from list after rename"
    assert found["name"] == "after-rename"


# ─── Test 6: PUT with empty name returns 400 ──────────────────────────────


def test_update_item_name_rejects_empty(
    harness: FunctionalHarness,
) -> None:
    """PUT {name: ""} → 400.

    workspace_items_update.zig:99-132 documents the strict contract:
    if the `name` key is PRESENT but the value is null/empty, reject
    with `name must be a non-empty string when present`. This protects
    the UI from a blank rename leaving the kanban name field showing
    nothing.
    """
    ws_id = _create_workspace(harness)
    item = _create_item(harness, ws_id, "to-be-renamed", "chat", "/tmp/nalar-items-crud")

    r = harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{item['id']}",
        json_body={"name": ""},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert "name" in body["error"].lower(), (
        f"empty-name error should mention 'name', got: {body['error']!r}"
    )

    # The original name is preserved (handler rejects before any DB write).
    got = _get_item(harness, ws_id, item["id"])
    assert got["name"] == "to-be-renamed"


# ─── Test 7: PUT with empty body returns 400 ──────────────────────────────


def test_update_item_rejects_empty_body(
    harness: FunctionalHarness,
) -> None:
    """PUT {} → 400.

    workspace_items_update.zig:156-161 enforces "at least one of
    item_type, name, or path is required". A bare PUT that sends
    nothing is a no-op that must NOT silently succeed.
    """
    ws_id = _create_workspace(harness)
    item = _create_item(harness, ws_id, "doomed-empty-put", "chat", "/tmp/nalar-items-crud")

    r = harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{item['id']}",
        json_body={},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert (
        "name" in body["error"].lower()
        or "path" in body["error"].lower()
        or "item_type" in body["error"].lower()
    ), f"empty-body error should mention updatable field, got: {body['error']!r}"


# ─── Test 8: PUT 404 for nonexistent item ────────────────────────────────


def test_update_item_404_for_nonexistent(
    harness: FunctionalHarness,
) -> None:
    """PUT /items/item_nope → 404 (the item-existence pre-check fires)."""
    ws_id = _create_workspace(harness)
    r = harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/item_nope",
        json_body={"name": "anything"},
        expect=404,
    )
    body = r.json()
    assert "error" in body
    assert "Workspace item not found" in body["error"]


# ─── Test 9: DELETE removes the item from the list + GET returns 404 ──────


def test_delete_item_removes_from_list(
    harness: FunctionalHarness,
) -> None:
    """DELETE → /items no longer contains it; GET-by-id is now 404.

    The handler returns `{id, success: true}` (the
    `WorkspaceItemResponse` shape from http_response.zig:6).
    """
    ws_id = _create_workspace(harness)
    item = _create_item(harness, ws_id, "doomed", "chat", "/tmp/nalar-items-crud")
    assert any(i["id"] == item["id"] for i in _list_items(harness, ws_id))

    del_body = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{item['id']}",
        expect=200,
    ).json()
    assert del_body.get("success") is True
    assert del_body.get("id") == item["id"]

    # List no longer contains it.
    items_after = _list_items(harness, ws_id)
    assert not any(i["id"] == item["id"] for i in items_after), (
        f"deleted item {item['id']!r} still in list"
    )

    # GET-by-id is now 404 (proves the DB row is gone, not just hidden
    # from the list).
    harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{item['id']}",
        expect=404,
    )


# ─── Test 10: DELETE 404 for nonexistent ─────────────────────────────────


def test_delete_item_404_for_nonexistent(
    harness: FunctionalHarness,
) -> None:
    """DELETE /items/item_nope → 404 with body shape."""
    ws_id = _create_workspace(harness)
    r = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/item_nope",
        expect=404,
    )
    body = r.json()
    assert "error" in body
    assert "Workspace item not found" in body["error"]


# ─── Test 11: POST /reorder changes item display order ────────────────────


def test_reorder_items_changes_display_order(
    harness: FunctionalHarness,
) -> None:
    """Create 7 items of mixed types; POST reorder with a permuted
    list; assert the list endpoint returns them in the new order.

    workspace_items_reorder.zig:124-127 documents the position
    formula: ordered_ids[0] gets the highest position (so it sorts
    to the top via `ORDER BY position DESC`).
    """
    ws_id = _create_workspace(harness)
    base = "/tmp/nalar-items-crud"
    # Create 7 items with deterministic names so we can identify them.
    created = []
    for i in range(7):
        item = _create_item(
            harness,
            ws_id,
            f"item-{i}",
            "chat" if i % 2 == 0 else "kanban",
            base,
        )
        created.append(item)
    ids = [it["id"] for it in created]

    # Sanity: the create-order has ids in ascending id order (or at
    # least in their creation order). Capture the actual returned
    # order from /items.
    initial_items = _list_items(harness, ws_id)
    # The workspace also carries its DEFAULT project (Migration 094), which
    # this test did not create. Exclude it by flag so the comparison is about
    # the seven items under test.
    default_items = [i for i in initial_items if i.get("is_default") == 1]
    assert len(default_items) == 1, f"expected one default project, got {initial_items!r}"
    created_items = [i for i in initial_items if not i.get("is_default")]
    initial_ids = [i["id"] for i in created_items]
    # Confirm the same 7 ids are present (in some order).
    assert set(initial_ids) == set(ids), (
        f"created ids should match listed ids:\n"
        f"  created: {ids}\n  listed:  {initial_ids}"
    )

    # Reorder to [item-6, item-0, item-3, item-2, item-1, item-5, item-4].
    new_order = [ids[6], ids[0], ids[3], ids[2], ids[1], ids[5], ids[4]]
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/reorder",
        json_body={"ordered_ids": new_order},
        expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("count") == 7, f"expected count=7, got {r.get('count')!r}"

    # The list endpoint returns items in `position DESC` order, so
    # ordered_ids[0] is at the top.
    #
    # The workspace's DEFAULT project (Migration 094) is excluded by flag
    # rather than by a `[:7]` slice. It was at the top before the reorder and
    # the reorder pushed the seven above it, so a positional slice silently
    # started comparing the wrong seven ids — which is exactly the kind of
    # assertion that keeps passing while testing something else.
    reordered_items = [
        i for i in _list_items(harness, ws_id) if not i.get("is_default")
    ]
    reordered_ids = [i["id"] for i in reordered_items]
    assert len(reordered_ids) == 7, f"expected 7 reordered items, got {reordered_ids!r}"
    assert reordered_ids == new_order, (
        f"reorder didn't apply:\n  expected: {new_order}\n  got:      {reordered_ids}"
    )


# ─── Test 12: DELETE design item cascade-removes on-disk .nalar/design/ ──


def test_delete_design_item_cascade_removes_html_files(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """Design item with 3 pages × 2 elements → DELETE item →
    `<path>/.nalar/design/` directory is gone.

    workspace_items_delete.zig:77-97 documents the on-disk cleanup:
    for design items, the handler `rmdir`s `<path>/.nalar/design/`
    BEFORE the SQL DELETE. The test verifies the cascade by checking
    the directory is gone (all element files inside it are also gone
    as a side-effect of the rmdir).
    """
    ws_id = _create_workspace(harness)
    design = _create_design_item(harness, ws_id, "design-to-delete", item_workspace_path)

    # Create 3 pages × 2 elements = 6 on-disk HTML files.
    page_ids: list[str] = []
    for i in range(3):
        pid = _create_design_page(harness, ws_id, design["id"], f"Page{i}")
        page_ids.append(pid)
        for j in range(2):
            _add_design_element(
                harness, ws_id, design["id"], pid,
                f"elem-{i}-{j}",
                html=f"<div>page {i} element {j}</div>",
            )

    # Verify the on-disk design folder exists with 6 .html files
    # (3 pages × 2 elements per page = 6).
    design_root = item_workspace_path / ".nalar" / "design"
    assert design_root.exists(), (
        f"design folder should exist before delete at {design_root}"
    )
    html_files = list(design_root.rglob("*.html"))
    assert len(html_files) == 6, (
        f"expected 6 .html files before delete, got {len(html_files)}: "
        f"{[str(f) for f in html_files]}"
    )

    # DELETE the design item.
    del_resp = harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{design['id']}",
        expect=200,
    ).json()
    assert del_resp.get("success") is True

    # The on-disk design folder is gone (cascade-rmdir). The DB row
    # is also gone (verified via list).
    assert not design_root.exists(), (
        f"design folder {design_root} should be gone after item delete. "
        f"Contents left behind: {list(design_root.rglob('*')) if design_root.exists() else 'gone'}"
    )
    items_after = _list_items(harness, ws_id)
    assert not any(i["id"] == design["id"] for i in items_after)


# ─── Test 13: DELETE chat item doesn't touch sibling items ───────────────


def test_delete_chat_item_does_not_touch_other_items(
    harness: FunctionalHarness,
) -> None:
    """5 items of mixed types; DELETE chat item #3; the other 4 are
    untouched (no FK cascade surprise, no orphan rows that the API
    forgets about).

    This is a regression guard for future migrations that add
    `ON DELETE CASCADE` to workspace_items' dependents (kanban_columns,
    design_pages). If a future migration cascades too aggressively,
    the other items should still be queryable + listed.
    """
    ws_id = _create_workspace(harness)
    base = "/tmp/nalar-items-crud"

    # 5 items of varied types.
    items = [
        _create_item(harness, ws_id, "alpha", "chat", base),
        _create_item(harness, ws_id, "bravo", "kanban", base),
        _create_item(harness, ws_id, "charlie-target", "chat", base),
        _create_item(harness, ws_id, "delta", "kanban", base),
        _create_item(harness, ws_id, "echo", "chat", base),
    ]
    target = items[2]
    others = [it for it in items if it["id"] != target["id"]]

    # Delete the chat item.
    harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{target['id']}",
        expect=200,
    )

    # The other 4 items are still present and GET-able.
    listed = _list_items(harness, ws_id)
    listed_ids = {it["id"] for it in listed}
    for it in others:
        assert it["id"] in listed_ids, (
            f"sibling item {it['id']!r} (type={it['item_type']!r}) "
            f"missing from list after sibling delete"
        )
        # GET-by-id still works (the DB row is intact).
        got = _get_item(harness, ws_id, it["id"])
        assert got["id"] == it["id"]
        assert got["item_type"] == it["item_type"]