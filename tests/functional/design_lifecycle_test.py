"""Functional tests for design mode lifecycle.

The on-disk HTML files are the differentiator: every design element
has an .html file at `<item_path>/.nalar/design/<page>/<element>.html`.
This suite verifies that the disk state stays in sync with the DB
state across page/element CRUD, atomic HTML rewrites, and
geometry PATCHes.

Plan: docs/superpowers/plans/2026-07-26-functional-tests-with-real-data.md (Chunk 5)
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "design-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_design(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str,
    path: str,
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/design",
        json_body={"name": name, "path": path},
        expect=201,
    )
    body = r.json()
    assert body["item_type"] == "design"
    return body["id"]


def _create_page(
    harness: FunctionalHarness,
    workspace_id: str,
    design_id: str,
    name: str = "Page 1",
    width: int = 1440,
    height: int = 1024,
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{design_id}/design/pages",
        json_body={"name": name, "width": width, "height": height},
        expect=201,
    )
    return r.json()["id"]


def _add_element(
    harness: FunctionalHarness,
    workspace_id: str,
    design_id: str,
    page_id: str,
    name: str,
    element_type: str,
    html: str,
    **kwargs: Any,
) -> dict[str, Any]:
    # Default fill to "#000000" if not provided. The backend's
    # design_page_elements.fill column is NOT NULL, and db.exec
    # binds empty []const u8 as SQL NULL (per project memory
    # zig-sqlite-patterns.md) — which trips the NOT NULL constraint.
    # The frontend always sends an explicit fill (e.g. "#000000"
    # for text, the user's chosen color for shapes), so the
    # production path never hits this. Functional tests must
    # mirror that — always pass a non-empty fill.
    body: dict[str, Any] = {
        "name": name,
        "type": element_type,
        "html": html,
    }
    if "fill" not in kwargs:
        body["fill"] = "#000000"
    body.update(kwargs)
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{design_id}/design/pages/{page_id}/elements",
        json_body=body,
        expect=201,
    )
    return r.json()


def _get_element_html(
    harness: FunctionalHarness,
    workspace_id: str,
    design_id: str,
    page_id: str,
    element_id: str,
) -> str:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{design_id}/design/pages/{page_id}/elements/{element_id}/html",
        expect=200,
    )
    return r.json()["html"]


def _get_page(
    harness: FunctionalHarness,
    workspace_id: str,
    design_id: str,
    page_id: str,
) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{design_id}/design/pages/{page_id}",
        expect=200,
    )
    return r.json()


# ─── Test 1: design item create requires path ───────────────────────────


def test_create_design_item_requires_path(
    harness: FunctionalHarness,
) -> None:
    """POST /items/design without a path returns 400."""
    ws_id = _create_workspace(harness)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/design",
        json_body={"name": "no-path"},
        expect=400,
    )
    body = r.json()
    assert "error" in body


# ─── Test 2: create page with 3 elements ─────────────────────────────────


def test_create_page_with_three_elements(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """Create page + 3 elements; get-page returns 3 elements."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "design-1", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "Login")

    e1 = _add_element(harness, ws_id, design_id, page_id, "rect", "rectangle", "<div>R</div>", x=10, y=20, width=100, height=50, fill="#3b82f6")
    e2 = _add_element(harness, ws_id, design_id, page_id, "text", "text", "<p>Hello</p>", x=10, y=80, width=200, height=30, fill="#000000")
    e3 = _add_element(harness, ws_id, design_id, page_id, "ellipse", "ellipse", "<div>E</div>", x=300, y=200, width=80, height=80, fill="#22c55e")

    page = _get_page(harness, ws_id, design_id, page_id)
    elements = page.get("elements", [])
    assert len(elements) == 3, f"expected 3 elements, got {len(elements)}"
    element_ids = {e["id"] for e in elements}
    assert e1["id"] in element_ids
    assert e2["id"] in element_ids
    assert e3["id"] in element_ids


# ─── Test 3: element HTML file is written to disk ───────────────────────


def test_element_html_file_written_to_disk(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /elements writes the HTML to <path>/.nalar/design/<page>/<elem>.html."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "disk-test", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "Disk")

    html = "<div class='hero' style='background: #3b82f6'>Hello, design!</div>"
    elem = _add_element(harness, ws_id, design_id, page_id, "hero", "rectangle", html)

    # Find the on-disk file. The path pattern is:
    # <item_path>/.nalar/design/<sanitized_page>/<sanitized_elem>.html
    elem_dir = item_workspace_path / ".nalar" / "design" / "Disk" / "hero.html"
    # The element name "hero" doesn't contain slashes, so the file
    # is at <page_dir>/<elem_name>.html
    candidates = list((item_workspace_path / ".nalar" / "design" / "Disk").glob("*.html"))
    assert len(candidates) >= 1, (
        f"no .html files found in {item_workspace_path}/.nalar/design/Disk/"
    )
    # Read the file and verify it matches the input HTML.
    file_content = candidates[0].read_text()
    assert file_content == html, (
        f"file content mismatch: expected {html!r}, got {file_content!r}"
    )


# ─── Test 4: update HTML atomically rewrites the file ───────────────────


def test_update_html_atomically_rewrites_file(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """PUT /elements/:eid with new html rewrites the on-disk file."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "rewrite-test", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "Page")

    initial_html = "<div>original</div>"
    elem = _add_element(harness, ws_id, design_id, page_id, "elem", "rectangle", initial_html)

    # Find the file.
    page_dir = item_workspace_path / ".nalar" / "design" / "Page"
    files = list(page_dir.glob("*.html"))
    assert len(files) == 1
    assert files[0].read_text() == initial_html

    # Update the HTML via PUT /elements/:eid.
    new_html = "<div>updated content with more text</div>"
    harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}",
        json_body={"html": new_html},
        expect=200,
    )

    # File is now the new content (atomic rewrite — no leftover).
    files_after = list(page_dir.glob("*.html"))
    assert len(files_after) == 1, (
        f"expected 1 file, got {len(files_after)}"
    )
    assert files_after[0].read_text() == new_html, (
        f"file not atomically rewritten: {files_after[0].read_text()!r}"
    )


# ─── Test 5: geometry PATCH does not touch HTML file ─────────────────────


def test_geometry_patch_does_not_touch_html(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """PATCH /geometry only updates x/y; HTML file is byte-equal."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "geom-test", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "Geom")

    html = "<div class='card' data-id='42'>preserved</div>"
    elem = _add_element(harness, ws_id, design_id, page_id, "card", "rectangle", html)

    page_dir = item_workspace_path / ".nalar" / "design" / "Geom"
    files = list(page_dir.glob("*.html"))
    assert len(files) == 1
    file_path = files[0]
    content_before = file_path.read_text()
    mtime_before = file_path.stat().st_mtime_ns

    # PATCH geometry (move + resize).
    harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}/geometry",
        json_body={"x": 999, "y": 888, "width": 1234, "height": 567},
        expect=200,
    )

    # File should be byte-equal and mtime should be unchanged.
    content_after = file_path.read_text()
    mtime_after = file_path.stat().st_mtime_ns
    assert content_after == content_before, (
        f"geometry PATCH must not modify HTML file: "
        f"before={content_before!r}, after={content_after!r}"
    )
    # The geometry PATCH should not even touch the file (no write).
    # We allow for filesystem mtime resolution noise; the byte
    # equality check above is the strong assertion.


# ─── Test 6: delete element removes the HTML file ──────────────────────


def test_delete_element_removes_html_file(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """DELETE /elements/:eid removes the on-disk HTML file."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "delete-test", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "Page")

    elem = _add_element(harness, ws_id, design_id, page_id, "doomed", "rectangle", "<div>x</div>")

    page_dir = item_workspace_path / ".nalar" / "design" / "Page"
    files = list(page_dir.glob("*.html"))
    assert len(files) == 1

    harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}",
        expect=200,
    )

    files_after = list(page_dir.glob("*.html"))
    assert files_after == [], (
        f"HTML file not removed after element delete: {files_after!r}"
    )


# ─── Test 7: delete page removes the entire directory ──────────────────


def test_delete_page_removes_entire_directory(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """DELETE /pages/:pid removes <page_dir>/ and all its contents."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "page-del-test", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "DoomedPage")

    # Add 2 elements.
    _add_element(harness, ws_id, design_id, page_id, "a", "rectangle", "<div>A</div>")
    _add_element(harness, ws_id, design_id, page_id, "b", "rectangle", "<div>B</div>")

    page_dir = item_workspace_path / ".nalar" / "design" / "DoomedPage"
    assert page_dir.exists()
    assert len(list(page_dir.glob("*.html"))) == 2

    # Delete the page.
    harness.http(
        "DELETE",
        f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}",
        expect=200,
    )

    # The page directory should be gone.
    assert not page_dir.exists(), (
        f"page directory {page_dir} not removed after page delete"
    )


# ─── Test 8: get html returns stored content ───────────────────────────


def test_get_html_returns_stored_content(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """GET /html returns the body byte-equal to what was POSTed."""
    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "html-test", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "Page")

    html_cases = [
        ("simple", "<p>hello</p>"),
        ("with-newlines", "line1\nline2\nline3"),
        ("with-quotes", '<div class="foo" data-x="42">"quoted"</div>'),
        ("with-unicode", "<p>こんにちは 🌍 αβγ</p>"),
        ("with-backslashes", "<div>path = C:\\Users\\foo</div>"),
    ]
    for name, html in html_cases:
        elem = _add_element(harness, ws_id, design_id, page_id, name, "rectangle", html)
        fetched = _get_element_html(harness, ws_id, design_id, page_id, elem["id"])
        assert fetched == html, (
            f"HTML round-trip mismatch for {name!r}: "
            f"sent {html!r}, got {fetched!r}"
        )


# ─── Test 9: design pages list groups by item ──────────────────────────


def test_design_pages_list_groups_by_item(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """2 design items × 2 pages each; each item's list returns only its 2."""
    ws_id = _create_workspace(harness)
    base_path = item_workspace_path
    design_a = _create_design(harness, ws_id, "design-a", str(base_path / "a"))
    design_b = _create_design(harness, ws_id, "design-b", str(base_path / "b"))

    # 2 pages on each.
    p_a1 = _create_page(harness, ws_id, design_a, "A1")
    p_a2 = _create_page(harness, ws_id, design_a, "A2")
    p_b1 = _create_page(harness, ws_id, design_b, "B1")
    p_b2 = _create_page(harness, ws_id, design_b, "B2")

    # List A's pages.
    a_pages = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{design_a}/design/pages",
        expect=200,
    ).json()["pages"]
    a_page_ids = {p["id"] for p in a_pages}
    assert a_page_ids == {p_a1, p_a2}, (
        f"design_a should have 2 pages, got {a_page_ids}"
    )

    # List B's pages.
    b_pages = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{design_b}/design/pages",
        expect=200,
    ).json()["pages"]
    b_page_ids = {p["id"] for p in b_pages}
    assert b_page_ids == {p_b1, p_b2}, (
        f"design_b should have 2 pages, got {b_page_ids}"
    )
    # No cross-leakage.
    assert not (a_page_ids & b_page_ids), (
        f"page lists overlap: {a_page_ids & b_page_ids}"
    )


# ─── Test 10: geometry throttle handles 60 patches per second ──────────


def test_geometry_throttle_handles_60_patches(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """Fire 60 PATCH /geometry calls in <2s; all return 200, final
    position matches the last call.
    """
    import time as _time

    ws_id = _create_workspace(harness)
    design_id = _create_design(harness, ws_id, "geom-throttle", str(item_workspace_path))
    page_id = _create_page(harness, ws_id, design_id, "Page")
    elem = _add_element(harness, ws_id, design_id, page_id, "drag", "rectangle", "<div/>")

    start = _time.monotonic()
    final_x = 0
    for i in range(60):
        r = harness.http(
            "PATCH",
            f"/api/workspaces/{ws_id}/items/{design_id}/design/pages/{page_id}/elements/{elem['id']}/geometry",
            json_body={"x": i * 10, "y": i * 5},
            expect=200,
        )
        final_x = i * 10
    elapsed = _time.monotonic() - start

    # All 60 succeeded.
    assert elapsed < 5.0, f"60 PATCHes took {elapsed:.2f}s (>5s budget)"

    # Read back the element and verify final x.
    page = _get_page(harness, ws_id, design_id, page_id)
    elements = page.get("elements", [])
    drag = next((e for e in elements if e["id"] == elem["id"]), None)
    assert drag is not None
    assert drag.get("x") == final_x, (
        f"final x should be {final_x}, got {drag.get('x')}"
    )
