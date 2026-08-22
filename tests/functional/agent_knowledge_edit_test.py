"""Functional tests for the Agent Knowledge EDIT flow (PR #291).

Exercises the PATCH /api/agents/:agent_id/knowledge/:knowledge_id
endpoint against a REAL nalar binary + REAL SQLite, replaying the
EXACT JSON bodies the frontend edit dialog sends.

  Plan: docs/superpowers/plans/2026-08-22-agent-mode-ui-ux.md
  Lesson (2026-08-22): the first implementation passed unit tests but
  failed in real use because
    1. `file_path: ""` (text-mode save) hit `isAbsolute("") == false`
       → 400 "file_path must be absolute".
    2. `content: ""` (file-mode save) hit the SqliteBackend
       empty-slice-binds-as-NULL gotcha → 500 NOT NULL constraint.
  These tests replay both payloads end-to-end so neither regression
  can ship again.

Covers:
  * TEXT-MODE SAVE  — {label, content, file_path:""} → 200, row flips
    to content-backed (file_path cleared, content set).
  * FILE-MODE SAVE  — {label, file_path, content:""} → 200, row flips
    to file-backed (content cleared, NOT a 500).
  * ROUND-TRIP      — file→text→file→text switches keep the row
    consistent after every hop.
  * LABEL-ONLY      — {label} alone → 200, source fields untouched.
  * GUARD           — non-empty relative file_path still → 400.
  * ROUTE ORDER     — PATCH /knowledge/reorder reaches the REORDER
    handler (not shadowed by /knowledge/:knowledge_id).
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "knowledge-edit-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_agent(harness: FunctionalHarness, workspace_id: str, name: str = "edit-agent") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": name, "path": "/tmp/agent-knowledge-edit-test"},
        expect=201,
    )
    body = r.json()
    return body["item"]["id"]


def _add_inline_knowledge(harness: FunctionalHarness, agent_id: str) -> dict:
    """Seed one INLINE (text) knowledge row. Returns the created row."""
    r = harness.http(
        "POST",
        f"/api/agents/{agent_id}/knowledge",
        json_body={"file_path": "", "label": "Seed notes", "content": "seed body"},
        expect=201,
    )
    return r.json()


def _add_file_knowledge(harness: FunctionalHarness, agent_id: str) -> dict:
    """Seed one FILE-BACKED knowledge row. Returns the created row."""
    r = harness.http(
        "POST",
        f"/api/agents/{agent_id}/knowledge",
        json_body={"file_path": "/tmp/agent-knowledge-edit-test/seed.md", "label": "Seed file", "content": ""},
        expect=201,
    )
    return r.json()


def _get_knowledge(harness: FunctionalHarness, workspace_id: str, agent_id: str) -> list[dict]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{agent_id}/agent",
        expect=200,
    )
    return r.json()["knowledge"]


def _patch(harness: FunctionalHarness, agent_id: str, knowledge_id: str, body: dict, expect: int = 200) -> dict:
    r = harness.http(
        "PATCH",
        f"/api/agents/{agent_id}/knowledge/{knowledge_id}",
        json_body=body,
        expect=expect,
    )
    return r.json()


# ─── Regression 1: text-mode save (used to 400 NotAbsolutePath) ────────────


def test_text_mode_save_clears_file_path_and_sets_content(harness: FunctionalHarness):
    """The edit dialog's Text-mode save sends {label, content, file_path:""}.

    Regression: `isAbsolute("")` is false, so the old useCase rejected
    this with 400 "file_path must be absolute". Empty string must mean
    "clear the column" (switch to content-backed), not an error.
    """
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_file_knowledge(harness, agent)

    updated = _patch(harness, agent, row["id"], {
        "label": "Switched to text",
        "content": "inline body after switch",
        "file_path": "",
    })

    assert updated["file_path"] == "", (
        f"file_path should be cleared after text-mode save, got {updated['file_path']!r}"
    )
    assert updated["content"] == "inline body after switch"
    assert updated["label"] == "Switched to text"

    # Refetch through the agent GET — the row must be consistent there too.
    rows = _get_knowledge(harness, ws, agent)
    mine = [k for k in rows if k["id"] == row["id"]]
    assert len(mine) == 1
    assert mine[0]["file_path"] == ""
    assert mine[0]["content"] == "inline body after switch"


# ─── Regression 2: file-mode save (used to 500 NOT NULL constraint) ────────


def test_file_mode_save_clears_content_and_sets_path(harness: FunctionalHarness):
    """The edit dialog's File-mode save sends {label, file_path, content:""}.

    Regression: SqliteBackend.exec binds empty slices as SQL NULL, so
    `content: ""` violated the NOT NULL constraint → 500. Empty string
    must land as '' (clear the column), not NULL.
    """
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_inline_knowledge(harness, agent)

    updated = _patch(harness, agent, row["id"], {
        "label": "Switched to file",
        "file_path": "/tmp/agent-knowledge-edit-test/switched.md",
        "content": "",
    })

    assert updated["file_path"] == "/tmp/agent-knowledge-edit-test/switched.md"
    assert updated["content"] == "", (
        f"content should be cleared to '', got {updated['content']!r}"
    )

    rows = _get_knowledge(harness, ws, agent)
    mine = [k for k in rows if k["id"] == row["id"]]
    assert mine[0]["file_path"] == "/tmp/agent-knowledge-edit-test/switched.md"
    assert mine[0]["content"] == ""


# ─── Round-trip: repeated mode switches stay consistent ────────────────────


def test_mode_switch_round_trip_file_text_file_text(harness: FunctionalHarness):
    """file→text→file→text: every hop must 200 and leave the row XOR-
    consistent (exactly one of file_path/content non-empty)."""
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_file_knowledge(harness, agent)
    kid = row["id"]

    # hop 1: file → text
    r1 = _patch(harness, agent, kid, {
        "label": "hop1", "content": "body one", "file_path": "",
    })
    assert r1["file_path"] == "" and r1["content"] == "body one"

    # hop 2: text → file
    r2 = _patch(harness, agent, kid, {
        "label": "hop2", "file_path": "/tmp/agent-knowledge-edit-test/hop2.md", "content": "",
    })
    assert r2["file_path"] == "/tmp/agent-knowledge-edit-test/hop2.md" and r2["content"] == ""

    # hop 3: file → text again
    r3 = _patch(harness, agent, kid, {
        "label": "hop3", "content": "body three", "file_path": "",
    })
    assert r3["file_path"] == "" and r3["content"] == "body three"

    # Final state via GET.
    rows = _get_knowledge(harness, ws, agent)
    mine = [k for k in rows if k["id"] == kid][0]
    assert mine["label"] == "hop3"
    assert mine["content"] == "body three"
    assert mine["file_path"] == ""


def test_label_only_update_keeps_source_fields(harness: FunctionalHarness):
    """A label-only PATCH must not touch file_path or content."""
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_inline_knowledge(harness, agent)

    updated = _patch(harness, agent, row["id"], {"label": "Renamed only"})

    assert updated["label"] == "Renamed only"
    assert updated["content"] == "seed body"
    assert updated["file_path"] == ""


# ─── Guard: non-empty relative path is still rejected ──────────────────────


def test_relative_path_still_rejected(harness: FunctionalHarness):
    """The empty-string exemption must not weaken the absolute-path guard."""
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_inline_knowledge(harness, agent)

    body = _patch(
        harness, agent, row["id"],
        {"file_path": "relative/path.md"},
        expect=400,
    )
    assert "absolute" in body.get("error", "").lower()


# ─── Route-order: /knowledge/reorder must not be shadowed ──────────────────


def test_reorder_route_not_shadowed_by_param_route(harness: FunctionalHarness):
    """PATCH /api/agents/:id/knowledge/reorder must reach the REORDER
    handler. The router matches in registration order, so if
    /knowledge/:knowledge_id is registered first, this request would be
    captured with knowledge_id="reorder" (pre-existing bug caught by
    writing these tests)."""
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row_a = _add_inline_knowledge(harness, agent)
    row_b = _add_file_knowledge(harness, agent)

    # Reorder: put row_b before row_a.
    r = harness.http(
        "PATCH",
        f"/api/agents/{agent}/knowledge/reorder",
        json_body={"ordered_ids": [row_b["id"], row_a["id"]]},
        expect=200,
    )
    assert r.json().get("ok") is True

    # GET must reflect the new order (position DESC per agents_get).
    rows = _get_knowledge(harness, ws, agent)
    ids = [k["id"] for k in rows]
    assert ids.index(row_b["id"]) < ids.index(row_a["id"]), (
        f"reorder did not take effect: {ids}"
    )
