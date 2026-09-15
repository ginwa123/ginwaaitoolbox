"""Functional tests for progressive tool search (search_tool / view_tool / use_tool).

The feature keeps MCP tools and NOT-enabled built-in tools out of the LLM's
tool list until the agent equips them with `use_tool` (recorded in
`session_progressive_tool`), and the three meta-tools are **default-equipped in
agent and kanban mode only** — the two modes whose creation path seeds
`DEFAULT_AGENT_TOOLS`. Design and folder items seed no tool list, and a plain
chat session has no workspace item at all, so none of them get the three.

These tests assert on what the real LLM request contained, via
`[STREAM START] model=... | messages=N | tools=K`. The harness's stub profile
points `base_url` at http://127.0.0.1:1 (a dead port), so there is no upstream
to capture a body from.

Note on a dead end: `workflow.zig`'s `[CHECKPOINT] ...` `logger.infoFmt` lines
do NOT reach the harness log, while the Agent's `[info] [STREAM ...]` lines do —
so these tests deliberately key off the STREAM line.

Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search.md
"""

from __future__ import annotations

import re
import sqlite3
import time
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness

# `[STREAM START] model=stub-model | messages=2 | tools=5 | streaming=true`
STREAM_START_RE = re.compile(r"\[STREAM START\].*?\btools=(?P<tools>\d+)")

PROGRESSIVE_TOOL_NAMES = ("search_tool", "view_tool", "use_tool")

# A fresh kanban item seeds DEFAULT_AGENT_TOOLS + DEFAULT_KANBAN_TOOLS. The
# agent defaults list ALREADY contains search_tool/view_tool/use_tool, so the
# three arrive through the seeded tool config — that seed is what scopes the
# default to agent/kanban mode, and only these two creation paths apply it.
AGENT_DEFAULTS = 25
KANBAN_ONLY_DEFAULTS = 2
KANBAN_SEEDED_TOOLS = AGENT_DEFAULTS + KANBAN_ONLY_DEFAULTS  # 27
# A tool that is NOT in the seeded set and is not design-only, so equipping it
# is legal for a kanban item and observably adds exactly one tool.
NOT_SEEDED_KANBAN_TOOL = "set_git_worktree"


def _db_path(h: FunctionalHarness) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _wait_for_tool_count(h: FunctionalHarness, timeout_s: float = 45.0) -> int:
    """The largest `tools=N` seen, i.e. the main agent call's tool count.

    The session-name generator call that precedes it reports tools=0.
    """
    deadline = time.monotonic() + timeout_s
    tail = ""
    best = -1
    while time.monotonic() < deadline:
        tail = h.tail_log(4000)
        best = -1
        for m in STREAM_START_RE.finditer(tail):
            best = max(best, int(m.group("tools")))
        if best > 0:
            return best
        time.sleep(0.2)
    raise AssertionError(
        f"no '[STREAM START] ... tools=N' line with N>0 within {timeout_s}s.\n"
        f"--- log tail ---\n{tail[-6000:]}"
    )


def _queue_plain_message(h: FunctionalHarness, session_id: str, allowed_tools: str) -> None:
    """A plain (unbound) chat session — the nalar-tui body shape."""
    h.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "queue_message": "hello from the progressive tool search test",
            "cwd_session": str(h.temp_dir),
            "allowed_tools": allowed_tools,
            "image_urls": "",
            "selected_profile_model": "",
            "is_auto_retry_until_stop": "",
        },
        expect=(201, 500),
    )


def _create_workspace(h: FunctionalHarness, name: str = "prog-ws") -> str:
    return h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _create_kanban(h: FunctionalHarness, workspace_id: str, name: str = "prog-board") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _run_kanban_task(
    h: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
    description: str = "run the agent",
) -> str:
    """Create + run a kanban task; returns its session id (== task id).

    This is how a session gets bound to a kanban item, which is what makes
    `self_item_type == "kanban"` during the agent run.
    """
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body={
            "mode": "create_and_run",
            "name": name,
            "description": description,
            "queue_message": f"{name}\n\n{description}",
        },
        expect=201,
    )
    body: dict[str, Any] = r.json()
    task = body.get("task")
    assert task is not None, f"create response missing 'task': {body!r}"
    return task["id"]


def _create_kanban_task_idle(
    h: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
) -> str:
    """Create a kanban task WITHOUT running it; returns its id (== session id).

    Needed because an equip row must exist BEFORE the session's first LLM call,
    and the session id is only known once the task exists.
    """
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": name, "description": ""},
        expect=201,
    )
    body: dict[str, Any] = r.json()
    task = body.get("task")
    assert task is not None, f"create response missing 'task': {body!r}"
    return task["id"]


def _run_existing_session(h: FunctionalHarness, session_id: str) -> None:
    """Queue a message onto an existing session, starting the workflow.

    `allowed_tools` is deliberately empty: for a kanban-bound session the board
    override supplies the real allowlist, which is the behaviour under test.
    """
    h.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "queue_message": "continue",
            "cwd_session": str(h.temp_dir),
            "allowed_tools": "",
            "image_urls": "",
            "selected_profile_model": "",
            "is_auto_retry_until_stop": "",
        },
        expect=(201, 500),
    )


def _equip_row(h: FunctionalHarness, session_id: str, tool_name: str, server: str = "") -> None:
    """Insert an equip row directly, the way a previous iteration would have."""
    conn = sqlite3.connect(str(_db_path(h)))
    try:
        conn.execute(
            "INSERT OR IGNORE INTO session_progressive_tool "
            "(session_id, tool_name, server_name, loaded_at_nano) "
            "VALUES (?, ?, ?, strftime('%s','now'))",
            (session_id, tool_name, server),
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture
def stub_harness(default_nalar_bin: Path):
    """A harness WITH a stub LLM profile, so the workflow reaches its loop."""
    h = FunctionalHarness.boot(default_nalar_bin, stub_llm_profile=True)
    try:
        yield h
    finally:
        h.teardown()




def test_unbound_chat_session_does_not_get_the_meta_tools(
    stub_harness: FunctionalHarness,
) -> None:
    """A plain chat session has no workspace item, so `self_item_type` is "" —
    not agent/kanban — and the three progressive tools must NOT be injected.
    This is what scopes the default to the two modes the user asked for."""
    _queue_plain_message(stub_harness, "prog-test-unbound", "read_file,glob")

    got = _wait_for_tool_count(stub_harness)
    assert got == 2, (
        f"a session with no workspace item must get only its 2 allowlisted "
        f"built-ins (no progressive tools), got {got}"
    )




# ─── 5. The validation rule at the DB level ─────────────────────────────────


def test_duplicate_equip_row_is_rejected_by_the_primary_key(
    stub_harness: FunctionalHarness,
) -> None:
    """`PRIMARY KEY(session_id, tool_name)` is the DB half of "if it is already
    equipped, do not insert" — INSERT OR IGNORE leaves exactly one row, which
    is what makes `use_tool`'s inserted=false honest."""
    session_id = "prog-test-dup"
    _equip_row(stub_harness, session_id, "set_git_worktree")
    _equip_row(stub_harness, session_id, "set_git_worktree")

    conn = sqlite3.connect(str(_db_path(stub_harness)))
    try:
        n = conn.execute(
            "SELECT COUNT(*) FROM session_progressive_tool WHERE session_id = ?",
            (session_id,),
        ).fetchone()[0]
    finally:
        conn.close()

    assert n == 1, f"expected exactly one row after two identical equips, got {n}"
