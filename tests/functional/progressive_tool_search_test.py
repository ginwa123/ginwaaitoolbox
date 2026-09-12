"""Functional tests for progressive tool search (search_tool / view_tool / use_tool).

The feature keeps MCP tools and NOT-enabled built-in tools out of the LLM's
tool list until the agent equips them with `use_tool` (recorded in
`session_progressive_tool`). These tests replay the real wire path and assert
on what the tool list ACTUALLY contained.

The hook is `[STREAM START] model=... | messages=N | tools=K | streaming=true`
— the tool count of the real LLM request. The harness's stub profile points
`base_url` at http://127.0.0.1:1 (a port that never answers), so there is no
upstream to capture a request body from; this log line is the observable
substitute, and it is emitted by the same code path that builds the request.

Note on a dead end: the workflow's `[CHECKPOINT] ...` `logger.infoFmt` lines
(including the one extended with mcp_equipped / builtin_equipped / catalog)
do NOT appear in the harness log, while the Agent's own `[info] [STREAM ...]`
lines do. So the tests deliberately key off the STREAM line instead.

Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search.md
"""

from __future__ import annotations

import re
import sqlite3
import time
from pathlib import Path

import pytest

from harness import FunctionalHarness

# `[STREAM START] model=stub-model | messages=2 | tools=5 | streaming=true`
STREAM_START_RE = re.compile(r"\[STREAM START\].*?\btools=(?P<tools>\d+)")

# Deliberately restrictive: with only two built-ins enabled, 38 of the 40
# registered tools are NOT enabled, so the catalog is large and the three
# meta-tools are injected. Expected request tool count = 2 + 3 = 5.
RESTRICTED_ALLOWLIST = "read_file,glob"
EXPECTED_RESTRICTED_TOOLS = 5
EXPECTED_RESTRICTED_PLUS_ONE_EQUIP = 6


def _db_path(h: FunctionalHarness) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _wait_for_tool_count(h: FunctionalHarness, timeout_s: float = 45.0) -> int:
    """The largest `tools=N` seen across the session's LLM calls.

    The main agent call carries the full tool list; the session-name generator
    call that precedes it reports tools=0, so the max is the real answer.
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


def _queue_message(h: FunctionalHarness, session_id: str, allowed_tools: str) -> None:
    """Create a session and queue one message (the nalar-tui body shape)."""
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


# ─── 1. A restricted allowlist leaves a catalog, so the meta-tools ship ─────


def test_meta_tools_are_injected_when_a_catalog_exists(stub_harness: FunctionalHarness) -> None:
    """2 allowlisted built-ins + search_tool + view_tool + use_tool == 5 tools
    on the real LLM request."""
    _queue_message(stub_harness, "prog-test-catalog", RESTRICTED_ALLOWLIST)

    assert _wait_for_tool_count(stub_harness) == EXPECTED_RESTRICTED_TOOLS, (
        "expected the 2 allowlisted built-ins plus the 3 progressive meta-tools"
    )


# ─── 2. An equipped not-enabled built-in reaches the real tool list ─────────


def test_equipped_builtin_is_injected_even_when_the_allowlist_excludes_it(
    stub_harness: FunctionalHarness,
) -> None:
    """The heart of the feature: `kanban_list` is NOT in the allowlist, but a
    session_progressive_tool row makes it appear — the request grows from 5 to
    6 tools."""
    session_id = "prog-test-equip"
    _equip_row(stub_harness, session_id, "kanban_list")

    _queue_message(stub_harness, session_id, RESTRICTED_ALLOWLIST)

    assert _wait_for_tool_count(stub_harness) == EXPECTED_RESTRICTED_PLUS_ONE_EQUIP, (
        "equipping one built-in must add exactly one tool to the request"
    )


# ─── 3. A stale equip name is inert ─────────────────────────────────────────


def test_stale_equip_name_adds_nothing(stub_harness: FunctionalHarness) -> None:
    """A name that is neither a registered built-in nor a cached MCP tool (a
    server that was since removed, say) must not change the tool list."""
    session_id = "prog-test-stale"
    _equip_row(stub_harness, session_id, "mcp_removed_server_do_thing", "removed")

    _queue_message(stub_harness, session_id, RESTRICTED_ALLOWLIST)

    assert _wait_for_tool_count(stub_harness) == EXPECTED_RESTRICTED_TOOLS, (
        "a stale session_progressive_tool row must contribute nothing"
    )


# ─── 4. The validation rule at the DB level ─────────────────────────────────


def test_duplicate_equip_row_is_rejected_by_the_primary_key(
    stub_harness: FunctionalHarness,
) -> None:
    """`PRIMARY KEY(session_id, tool_name)` is the DB half of "if it is already
    equipped, do not insert" — INSERT OR IGNORE leaves exactly one row, which
    is what makes `use_tool`'s inserted=false honest."""
    session_id = "prog-test-dup"
    _equip_row(stub_harness, session_id, "glob")
    _equip_row(stub_harness, session_id, "glob")

    conn = sqlite3.connect(str(_db_path(stub_harness)))
    try:
        n = conn.execute(
            "SELECT COUNT(*) FROM session_progressive_tool WHERE session_id = ?",
            (session_id,),
        ).fetchone()[0]
    finally:
        conn.close()

    assert n == 1, f"expected exactly one row after two identical equips, got {n}"


# ─── 5. The equip is per session ────────────────────────────────────────────


def test_equip_does_not_leak_into_another_session(stub_harness: FunctionalHarness) -> None:
    _equip_row(stub_harness, "prog-test-scope-a", "kanban_list")

    _queue_message(stub_harness, "prog-test-scope-b", RESTRICTED_ALLOWLIST)

    assert _wait_for_tool_count(stub_harness) == EXPECTED_RESTRICTED_TOOLS, (
        "another session's equip row must not reach this session's tool list"
    )
