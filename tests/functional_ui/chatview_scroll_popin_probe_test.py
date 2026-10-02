"""Probe: small scroll steps must not open blank holes or teleport content.

User report (after #597 + #598 merged): "when i bit scroll suddenly some
content showup" — a small scroll makes content suddenly pop into view.

This test seeds a long chat with MIXED item heights (tall paragraphs +
short one-liners, like a real agentic session), jumps mid-list, then
walks DOWN in 60px steps — the "bit scroll" gesture. After each step it
lets the scroller settle (debounce + measure + rAF) and samples geometry.

Two failure signatures, one per mechanism:
  * HOLE — the viewport is not covered by the content box (blank sizer
    region where messages should be; the next scroll pops content in).
  * JUMP — topSpacer moves disproportionately to scrollTop (the window
    teleports instead of tracking 1:1).

Run (frontend is served from THIS worktree; backend binary may come
from anywhere since only frontend code is under test):
    NALAR_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/nalarcore-linux-x86_64 \\
        /tmp/nalar-ui-venv/bin/python -m pytest \\
        tests/functional_ui/chatview_scroll_popin_probe_test.py -v
"""

from __future__ import annotations

from pathlib import Path

import pytest

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
from db_seed import DbSeed


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots."""
    monkeypatch.setenv("NALAR_TEST_SSE_EMIT", "1")

TALL_BODY = (
    "Message {i} paragraph one.\n\n"
    "Message {i} paragraph two with longer text to give the bubble real "
    "height in the virtual scroller. Lorem ipsum dolor sit amet, consectetur "
    "adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore "
    "magna aliqua.\n\n"
    "Message {i} paragraph three with even more filler so each bubble "
    "measures a few hundred pixels tall in real layout."
)
SHORT_BODIES = ("ok", "go on", "Done.", "On it.", "thanks", "noted")


def _seed_db_path(h) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _seed_mixed_session(h, workspace_id: str, session_id: str, count: int = 700) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"Popin probe {count}")
        bind_session_workspace(conn, workspace_id, session_id)
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            if i % 4 < 2:
                body = TALL_BODY.format(i=i)
            else:
                body = SHORT_BODIES[i % len(SHORT_BODIES)]
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


_GEOM_SCRIPT = r"""
() => {
  const all = [...document.querySelectorAll('.virtual-scroller')]
    .filter((el) => el.offsetParent !== null)
    .map((el) => ({ el, ch: el.clientHeight }))
    .sort((a, b) => b.ch - a.ch);
  if (!all.length) return null;
  const el = all[0].el;
  const sizer = el.querySelector('.virtual-scroller-sizer');
  const content = el.querySelector('.virtual-scroller-content');
  const m = /translate3d\(0px,\s*([-\d.]+)px/.exec(content.style.transform || '');
  const kids = [...content.children];
  const rows = kids.map((k) => [
    parseInt(k.getAttribute('data-vs-index'), 10),
    k.offsetHeight,
  ]);
  return {
    scrollTop: el.scrollTop,
    scrollHeight: el.scrollHeight,
    clientHeight: el.clientHeight,
    sizerH: parseFloat(sizer.style.height) || 0,
    topSpacer: m ? parseFloat(m[1]) : null,
    contentH: content.offsetHeight,
    firstIdx: kids.length ? parseInt(kids[0].getAttribute('data-vs-index'), 10) : null,
    lastIdx: kids.length
      ? parseInt(kids[kids.length - 1].getAttribute('data-vs-index'), 10)
      : null,
    rendered: kids.length,
    rows,
  };
}
"""

_STEP_PX = 60
_STEPS = 12
_COVER_TOL_PX = 120
_TRACK_TOL_PX = 60


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "chat scroller not found"
    assert g["topSpacer"] is not None, "content transform missing"
    return g


def _track_violation(prev: dict, cur: dict, n: int) -> str | None:
    """The JUMP check: did the top spacer agree with the rows that left?

    It used to be ``abs(d_spacer - d_scroll) > _TRACK_TOL_PX``, which is not a
    sound invariant for a row-based scroller. The spacer only ever moves in
    whole-row steps while the scroll moves continuously, so that difference is
    small only by luck. With ``_STEP_PX`` pinned at 60 the old check reduced to
    "d_spacer <= 310", and this fixture's adjacent TALL rows release ~322px in
    one 60px step, so no implementation could satisfy it — it has failed on
    every run since it was added (e9d65b76).

    The real pop-in signature is the spacer disagreeing with the rows it
    actually released, so measure those heights and require the two to agree.
    On the plain small-scroll case the delta is 0 on every step.

    Only applied when the window moves DOWN (rows leaving it are always ones it
    has already rendered and measured). Scrolling UP into the unmeasured head
    moves the spacer by the model's ESTIMATES for rows that were never
    rendered, so there is nothing on the DOM to compare against — the HOLE
    checks are what guard that direction.
    """
    d_spacer = cur["topSpacer"] - prev["topSpacer"]
    prev_first, cur_first = prev["firstIdx"], cur["firstIdx"]
    if prev_first is None or cur_first is None or cur_first <= prev_first:
        return None
    released = sum(
        h for idx, h in (prev.get("rows") or []) if prev_first <= idx < cur_first
    )
    if abs(d_spacer - released) <= _TRACK_TOL_PX:
        return None
    return (
        f"step {n}: JUMP "
        f"(d_spacer={d_spacer:.0f} released={released:.0f} "
        f"win {prev_first}->{cur_first})"
    )


def test_small_scrolls_neither_hole_nor_jump(ui_harness, page) -> None:
    h = ui_harness
    session_id = "sess-scroll-popin-probe"
    workspace_id = create_workspace(h)
    _seed_mixed_session(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_function(
        "() => [...document.querySelectorAll('.virtual-scroller')]"
        ".some((el) => el.offsetParent !== null)",
        timeout=20000,
    )
    page.wait_for_timeout(2000)  # initial load + measure passes settle

    # Jump mid-list and let the fresh window measure + converge.
    start_top = page.evaluate(
        "() => { const g = (" + _GEOM_SCRIPT + ")(); return g.scrollHeight * 0.55; }"
    )
    page.evaluate(f"() => {{ const all=[...document.querySelectorAll('.virtual-scroller')].filter((el)=>el.offsetParent!==null).sort((a,b)=>b.clientHeight-a.clientHeight); all[0].scrollTop = {start_top}; }}")
    page.wait_for_timeout(1500)

    samples = [_geom(page)]
    for _ in range(_STEPS):
        page.evaluate(
            f"() => {{ const all=[...document.querySelectorAll('.virtual-scroller')].filter((el)=>el.offsetParent!==null).sort((a,b)=>b.clientHeight-a.clientHeight); all[0].scrollTop = all[0].scrollTop + {_STEP_PX}; }}"
        )
        page.wait_for_timeout(450)  # onScroll debounce + measure + rAF settle
        samples.append(_geom(page))

    violations: list[str] = []
    for n in range(1, len(samples)):
        prev, cur = samples[n - 1], samples[n]
        s, v = cur["scrollTop"], cur["clientHeight"]
        box_top, box_bot = cur["topSpacer"], cur["topSpacer"] + cur["contentH"]
        at_top_edge = s <= 8
        at_bottom_edge = s + v >= cur["sizerH"] - 8
        # HOLE: viewport sticks out of the content box into sizer-only space.
        if not at_top_edge and box_top > s + _COVER_TOL_PX:
            violations.append(
                f"step {n}: HOLE above content "
                f"(scrollTop={s:.0f} box_top={box_top:.0f} "
                f"win=[{cur['firstIdx']},{cur['lastIdx']}] rendered={cur['rendered']})"
            )
        if not at_bottom_edge and box_bot < s + v - _COVER_TOL_PX:
            violations.append(
                f"step {n}: HOLE below content "
                f"(viewport_bot={s + v:.0f} box_bot={box_bot:.0f} sizer={cur['sizerH']:.0f} "
                f"win=[{cur['firstIdx']},{cur['lastIdx']}] rendered={cur['rendered']})"
            )
        # JUMP: the spacer must agree with the rows that left the window.
        # See _track_violation for why comparing it against the scroll delta is
        # unsound for a row-based scroller.
        violation = _track_violation(prev, cur, n)
        if violation is not None:
            violations.append(violation)

    assert not violations, "pop-in signatures on small scrolls:\n" + "\n".join(violations)


_PICK_TALLEST = (
    "[...document.querySelectorAll('.virtual-scroller')]"
    ".filter((el)=>el.offsetParent!==null)"
    ".sort((a,b)=>b.clientHeight-a.clientHeight)[0]"
)


def _scroll_by(page, px: int) -> None:
    page.evaluate(f"() => {{ {_PICK_TALLEST}.scrollTop = {_PICK_TALLEST}.scrollTop + ({px}); }}")


def _jump_to_fraction(page, frac: float) -> None:
    page.evaluate(
        f"() => {{ const el = {_PICK_TALLEST}; el.scrollTop = el.scrollHeight * ({frac}); }}"
    )


def _emit_chunk(h, session_id: str, text: str) -> None:
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={"type": "chunk", "content": text, "session_id": session_id},
        expect=200,
    )


def _audit(samples: list[dict]) -> list[str]:
    """Same hole/jump signatures as the idle test, over any sample series."""
    violations: list[str] = []
    for n in range(1, len(samples)):
        prev, cur = samples[n - 1], samples[n]
        s, v = cur["scrollTop"], cur["clientHeight"]
        box_top, box_bot = cur["topSpacer"], cur["topSpacer"] + cur["contentH"]
        at_top_edge = s <= 8
        at_bottom_edge = s + v >= cur["sizerH"] - 8
        if not at_top_edge and box_top > s + _COVER_TOL_PX:
            violations.append(
                f"step {n}: HOLE above content "
                f"(scrollTop={s:.0f} box_top={box_top:.0f} "
                f"win=[{cur['firstIdx']},{cur['lastIdx']}] rendered={cur['rendered']})"
            )
        if not at_bottom_edge and box_bot < s + v - _COVER_TOL_PX:
            violations.append(
                f"step {n}: HOLE below content "
                f"(viewport_bot={s + v:.0f} box_bot={box_bot:.0f} sizer={cur['sizerH']:.0f} "
                f"win=[{cur['firstIdx']},{cur['lastIdx']}] rendered={cur['rendered']})"
            )
        d_scroll = s - prev["scrollTop"]
        d_spacer = cur["topSpacer"] - prev["topSpacer"]
        violation = _track_violation(prev, cur, n)
        if violation is not None:
            violations.append(violation)
    return violations


def test_small_scrolls_while_streaming_neither_hole_nor_jump(ui_harness, page) -> None:
    """Streaming tail + mid-list small scrolls (the user's exact setup).

    The user's screenshots show an ACTIVE stream (stop button, token
    counter) while scrolled mid-list. Every chunk recomputes
    messageGroups (all-new group objects) and re-renders the window;
    the question is whether that churn moves the mid-list viewport.
    """
    h = ui_harness
    session_id = "sess-scroll-popin-streaming"
    workspace_id = create_workspace(h)
    _seed_mixed_session(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_function(
        "() => [...document.querySelectorAll('.virtual-scroller')]"
        ".some((el) => el.offsetParent !== null)",
        timeout=20000,
    )
    page.wait_for_timeout(2000)

    _jump_to_fraction(page, 0.55)
    page.wait_for_timeout(1500)

    samples = [_geom(page)]

    # Phase 1: stream WITHOUT scrolling — the viewport must not move.
    for k in range(3):
        _emit_chunk(h, session_id, f" Streaming part {k} with enough words to grow the tail row. " * 4)
        page.wait_for_timeout(500)
        samples.append(_geom(page))

    # Phase 2: stream AND scroll — the reported gesture.
    for k in range(3, 11):
        _emit_chunk(h, session_id, f" Streaming part {k} with enough words to grow the tail row. " * 4)
        _scroll_by(page, _STEP_PX)
        page.wait_for_timeout(450)
        samples.append(_geom(page))

    violations = _audit(samples)
    assert not violations, "pop-in signatures while streaming:\n" + "\n".join(violations)


def test_small_scrolls_up_into_unmeasured_head(ui_harness, page) -> None:
    """Upward small scrolls into never-measured head territory.

    Initial load sticks to the BOTTOM, so the tail is measured and the
    head keeps median estimates. Scrolling UP (the user's screenshots
    show the window top moving 641 -> 640) enters virgin items every
    step: each fresh measure pass corrects estimates, and the question
    is whether those corrections teleport the viewport.
    """
    h = ui_harness
    session_id = "sess-scroll-popin-up"
    workspace_id = create_workspace(h)
    _seed_mixed_session(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_function(
        "() => [...document.querySelectorAll('.virtual-scroller')]"
        ".some((el) => el.offsetParent !== null)",
        timeout=20000,
    )
    page.wait_for_timeout(2000)

    _jump_to_fraction(page, 0.55)
    page.wait_for_timeout(1500)

    samples = [_geom(page)]
    # ~1 wheel tick per step, 25 steps ≈ 2500px — walks out of the
    # measured window into virgin head territory.
    for _ in range(25):
        _scroll_by(page, -100)
        page.wait_for_timeout(450)
        samples.append(_geom(page))

    violations = _audit(samples)
    assert not violations, "pop-in signatures scrolling up:\n" + "\n".join(violations)
