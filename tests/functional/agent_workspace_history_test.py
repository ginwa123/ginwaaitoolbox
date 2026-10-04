"""Workspace-scoped chat history: `read_workspace_session` replaces `search_history`.

Background
----------
The global `search_history` agent tool is deleted. Its replacement,
`read_workspace_session`, discovers (LIST), searches (SEARCH, FTS5),
reads (READ), and searches-within (SEARCH-WITHIN) other chat sessions
in the CALLER's workspace only — scope is derived server-side from the
calling session, cross-workspace targets get `<denied>`, never content.

A full end-to-end LLM tool_call is not feasible here (no stub LLM emits
tool_calls — see `agent_add_mcp_server_test.py` / `command_tool_test.py`
for the precedent). The tool itself is covered by the Zig in-memory
SQLite tests in `read_workspace_session.zig` (list/search/read/denied,
workspace isolation) and `workspace_scope.zig` (resolution, ties,
fail-closed). These functional tests guard the wire-visible halves,
replaying the EXACT JSON bodies the frontend sends:

  * REGISTRY — GET /api/agent-tools/registry exposes
    `read_workspace_session` and NOT `search_history` (proves the
    equipped surface swapped; the name must never appear again).
  * ENABLE/DISABLE — POST/DELETE /api/agents/:id/tools round-trips
    `read_workspace_session`; POST `search_history` now 400s (proves
    the old name is no longer equipped).
  * LINKAGE — workspace + kanban + task (mode='create_session') seeds
    session.id == task.id with a user message; a second workspace's
    task seeds a disjoint session. This is the exact task→session→
    workspace join the tool's SQL scopes on, verified over HTTP.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \
      python3 -m pytest tests/functional/agent_workspace_history_test.py -v
"""

from __future__ import annotations

from typing import Any

from harness import FunctionalHarness


# ─── Helpers (mirror command_tool_test.py / agent_kanbans_test.py) ──────────


def _create_workspace(harness: FunctionalHarness, name: str = "ws-history") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_agent(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str = "history-agent",
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": name, "path": "/tmp/agent-workspace-history-test"},
        expect=201,
    )
    body = r.json()
    return body["item"]["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "sprint") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
    description: str,
) -> dict[str, Any]:
    """POST mode='create_session' — mirrors the frontend's plain
    "Create task" button. Seeds session.id == task.id + one user message."""
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": name, "description": description},
        expect=201,
    )
    return r.json()


def _user_messages(harness: FunctionalHarness, session_id: str) -> list[dict[str, Any]]:
    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/messages",
        params={"sort_by": "created_at", "direction": "asc", "limit": 100},
        expect=200,
    )
    body = r.json()
    msgs = body.get("messages")
    assert isinstance(msgs, list), f"expected messages list, got: {body!r}"
    return [m for m in msgs if m.get("role") == "user"]


def _registry_names(harness: FunctionalHarness) -> list[str]:
    r = harness.http("GET", "/api/agent-tools/registry", expect=200)
    body = r.json()
    names = [t["name"] for t in body.get("tools", [])]
    assert len(names) >= 1, "registry returned 0 tools — fixture broken?"
    return names


# ─── Tests ───────────────────────────────────────────────────────────────────


class TestRegistrySwap:
    def test_registry_exposes_new_tool_no_old_name(
        self, harness: FunctionalHarness
    ) -> None:
        """The equipped surface is `read_workspace_session` ONLY —
        the old name must never appear again (any spelling)."""
        names = _registry_names(harness)
        assert "read_workspace_session" in names, (
            f"registry missing 'read_workspace_session'; got {names!r}"
        )
        for banned in ("search_history", "SearchHistory", "search-history"):
            assert banned not in names, (
                f"registry still exposes {banned!r}; got {names!r}"
            )
            assert not any(banned in n for n in names), (
                f"registry has a tool name containing {banned!r}; got {names!r}"
            )


class TestEnableDisable:
    def test_enable_disable_round_trip(
        self, harness: FunctionalHarness
    ) -> None:
        """DELETE/POST/DELETE /api/agents/:id/tools round-trips the new
        name (it ships as a default, so DELETE first, like `command`)."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        r = harness.http(
            "DELETE",
            f"/api/agents/{agent_id}/tools/read_workspace_session",
            expect=200,
        )
        assert r.json().get("ok") is True

        r = harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": "read_workspace_session"},
            expect=201,
        )
        assert r.json().get("tool_name") == "read_workspace_session"

        r = harness.http(
            "DELETE",
            f"/api/agents/{agent_id}/tools/read_workspace_session",
            expect=200,
        )
        assert r.json().get("ok") is True

    def test_legacy_name_rejected(self, harness: FunctionalHarness) -> None:
        """POST `search_history` now 400s (no longer equipped)."""
        ws_id = _create_workspace(harness)
        agent_id = _create_agent(harness, ws_id)

        harness.http(
            "POST",
            f"/api/agents/{agent_id}/tools",
            json_body={"tool_name": "search_history"},
            expect=400,
        )


class TestWorkspaceLinkage:
    def test_tasks_seed_disjoint_sessions_per_workspace(
        self, harness: FunctionalHarness
    ) -> None:
        """Two workspaces, three tasks: session.id == task.id in each,
        with disjoint user messages. This is the exact join
        (task → session → workspace) the tool scopes on."""
        ws_a = _create_workspace(harness, "ws-a")
        kanban_a = _create_kanban(harness, ws_a, "sprint-a")
        task_a1 = _create_task(
            harness, ws_a, kanban_a,
            name="Fix login bug", description="alpha workspace login failure",
        )["task"]
        task_a2 = _create_task(
            harness, ws_a, kanban_a,
            name="Login page polish", description="alpha workspace login styling",
        )["task"]

        ws_b = _create_workspace(harness, "ws-b")
        kanban_b = _create_kanban(harness, ws_b, "sprint-b")
        task_b1 = _create_task(
            harness, ws_b, kanban_b,
            name="Deploy checklist", description="beta workspace deployment steps",
        )["task"]

        # session.id == task.id (the invariant workspace_scope joins on).
        for task in (task_a1, task_a2, task_b1):
            msgs = _user_messages(harness, task["id"])
            assert len(msgs) >= 1, (
                f"task {task['id']!r} seeded no user message"
            )

        # Content is per-session disjoint: the beta session's message
        # mentions deployment, the alpha sessions mention login.
        bodies_b = " ".join(
            str(m.get("content", "")) for m in _user_messages(harness, task_b1["id"])
        )
        assert "deployment" in bodies_b, f"beta session lost its seed: {bodies_b!r}"
        for task in (task_a1, task_a2):
            bodies_a = " ".join(
                str(m.get("content", "")) for m in _user_messages(harness, task["id"])
            )
            assert "login" in bodies_a, f"alpha session lost its seed: {bodies_a!r}"
            assert "deployment" not in bodies_a, (
                f"cross-workspace content leak over HTTP: {bodies_a!r}"
            )
