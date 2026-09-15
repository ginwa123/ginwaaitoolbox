"""Functional UI test: chatview pill rail + realtime active pill.

Covers the user-reported bugs on the realtime-slider task
(task_1789495662604_4, PR #520):

    1. "the pill still not active yet?" — ``activePillGroupIndex`` was
       only assigned on click-jump, so scrolling never lit any pill.
       Fixed: recomputed every ``handleVirtualScroll`` from the
       scroller's ``effectiveRange``.

    2. "i am on last messages but why the pil active on index 0?" —
       the anchor used the rendered window TOP, but the scroller
       renders ~30 buffer items above the viewport, so short chats
       (or near-bottom positions) render from index 0 and pill 0 lit
       at the bottom. Fixed: anchor to the buffer-compensated
       viewport bottom (``estimateViewportEnd``) — the latest user
       turn at/above the viewport bottom lights up.

    3. bg-command outputs (``role=user`` on the wire, tool card in
       pixels) got rail pills. Fixed: ``isPillGroup`` skips bg-only
       groups.

Scenarios (real browser, real backend, seeded DB — no LLM needed):

    - bottom of chat  → LAST pill carries ``user-pill--active``.
    - scrolled to top → FIRST pill carries ``user-pill--active``.
    - bg output seeded among user turns → pill count == real user
      turns only (bg output gets no pill).

Run:
    NALAR_BIN=./zig-out/bin/nalarcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_pill_rail_ui_test.py -v
"""

from __future__ import annotations

from pathlib import Path

from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _seed_chat(
    h: UIHarness,
    session_id: str,
    n_pairs: int = 8,
    with_bg_output: bool = False,
) -> int:
    """Seed alternating user/assistant turns; return the real user count.

    Bodies are multi-paragraph so the transcript overflows the ~900px
    chat viewport and the scroller is actually scrollable (otherwise
    the rail/pill logic has nothing to track).

    ``with_bg_output``: inserts a ``<background_command>`` user-role
    message mid-history (the stale-background-process cron wire
    shape). It renders as a tool card, NOT a blue bubble — so it must
    NOT produce a rail pill. Returns the count of REAL user turns.
    """
    seed = DbSeed(_seed_db_path(h))
    total = n_pairs * 2 + (1 if with_bg_output else 0)
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Pill rail test")
        stamps = DbSeed.baseline_timestamps(count=total, interval_seconds=30)
        idx = 0
        real_users = 0
        for pair in range(n_pairs):
            user_body = (
                f"User question {pair} paragraph one.\n\n"
                f"User question {pair} paragraph two with enough filler text "
                f"to give the bubble real height in the virtual scroller. "
                f"Lorem ipsum dolor sit amet, consectetur adipiscing elit, "
                f"sed do eiusmod tempor incididunt ut labore et dolore.\n\n"
                f"User question {pair} paragraph three closing out the turn."
            )
            seed.seed_user_message(conn, session_id, user_body, created_at=stamps[idx])
            idx += 1
            real_users += 1
            if with_bg_output and pair == n_pairs // 2:
                bg_body = (
                    "<background_command>\n"
                    "<pid>4242</pid>\n"
                    "<command>sleep 30</command>\n"
                    "<stdout>background job finished ok</stdout>\n"
                    "<truncated>false</truncated>\n"
                    "</background_command>"
                )
                seed.seed_user_message(conn, session_id, bg_body, created_at=stamps[idx])
                idx += 1
            asst_body = (
                f"Assistant answer {pair} paragraph one.\n\n"
                f"Assistant answer {pair} paragraph two with enough filler "
                f"text to give the paragraph real height in the layout. "
                f"Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n\n"
                f"Assistant answer {pair} paragraph three closing out."
            )
            seed.seed_assistant_message(conn, session_id, asst_body, created_at=stamps[idx])
            idx += 1
    return real_users


def _open_chat(page, h: UIHarness, session_id: str, last_marker: str) -> None:
    page.set_viewport_size({"width": 1440, "height": 900})
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="domcontentloaded",
        timeout=30000,
    )
    page.locator(f"text={last_marker}").first.wait_for(timeout=15000, state="attached")
    # Let the initial layout + measurement passes settle (measureItems
    # debounces at 50ms; the pill highlight follows the first scroll
    # event after mount).
    page.wait_for_timeout(1000)


def _chat_scroller_js() -> str:
    """JS: return the CHAT scroller (taller visible .virtual-scroller)."""
    return (
        "[...document.querySelectorAll('.virtual-scroller')]"
        ".filter(el => el.offsetParent !== null)"
        ".sort((a, b) => b.clientHeight - a.clientHeight)[0]"
    )


def _pill_active_flags(page) -> list[bool]:
    """Per-pill active flags in rail order."""
    return page.evaluate(
        "() => [...document.querySelectorAll('[data-testid=\"user-pill\"]')]"
        ".map(el => el.classList.contains('user-pill--active'))"
    )


def _pill_count(page) -> int:
    return page.evaluate("() => document.querySelectorAll('[data-testid=\"user-pill\"]').length")


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_bottom_of_chat_lights_last_pill(page, ui_harness: UIHarness) -> None:
    """THE reported bug: at the last messages, the LAST pill is active.

    Pre-fix behaviour: the anchor used the rendered window top, which
    is index 0 for short/near-bottom chats (overscan buffer), so pill
    index 0 lit while the user read the last messages.
    """
    h = ui_harness
    session_id = "sess_pill_bottom_001"
    real_users = _seed_chat(h, session_id, n_pairs=8)
    assert real_users >= 2  # rail only renders with 2+ pills

    _open_chat(page, h, session_id, "User question 7 paragraph one")

    flags = _pill_active_flags(page)
    assert len(flags) == real_users, f"expected one pill per user turn: {flags}"
    assert flags[-1] is True, f"last pill must be active at the bottom: {flags}"
    assert flags[0] is False, f"first pill must NOT be active at the bottom: {flags}"


def test_scroll_to_top_lights_first_pill(page, ui_harness: UIHarness) -> None:
    """Scrolling to the top moves the highlight to the FIRST pill."""
    h = ui_harness
    session_id = "sess_pill_top_001"
    real_users = _seed_chat(h, session_id, n_pairs=8)

    _open_chat(page, h, session_id, "User question 7 paragraph one")

    # Sanity: starts at the bottom with the last pill lit.
    assert _pill_active_flags(page)[-1] is True

    # Real user scroll to the very top (native scroll event so the
    # VirtualScroller emit path runs exactly as in production).
    page.evaluate(
        f"() => {{ const el = {_chat_scroller_js()};"
        " el.scrollTop = 0; el.dispatchEvent(new Event('scroll')); }"
    )
    page.wait_for_timeout(800)

    flags = _pill_active_flags(page)
    assert len(flags) == real_users
    assert flags[0] is True, f"first pill must be active at the top: {flags}"
    assert flags[-1] is False, f"last pill must NOT be active at the top: {flags}"


def test_bg_command_output_gets_no_pill(page, ui_harness: UIHarness) -> None:
    """A bg-command user-role message produces NO rail pill."""
    h = ui_harness
    session_id = "sess_pill_bg_001"
    real_users = _seed_chat(h, session_id, n_pairs=6, with_bg_output=True)

    _open_chat(page, h, session_id, "User question 5 paragraph one")

    count = _pill_count(page)
    assert count == real_users, (
        f"bg-command output must not produce a pill: got {count} pills "
        f"for {real_users} real user turns"
    )
    # And the bottom highlight still lands on the last REAL user turn.
    flags = _pill_active_flags(page)
    assert flags[-1] is True, f"last real pill must be active: {flags}"
