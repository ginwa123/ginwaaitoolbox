"""Functional tests for default agent tools seeded at creation.

Plan: docs/superpowers/plans/2026-09-06-default-agent-tools-on-creation.md

Covers:
  * AGENT — POST /api/workspaces/:ws/items/agent → GET /api/agents/:id/tools
    returns the 25-tool DEFAULT_AGENT_TOOLS (sorted ASC).
  * KANBAN — POST /api/workspaces/:ws/items/kanban →
    GET /api/agent-kanbans/:id/tools returns the 25 agent defaults +
    2 kanban tools (kanban_list, kanban_move_task) — 27 total — and the
    bundle GET /api/workspaces/:ws/items/:id/agent_kanban is 200 (configured,
    not 404 NotConfigured).
  * NO-BACKFILL — deleting all tools on a fresh agent leaves [] (empty is
    stable; the seed runs once at creation, never on read).
"""

from __future__ import annotations

from harness import FunctionalHarness

EXPECTED_DEFAULTS = [
    "add_skill",
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
    "view_tool",
    "write_file",
]

# Kanban boards seed DEFAULT_AGENT_TOOLS + DEFAULT_KANBAN_TOOLS.
EXPECTED_KANBAN_DEFAULTS = [
    "add_skill",
    "command",
    "edit_skill",
    "get_plan",
    "glob",
    "kanban_list",
    "kanban_move_task",
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
    "view_tool",
    "write_file",
]


def _create_workspace(harness: FunctionalHarness, name: str = "defaults-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def test_agent_create_seeds_default_tools(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/agent",
        json_body={"name": "fresh-agent", "path": "/tmp/defaults-agent"},
        expect=201,
    )
    item_id = r.json()["item"]["id"]

    tools = harness.http("GET", f"/api/agents/{item_id}/tools", expect=200).json()["tools"]
    assert tools == EXPECTED_DEFAULTS, f"fresh agent should seed defaults, got {tools!r}"


def test_kanban_create_seeds_agent_kanban_and_tools(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/kanban",
        json_body={"name": "fresh-board"},
        expect=201,
    )
    kanban_id = r.json()["item"]["id"]

    tools = harness.http(
        "GET", f"/api/agent-kanbans/{kanban_id}/tools", expect=200
    ).json()["tools"]
    assert tools == EXPECTED_KANBAN_DEFAULTS, f"fresh kanban should seed defaults, got {tools!r}"

    bundle = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/agent_kanban",
        expect=200,
    ).json()
    assert bundle["tools"] == EXPECTED_KANBAN_DEFAULTS, (
        f"fresh kanban bundle should carry defaults, got {bundle['tools']!r}"
    )


def test_delete_all_tools_leaves_empty_no_backfill(harness: FunctionalHarness) -> None:
    """Seed runs once at creation — deleting everything stays empty."""
    ws_id = _create_workspace(harness)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/agent",
        json_body={"name": "strip-agent", "path": "/tmp/defaults-strip"},
        expect=201,
    )
    agent_id = r.json()["item"]["id"]

    for name in EXPECTED_DEFAULTS:
        harness.http("DELETE", f"/api/agents/{agent_id}/tools/{name}", expect=200)

    tools = harness.http("GET", f"/api/agents/{agent_id}/tools", expect=200).json()["tools"]
    assert tools == [], f"after deleting all defaults, tools should stay empty, got {tools!r}"
