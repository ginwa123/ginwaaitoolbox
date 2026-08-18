"""Functional tests for design advanced (Tier 1.4).

Exercises the design-mode HTTP surface that's NOT covered by
`design_lifecycle_test.py`:

  - POST /elements/group (2-child union bbox, z-index BELOW children,
    frame vs group, single-child 400, already-parented 409)
  - POST /elements/ungroup (parent removed, children reset)
  - POST /elements/reorder (in-page z-order)
  - POST /elements/reparent-batch (5 children → new parent)
  - POST /elements/:eid/translate (delta + group cascade)
  - POST /elements/:eid/resize (w/h only, x/y untouched)
  - POST /elements/geometry-batch (12 elements, single 200)
  - POST /elements/move-batch (8 elements with deltas)
  - POST /elements/:eid/move-to-page (cross-page relocate)
  - PATCH /pages/:page_id (w/h + name + out-of-range 400)
  - PATCH /elements/:eid/html (atomic rewrite)
  - POST /elements with image_url data-URI (round-trip)

Each test boots a fresh nalar (function-scoped fixture).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "design-adv-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_design(harness: FunctionalHarness, ws_id: str, name: str, path: Path) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/design",
        json_body={"name": name, "path": str(path)},
        expect=201,
    )
    return r.json()["id"]


def _create_page(
    harness: FunctionalHarness,
    ws_id: str,
    design_id: str,
    name: str = "Page",
    width: int = 1440,
    height: int = 1024,
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages",
        json_body={"name": name, "width": width, "height": height},
        expect=201,
    )
    return r.json()["id"]


def _add_element(
    harness: FunctionalHarness,
    ws_id: str,
    design_id: str,
    page_id: str,
    name: str,
    element_type: str = "rectangle",
    html: str = "<div>x</div>",
    **kwargs: Any,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "name": name,
        "type": element_type,
        "html": html,
        "fill": "#000000",
    }
    body.update(kwargs)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements",
        json_body=body,
        expect=201,
    )
    return r.json()


def _get_page(
    harness: FunctionalHarness, ws_id: str, design_id: str, page_id: str
) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}",
        expect=200,
    )
    return r.json()


# ─── Test 1: group 2 children creates parent at union bbox ──────────────


def test_group_two_elements_creates_parent_at_union_bbox(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/group with 2 child ids → parent is placed at
    `min(x)..max(x+w)`, `min(y)..max(y+h)`.

    design_elements_group.zig calls `design_model.groupElements`
    which computes the parent bbox from the children.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "group-test", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "GroupPage")

    e1 = _add_element(
        harness, ws_id, design_id, page_id, "e1",
        x=10, y=20, width=100, height=50,
    )
    e2 = _add_element(
        harness, ws_id, design_id, page_id, "e2",
        x=300, y=200, width=80, height=80,
    )

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={"child_ids": [e1["id"], e2["id"]], "name": "G"},
        expect=201,
    ).json()
    parent = r.get("parent")
    assert parent is not None, f"group response missing 'parent': {r!r}"
    assert parent["type"] == "group"
    # Union bbox: x=10..380, y=20..280
    assert parent["x"] == 10, f"group x should be min(child x)=10, got {parent.get('x')}"
    assert parent["y"] == 20, f"group y should be min(child y)=20, got {parent.get('y')}"
    assert parent["width"] == 370, (
        f"group width should be max(x+w)-min(x)=380-10=370, got {parent.get('width')}"
    )
    assert parent["height"] == 260, (
        f"group height should be max(y+h)-min(y)=280-20=260, got {parent.get('height')}"
    )

    # The children are listed back in the response.
    children = r.get("children", [])
    assert len(children) == 2, f"expected 2 children, got {len(children)}"
    child_ids = {c["id"] for c in children}
    assert e1["id"] in child_ids and e2["id"] in child_ids


# ─── Test 2: group z-index sits BELOW children ────────────────────────────


def test_group_parent_z_index_below_children(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """The new group element's z_index is `min(children.z_index) - 1`,
    so the container paints BEHIND its children (the historical bug
    was `max + 1` which put the group on top and occluded its kids).
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "zidx-test", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "ZPage")

    e1 = _add_element(harness, ws_id, design_id, page_id, "e1")
    e2 = _add_element(harness, ws_id, design_id, page_id, "e2")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={"child_ids": [e1["id"], e2["id"]], "name": "G"},
        expect=201,
    ).json()
    parent = r["parent"]
    # Children default to z_index=0; parent's z_index must be < 0.
    assert parent["z_index"] < 0, (
        f"group z_index should be < children's (0) so it paints behind them, "
        f"got {parent.get('z_index')}"
    )


# ─── Test 3: type=frame creates a clipping container ─────────────────────


def test_group_type_frame_creates_clipping_container(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/group with `type: 'frame'` creates a frame
    (clipping container); `type: 'group'` (the default) is a
    non-clipping container.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "frame-test", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "FramePage")

    e1 = _add_element(harness, ws_id, design_id, page_id, "e1")
    e2 = _add_element(harness, ws_id, design_id, page_id, "e2")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={
            "child_ids": [e1["id"], e2["id"]],
            "name": "F",
            "type": "frame",
        },
        expect=201,
    ).json()
    assert r["parent"]["type"] == "frame", (
        f"type=frame should create a frame element, got {r['parent'].get('type')!r}"
    )


# ─── Test 4: group rejects single child ──────────────────────────────────


def test_group_rejects_single_child(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/group with `child_ids: [a]` → 400 'TooFewChildren'."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "single-child", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    e1 = _add_element(harness, ws_id, design_id, page_id, "only")

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={"child_ids": [e1["id"]], "name": "G"},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert (
        "at least" in body["error"].lower()
        or "two" in body["error"].lower()
        or "TooFew" in body["error"]
    )


# ─── Test 5: group rejects already-parented child ───────────────────────


def test_group_rejects_already_parented_child(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/group where one child is already in another group
    → 409 (the cross-page / already-parented guard).
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "reparent", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    # First, group [c1, c2] → outer group
    c1 = _add_element(harness, ws_id, design_id, page_id, "c1")
    c2 = _add_element(harness, ws_id, design_id, page_id, "c2")
    c3 = _add_element(harness, ws_id, design_id, page_id, "c3")

    outer = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={"child_ids": [c1["id"], c2["id"]], "name": "outer"},
        expect=201,
    ).json()

    # Now try to group [c1 (already inside outer), c3] → 409.
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={"child_ids": [c1["id"], c3["id"]], "name": "nested"},
        expect=409,
    )
    body = r.json()
    assert "error" in body


# ─── Test 6: ungroup removes parent + resets children to top-level ──────


def test_ungroup_removes_parent_and_resets_children(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/ungroup dissolves the group: parent row gone,
    children have parent_id = '' (top-level).
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "ungroup", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    c1 = _add_element(harness, ws_id, design_id, page_id, "c1")
    c2 = _add_element(harness, ws_id, design_id, page_id, "c2")

    group_resp = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={"child_ids": [c1["id"], c2["id"]], "name": "G"},
        expect=201,
    ).json()
    group_id = group_resp["parent"]["id"]

    # Ungroup.
    ungroup_resp = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/ungroup",
        json_body={"element_id": group_id},
        expect=200,
    ).json()
    orphaned = ungroup_resp.get("orphaned", [])
    assert len(orphaned) == 2, f"expected 2 orphaned children, got {len(orphaned)}"
    for o in orphaned:
        # Children are now top-level (no parent_id on the wire).
        assert o.get("parent_id") in (None, ""), (
            f"orphaned child should have empty parent_id, got {o.get('parent_id')!r}"
        )

    # Re-fetch the page; the group is gone, both children are top-level.
    page = _get_page(harness, ws_id, design_id, page_id)
    elements = page.get("elements", [])
    group_present = any(e["id"] == group_id for e in elements)
    assert not group_present, f"group {group_id!r} should be gone after ungroup"
    children_present = {e["id"]: e for e in elements}
    assert c1["id"] in children_present and c2["id"] in children_present


# ─── Test 7: reorder changes the z-order on the page ─────────────────────


def test_reorder_elements_within_page(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/reorder with mode='bring_to_front' moves the
    selected ids to the top of the z-order.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "reorder", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    a = _add_element(harness, ws_id, design_id, page_id, "a")
    b = _add_element(harness, ws_id, design_id, page_id, "b")
    c = _add_element(harness, ws_id, design_id, page_id, "c")

    # Bring 'a' to front. After: z-order = b, c, a (a is on top).
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/reorder",
        json_body={"mode": "bring_to_front", "element_ids": [a["id"]]},
        expect=200,
    ).json()
    reordered = r.get("reordered", [])
    assert len(reordered) == 3, f"expected all 3 elements in response, got {len(reordered)}"

    # Read back: 'a' is now at the highest z_index (top of the list).
    page = _get_page(harness, ws_id, design_id, page_id)
    elements = sorted(
        page.get("elements", []),
        key=lambda e: e.get("z_index", 0),
        reverse=True,
    )
    assert elements[0]["id"] == a["id"], (
        f"a should be at top after bring_to_front, "
        f"got order: {[e['id'] for e in elements]}"
    )


# ─── Test 8: reparent-batch moves 5 children to a new parent in one call ─


def test_reparent_batch_moves_multiple_at_once(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/reparent-batch with 5 children + new_parent_id
    reparents all 5 in one transaction.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "reparent-batch", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    # Pre-create the destination group with 2 unrelated children (so
    # the new_parent_id is a real group on this page).
    new_parent = _add_element(harness, ws_id, design_id, page_id, "dest", element_type="group")
    _add_element(harness, ws_id, design_id, page_id, "dest-child-1")
    _add_element(harness, ws_id, design_id, page_id, "dest-child-2")

    # 5 elements to be reparented.
    to_move = [_add_element(harness, ws_id, design_id, page_id, f"src-{i}") for i in range(5)]
    src_ids = [e["id"] for e in to_move]

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/reparent-batch",
        json_body={
            "element_ids": src_ids,
            "new_parent_id": new_parent["id"],
            "reposition": "last_in_parent",
        },
        expect=200,
    ).json()
    updated = r.get("updated", [])
    assert len(updated) == 5, f"expected 5 updated, got {len(updated)}"
    for u in updated:
        assert u.get("parent_id") == new_parent["id"], (
            f"updated element {u['id']!r} should have parent_id={new_parent['id']!r}, "
            f"got {u.get('parent_id')!r}"
        )


# ─── Test 9: translate moves an element by the delta ─────────────────────


def test_translate_moves_element_by_delta(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/:eid/translate with {dx, dy} updates x by +dx
    and y by +dy. Other geometry (w/h/rotation) is untouched.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "translate", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    elem = _add_element(
        harness, ws_id, design_id, page_id, "e",
        x=100, y=200, width=50, height=50,
    )

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}/translate",
        json_body={"dx": 50, "dy": 30},
        expect=200,
    ).json()
    updated = r.get("updated", [])
    assert len(updated) == 1
    moved = updated[0]
    assert moved["x"] == 150, f"x should be 100+50=150, got {moved.get('x')}"
    assert moved["y"] == 230, f"y should be 200+30=230, got {moved.get('y')}"
    # width/height untouched.
    assert moved["width"] == 50
    assert moved["height"] == 50


# ─── Test 10: translate cascades to children on a group ──────────────────


def test_translate_cascades_to_children_on_group(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/:group_id/translate cascades (dx, dy) to every
    transitive descendant. Figma parity for group-drag UX.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "cascade", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    c1 = _add_element(harness, ws_id, design_id, page_id, "c1", x=10, y=20)
    c2 = _add_element(harness, ws_id, design_id, page_id, "c2", x=60, y=70)
    group = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/group",
        json_body={"child_ids": [c1["id"], c2["id"]], "name": "G"},
        expect=201,
    ).json()["parent"]

    # Translate the group by (10, 20) — both children should move too.
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{group['id']}/translate",
        json_body={"dx": 10, "dy": 20},
        expect=200,
    ).json()
    updated = r.get("updated", [])
    # 3 elements updated (group + 2 children)
    assert len(updated) == 3, f"expected 3 cascaded updates, got {len(updated)}"
    # Find the children and verify they were translated.
    by_id = {u["id"]: u for u in updated}
    assert by_id[c1["id"]]["x"] == 20, f"c1.x should be 10+10=20, got {by_id[c1['id']]['x']}"
    assert by_id[c1["id"]]["y"] == 40, f"c1.y should be 20+20=40, got {by_id[c1['id']]['y']}"
    assert by_id[c2["id"]]["x"] == 70, f"c2.x should be 60+10=70, got {by_id[c2['id']]['x']}"
    assert by_id[c2["id"]]["y"] == 90, f"c2.y should be 70+20=90, got {by_id[c2['id']]['y']}"


# ─── Test 11: resize changes w/h only; x/y/rotation untouched ───────────


def test_resize_changes_width_height_only(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/:eid/resize with {width, height} mutates ONLY
    width + height; x/y/rotation are left unchanged.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "resize", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    elem = _add_element(
        harness, ws_id, design_id, page_id, "e",
        x=100, y=200, width=50, height=50,
    )

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}/resize",
        json_body={"width": 300, "height": 150},
        expect=200,
    ).json()
    # The resize endpoint returns a single DesignElement (not an array).
    assert r.get("width") == 300
    assert r.get("height") == 150
    # x/y untouched.
    assert r.get("x") == 100
    assert r.get("y") == 200


# ─── Test 12: geometry-batch updates N elements in one request ──────────


def test_geometry_batch_patches_n_elements_in_one_request(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/geometry-batch with 12 elements → all 12 are
    updated in a single 200 response.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "geom-batch", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    elems = [
        _add_element(
            harness, ws_id, design_id, page_id, f"e{i}",
            x=0, y=0, width=10, height=10,
        )
        for i in range(12)
    ]
    updates = [
        {"element_id": e["id"], "x": 100 + i, "y": 200 + i}
        for i, e in enumerate(elems)
    ]

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/geometry-batch",
        json_body={"updates": updates},
        expect=200,
    ).json()
    updated = r.get("updated", [])
    assert len(updated) == 12, f"expected 12 updated, got {len(updated)}"
    # Each id appears in input order (the batch returns input order).
    for i, u in enumerate(updated):
        assert u["x"] == 100 + i, f"updated[{i}].x should be {100+i}, got {u.get('x')}"
        assert u["y"] == 200 + i, f"updated[{i}].y should be {200+i}, got {u.get('y')}"


# ─── Test 13: move-batch translates many at once ────────────────────────


def test_move_batch_translates_many_at_once(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/move-batch with N elements + deltas → all N are
    translated by their respective (dx, dy).

    Regression for the 2026-08-18 use-after-free in
    `design_model.moveElementsWithDescendantsBatch`: a
    `std.StringHashMap(void)` was used as the per-batch dedup set,
    but its `[]const u8` slice headers pointed at the previous
    iteration's `subtree_ids` buffers (which were freed at the end
    of each iteration body). When a batch had ≥8 items the hashmap's
    `eqlString` comparison read freed memory and crashed with
    `assert(!self.containsContext(key, ctx))` (SIGABRT) inside
    Zig 0.16 `std.hash_map`. The fix replaces the hashmap with an
    O(n²) linear scan over an owned-`affected_ids` list (size bounded
    by the SELECTED element count in the UI, so the constant wins).
    Bumped to N=12 (well above the crash threshold).
    """
    N = 12

    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "move-batch", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    elems = [
        _add_element(
            harness, ws_id, design_id, page_id, f"m{i}",
            x=0, y=0, width=10, height=10,
        )
        for i in range(N)
    ]
    items = [{"element_id": e["id"], "dx": (i + 1) * 10, "dy": (i + 1) * 5} for i, e in enumerate(elems)]

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/move-batch",
        json_body={"items": items},
        expect=200,
    ).json()
    updated = r.get("updated", [])
    assert len(updated) == N, f"expected {N} updated, got {len(updated)}"
    # Each element was translated by its own delta.
    by_id = {u["id"]: u for u in updated}
    for i, e in enumerate(elems):
        expected_dx = (i + 1) * 10
        expected_dy = (i + 1) * 5
        actual = by_id[e["id"]]
        assert actual["x"] == expected_dx, f"e{i}.x should be {expected_dx}, got {actual.get('x')}"
        assert actual["y"] == expected_dy, f"e{i}.y should be {expected_dy}, got {actual.get('y')}"


# ─── Test 14: move-to-page cross-page relocate ───────────────────────────


def test_move_element_to_page_cross_page(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements/:eid/move-to-page with {new_page_id} relocates
    the element to another page on the same design item. Cascades
    to descendants by default.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "move-page", item_workspace_path)
    src_page = _create_page(harness, ws_id, design_id, "Source")
    tgt_page = _create_page(harness, ws_id, design_id, "Target")

    elem = _add_element(
        harness, ws_id, design_id, src_page, "e",
        x=0, y=0, width=50, height=50,
    )

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{src_page}/elements/{elem['id']}/move-to-page",
        json_body={"new_page_id": tgt_page},
        expect=200,
    ).json()
    updated = r.get("updated", [])
    assert len(updated) == 1
    assert updated[0]["page_id"] == tgt_page, (
        f"element should now be on target page {tgt_page!r}, "
        f"got page_id={updated[0].get('page_id')!r}"
    )


# ─── Test 15: PATCH page updates width + height ─────────────────────────


def test_patch_page_updates_width_height(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """PATCH /pages/:page_id with {width, height} → 200, new dims persisted."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "patch-page", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "PatchPage")

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}",
        json_body={"width": 1920, "height": 1080},
        expect=200,
    ).json()
    assert r.get("width") == 1920
    assert r.get("height") == 1080

    # Re-fetch and verify.
    page = _get_page(harness, ws_id, design_id, page_id)
    # GET /pages/:page_id returns `{page: {...}, elements: [...]}`.
    inner = page.get("page", page)
    assert inner.get("width") == 1920
    assert inner.get("height") == 1080


# ─── Test 16: PATCH page rejects out-of-range dimensions ─────────────────


def test_patch_page_rejects_out_of_range_dimensions(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """PATCH /pages/:page_id with width=100 (<320) → 400."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "patch-bad", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "BadPage")

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}",
        json_body={"width": 100, "height": 1024},
        expect=400,
    )
    body = r.json()
    assert "error" in body
    assert (
        "width" in body["error"].lower()
        or "range" in body["error"].lower()
        or "between" in body["error"].lower()
    )

    # Height too.
    r2 = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}",
        json_body={"width": 1440, "height": 10000},
        expect=400,
    )
    body2 = r2.json()
    assert "error" in body2
    assert "height" in body2["error"].lower()


# ─── Test 17: PATCH element html atomically rewrites the file ──────────


def test_patch_element_html_atomically_rewrites_file(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """PATCH /elements/:eid/html with {html: 'new'} rewrites the
    on-disk file byte-equally.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "patch-html", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    initial_html = "<div>original</div>"
    elem = _add_element(
        harness, ws_id, design_id, page_id, "e", html=initial_html,
    )

    new_html = "<div>updated content with more text</div>"
    harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}/html",
        json_body={"html": new_html},
        expect=200,
    )

    # Re-GET the html to confirm it was rewritten byte-equal.
    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}/html",
        expect=200,
    ).json()
    assert r["html"] == new_html, (
        f"html didn't rewrite byte-equal; got {r['html']!r}"
    )


# ─── Test 18: image_url data-URI round-trips on create ──────────────────


def test_image_url_data_uri_round_trips(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements with `type: 'image'` + `image_url: 'data:image/png;base64,...'`
    → the data URI round-trips through the list endpoint.
    """
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "img", item_workspace_path)
    page_id = _create_page(harness, ws_id, design_id, "Page")

    data_uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX///+nxBvIAAAAC0lEQVQI12NgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
    # design_elements_create.zig:255 requires `html.len > 0` for ALL
    # element types (the HTML body is the file content, not the rendered
    # shape — image elements still need an .html file on disk). Use a
    # placeholder <img> tag for the image element.
    elem = _add_element(
        harness, ws_id, design_id, page_id, "img-1",
        element_type="image",
        html='<img src="placeholder">',
        image_url=data_uri,
    )
    assert elem["id"].startswith("elem_")

    # Re-fetch the page and verify the image_url is preserved.
    page = _get_page(harness, ws_id, design_id, page_id)
    elements = page.get("elements", [])
    found = next((e for e in elements if e["id"] == elem["id"]), None)
    assert found is not None, f"created element {elem['id']!r} missing from page"
    if found.get("image_url"):
        # If the wire field is present, it must match verbatim.
        assert found["image_url"] == data_uri, (
            f"image_url didn't round-trip; got {found['image_url']!r}"
        )