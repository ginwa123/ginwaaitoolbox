"""Playwright regression test for the 2026-08-24 chatview wire-shape bug.

Background (task_1787545088500_6, bug A): the chatview's `groupToolNames`
computed (ChatView.vue ~1376) is supposed to suppress the "tools" pill
when every tool call in an assistant row's `tool_calls_json` has a
matching `tool` row in the transcript. The suppression depends on
parsing `msg.tool_calls_json` to walk each call's `id` — but the
REST/SSE wire had to carry that field onto the Vue `Message` object.

Bug A: REST path worked (loadChatHistory mapped `tool_calls_json`
into the Vue message at ChatView.vue:1579) but the SSE path didn't
(push at ChatView.vue:2300 omitted the field). On a live SSE round
trip the field was undefined → JSON.parse never ran → pill flashed
between every tool card. Refresh-renders were fine because REST
came in correct.

These tests use DB-seeding (no live SSE) so they verify the
**render path** end-to-end: loadChatHistory → Message → groupToolNames
→ DOM. They are guard-rails — if a future refactor drops
`tool_calls_json` from the REST mapper too, the pill-suppression
contract breaks and the chatview becomes noisy again. Both the
"snapshot loaded with tool_call_ids present" and "no pill renders"
asserts are sourced from the original bug report.

We assert on DOM presence of the pill (.tool-calls-badge inside
.tool-calls-summary). NOT on .markdown-content count == 0 (the
chatview group container always carries .markdown-content for
non-user groups — see memory mem_d1b1e0db27185dd3).
"""

from __future__ import annotations

import json

from db_seed import DbSeed
from ui_harness import UIHarness


def _seed_db_path(h: UIHarness):
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _open_chatview(page, h: UIHarness, session_id: str, timeout_ms: int = 30000) -> None:
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="load",
        timeout=timeout_ms,
    )


def _wait_for_text(page, text: str, timeout_ms: int = 10000) -> None:
    page.locator(f"text={text}").first.wait_for(timeout=timeout_ms, state="attached")


def _pill_count(page) -> int:
    """Count rendered "tools" pills (.tool-calls-badge) in the DOM.

    Each assistant group whose `groupToolNames` returns a string
    (anything other than null) renders one .tool-calls-summary block
    containing one .tool-calls-badge. This is the live, user-visible
    artifact of bug A.
    """
    return page.locator(".tool-calls-badge").count()


# ─── Test 1: rendered pill suppressed when every tool_call has a tool row ──


def test_pill_suppressed_when_tool_rows_match_tool_call_ids(
    ui_harness: UIHarness, page,
) -> None:
    """Multi-tool turn where every tool_call_id has a matching tool row:
    the chatview MUST NOT render any "tools" pill.

    Reproduces task_1787545088500_6 screenshot 1 (session
    task_1787540075329_3) where pills spammed between every card.
    The wire-shape fix (ChatView.vue loadChatHistory maps
    tool_calls_json) is what makes this test pass.
    """
    h = ui_harness
    session_id = "sess_pill_suppression_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Pill suppression test")

        ts = DbSeed.baseline_timestamps(count=5, interval_seconds=10)
        # User prompt
        seed.seed_user_message(conn, session_id, "do three things", created_at=ts[0])

        # Assistant row with 3 tool_calls whose ids ALL have matching tool rows
        tool_calls = [
            {
                "id": "tc_bash_1",
                "type": "function",
                "function": {"name": "bash", "arguments": '{"command": "ls"}'},
            },
            {
                "id": "tc_read_1",
                "type": "function",
                "function": {"name": "read_file", "arguments": '{"path": "/x"}'},
            },
            {
                "id": "tc_search_1",
                "type": "function",
                "function": {"name": "search", "arguments": '{"pattern": "foo"}'},
            },
        ]
        seed.seed_assistant_message(
            conn,
            session_id,
            text="",
            finish_reason="tool_calls",
            tool_calls=tool_calls,
            created_at=ts[1],
        )

        # Three tool rows with matching tool_call_ids
        seed.seed_tool_result(
            conn, session_id,
            tool_call_id="tc_bash_1",
            tool_name="bash",
            content="<tool><name>bash</name><parameters><command>ls</command></parameters><data>file.txt</data></tool>",
            created_at=ts[2],
        )
        seed.seed_tool_result(
            conn, session_id,
            tool_call_id="tc_read_1",
            tool_name="read_file",
            content="<tool><name>read_file</name><parameters><path>/x</path></parameters><data>contents</data></tool>",
            created_at=ts[3],
        )
        seed.seed_tool_result(
            conn, session_id,
            tool_call_id="tc_search_1",
            tool_name="search",
            content="<tool><name>search</name><parameters><pattern>foo</pattern></parameters><data>match</data></tool>",
            created_at=ts[4],
        )

    _open_chatview(page, h, session_id)
    # Wait for any one of the tool cards to mount as the
    # "render-stable" signal. The bash/read/search cards all share
    # .chat-tool-card so any of them works.
    page.locator(".chat-tool-card").first.wait_for(timeout=15000, state="attached")
    # Give Vue a tick to recompute groupToolNames after the last card mounted
    page.wait_for_timeout(500)

    pill_total = _pill_count(page)
    assert pill_total == 0, (
        f"pill_suppressed_when_tool_rows_match: expected 0 tools pills, "
        f"got {pill_total}. The pill-spam bug A has regressed — check "
        f"that loadChatHistory (ChatView.vue ~1579) still maps "
        f"msg.tool_calls_json onto the Vue message AND that "
        f"groupToolNames still parses it."
    )


# ─── Test 2: pill renders when there is a tool_calls row but NO tool row ──


def test_pill_renders_when_assistant_has_tool_calls_but_no_tool_row(
    ui_harness: UIHarness, page,
) -> None:
    """Orphan tool_calls: assistant row has tool_calls_json but no tool
    rows exist in the transcript. The pill MUST render (so the user
    knows the agent is waiting on a tool result) — defensive regression
    guard so the suppression logic doesn't suppress legitimate "..."
    cases.
    """
    h = ui_harness
    session_id = "sess_pill_render_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Pill should render")

        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=10)
        seed.seed_user_message(conn, session_id, "do thing", created_at=ts[0])

        # Assistant row with tool_calls but NO matching tool rows follow
        tool_calls = [
            {
                "id": "tc_orphan_1",
                "type": "function",
                "function": {"name": "bash", "arguments": '{"command": "x"}'},
            },
        ]
        seed.seed_assistant_message(
            conn,
            session_id,
            text="",
            finish_reason="tool_calls",
            tool_calls=tool_calls,
            created_at=ts[1],
        )

    _open_chatview(page, h, session_id)
    _wait_for_text(page, "do thing")
    # Pill must appear because no tool row exists for tc_orphan_1
    page.locator(".tool-calls-badge").first.wait_for(timeout=10000, state="attached")
    assert _pill_count(page) >= 1, (
        "pill_renders_when_no_tool_row: expected at least 1 tools pill "
        "for an orphan tool_calls assistant row."
    )


# ─── Test 3: tool_calls_json is in the REST response (loadChatHistory) ────


def test_rest_endpoint_includes_tool_calls_json(
    ui_harness: UIHarness,
) -> None:
    """The REST `/api/llm/session/<id>/messages` endpoint MUST include
    `tool_calls_json` for each assistant row that has tool_calls.

    This is the source-of-truth guard for the REST wire shape. The
    frontend ChatView.vue ~1579 reads `msg.tool_calls_json` from the
    REST response to populate the Vue `Message` object's
    `tool_calls_json`. If the REST endpoint drops the field, the
    suppression logic breaks and pill-spam returns.

    The corresponding SSE shape is verified by the unit test
    ChatView.toolCallsJsonWireShape.spec.ts (source-contract).
    """
    h = ui_harness
    session_id = "sess_rest_tcjson_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "REST shape test")
        tc_payload = [
            {
                "id": "tc_rest_1",
                "type": "function",
                "function": {"name": "bash", "arguments": '{"command": "ls"}'},
            }
        ]
        seed.seed_assistant_message(
            conn, session_id, text="", finish_reason="tool_calls",
            tool_calls=tc_payload,
        )

    resp = h.http(
        "GET",
        f"/api/llm/session/{session_id}/messages?sort_by=created_at&direction=desc&limit=50",
        expect=200,
    )
    body = resp.json()
    msgs = body.get("messages") or []
    assert len(msgs) >= 1, f"REST returned 0 messages for session {session_id}"
    asst = next((m for m in msgs if m.get("role") == "assistant"), None)
    assert asst is not None, f"no assistant row in REST response: {msgs}"
    tcj = asst.get("tool_calls_json")
    assert tcj is not None, (
        "REST assistant row MISSING tool_calls_json — loadChatHistory "
        "won't be able to suppress the 'tools' pill. Re-check the "
        "SessionMessageResponse shape in http_handlers/session_messages_get.zig."
    )
    # Must be parseable JSON (string-encoded, as production sends it)
    if isinstance(tcj, str):
        parsed = json.loads(tcj)
    else:
        parsed = tcj
    assert isinstance(parsed, list) and len(parsed) == 1
    assert parsed[0]["id"] == "tc_rest_1"
    assert parsed[0]["function"]["name"] == "bash"
