"""Functional UI test: agentic-loop errors render in AgentErrorCard.

Covers task_1787663566535_2 ("we need to change how error message
displayed where ai agent error").

THE BUG (pre-fix):

    Agentic-loop diagnostics — e.g.

        [Retry 1/10] StreamInterrupted (callDynamicAgentNew). Retrying in 10000ms.
        Server said: {"error":{"message":"Provider returned error","code":429}}

    — were inserted via insertLLMHistories with role=user and emitted on
    the SAME llm_full SSE event as normal messages, with NO error marker.
    ChatView's full-event handler pushed them into messages.value, so
    they rendered as a plain user chat bubble indistinguishable from a
    real user turn.

THE FIX (this branch):

    workflow.zig's 3 diagnostic sites set is_error=true; the flag rides
    the llm_full payload to the frontend. ChatView intercepts full events
    with is_error=true BEFORE the dedupe/push logic, routes them into the
    `agentError` singleton ref, and renders the single card via
    AgentErrorCard BELOW the VirtualScroller (never inside messages.value).

How this test drives the SSE path without a real LLM:

    Same mechanism as chatview_sse_stick_ui_test.py: the harness boots
    nalar with NALAR_TEST_SSE_EMIT=1, which arms POST /api/dev/sse/emit_llm.
    The test seeds a session, opens the chatview, then fires `full`
    events with is_error=true through the endpoint — the exact wire path
    a real agent loop uses.

Assertions (the bug contract):

    1. An is_error=true full event renders an [data-testid=agent-error-card]
       (NOT a user bubble) containing the retry chip + server detail.
    2. The event does NOT appear as a user message in the transcript.
    3. A normal (is_error=false) full event still renders as a regular
       assistant message — no regression on the happy path.
    4. Multiple error events overwrite in place — the singleton slot
       shows only the LATEST error (retry chain progress: 1/10 → 2/10
       on the SAME card). See commit 1e1d113a (task_1787668954023_2)
       for the rationale: avoids pile-up, surfaces the latest status.

Run:
    NALAR_BIN=./zig-out/bin/nalarcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_agent_error_card_ui_test.py -v
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Constants ──────────────────────────────────────────────────────────────

RETRY_CONTENT = (
    "[Retry 1/10] StreamInterrupted (callDynamicAgentNew). Retrying in 10000ms.\n"
    'Server said: {"error":{"message":"Provider returned error","code":429}}'
)

RETRY_CONTENT_2 = (
    "[Retry 2/10] StreamInterrupted (callDynamicAgentNew). Retrying in 10000ms.\n"
    "Server said: upstream provider rate-limited"
)

NORMAL_CONTENT = "Final assistant answer after a successful turn."


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _seed_session(h: UIHarness, session_id: str) -> None:
    """Seed one session with a short alternating history."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Agent error card test")
        stamps = DbSeed.baseline_timestamps(count=4, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "Hello agent", created_at=stamps[0])
        seed.seed_assistant_message(conn, session_id, "Hi! How can I help?", created_at=stamps[1])
        seed.seed_user_message(conn, session_id, "Do the thing", created_at=stamps[2])
        seed.seed_assistant_message(conn, session_id, "Working on it…", created_at=stamps[3])


def _emit_llm_event(h: UIHarness, session_id: str, payload: dict) -> None:
    """POST one SSE event through the test-only emit endpoint."""
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={**payload, "session_id": session_id},
        expect=200,
    )


def _open_chat(page, h: UIHarness, session_id: str) -> None:
    page.set_viewport_size({"width": 1440, "height": 900})
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="domcontentloaded",
        timeout=30000,
    )
    # Wait for the seeded history to render before firing events.
    page.locator("text=Working on it…").first.wait_for(timeout=15000, state="attached")
    page.wait_for_timeout(500)


# ─── Fixtures ───────────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots."""
    monkeypatch.setenv("NALAR_TEST_SSE_EMIT", "1")


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_is_error_event_renders_agent_error_card_not_user_bubble(
    page, ui_harness: UIHarness
) -> None:
    """THE bug contract: an is_error=true full event surfaces as an
    AgentErrorCard, NOT as a plain user chat bubble."""
    h = ui_harness
    session_id = "sess_agent_err_001"
    _seed_session(h, session_id)
    _open_chat(page, h, session_id)

    # Pre-condition: no error cards yet.
    assert page.locator('[data-testid="agent-error-card"]').count() == 0

    # Fire the diagnostic through the real wire path.
    _emit_llm_event(
        h,
        session_id,
        {
            "type": "full",
            "index": 1,
            "content": RETRY_CONTENT,
            "role": "user",
            "finish_reason": "null",
            "is_error": True,
        },
    )

    # 1. The dedicated card renders…
    card = page.locator('[data-testid="agent-error-card"]').first
    card.wait_for(timeout=10000, state="visible")

    # …with the parsed retry chip and server detail.
    chip = page.locator('[data-testid="agent-error-retry"]').first
    assert "1/10" in chip.inner_text(), f"retry chip missing '1/10': {chip.inner_text()!r}"

    headline = page.locator('[data-testid="agent-error-headline"]').first
    assert "StreamInterrupted" in headline.inner_text()
    assert "callDynamicAgentNew" in headline.inner_text()

    # Detail section exists but is collapsed by default.
    detail = page.locator('[data-testid="agent-error-detail"]').first
    assert detail.count() == 1

    # 2. The content must NOT appear as a user bubble in the transcript.
    #    User bubbles live inside the virtual scroller's message rows;
    #    the error card lives OUTSIDE it. Assert the raw content text is
    #    not rendered anywhere as a message paragraph.
    user_bubbles = page.locator(
        '.virtual-scroller >> text=[Retry 1/10] StreamInterrupted'
    )
    assert user_bubbles.count() == 0, (
        "is_error event leaked into the message transcript as a chat bubble"
    )


def test_normal_full_event_still_renders_as_assistant_message(
    page, ui_harness: UIHarness
) -> None:
    """No regression: a normal (is_error=false) full event still lands in
    the transcript as a regular assistant message."""
    h = ui_harness
    session_id = "sess_agent_err_002"
    _seed_session(h, session_id)
    _open_chat(page, h, session_id)

    _emit_llm_event(
        h,
        session_id,
        {
            "type": "full",
            "index": 1,
            "content": NORMAL_CONTENT,
            "role": "assistant",
            "finish_reason": "stop",
            "is_error": False,
        },
    )

    page.locator(f"text={NORMAL_CONTENT}").first.wait_for(timeout=10000, state="attached")
    assert page.locator('[data-testid="agent-error-card"]').count() == 0


def test_multiple_error_events_latest_wins_overwrites_in_place(
    page, ui_harness: UIHarness
) -> None:
    """Two consecutive retries → ONE card with the LATEST content.

    ChatView routes every `full` SSE event with is_error=true into a
    singleton `agentError` ref (see ChatView.vue: the line that does
    `agentError.value = { ... }` overwrites the previous entry on every
    new error). The retry chain therefore shows 1/10 → 2/10 → ... →
    final 10/10 bail ALL on the SAME card, not as a pile-up.

    Rationale (commit 1e1d113a, task_1787668954023_2, dedupe +
    expand): the user only ever needs the most recent status; older
    errors are noise once the agent has moved past them. The card also
    auto-clears as soon as ANY non-error `full` event arrives for the
    same session — i.e. the moment the agent recovers.
    """
    h = ui_harness
    session_id = "sess_agent_err_003"
    _seed_session(h, session_id)
    _open_chat(page, h, session_id)

    for i, content in enumerate((RETRY_CONTENT, RETRY_CONTENT_2), start=1):
        _emit_llm_event(
            h,
            session_id,
            {
                "type": "full",
                "index": i,
                "content": content,
                "role": "user",
                "finish_reason": "null",
                "is_error": True,
            },
        )
        page.wait_for_timeout(150)

    # Wait for the (single) card to surface. The Vue key=agentError.id
    # means the SECOND emission triggers a fresh mount, so we wait_for
    # the 2/10 retry chip to confirm the latest content arrived (the
    # first emission's 1/10 chip would race past this point in time).
    chip = page.locator('[data-testid="agent-error-retry"]').first
    chip.wait_for(timeout=10000, state="visible")
    assert "2/10" in chip.inner_text(), (
        f"latest-wins: retry chip should reflect the SECOND error "
        f"event's content, got {chip.inner_text()!r}"
    )

    # SINGLE card on the page (no accumulation).
    cards = page.locator('[data-testid="agent-error-card"]')
    assert cards.count() == 1, (
        f"latest-wins: expected 1 error card (singleton ref), got {cards.count()}"
    )

    # SINGLE retry chip too (the older one is replaced, not appended).
    chips = page.locator('[data-testid="agent-error-retry"]')
    assert chips.count() == 1, (
        f"latest-wins: expected 1 retry chip, got {chips.count()}"
    )

    # The card's content reflects the latest emission (RETRY_CONTENT_2 =
    # "Retry 2/10 ... upstream provider rate-limited"), NOT the first
    # one. Both the retry chip and the server-detail section reflect
    # this overwrite-in-place behavior.
    detail = page.locator('[data-testid="agent-error-detail"]').first
    assert "upstream provider rate-limited" in detail.inner_text(), (
        f"latest-wins: detail should reflect the SECOND error's "
        f"'Server said:' payload, got {detail.inner_text()!r}"
    )
