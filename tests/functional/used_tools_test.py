"""Wire tests for the `used_tools` agent tool.

`used_tools` (`src/modules/agent/tools/used_tools.zig`,
`src/agentic_loop/tools_exec_used_tools.zig`) is the read-only
introspection tool that lists the tools currently equipped for the
calling session ("what tools do I have").

Covers (all modes — agent, kanban, design, plain chat):
  * REGISTRY — GET /api/agent-tools/registry exposes `used_tools`
    with a non-empty description (single source of truth:
    `tools_equipped.UNIFIED_TOOL_REGISTRY()`).
  * AGENT SEED — a fresh agent's allowlist contains `used_tools`
    (backend DEFAULT_AGENT_TOOLS).
  * KANBAN SEED — a fresh kanban board's allowlist contains
    `used_tools` (DEFAULT_AGENT_TOOLS legacy path).
  * LIFECYCLE — DELETE removes it, re-POST restores it (round-trip),
    proving it is a first-class registry tool, not a phantom.

The exec adapter's session-aware listing (allowlist filter +
sub-agent strip + progressive rows) is covered by the Zig unit
tests in `tools_exec_used_tools.zig`, which run in-memory without
an LLM. These functional tests guard the HTTP-visible wiring:
registry exposure + per-mode seeding.

Run: python3 -m pytest tests/functional/used_tools_test.py -v
"""

from __future__ import annotations

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "used-tools-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_agent(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str = "used-tools-agent",
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": name, "path": "/tmp/used-tools-test"},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_kanban(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str = "used-tools-board",
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _registry(harness: FunctionalHarness) -> list[dict]:
    r = harness.http("GET", "/api/agent-tools/registry", expect=200)
    body = r.json()
    tools = body.get("tools", [])
    assert len(tools) >= 1, "registry returned 0 tools — fixture broken?"
    return tools


# ─── Tests ─────────────────────────────────────────────────────────────────


class TestUsedToolsRegistry:
    def test_registry_exposes_used_tools_with_description(
        self, harness: FunctionalHarness
    ) -> None:
        """UNIFIED_TOOL_REGISTRY → GET /api/agent-tools/registry."""
        by_name = {t["name"]: t for t in _registry(harness)}
        assert "used_tools" in by_name, (
            f"registry missing 'used_tools'; got {sorted(by_name)!r}"
        )
        desc = by_name["used_tools"].get("description", "")
        assert isinstance(desc, str) and len(desc) > 0, (
            "used_tools registry entry should carry a description"
        )


class TestUsedToolsSeeded:
    def test_fresh_agent_allowlist_contains_used_tools(
        self, harness: FunctionalHarness
    ) -> None:
        """Agent mode: DEFAULT_AGENT_TOOLS seeds used_tools at creation."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)
        tools = harness.http(
            "GET", f"/api/agents/{agent_id}/tools", expect=200
        ).json()["tools"]
        assert "used_tools" in tools, (
            f"fresh agent should seed used_tools, got {tools!r}"
        )

    def test_fresh_kanban_allowlist_contains_used_tools(
        self, harness: FunctionalHarness
    ) -> None:
        """Kanban mode: DEFAULT_AGENT_TOOLS legacy path seeds used_tools."""
        ws_id = _create_workspace(harness)
        kanban_id = _create_kanban(harness, ws_id)
        tools = harness.http(
            "GET", f"/api/agent-kanbans/{kanban_id}/tools", expect=200
        ).json()["tools"]
        assert "used_tools" in tools, (
            f"fresh kanban should seed used_tools, got {tools!r}"
        )


class TestUsedToolsLifecycle:
    def test_disable_and_reenable_round_trip(
        self, harness: FunctionalHarness
    ) -> None:
        """DELETE removes it; re-POST restores it (first-class tool)."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        harness.http(
            "DELETE", f"/api/agents/{agent_id}/tools/used_tools", expect=200
        )
        tools = harness.http(
            "GET", f"/api/agents/{agent_id}/tools", expect=200
        ).json()["tools"]
        assert "used_tools" not in tools, (
            f"used_tools should be gone after DELETE, got {tools!r}"
        )

        r = harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": "used_tools"},
            expect=201,
        )
        assert r.json().get("tool_name") == "used_tools"
        tools = harness.http(
            "GET", f"/api/agents/{agent_id}/tools", expect=200
        ).json()["tools"]
        assert "used_tools" in tools, (
            f"used_tools should be back after re-POST, got {tools!r}"
        )
