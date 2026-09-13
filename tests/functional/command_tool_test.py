"""Functional wire verification for the unified `command` tool.

Branch: worktree/nalar-unify-command (commit `unify: add command tool
merged from bash+pwsh`).

What this covers
================
The unify change merges `bash` + `pwsh` into a single `command` tool
(`src/modules/agent/tools/command.zig`) that dispatches per-OS
(`pwsh` on Windows, `bash` elsewhere). `bash`/`pwsh` survive only as
unregistered shim modules (they still compile) — the equipped registry
(`tools_equipped.zig`: `equips()` + `UNIFIED_TOOL_REGISTRY()`) exposes
`command` ONLY.

A full end-to-end LLM agent run (`echo hello` via chat) is too heavy
for a wire test (it needs a stub LLM that returns a tool_call for
`command`), so this test verifies the wire-visible halves instead —
the same strategy as `agent_add_mcp_server_test.py`:

  * REGISTRY — GET /api/agent-tools/registry exposes `command` and
    NOT `bash` / `pwsh` (proves the equipped surface is command-only).
  * ENABLE/DISABLE — POST/DELETE /api/agents/:id/tools round-trips
    `command` (proves the per-agent allowlist path accepts the new
    name; unknown names 400).
  * LEGACY — POST `bash` / `pwsh` now 400s (proves the old names are
    no longer equipped).

Run:
    NALAR_BIN=<worktree>/zig-out/bin/nalarcore-linux-x86_64 \
      python3 -m pytest tests/functional/command_tool_test.py -v
"""

from __future__ import annotations

from typing import Any

from harness import FunctionalHarness


# ─── Helpers (mirror agent_tools_toggle_test.py) ─────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "cmd-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_agent(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str = "cmd-agent",
    path: str = "/tmp/command-tool-test",
) -> str:
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
    assert agent["id"] == item["id"], (
        f"agents.id should equal workspace_items.id (1-1 invariant). "
        f"got agent.id={agent['id']!r} vs item.id={item['id']!r}"
    )
    return item["id"]


def _registry_names(harness: FunctionalHarness) -> list[str]:
    r = harness.http("GET", "/api/agent-tools/registry", expect=200)
    body = r.json()
    names = [t["name"] for t in body.get("tools", [])]
    assert len(names) >= 1, "registry returned 0 tools — fixture broken?"
    return names


def _list_tools(harness: FunctionalHarness, agent_id: str) -> list[str]:
    r = harness.http("GET", f"/api/agents/{agent_id}/tools", expect=200)
    body = r.json()
    assert isinstance(body.get("tools"), list), (
        f"tools response should be {{tools: list}}, got {body!r}"
    )
    return list(body["tools"])


def _enable_tool(
    harness: FunctionalHarness, agent_id: str, tool_name: str
) -> dict[str, Any]:
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
    return tool


# ─── Tests ───────────────────────────────────────────────────────────────────


class TestCommandRegistry:
    def test_registry_exposes_only_command_no_bash_no_pwsh(
        self, harness: FunctionalHarness
    ) -> None:
        """The equipped surface is `command` ONLY."""
        names = _registry_names(harness)
        assert "command" in names, (
            f"registry missing unified 'command' tool; got {names!r}"
        )
        assert "bash" not in names, (
            f"registry still equips legacy 'bash'; got {names!r}"
        )
        assert "pwsh" not in names, (
            f"registry still equips legacy 'pwsh'; got {names!r}"
        )


class TestCommandEnableDisable:
    # Fresh agents are born with the 23-tool defaults (sorted ASC) — see
    # commit 43e37c8e (21-tool defaults expansion) and
    # docs/superpowers/plans/2026-09-06-default-agent-tools-on-creation.md.
    # (`delete_memory` removed 2026-09-12: memory is append-only.)
    _DEFAULTS = ["add_skill", "command", "edit_skill", "get_plan", "glob", "list_directory", "list_skills", "list_sub_agent", "load_memory", "read_file", "remove_file", "remove_skill", "save_memory", "search", "search_history", "search_tool", "spawn_sub_agent", "text_replace", "update_plan", "use_skill", "use_tool", "view_tool", "write_file"]
    # Post-DELETE expectation: the 23-tool list minus "command" (22 others, ASC).
    _DEFAULTS_MINUS_COMMAND = ["add_skill", "edit_skill", "get_plan", "glob", "list_directory", "list_skills", "list_sub_agent", "load_memory", "read_file", "remove_file", "remove_skill", "save_memory", "search", "search_history", "search_tool", "spawn_sub_agent", "text_replace", "update_plan", "use_skill", "use_tool", "view_tool", "write_file"]

    def test_command_enable_list_disable_lifecycle(
        self, harness: FunctionalHarness
    ) -> None:
        """DELETE command removes it; re-POST restores it (round-trip)."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        assert _list_tools(harness, agent_id) == self._DEFAULTS

        r = harness.http(
            "DELETE", f"/api/agents/{agent_id}/tools/command", expect=200
        )
        assert r.json().get("ok") is True, f"expected ok=true, got {r.json()!r}"
        assert _list_tools(harness, agent_id) == self._DEFAULTS_MINUS_COMMAND

        _enable_tool(harness, agent_id, "command")
        assert _list_tools(harness, agent_id) == self._DEFAULTS

    def test_command_enable_duplicate_is_409(
        self, harness: FunctionalHarness
    ) -> None:
        """POST of seeded `command` hits the UNIQUE index → 409."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": "command"},
            expect=409,
        )
        assert _list_tools(harness, agent_id) == self._DEFAULTS


class TestLegacyNamesRejected:
    # Fresh agents seed the 23-tool defaults (sorted ASC, commit 43e37c8e).
    _DEFAULTS = ["add_skill", "command", "edit_skill", "get_plan", "glob", "list_directory", "list_skills", "list_sub_agent", "load_memory", "read_file", "remove_file", "remove_skill", "save_memory", "search", "search_history", "search_tool", "spawn_sub_agent", "text_replace", "update_plan", "use_skill", "use_tool", "view_tool", "write_file"]

    def test_bash_enable_now_400s_after_unify(
        self, harness: FunctionalHarness
    ) -> None:
        """The removed `bash` name is no longer equipped (unknown → 400)."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": "bash"},
            expect=400,
        )
        assert _list_tools(harness, agent_id) == self._DEFAULTS

    def test_pwsh_enable_now_400s_after_unify(
        self, harness: FunctionalHarness
    ) -> None:
        """The removed `pwsh` name is no longer equipped (unknown → 400)."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": "pwsh"},
            expect=400,
        )
        assert _list_tools(harness, agent_id) == self._DEFAULTS
