"""Functional tests for the Agent Mode tool toggle wire.

Exercises the INSERT/DELETE flow against the `agent_tools` table
(per-plan path):

  Plan: docs/superpowers/plans/2026-08-19-agent-tools-toggle-wire.md

Covers:
  * ENABLE  — POST /api/agents/:agent_id/tools  → 201 + new row
  * DUPLICATE — POST same tool again → 409 (UNIQUE violation)
  * UNKNOWN — POST a tool_name not in the registry → 400
  * LIST    — GET returns tool_names sorted ASC
  * DISABLE — DELETE /api/agents/:agent_id/tools/:tool_name → 200, row gone
  * IDEMPOTENT — DELETE non-existent → 200 (no-op)
  * LIFECYCLE — end-to-end: enable → list → enable more → delete → list

The DELETE path-param switch from `:tool_id` to `:tool_name`
(Tasks 1+2 of the plan) is what these tests specifically guard —
without the rename, `harness.http("DELETE", ".../tools/{tool_name}")`
would 404 against the old `:tool_id` route.
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "agent-ws") -> str:
    """Create a fresh workspace. Returns its id."""
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_agent(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str = "test-agent",
    path: str = "/tmp/agent-tools-toggle-test",
) -> str:
    """Create an Agent workspace item. Returns the agent id
    (= workspace_item.id per the agents/workspace_items 1-1 invariant).

    The `path` field is required by the create handler
    (workspace_items_create_agent.zig → error.PathRequired on empty).
    The path does NOT need to exist on disk — the create handler does
    not fs-stat it; only the runtime knowledge loader does, lazily,
    and only when a chat starts.
    """
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": name, "path": path},
        expect=201,
    )
    body = r.json()
    item = body.get("item")
    agent = body.get("agent")
    assert item is not None, f"missing 'item' envelope: {body!r}"
    assert agent is not None, f"missing 'agent' envelope: {body!r}"
    assert item["item_type"] == "agent", (
        f"created item should be type 'agent', got {item.get('item_type')!r}"
    )
    assert agent["id"] == item["id"], (
        f"agents.id should equal workspace_items.id (1-1 invariant). "
        f"got agent.id={agent['id']!r} vs item.id={item['id']!r}"
    )
    return item["id"]


def _list_tools(harness: FunctionalHarness, agent_id: str) -> list[str]:
    """Return the enabled tool_names for the agent (sorted ASC).

    Fresh agents are born with DEFAULT_AGENT_TOOLS;
    an empty list means the user deleted every tool (never 404).
    """
    r = harness.http(
        "GET",
        f"/api/agents/{agent_id}/tools",
        expect=200,
    )
    body = r.json()
    assert isinstance(body.get("tools"), list), (
        f"tools response should be {{tools: list}}, got {body!r}"
    )
    return list(body["tools"])


def _enable_tool(
    harness: FunctionalHarness, agent_id: str, tool_name: str
) -> dict[str, Any]:
    """POST enable; returns the created AgentToolRow.

    Wire shape: the backend returns the row DIRECTLY (not wrapped in
    `{tool: ...}`). The original 2026-08-15 spec called for the wrapped
    shape, but the implementation (`agent_tools_create.zig`) returns
    ``output.tool`` directly. The frontend's `api.enableAgentTool` types
    its return as `Promise<AgentToolRow>`, which matches the flat shape.
    """
    r = harness.http(
        "POST",
        f"/api/agents/{agent_id}/tools",
        json_body={"tool_name": tool_name},
        expect=201,
    )
    tool = r.json()
    assert tool.get("tool_name") == tool_name, (
        f"expected tool_name={tool_name!r}, got {tool!r}"
    )
    assert tool.get("agent_id") == agent_id, (
        f"expected agent_id={agent_id!r}, got {tool!r}"
    )
    assert tool.get("id", "").startswith("at_"), (
        f"expected row id to start with 'at_', got {tool!r}"
    )
    assert tool.get("enabled") == 1, f"expected enabled=1, got {tool!r}"
    return tool


def _disable_tool(
    harness: FunctionalHarness, agent_id: str, tool_name: str
) -> dict[str, Any]:
    """DELETE; returns the {ok: true} body. No-op on missing tool."""
    r = harness.http(
        "DELETE",
        f"/api/agents/{agent_id}/tools/{tool_name}",
        expect=200,
    )
    body = r.json()
    assert body.get("ok") is True, f"expected ok=true, got {body!r}"
    return body


def _registry_tools(harness: FunctionalHarness) -> list[str]:
    """Return the canonical tool-name list from /api/agent-tools/registry.

    Used to pick a tool_name we KNOW is valid (so enable-unknown
    test cases are intentional, not by accident).
    """
    r = harness.http("GET", "/api/agent-tools/registry", expect=200)
    body = r.json()
    names = [t["name"] for t in body.get("tools", [])]
    assert len(names) >= 1, "registry returned 0 tools — fixture broken?"
    return names


# Fresh agents are born with DEFAULT_AGENT_TOOLS — see
# src/agentic_loop/tools_equipped.zig::DEFAULT_AGENT_TOOLS.
# Tests that need a clean enable use `preview_design_page` (in-registry, never a default).
EXPECTED_DEFAULTS = [
    "add_skill",
    "ask_user",
    "command",
    "edit_skill",
    "get_plan",
    "glob",
    "list_directory",
    "list_skills",
    "list_sub_agent",
    "load_memory",
    "present_files",
    "read_file",
    "read_workspace_session",
    "remove_file",
    "remove_skill",
    "save_memory",
    "search",
    "search_tool",
    "spawn_sub_agent",
    "text_replace",
    "update_plan",
    "use_skill",
    "use_tool",
    "used_tools",
    "view_tool",
    "write_file",
]
NON_DEFAULT_TOOL = "preview_design_page"


# ─── Tests ────────────────────────────────────────────────────────────────


class TestEnableTool:
    """POST /api/agents/:agent_id/tools — INSERT row."""

    def test_post_inserts_row_and_returns_envelope(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)
        tool = _enable_tool(harness, agent_id, NON_DEFAULT_TOOL)
        assert tool["tool_name"] == NON_DEFAULT_TOOL
        assert tool["enabled"] == 1

        # The DB row persists beyond the create call —
        # list now reflects defaults + the new tool (sorted ASC).
        assert _list_tools(harness, agent_id) == sorted(
            EXPECTED_DEFAULTS + [NON_DEFAULT_TOOL]
        )

    def test_post_rejects_duplicate_with_409(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        _enable_tool(harness, agent_id, NON_DEFAULT_TOOL)

        # Second POST with the same (agent_id, tool_name) hits
        # the UNIQUE index → 409 Conflict.
        harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": NON_DEFAULT_TOOL},
            expect=409,
        )

        # State unchanged — defaults + exactly one extra row.
        assert _list_tools(harness, agent_id) == sorted(
            EXPECTED_DEFAULTS + [NON_DEFAULT_TOOL]
        )

    def test_post_rejects_unknown_tool_with_400(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        # tool_name 'this_tool_definitely_does_not_exist_xyz' is
        # not in the registry by construction.
        harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": "this_tool_definitely_does_not_exist_xyz"},
            expect=400,
        )

        # No row created — defaults unchanged.
        assert _list_tools(harness, agent_id) == EXPECTED_DEFAULTS

    def test_post_rejects_empty_tool_name_with_400(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": ""},
            expect=400,
        )


class TestListTools:
    """GET /api/agents/:agent_id/tools — list enabled names sorted ASC."""

    def test_defaults_seeded_on_create(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        # Fresh agents are born with DEFAULT_AGENT_TOOLS (sorted ASC).
        assert _list_tools(harness, agent_id) == EXPECTED_DEFAULTS

    def test_returns_sorted_ascending(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        # Enable in NON-alphabetical order: the agent loop filter
        # + frontend list depend on sorted ASC. Pick tools outside the
        # seeded defaults so the enables are clean 201s.
        registry = _registry_tools(harness)
        candidates = [n for n in registry if n not in EXPECTED_DEFAULTS]
        assert len(candidates) >= 3, (
            f"need >=3 non-default tools in registry; got {candidates!r}"
        )
        picked = candidates[:3]
        for name in reversed(picked):  # insert in reverse order
            _enable_tool(harness, agent_id, name)

        listed = _list_tools(harness, agent_id)
        assert listed == sorted(EXPECTED_DEFAULTS + picked), (
            f"GET /tools should return sorted ASC; got {listed!r} "
            f"vs sorted {sorted(EXPECTED_DEFAULTS + picked)!r}"
        )


class TestDisableTool:
    """DELETE /api/agents/:agent_id/tools/:tool_name — DELETE row.

    The DELETE path param was changed from `:tool_id` to `:tool_name`
    in the plan. These tests guard the new wire shape.
    """

    def test_delete_removes_row(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        _enable_tool(harness, agent_id, NON_DEFAULT_TOOL)
        assert _list_tools(harness, agent_id) == sorted(
            EXPECTED_DEFAULTS + [NON_DEFAULT_TOOL]
        )

        _disable_tool(harness, agent_id, NON_DEFAULT_TOOL)
        assert _list_tools(harness, agent_id) == EXPECTED_DEFAULTS

    def test_delete_is_idempotent(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        _enable_tool(harness, agent_id, NON_DEFAULT_TOOL)

        # First delete removes the row.
        _disable_tool(harness, agent_id, NON_DEFAULT_TOOL)
        assert _list_tools(harness, agent_id) == EXPECTED_DEFAULTS

        # Second delete is a no-op (200, not 404) — matches the
        # useCase's scope-by-agent_id design + handler semantics.
        _disable_tool(harness, agent_id, NON_DEFAULT_TOOL)
        assert _list_tools(harness, agent_id) == EXPECTED_DEFAULTS

    def test_delete_unknown_tool_name_no_ops(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        # No row exists for this tool_name → DELETE should be
        # a no-op (200), not 404. Documented contract.
        _disable_tool(harness, agent_id, "totally_nonexistent_tool_xyz")
        assert _list_tools(harness, agent_id) == EXPECTED_DEFAULTS

    def test_delete_rejects_empty_tool_name(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        # Empty path segment resolves to ``tools/<empty>`` which the
        # router maps to ``tool_name=""``. The handler validates that
        # against the ToolNameRequired error → 400 (NOT 404). The router
        # happily matches the route with an empty path param.
        harness.http(
            "DELETE",
            f"/api/agents/{agent_id}/tools/",
            expect=400,
        )


class TestToolToggleLifecycle:
    """End-to-end: enable + list + enable + delete + list."""

    def test_full_lifecycle(
        self, harness: FunctionalHarness
    ) -> None:
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)
        registry = _registry_tools(harness)
        candidates = [n for n in registry if n not in EXPECTED_DEFAULTS]
        assert len(candidates) >= 2, (
            f"need >=2 non-default tools for lifecycle; got {candidates!r}"
        )

        tool_a, tool_b = candidates[0], candidates[1]
        baseline = list(EXPECTED_DEFAULTS)

        # 1. Enable tool_a.
        _enable_tool(harness, agent_id, tool_a)
        assert _list_tools(harness, agent_id) == sorted(baseline + [tool_a])

        # 2. Enable tool_b (mixed alphabetical order — proves list
        #    returns ASC sorted regardless of insertion order).
        _enable_tool(harness, agent_id, tool_b)
        assert _list_tools(harness, agent_id) == sorted(baseline + [tool_a, tool_b])

        # 3. Disable tool_a. tool_b should remain.
        _disable_tool(harness, agent_id, tool_a)
        assert _list_tools(harness, agent_id) == sorted(baseline + [tool_b])

        # 4. Disable tool_b. Back to seeded defaults.
        _disable_tool(harness, agent_id, tool_b)
        assert _list_tools(harness, agent_id) == baseline

        # 5. State survives: re-enabling tool_a starts fresh —
        #    no UNIQUE violation since the row was deleted.
        _enable_tool(harness, agent_id, tool_a)
        assert _list_tools(harness, agent_id) == sorted(baseline + [tool_a])

    def test_scoped_to_agent_id(
        self, harness: FunctionalHarness
    ) -> None:
        """Tool toggles on agent_A do not affect agent_B.

        Both agents live in separate workspaces (isolation proof;
        same-workspace second create also works since the
        workspace_item_id fix in workspace_items_create_agent.zig).
        """
        ws_a = _create_workspace(harness, name="ws-A")
        ws_b = _create_workspace(harness, name="ws-B")
        agent_a = _create_agent(harness, ws_a, name="agent-A")
        agent_b = _create_agent(harness, ws_b, name="agent-B")

        _enable_tool(harness, agent_a, NON_DEFAULT_TOOL)

        # agent_B keeps its own seeded defaults — proving no
        # cross-agent leakage regardless of workspace.
        assert _list_tools(harness, agent_b) == EXPECTED_DEFAULTS
        assert _list_tools(harness, agent_a) == sorted(
            EXPECTED_DEFAULTS + [NON_DEFAULT_TOOL]
        )

        # DELETE scoping: deleting the extra tool from agent_B is a no-op
        # (agent_B never had it), and agent_A's row is untouched.
        _disable_tool(harness, agent_b, NON_DEFAULT_TOOL)
        assert _list_tools(harness, agent_a) == sorted(
            EXPECTED_DEFAULTS + [NON_DEFAULT_TOOL]
        )
