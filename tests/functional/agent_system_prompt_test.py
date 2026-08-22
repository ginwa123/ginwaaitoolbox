"""Functional tests for the agent_system_prompt CRUD wire.

Exercises the 4 new routes (Migration 080) against a real nalar
binary, replaying the exact JSON bodies the frontend sends:

  Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md

Covers:
  * CREATE   — POST /api/agents/:agent_id/system_prompt → 201 + row
  * VALIDATE — POST with empty content → 400
  * UNKNOWN  — POST against unknown agent_id → 404
  * UPDATE   — PATCH title+content → 200, fields changed
  * EMPTYSTR — PATCH with content:"" → 200 (empty string is legal,
               NOT NULL — regression for empty-slice-binds-as-NULL)
  * DELETE   — DELETE → {ok:true}, GET bundle no longer lists it
  * REORDER  — PATCH /reorder → positions reflect new order
  * BUNDLE   — GET /api/workspaces/:ws/items/:id/agent includes
               system_prompts: [] for a fresh agent

NOTE: port 8081 is RESERVED (never used here — the harness picks a
free port in 8080..8199 excluding it).
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "asp-ws") -> str:
    """Create a fresh workspace. Returns its id."""
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_agent(harness: FunctionalHarness, workspace_id: str) -> str:
    """Create an Agent workspace item. Returns the agent id
    (= workspace_item.id per the agents/workspace_items 1-1 invariant)."""
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": "asp-agent", "path": "/tmp/agent-system-prompt-test"},
        expect=201,
    )
    body = r.json()
    item = body.get("item")
    assert item is not None, f"missing 'item' envelope: {body!r}"
    return item["id"]


def _create_prompt(
    harness: FunctionalHarness,
    agent_id: str,
    title: str,
    content: str,
    expect: int = 201,
) -> dict[str, Any]:
    """POST create; returns the row directly (flat shape)."""
    r = harness.http(
        "POST",
        f"/api/agents/{agent_id}/system_prompt",
        json_body={"title": title, "content": content},
        expect=expect,
    )
    return r.json()


def _get_bundle(harness: FunctionalHarness, workspace_id: str, item_id: str) -> dict:
    r = harness.http(
        "GET", f"/api/workspaces/{workspace_id}/items/{item_id}/agent", expect=200
    )
    return r.json()


# ─── Tests ────────────────────────────────────────────────────────────────


class TestCreateSystemPrompt:
    def test_create_returns_201_with_row(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)

        row = _create_prompt(harness, agent_id, "Persona", "You are a pirate.")
        assert row.get("id", "").startswith("asp_"), f"bad id: {row!r}"
        assert row.get("agent_id") == agent_id
        assert row.get("title") == "Persona"
        assert row.get("content") == "You are a pirate."
        assert row.get("position") == 0

    def test_second_row_gets_position_1(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        _create_prompt(harness, agent_id, "A", "body a")
        row2 = _create_prompt(harness, agent_id, "B", "body b")
        assert row2.get("position") == 1

    def test_empty_content_returns_400(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        body = _create_prompt(harness, agent_id, "T", "", expect=400)
        assert "error" in body, f"expected error envelope: {body!r}"

    def test_whitespace_content_returns_400(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        body = _create_prompt(harness, agent_id, "T", "   \n\t ", expect=400)
        assert "error" in body

    def test_unknown_agent_returns_404(self, harness: FunctionalHarness):
        body = _create_prompt(harness, "ws_item_404", "T", "C", expect=404)
        assert "error" in body


class TestUpdateSystemPrompt:
    def test_patch_updates_title_and_content(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        row = _create_prompt(harness, agent_id, "Old", "old body")

        r = harness.http(
            "PATCH",
            f"/api/agents/{agent_id}/system_prompt/{row['id']}",
            json_body={"title": "New", "content": "new body"},
            expect=200,
        )
        updated = r.json()
        assert updated.get("title") == "New"
        assert updated.get("content") == "new body"

    def test_patch_empty_string_content_is_legal_not_null(
        self, harness: FunctionalHarness
    ):
        """Regression: SqliteBackend.exec binds '' as SQL NULL, which would
        trip content's NOT NULL constraint without COALESCE(?, '')."""
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        row = _create_prompt(harness, agent_id, "Keep", "body")

        r = harness.http(
            "PATCH",
            f"/api/agents/{agent_id}/system_prompt/{row['id']}",
            json_body={"content": ""},
            expect=200,
        )
        updated = r.json()
        assert updated.get("content") == ""
        assert updated.get("title") == "Keep"

    def test_patch_unknown_row_returns_404(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        harness.http(
            "PATCH",
            f"/api/agents/{agent_id}/system_prompt/asp_404",
            json_body={"title": "X"},
            expect=404,
        )


class TestDeleteSystemPrompt:
    def test_delete_removes_row_from_bundle(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        row = _create_prompt(harness, agent_id, "Doomed", "bye")

        r = harness.http(
            "DELETE", f"/api/agents/{agent_id}/system_prompt/{row['id']}", expect=200
        )
        assert r.json().get("ok") is True

        bundle = _get_bundle(harness, ws, agent_id)
        ids = [p["id"] for p in bundle.get("system_prompts", [])]
        assert row["id"] not in ids

    def test_delete_unknown_row_is_noop_200(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        r = harness.http(
            "DELETE", f"/api/agents/{agent_id}/system_prompt/asp_404", expect=200
        )
        assert r.json().get("ok") is True


class TestReorderSystemPrompt:
    def test_reorder_updates_positions(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        a = _create_prompt(harness, agent_id, "A", "body a")
        b = _create_prompt(harness, agent_id, "B", "body b")
        c = _create_prompt(harness, agent_id, "C", "body c")

        # Reverse: C first (highest position), then B, then A.
        harness.http(
            "PATCH",
            f"/api/agents/{agent_id}/system_prompt/reorder",
            json_body={"ordered_ids": [c["id"], b["id"], a["id"]]},
            expect=200,
        )

        bundle = _get_bundle(harness, ws, agent_id)
        by_id = {p["id"]: p["position"] for p in bundle.get("system_prompts", [])}
        assert by_id[c["id"]] == 2, f"C should be position 2: {by_id!r}"
        assert by_id[b["id"]] == 1
        assert by_id[a["id"]] == 0


class TestGetBundleIncludesSystemPrompts:
    def test_fresh_agent_has_empty_system_prompts_array(
        self, harness: FunctionalHarness
    ):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        bundle = _get_bundle(harness, ws, agent_id)
        assert bundle.get("system_prompts") == [], (
            f"fresh agent should have empty system_prompts array: "
            f"{bundle.get('system_prompts')!r}"
        )

    def test_bundle_lists_created_rows(self, harness: FunctionalHarness):
        ws = _create_workspace(harness)
        agent_id = _create_agent(harness, ws)
        row = _create_prompt(harness, agent_id, "Listed", "shown in bundle")
        bundle = _get_bundle(harness, ws, agent_id)
        prompts = bundle.get("system_prompts", [])
        assert len(prompts) == 1
        assert prompts[0]["id"] == row["id"]
