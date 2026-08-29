"""Functional UI test: chatview stick-to-bottom under SSE streaming.

Reproduces the user-reported bug (task_1787595375531_0, "when new data
come in, why i can scroll until bottom like this?"):

    When SSE chunks arrive, the chat view's scroll position ends up NOT
    at the bottom of the content. The user can scroll further DOWN into
    empty sizer space — a large blank gap between the last message and
    the bottom of the scroller.

Root causes fixed on this branch (PR #333 + follow-up):

    1. `container.scrollTop = container.scrollHeight` relied on the
       browser's implicit clamp — timing-fragile when the sizer's
       `:style.height` hadn't flushed. Fixed to explicit
       `Math.max(0, scrollHeight - clientHeight)`.

    2. `handleVirtualScroll` flipped `isAtBottom=false` when content
       grew under a stationary viewport (deltaTop=0, distanceFromBottom
       jumped past the 10px threshold). That permanently disengaged the
       auto-stick — every later contentShift skipped (spacer-resize-skip)
       and the gap grew with every chunk. Fixed: only a real upward
       scroll (deltaTop < 0) disengages.

How this test drives the SSE path without a real LLM:

    The harness boots the nalar binary with NALAR_TEST_SSE_EMIT=1, which
    arms the test-only endpoint POST /api/dev/sse/emit_llm. The test
    seeds a session + history via DB, opens the chatview, waits at the
    bottom, then fires a burst of `chunk` events followed by a `full`
    event through the endpoint — the exact wire path a real agent loop
    uses (event_bus "llm" routing key → frontend sseClient → ChatView).

Assertions (the actual bug contract):

    After the SSE burst, the scroller's distance-from-bottom must stay
    under a small threshold — i.e. the view is still stuck to the
    bottom, with NO large blank gap below the last message.

    On the pre-fix code this fails: the first chunk that grows the
    content while the viewport is stationary flips isAtBottom=false,
    the re-stick skips, and the gap grows to hundreds of px.

Run:
    NALAR_BIN=./zig-out/bin/nalarcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_sse_stick_ui_test.py -v
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Constants ──────────────────────────────────────────────────────────────

#: How close to the true bottom the view must stay after the SSE burst.
#: The VirtualScroller's re-stick runs inside a rAF, so a frame or two
#: of lag is expected; anything under ~120px means the stick is engaged.
#: The pre-fix bug produced gaps of 500-2000px+ (growing per chunk).
STICK_GAP_THRESHOLD_PX = 120

#: Number of streamed chunks to fire. Each chunk appends a line of text
#: to the streaming assistant message, growing the content by ~40-60px.
#: 12 chunks ≈ 500-700px of growth — enough to expose a disengaged stick.
CHUNK_COUNT = 12

#: Text per chunk — one markdown paragraph line. Rendered height ≈ 40-60px.
CHUNK_TEXT_TEMPLATE = "\n\nStreaming line {i}: the quick brown fox jumps over the lazy dog repeatedly to grow the message height."


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _seed_session_with_history(
    h: UIHarness,
    session_id: str,
    n_messages: int = 20,
    older_count: int = 0,
) -> None:
    """Seed a session with enough history to make the scroller overflow.

    20 alternating user/assistant messages with multi-paragraph bodies
    ≈ 6000-8000px of content — comfortably taller than the ~900px chat
    viewport, so the scroller is scrollable and the initial-load
    scrollToBottom matters.

    ``older_count``: extra messages seeded with created_at_nano values
    BELOW the main batch (chronologically older). The messages endpoint
    pages with `direction=desc` + `cursor` (created_at_nano < cursor),
    so these older rows are what a loadMore prepend fetches — and
    because they exist, the initial page reports has_more=true (the
    backend queries limit+1 rows). Pass >0 to exercise the loadMore
    prepend path (Bug C, task_1787638309623_3).
    """
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "SSE stick test")
        stamps = DbSeed.baseline_timestamps(count=n_messages, interval_seconds=30)
        for i in range(n_messages):
            body = (
                f"Message {i} paragraph one.\n\n"
                f"Message {i} paragraph two with some longer text to give the "
                f"bubble real height in the virtual scroller. Lorem ipsum dolor "
                f"sit amet, consectetur adipiscing elit, sed do eiusmod tempor "
                f"incididunt ut labore et dolore magna aliqua.\n\n"
                f"Message {i} paragraph three with even more filler text so each "
                f"bubble measures a few hundred pixels tall in the layout."
            )
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])
        if older_count > 0:
            # Chronologically OLDER than stamps[0] — the loadMore cursor
            # (created_at_nano < stamps[0]) fetches exactly these.
            from datetime import datetime, timedelta, timezone

            first_dt = datetime.fromisoformat(stamps[0].replace("Z", "+00:00"))
            older_stamps = DbSeed.baseline_timestamps(
                base=first_dt - timedelta(seconds=60 * (older_count + 1)),
                count=older_count,
                interval_seconds=30,
            )
            for i in range(older_count):
                body = (
                    f"Older message {i} paragraph one.\n\n"
                    f"Older message {i} paragraph two with enough filler text "
                    f"to give the prepended bubble real height in the layout. "
                    f"Lorem ipsum dolor sit amet, consectetur adipiscing elit."
                )
                if i % 2 == 0:
                    seed.seed_user_message(conn, session_id, body, created_at=older_stamps[i])
                else:
                    seed.seed_assistant_message(conn, session_id, body, created_at=older_stamps[i])


def _emit_llm_event(h: UIHarness, session_id: str, payload: dict) -> None:
    """POST one SSE event through the test-only emit endpoint."""
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={**payload, "session_id": session_id},
        expect=200,
    )


def _scroller_geometry(page) -> dict:
    """Read the CHAT scroller's live geometry from the browser.

    NOTE: there are TWO `.virtual-scroller` elements on the page — the
    sidebar ChatsList and the chat messages scroller. We scope to the
    chat one via the messages wrapper (`.relative.flex-1.min-h-0` div
    that ChatView renders around the VirtualScroller).
    """
    return page.evaluate(
        """() => {
            const wrapper = document.querySelector('.virtual-scroller');
            // Pick the chat scroller: the one inside the messages wrapper
            // (flex-1 min-h-0), NOT the sidebar ChatsList. Heuristic: the
            // chat scroller is the TALLER of the visible scrollers.
            const all = [...document.querySelectorAll('.virtual-scroller')]
                .filter(el => el.offsetParent !== null)
                .map(el => ({
                    el,
                    ch: el.clientHeight,
                }))
                .sort((a, b) => b.ch - a.ch);
            if (!all.length) return null;
            const el = all[0].el;
            return {
                scrollTop: el.scrollTop,
                scrollHeight: el.scrollHeight,
                clientHeight: el.clientHeight,
                distanceFromBottom: el.scrollHeight - el.scrollTop - el.clientHeight,
            };
        }"""
    )


def _wait_for_streaming_text(page, text: str, timeout_ms: int = 15000) -> None:
    page.locator(f"text={text}").first.wait_for(timeout=timeout_ms, state="attached")


# ─── Fixtures ───────────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch, request: pytest.FixtureRequest) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots.

    The harness copies os.environ at boot time, so setting the var in a
    fixture that runs before ui_harness boot is sufficient. Tests that
    need the gate OFF (the 404 contract test) mark themselves with
    ``@pytest.mark.no_sse_gate`` and this fixture skips arming.
    """
    if "no_sse_gate" in request.keywords:
        monkeypatch.delenv("NALAR_TEST_SSE_EMIT", raising=False)
    else:
        monkeypatch.setenv("NALAR_TEST_SSE_EMIT", "1")


# ─── Tests ──────────────────────────────────────────────────────────────────


@pytest.mark.no_sse_gate
def test_gate_off_returns_404(ui_harness: UIHarness) -> None:
    """Without NALAR_TEST_SSE_EMIT=1 the endpoint is inert (404).

    The autouse fixture sees the ``no_sse_gate`` mark and does NOT arm
    the env var for this boot — proving the gate actually gates (and
    that production binaries expose nothing).
    """
    r = ui_harness.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={"session_id": "sess_x", "type": "chunk", "content": "hi"},
        expect=404,
    )
    assert "error" in r.json()


def test_sse_burst_keeps_view_stuck_to_bottom(page, ui_harness: UIHarness) -> None:
    """THE bug contract: after an SSE chunk burst, the view is at the bottom.

    Pre-fix behaviour (both bugs): the first chunk grows the content
    under a stationary viewport → isAtBottom flips false → re-stick
    skips → gap grows with every chunk → final distanceFromBottom is
    hundreds/thousands of px.

    Post-fix: the stick stays engaged (stationary viewport + growing
    content ≠ user scroll), every contentShift re-sticks, and the final
    distanceFromBottom stays under STICK_GAP_THRESHOLD_PX.
    """
    h = ui_harness
    session_id = "sess_sse_stick_001"
    _seed_session_with_history(h, session_id, n_messages=20)

    # Realistic desktop viewport — the default 1280x720 gives the chat
    # scroller only ~238px of height in this layout, which makes the
    # seeded history fit without scrolling.
    page.set_viewport_size({"width": 1440, "height": 900})

    # Open the chatview. The initial load lands at the bottom
    # (scrollToBottom(true, 'initial-load')).
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="domcontentloaded",
        timeout=30000,
    )
    _wait_for_streaming_text(page, "Message 19 paragraph one")

    # Wait for the initial layout + measurement passes to settle
    # (measureItems debounces at 50ms; give it a few hundred ms).
    page.wait_for_timeout(800)

    geo_before = _scroller_geometry(page)
    assert geo_before is not None, "virtual-scroller element not found"
    # Sanity: the seeded history must overflow the viewport (scrollable),
    # otherwise the test isn't exercising the stick path at all.
    assert geo_before["scrollHeight"] > geo_before["clientHeight"], (
        f"seeded history did not overflow the viewport: {geo_before}"
    )
    # Sanity: initial load landed at (or near) the bottom.
    assert geo_before["distanceFromBottom"] < STICK_GAP_THRESHOLD_PX, (
        f"initial load did not land at the bottom: {geo_before}"
    )

    # Fire the SSE burst: N content chunks (streaming assistant message
    # grows) followed by one `full` event (canonical row replaces the
    # streaming row). This is the exact event sequence a real agent
    # turn produces.
    for i in range(1, CHUNK_COUNT + 1):
        _emit_llm_event(
            h,
            session_id,
            {"type": "chunk", "index": i, "content": CHUNK_TEXT_TEMPLATE.format(i=i)},
        )
        # Small gap between chunks so each one is a separate render
        # frame — mirrors real chunk cadence (~50-100ms apart).
        page.wait_for_timeout(60)

    _emit_llm_event(
        h,
        session_id,
        {
            "type": "full",
            "index": CHUNK_COUNT + 1,
            # The canonical row is MUCH taller than the streamed chunks
            # were (real assistant turns often render markdown/code
            # blocks far taller than the streamed prefix). This forces
            # the full-event remount + measurement pass to swing the
            # sizer hard — the exact geometry that exposed the bug in
            # the user's log (scrollHeight 11732→11390 while msgs
            # 268→269).
            "content": "Final assistant answer after streaming.\n\n"
                       + ("Detailed paragraph with enough text to make this "
                          "canonical message much taller than the streamed "
                          "prefix was. " * 20),
            "role": "assistant",
            "finish_reason": "stop",
        },
    )

    # The final message must be rendered.
    _wait_for_streaming_text(page, "Final assistant answer after streaming.")

    # Give the full-event remount + measurement passes time to settle
    # (measureItems debounces at 50ms; the sizer can swing for a few
    # hundred ms after a big remount).
    page.wait_for_timeout(1500)

    geo_after = _scroller_geometry(page)
    assert geo_after is not None

    # THE assertion: no large blank gap below the last message.
    assert geo_after["distanceFromBottom"] < STICK_GAP_THRESHOLD_PX, (
        "SSE burst left the view detached from the bottom — the "
        f"auto-stick disengaged mid-stream. geometry={geo_after} "
        f"threshold={STICK_GAP_THRESHOLD_PX}px"
    )


def test_user_scroll_up_during_stream_is_respected(page, ui_harness: UIHarness) -> None:
    """A REAL upward scroll still disengages the stick (UX contract).

    The fix keeps the stick engaged for content-growth-under-a-stationary
    viewport, but a genuine user scroll-up (deltaTop < 0) must still
    stop the auto-stick — otherwise the user can't read history during
    a stream.
    """
    h = ui_harness
    session_id = "sess_sse_stick_002"
    _seed_session_with_history(h, session_id, n_messages=20)

    page.set_viewport_size({"width": 1440, "height": 900})
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="domcontentloaded",
        timeout=30000,
    )
    _wait_for_streaming_text(page, "Message 19 paragraph one")
    page.wait_for_timeout(800)

    # Real user scroll: drag the CHAT scroller (the taller visible one —
    # see _scroller_geometry) up 600px.
    page.evaluate(
        """() => {
            const all = [...document.querySelectorAll('.virtual-scroller')]
                .filter(el => el.offsetParent !== null)
                .sort((a, b) => b.clientHeight - a.clientHeight);
            const el = all[0];
            el.scrollTop = Math.max(0, el.scrollTop - 600);
            el.dispatchEvent(new Event('scroll'));
        }"""
    )
    page.wait_for_timeout(300)
    geo_scrolled = _scroller_geometry(page)
    assert geo_scrolled["distanceFromBottom"] > 400, (
        f"scroll-up did not take effect: {geo_scrolled}"
    )

    # Fire chunks — the view must NOT be yanked back to the bottom.
    for i in range(1, 6):
        _emit_llm_event(
            h,
            session_id,
            {"type": "chunk", "index": i, "content": CHUNK_TEXT_TEMPLATE.format(i=i)},
        )
        page.wait_for_timeout(60)

    page.wait_for_timeout(800)
    geo_after = _scroller_geometry(page)

    # The user's reading position is preserved: they are still ~600px
    # (± the content growth above them) from the bottom — definitely
    # NOT stuck back at 0.
    assert geo_after["distanceFromBottom"] > 400, (
        f"user scroll-up was overridden by the auto-stick: {geo_after}"
    )


# 2026-09-02 (task_1787852314252_4): test_loadmore_during_stream_no_gap_on_return_to_bottom
# was DELETED. It triggered a 100% CPU / freeze in the chromium tab when run
# under functional-test-ui, hanging the job for hours (CI screenshot showed
# 2h 3m 18s elapsed before the runner was killed). Root cause: PR #355
# (2026-08-26, real-bottom stick + render-level sizer clamp) added a reactive
# `sizerHeight` computed + `onContentRef` ref-callback to VirtualScroller.vue
# whose loop (chunk → content grows → onContentRef → renderTick bumps →
# sizerHeight shrinks → scrollHeight shrinks → browser clamps scrollTop →
# scroll event → visibleRange recomputes → content div offsetHeight changes
# → onContentRef again) never converges while content is actively streaming.
#
# Bug C (task_1787638309623_3) is still real, but the unit spec T6a-T6d in
# ChatView.__tests__/ covers the wasAtBottom snapshot + post-preserve
# re-stick wiring. Functional coverage is paused until the PR #355 loop is
# fixed. Tracked on kanban as the follow-up card created alongside this
# deletion.

