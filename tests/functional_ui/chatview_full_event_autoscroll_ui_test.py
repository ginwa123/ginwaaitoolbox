"""Functional UI test: the SSE `llm_chunk` → `llm_full(finish_reason=stop)` pair.

The report, verbatim:

    "Chatview has issue if sse send a llm chunk and llm full data finish reason
     stop, its like automatically go to bottom scrollbar chatview"

What makes this pair special
    It is the ONE auto-stick trigger in ChatView that is two events wide, and
    it is the only one that REWRITES the transcript instead of appending to it:

      * `llm_chunk` → `updateStreamingMessage()` finds/creates the synthetic
        `streaming-*` row, appends the delta, and (coalesced into one rAF)
        calls `scrollToBottom(false, 'sse-chunk')`.
      * `llm_full` with `finish_reason` → the handler FILTERS the `streaming-*`
        row out, PUSHES the canonical DB row under a brand-new group key, and
        in `nextTick` calls `remeasure()` + `scrollToBottom(false,
        'sse-message-complete')`.

    So the `full` is not an append — it is an identity swap (new `id`, new group
    key, no measured height) that lands in a DIFFERENT height than the row it
    replaced. That is the step the chunk-only tests cannot reach.

Why this is not already covered
    `chatview_at_bottom_stick_ui_test.py` is the real-browser home of this
    subsystem and it is thorough — but every test in it drives `_emit_chunk`
    only. `_emit_turn` (the `full` emitter) is used by exactly one test, and
    that one is about SENDING from history, not about the swap's scroll
    behaviour. The unit-level `ChatView.chunk-stream.spec.ts` is a hand-written
    replica of the handler with no scroll assertions at all, and
    `ChatView.streamingStick.spec.ts` cannot even mount the scroller (it mocks
    `api.getChatHistory`, which the `chatEngineDb` refactor made unreachable;
    see the sibling spec added in this same change).

Why a real browser
    Same reason as the sibling file: the defect is about measured geometry
    (`offsetHeight`, the sizer model, the tail cap) and jsdom reports zeros for
    all of it. In jsdom the two auto-stick call sites are provably correct —
    they are gated on `isAtBottom`, and a scrolled-up reader is not yanked. The
    browser is where the height model exists.

Run (the frontend is served from THIS worktree — that is the code under test;
the backend binary can come from anywhere, since no backend code changed):

    zig build
    NALAR_BIN=./zig-out/bin/nalarcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_full_event_autoscroll_ui_test.py -v

Ports: the UI harness reserves (5173, 8081) and picks both the backend and the
Vite port from [20000, 32000]. NEVER 8081 — a dev server runs there.
"""

from __future__ import annotations

import pytest

from chatview_boot import bind_session_workspace, create_workspace, open_chatview
from db_seed import DbSeed
from ui_harness import UIHarness

# Reuse the sibling suite's geometry reader and emitters verbatim. Re-deriving
# `appBottom` here would be re-implementing the predicate under test, which is
# how a test ends up asserting nothing.
from chatview_at_bottom_stick_ui_test import (
    MAX_TAIL_GAP_PX,
    SLACK_PX,
    TALL_BODY,
    TURN_COUNT,
    _CHAT_SCROLLER,
    _emit_chunk,
    _emit_turn,
    _geom,
    _open_chat,
    _scroll_to_fraction,
)


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots."""
    monkeypatch.setenv("NALAR_TEST_SSE_EMIT", "1")


def _seed_session(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """A transcript far taller than the viewport, uniform body heights."""
    seed = DbSeed(h.temp_dir / ".config" / "nalar" / "agent.db")
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"Full-event autoscroll {TURN_COUNT}")
        bind_session_workspace(conn, workspace_id, session_id)
        stamps = DbSeed.baseline_timestamps(count=TURN_COUNT, interval_seconds=30)
        for i in range(TURN_COUNT):
            body = TALL_BODY.format(i=i)
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


def _open(page, h: UIHarness, session_id: str) -> None:
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    _open_chat(page, h, workspace_id, session_id)


def _settle(page) -> None:
    page.wait_for_timeout(900)


# ─── The two halves of the contract ─────────────────────────────────────────


def test_a_scrolled_up_reader_is_not_rolled_to_the_bottom_by_chunk_then_full(
    ui_harness: UIHarness, page
) -> None:
    """THE report: chunk → full(stop) must not drag a reader in the history down.

    This is the scenario the report describes and the one nothing covered: the
    reader has deliberately scrolled up, the turn is streaming below them, and
    the turn's FINAL `llm_full` swaps the streaming row for the canonical one.
    Both auto-stick call sites are gated on `isAtBottom`, so the claim is that
    the gate still reads false after an identity swap that changes the row's
    height and its group key.

    The assertion is deliberately on `scrollTop` DELTA across the `full`,
    sampled after the swap has settled. A transient excursion that healed
    itself would still be a visible jump, so the delta is taken against the
    pre-`full` position rather than against "the bottom".
    """
    h = ui_harness
    session_id = "sess-full-event-scrolled-up"
    _open(page, h, session_id)

    _scroll_to_fraction(page, 0.35)
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')", timeout=10000
    )
    parked = _geom(page)
    print(f"\n[full-event] scrolled up : {parked}")
    assert parked["arrow"], "precondition failed: scrolling up did not disarm the stick"

    # The streaming half of the pair: the delta lands below the viewport.
    _emit_chunk(h, session_id, "Streamed body that lands below the fold. " * 4)
    _settle(page)
    after_chunk = _geom(page)
    print(f"[full-event] after the chunk : {after_chunk}")
    assert abs(after_chunk["scrollTop"] - parked["scrollTop"]) <= SLACK_PX, (
        "the reader scrolled up to read history and the chunk dragged them down: "
        f"{parked['scrollTop']} -> {after_chunk['scrollTop']}"
    )
    assert after_chunk["arrow"], (
        f"the stick re-engaged mid-stream for a reader still in the history: {after_chunk}"
    )

    # The finishing half — the one nothing covered.
    _emit_turn(
        h,
        session_id,
        "Streamed body that lands below the fold. And here is the canonical "
        "assistant row that replaces it, with the full settled text.",
        index=9101,
    )
    _settle(page)
    after_full = _geom(page)
    print(f"[full-event] after the full(stop) : {after_full}")

    assert abs(after_full["scrollTop"] - after_chunk["scrollTop"]) <= SLACK_PX, (
        "llm_full(finish_reason=stop) rolled the reader to the bottom: scrollTop "
        f"{after_chunk['scrollTop']} -> {after_full['scrollTop']} "
        f"(the bottom is at {after_full['appBottom']})"
    )
    assert after_full["arrow"], (
        "the app now believes the reader is at the bottom although they never "
        f"left the history — the next chunk will drag them down: {after_full}"
    )


def test_an_at_bottom_reader_stays_through_chunk_then_full(
    ui_harness: UIHarness, page
) -> None:
    """The other half: the swap must not strand a reader who was at the bottom.

    An over-broad fix for the test above — freezing `isAtBottom`, or dropping
    the post-swap `remeasure()` unconditionally — would make this one fail. The
    canonical row renders at a different height than the streaming row it
    replaces, so without the remeasure the reader is left short of the bottom
    after a routine turn.
    """
    h = ui_harness
    session_id = "sess-full-event-at-bottom"
    _open(page, h, session_id)

    page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; if (el) el.scrollTop = 1e9; }"
    )
    _settle(page)
    armed = _geom(page)
    print(f"\n[full-event] armed : {armed}")
    assert not armed["arrow"], f"precondition failed: the stick is not armed: {armed}"

    _emit_chunk(h, session_id, "Streamed body. " * 6)
    _settle(page)
    after_chunk = _geom(page)
    assert not after_chunk["arrow"], f"the stick died on the chunk: {after_chunk}"

    _emit_turn(
        h,
        session_id,
        "Streamed body. " * 6 + "And here is the canonical assistant row.",
        index=9102,
    )
    _settle(page)
    after_full = _geom(page)
    print(f"[full-event] at the bottom, after full(stop) : {after_full}")

    assert not after_full["arrow"], (
        "the reader was at the bottom the whole time and llm_full decided "
        f"otherwise — the arrow is on a chat nobody scrolled: {after_full}"
    )
    assert after_full["scrollTop"] >= after_full["appBottom"] - SLACK_PX, (
        "llm_full stranded the reader "
        f"{after_full['appBottom'] - after_full['scrollTop']:.0f}px above the "
        f"bottom: {after_full}"
    )
    # The swap must actually have moved the transcript, or the assertions above
    # proved nothing.
    assert after_full["appBottom"] > armed["appBottom"], (
        f"the turn did not grow the transcript, so nothing was under test: "
        f"{armed['appBottom']} -> {after_full['appBottom']}"
    )
    # The blank-viewport guard is still intact: a correct stick is allowed to
    # sit up to the tail cap above the DOM max, and no further.
    assert after_full["rulerGap"] <= MAX_TAIL_GAP_PX + SLACK_PX, (
        f"the sizer overshoots the real content by {after_full['rulerGap']:.0f}px "
        f"past the {MAX_TAIL_GAP_PX}px tail cap: {after_full}"
    )
