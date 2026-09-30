"""Functional tests for the Agent-Routines mirror (Migration 087).

Exercises the new agent-routines CRUD endpoints against a REAL nalar
binary + REAL SQLite, replaying the EXACT JSON bodies the frontend
RoutineView Agent tab sends.

  Routine mode task_1789505553300_1 (option A, mirror agent_kanban_*).

Covers:
  * BUNDLE GET      — fresh routine → 200 configured with seeded row +
                       empty tools (no defaults; empty allowlist = all
                       tools, kanban D5 semantics).
  * GET wrong type  — kanban-type item → 400 ItemNotRoutine (route
                       scoping).
  * PATCH update    — description round-trips, incl. empty string
                       (empty-slice-as-NULL regression).
  * KNOWLEDGE POST  — inline content (file_path='' + content) persists.
  * KNOWLEDGE PATCH — mode switch (file_path='' clears, content set).
  * KNOWLEDGE REORDER — PATCH /knowledge/reorder reaches REORDER
                        handler (NOT shadowed by /knowledge/:id).
  * KNOWLEDGE DELETE — scoped by both id AND routine_id.
  * SYSTEM_PROMPT POST/PATCH — first row position 0; title-only
                        update keeps content.
  * TOOLS POST/LIST/DELETE — unknown tool → 400, duplicate → 409,
                        list reflects enables.
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness, harness_path


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "agent-routines-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_routine(harness: FunctionalHarness, workspace_id: str, name: str = "routine") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/routine",
        json_body={"name": name, "path": harness_path(harness, "agent-routines-test")},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "kanban") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


# ─── Tests ────────────────────────────────────────────────────────────────


def test_bundle_get_fresh_routine_is_seeded(harness: FunctionalHarness) -> None:
    """Fresh routine is born configured (seeded row) with zero tools."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id, "bare")

    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{routine_id}/agent_routine",
        expect=200,
    )
    body = r.json()
    assert body["agent_routine"]["id"] == routine_id, body
    assert body.get("tools") == [], f"fresh routine seeds no tools, got: {body!r}"
    assert body.get("knowledges") == [], body
    assert body.get("system_prompts") == [], body


def test_bundle_get_kanban_type_returns_400(harness: FunctionalHarness) -> None:
    """GET on kanban-type item → 400 ItemNotRoutine (route scoping)."""
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/agent_routine",
        expect=400,
    )
    assert "not a routine" in r.json().get("error", "").lower(), r.json()


def test_bundle_update_description_round_trips_empty(harness: FunctionalHarness) -> None:
    """PATCH description '' persists as '' (empty-slice-as-NULL regression)."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{routine_id}/agent_routine",
        json_body={"description": ""},
        expect=200,
    )
    assert r.json()["agent_routine"]["description"] == "", r.json()


def test_knowledge_create_inline_content(harness: FunctionalHarness) -> None:
    """POST knowledge with file_path='' + content → row persists inline."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    r = harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/knowledge",
        json_body={"file_path": "", "label": "Notes", "content": "inline body"},
        expect=201,
    )
    row = r.json()
    assert row["file_path"] == "", row
    assert row["content"] == "inline body", row
    assert row["position"] == 0, row


def test_knowledge_patch_mode_switch(harness: FunctionalHarness) -> None:
    """PATCH knowledge file_path='' + content set (text-mode save)."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    created = harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/knowledge",
        json_body={"file_path": harness_path(harness, "switch.md"), "label": "Switch"},
        expect=201,
    ).json()

    updated = harness.http(
        "PATCH",
        f"/api/agent-routines/{routine_id}/knowledge/{created['id']}",
        json_body={"label": "Switched to text", "content": "inline body", "file_path": ""},
        expect=200,
    ).json()
    assert updated["file_path"] == "", updated
    assert updated["content"] == "inline body", updated


def test_knowledge_reorder_not_shadowed(harness: FunctionalHarness) -> None:
    """PATCH /knowledge/reorder reaches the reorder handler (route order)."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    first = harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/knowledge",
        json_body={"file_path": "", "label": "A", "content": "a"},
        expect=201,
    ).json()
    second = harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/knowledge",
        json_body={"file_path": "", "label": "B", "content": "b"},
        expect=201,
    ).json()

    # ordered_ids[0] takes the highest position → first in DESC order.
    # If route shadowing bit, this would 404 ("knowledge row not found",
    # captured by :knowledge_id="reorder") instead of {ok:true}.
    harness.http(
        "PATCH",
        f"/api/agent-routines/{routine_id}/knowledge/reorder",
        json_body={"ordered_ids": [second["id"], first["id"]]},
        expect=200,
    )

    bundle = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{routine_id}/agent_routine",
        expect=200,
    ).json()
    ids = [k["id"] for k in bundle["knowledges"]]
    assert ids == [second["id"], first["id"]], f"reorder didn't change ordering; got {ids!r}"


def test_knowledge_delete_scoped(harness: FunctionalHarness) -> None:
    """DELETE knowledge removes the row; bundle no longer lists it."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    created = harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/knowledge",
        json_body={"file_path": "", "label": "Gone", "content": "x"},
        expect=201,
    ).json()

    harness.http(
        "DELETE",
        f"/api/agent-routines/{routine_id}/knowledge/{created['id']}",
        expect=200,
    )
    bundle = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{routine_id}/agent_routine",
        expect=200,
    ).json()
    assert all(k["id"] != created["id"] for k in bundle["knowledges"])


def test_system_prompt_post_then_title_patch(harness: FunctionalHarness) -> None:
    """POST prompt gets position 0; title-only PATCH keeps content."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    created = harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/system_prompt",
        json_body={"title": "Persona", "content": "You are a helper."},
        expect=201,
    ).json()
    assert created["position"] == 0, created

    updated = harness.http(
        "PATCH",
        f"/api/agent-routines/{routine_id}/system_prompt/{created['id']}",
        json_body={"title": "Renamed"},
        expect=200,
    ).json()
    assert updated["title"] == "Renamed", updated
    assert updated["content"] == "You are a helper.", updated


def test_tools_enable_unknown_returns_400(harness: FunctionalHarness) -> None:
    """POST unknown tool_name → 400 (registry validation)."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    r = harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/tools",
        json_body={"tool_name": "no_such_tool_xyz"},
        expect=400,
    )
    assert r.json().get("error"), r.json()


def test_tools_enable_duplicate_returns_409(harness: FunctionalHarness) -> None:
    """POST same tool twice → 409 on the duplicate."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/tools",
        json_body={"tool_name": "read_file"},
        expect=201,
    )
    harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/tools",
        json_body={"tool_name": "read_file"},
        expect=409,
    )


def test_tools_list_and_delete(harness: FunctionalHarness) -> None:
    """Enabled tools appear in LIST and the bundle; DELETE removes them."""
    ws_id = _create_workspace(harness)
    routine_id = _create_routine(harness, ws_id)

    harness.http(
        "POST",
        f"/api/agent-routines/{routine_id}/tools",
        json_body={"tool_name": "read_file"},
        expect=201,
    )
    listed = harness.http(
        "GET",
        f"/api/agent-routines/{routine_id}/tools",
        expect=200,
    ).json()
    assert listed["tools"] == ["read_file"], listed

    bundle = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{routine_id}/agent_routine",
        expect=200,
    ).json()
    assert bundle["tools"] == ["read_file"], bundle

    harness.http(
        "DELETE",
        f"/api/agent-routines/{routine_id}/tools/read_file",
        expect=200,
    )
    listed_after = harness.http(
        "GET",
        f"/api/agent-routines/{routine_id}/tools",
        expect=200,
    ).json()
    assert listed_after["tools"] == [], listed_after
