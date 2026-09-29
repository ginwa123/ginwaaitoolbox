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
import time
from pathlib import Path

import pytest

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
from db_seed import DbSeed
from ui_harness import UIHarness

try:
    # Only used to distinguish a retryable wait_for timeout from a real
    # error in _emit_and_wait_for. If Playwright isn't installed the
    # conftest browser fixture skips these tests anyway.
    from playwright.sync_api import TimeoutError as _PlaywrightTimeoutError
except ImportError:  # pragma: no cover
    _PlaywrightTimeoutError = None  # type: ignore[assignment,misc]


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


def _seed_session(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """Seed one session with a short alternating history."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Agent error card test")
        bind_session_workspace(conn, workspace_id, session_id)
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


def _open_chat(page, h: UIHarness, workspace_id: str, session_id: str) -> None:
    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, session_id)
    # Wait for the seeded history to render before firing events.
    # NOTE: no fixed sleep here — SSE readiness is handled by
    # _emit_and_wait_for's emit-with-retry loop (see below). A fixed
    # 500ms sleep used to race the cross-tab leader election (PR #450:
    # ~1s heartbeat + 250ms jitter before the EventSource opens) and
    # lose the race on slow macOS runners.
    page.locator("text=Working on it…").first.wait_for(timeout=15000, state="attached")


# ─── Emit-with-retry ────────────────────────────────────────────────────
#
# WHY THIS EXISTS (macOS flake, PR #450):
#
#     The frontend now opens ONE EventSource per origin: a fresh tab
#     starts as a BroadcastChannel follower and only becomes leader
#     (and opens the stream) after ~1s heartbeat + 250ms election
#     jitter. The test-only emit endpoint publishes on the backend bus
#     and DROPS the event when no stream is connected yet — so an emit
#     fired ~500ms after history render is silently lost on slow
#     runners, and the test then burns a full 10s wait_for timeout.
#
# FIX (test-only, no product change): re-emit until the expected
# locator surfaces. Re-emitting the same payload is idempotent for
# these assertions (singleton error card / transcript message), so:
# emit → 1s wait → re-emit → … until visible or the overall deadline.
# The fast path resolves on the first iteration (faster than the old
# fixed sleeps); slow runners self-heal instead of timing out.

#: Per-attempt wait inside the retry loop. Short so a lost first emit
#: is re-fired quickly; the overall deadline stays generous for slow
#: macOS runners.
_EMIT_RETRY_WAIT_MS = 1000


def _emit_and_wait_for(
    h: UIHarness,
    session_id: str,
    payload: dict,
    locator,
    *,
    state: str = "visible",
    timeout_ms: int = 15000,
) -> None:
    """Emit one SSE event, re-emitting until `locator` reaches `state`.

    Raises the last Playwright timeout if the overall deadline expires
    (keeps the useful call log). Non-timeout errors fail fast.
    """
    deadline = time.monotonic() + timeout_ms / 1000
    last_err: Exception | None = None
    while True:
        _emit_llm_event(h, session_id, payload)
        try:
            locator.wait_for(timeout=_EMIT_RETRY_WAIT_MS, state=state)
            return
        except Exception as e:  # noqa: BLE001 — filtered below
            if _PlaywrightTimeoutError is not None and not isinstance(
                e, _PlaywrightTimeoutError
            ):
                raise
            last_err = e
            if time.monotonic() >= deadline:
                assert last_err is not None
                raise last_err


def _emit_until_text(
    h: UIHarness,
    session_id: str,
    payload: dict,
    locator,
    needle: str,
    *,
    timeout_ms: int = 15000,
) -> str:
    """Re-emit until `locator`'s text contains `needle`. Returns the text.

    For the latest-wins test: the card is ALREADY visible from the
    previous emission, so a plain wait_for(visible) would return
    immediately on stale content. Poll the text instead, re-emitting
    on each miss (covers the same election-race loss as above).
    """
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        _emit_llm_event(h, session_id, payload)
        end = min(deadline, time.monotonic() + _EMIT_RETRY_WAIT_MS)
        while time.monotonic() < end:
            text = locator.inner_text()
            if needle in text:
                return text
            time.sleep(0.2)
        if time.monotonic() >= deadline:
            text = locator.inner_text()
            assert needle in text, (
                f"timed out waiting for {needle!r} in locator text, got {text!r}"
            )
            return text


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
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    _open_chat(page, h, workspace_id, session_id)

    # Pre-condition: no error cards yet.
    assert page.locator('[data-testid="agent-error-card"]').count() == 0

    # Fire the diagnostic through the real wire path. Emit-with-retry:
    # if the EventSource isn't up yet (leader election still running),
    # the first emission is dropped and transparently re-fired.
    card = page.locator('[data-testid="agent-error-card"]').first
    _emit_and_wait_for(
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
        card,
        state="visible",
    )

    # …with the parsed retry chip and server detail (single roundtrip
    # per element — inner_text() is a browser roundtrip each call).
    chip = page.locator('[data-testid="agent-error-retry"]').first
    chip_text = chip.inner_text()
    assert "1/10" in chip_text, f"retry chip missing '1/10': {chip_text!r}"

    headline = page.locator('[data-testid="agent-error-headline"]').first
    headline_text = headline.inner_text()
    assert "StreamInterrupted" in headline_text
    assert "callDynamicAgentNew" in headline_text

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
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    _open_chat(page, h, workspace_id, session_id)

    _emit_and_wait_for(
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
        page.locator(f"text={NORMAL_CONTENT}").first,
        state="attached",
    )
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
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    _open_chat(page, h, workspace_id, session_id)

    # Sequential + retry: emit #1 until the card shows 1/10, THEN emit
    # #2 until it flips to 2/10. The old code fired both blind with a
    # fixed 150ms gap and waited only for 2/10 — if the stream wasn't
    # up yet, BOTH emissions were dropped and the test burned a full
    # 10s timeout. Waiting for 1/10 first also proves the stream is
    # live, so the second emission is near-instant on fast runners.
    card = page.locator('[data-testid="agent-error-card"]').first
    _emit_and_wait_for(
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
        card,
        state="visible",
    )
    chip = page.locator('[data-testid="agent-error-retry"]').first
    first_text = chip.inner_text()
    assert "1/10" in first_text, (
        f"first error event did not render 1/10 chip, got {first_text!r}"
    )

    # Wait for the (single) card to surface the LATEST content. The Vue
    # key=agentError.id means the SECOND emission triggers a fresh
    # mount — poll the chip text (not just visibility: the card is
    # already visible with stale 1/10 content at this point).
    chip_text = _emit_until_text(
        h,
        session_id,
        {
            "type": "full",
            "index": 2,
            "content": RETRY_CONTENT_2,
            "role": "user",
            "finish_reason": "null",
            "is_error": True,
        },
        chip,
        "2/10",
    )
    assert "2/10" in chip_text, (
        f"latest-wins: retry chip should reflect the SECOND error "
        f"event's content, got {chip_text!r}"
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
