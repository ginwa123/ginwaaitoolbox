"""Functional UI test: sending a message takes the transcript to the bottom.

The report, verbatim:

    "after send or quueue message it should automatically go to bottom"

Why a real browser is the only place this can be proven
    The whole auto-stick is gated on one boolean, `isAtBottom`, and a reader
    who has scrolled up to read history is `false` by definition. A send has to
    RE-ARM that boolean, and the pre-fix code did not: it called
    `scrollToBottom(true, …)`, which writes `container.scrollTop` and leaves the
    flag to whatever the browser reports afterwards. jsdom has no layout and no
    `scroll` event on `scrollTop` writes, so a unit test can neither reproduce
    that nor observe the consequence. Here the scroll is real, the geometry is
    real, and the turn the server echoes back is real.

The hard gate
    The assertion is made against the bottom measured AFTER the sent turn has
    landed, not the bottom that existed when the button was pressed. A pin that
    aims at the pre-send bottom passes a "did you scroll down?" check and still
    leaves the turn the reader just asked for one screen below the fold — which
    is the reported symptom.

    The observable for the flag itself is the floating jump-to-bottom arrow
    (`.chat-scroll-to-bottom`), which ChatView renders under
    `v-if="!isAtBottom && messageGroups.length > 0"`. Arrow gone == the stick is
    armed. That is a stronger statement than a scroll position: it is the state
    the follow gates read.

    Also asserted: the turn that was sent is actually ON SCREEN (its row is
    inside the viewport), not merely that the scroller moved.

WHICH "bottom" — the flake this suite used to have (2026-10-10)
    This file asserted `scrollTop >= scrollHeight - clientHeight - 24` and was
    intermittently red on the slower macOS CI runner while green on Linux. The
    app was never wrong; the RULER was.

    `VirtualScroller`'s sizer is a height MODEL. When it overshoots the real
    content, `scrollToBottom` deliberately parks the reader at the REAL content
    bottom (`topSpacer + content.offsetHeight - clientHeight`) rather than the
    DOM max, so the reader never sits in a blank region — the blank-viewport
    fix. The DOM max is therefore a position the reader is never AT, by up to
    `maxTailGap` (100px). Measured in a real browser at CPU throttle 12 (which
    reproduces the macOS runner):

        scrollTop = 24349   domEdge = 24405   appTarget = 24349
        overshoot = 56px    override engaged = True
        last row fully visible = True    arrow gone = True
        scrollTop === appTarget = True   old assertion passes = False

    The app was parked EXACTLY where it means to park, the last row was fully
    visible, and `isAtBottom` was true. The 24px tolerance was simply smaller
    than the 56px overshoot — and the overshoot size depends on how far the
    height model has converged, which is timing-dependent. Fast runner: model
    converged, gap ~ 0, pass. Slow runner: gap ~ 56px, fail. That is the flake.

    The fix is to measure with the app's own ruler: `bottomScrollTop()`, the
    same number `scrollToBottom` writes and the same one `isAtBottom` is
    measured against, read off the exposed Vue instance. The sibling
    `chatview_at_bottom_stick_ui_test.py` already does this. A `rulerGap <=
    maxTailGap + slack` bound keeps the assertion honest — it still fails if
    the app parks the reader anywhere the tail-gap cap does not allow.

What this does NOT prove
    HONEST SCOPE, read this before trusting a green run as "the bug is dead".

    1. Both tests here PASS on the pre-fix build. In a real browser the
       pre-fix `scrollToBottom(true, …)` does move the scroller, and the native
       `scroll` event that follows does flip `isAtBottom`. The failure the fix
       removes is the one this harness cannot stage: a scroll write that is a
       no-op (so no event, so no flag), and `isPreservingScroll` swallowing the
       pin during a lazy-load prepend with nothing scheduled to retry it. Both
       are real; neither is reachable from Playwright against a live server.

    2. The QUEUE half of the report is not covered here. Queueing needs a live
       worker — the server parks a turn in `session_queue_messages` only when
       one is already running — and the harness's stub LLM profile points at a
       dead port, so a run dies instantly and every turn ends up RUNNING
       instead of QUEUED. Holding a worker open needs a live LLM endpoint, and
       pabrik reads its profile at boot, so it cannot be swapped in from a
       fixture. The queue path is covered instead by
       `src/apps/desktop/src/__tests__/ChatView.sendScrollsToBottom.spec.ts`
       (which pins the `queue_queued` branch to the same re-arm the send uses)
       and by `ChatScrollPolicyTest.aQueuedTurnFollowsTheTranscriptWhenTheWorkerDrainsIt`
       on Android.

    What IS proved here: the behaviour the user reported, end to end, in a real
    browser against a real backend — send from up in the history, and the turn
    lands where they can see it.

Run (the frontend is served from THIS worktree — that is the code under test;
the backend binary can come from anywhere, since no backend code changed):

    zig build
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_send_scrolls_to_bottom_ui_test.py -v

Environment notes found the hard way here, both pre-existing and both the
reason `chatview_ui_test.py` is red on a clean tree:

  * The chat only opens at `/app/<workspace_id>/chat/<session_id>`. The
    `/app?view=chat&session=…` shape used by `chatview_ui_test.py` needs a
    workspace already in context and otherwise lands on the home screen, where
    every geometry assertion would be about the wrong scroller.
  * `page.add_init_script` is a no-op in this Playwright build, so request
    interception has to be installed with `page.evaluate` after navigation.

Ports: the UI harness reserves (5173, 8081) and picks the backend port from
[20000, 32000]. NEVER 8081 — a dev server runs there.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from db_seed import DbSeed

#: Enough turns that the transcript is comfortably taller than the 800px
#: viewport, so "scrolled into history" is a real position and not a rounding
#: error. Virtualized, so the cost is bounded by the scroller's window.
TURN_COUNT = 400

#: How far up to park the reader before sending. Anywhere in the middle will
#: do; the point is only that `isAtBottom` is false.
HISTORY_FRACTION = 0.35

#: Slack for "parked at the bottom", in CSS px. The scroller's sizer is a height
#: MODEL and its real-bottom override can land a few px short of the model
#: bottom; this is not a layout-precision test.
BOTTOM_TOL_PX = 24

#: Contract under test — the DOM's max scrollTop may sit at most this far above
#: the real content bottom (mirrors VirtualScroller's `maxTailGap` prop). The
#: app deliberately parks the reader at the REAL bottom when the height model
#: overshoots by more than `HYSTERESIS_PX`, so the two rulers disagree by up to
#: this much on purpose. Asserting against the DOM ruler instead measures that
#: deliberate gap — which is how this suite went flaky (see the module docstring).
MAX_TAIL_GAP_PX = 100

#: Index fed to the dev SSE emitter. It becomes the row's id (`test-{index}`),
#: so it has to be distinct from anything the seeded rows or a real run use.
ECHO_INDEX = 9001


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots."""
    monkeypatch.setenv("PABRIK_TEST_SSE_EMIT", "1")


# ─── The scroller ────────────────────────────────────────────────────────────

# Two `.virtual-scroller` elements exist (the sidebar chat list and the chat
# transcript). Scope to the transcript's own wrapper, which is what
# chatview_tail_gap_probe_test.py does, and fall back to the tallest visible
# scroller so a template rename is a readable failure rather than a null.
_CHAT_SCROLLER = (
    "(() => {"
    "  const wrap = document.querySelector('.messages-scroll-hide-native');"
    "  const el = wrap ? wrap.querySelector('.virtual-scroller') : null;"
    "  if (el) return el;"
    "  return [...document.querySelectorAll('.virtual-scroller')]"
    "    .filter((e) => e.offsetParent !== null)"
    "    .sort((a, b) => b.clientHeight - a.clientHeight)[0] || null;"
    "})()"
)

# `.chat-scroll-to-bottom` is rendered only while `isAtBottom` is false, so its
# presence IS the flag — read in the same evaluate as the geometry so the two
# can never disagree about which frame they describe.
#
# `appBottom` is the app's OWN notion of the bottom, read off the value it
# exposes for exactly this purpose (`VirtualScroller.bottomScrollTop` — the same
# number `scrollToBottom` writes and the same one `isAtBottom` is measured
# against). Re-deriving it here would be re-implementing the predicate under
# test, and getting it wrong is exactly the bug this file exists to catch.
#
# Why not `scrollHeight - clientHeight`: the sizer is a height MODEL, and when
# it overshoots the real content the app deliberately parks the reader at the
# REAL bottom instead (the blank-viewport fix). The DOM max is then a position
# the reader is never AT — by up to `maxTailGap` (100px). Asserting against it
# measures that deliberate gap, and the gap's size depends on how far the model
# has converged, which is timing-dependent. That is the flake this file used to
# have: on a fast runner the model had converged (gap ~ 0, pass); on a slow one
# it had not (gap ~ 56px > the 24px tolerance, fail) — with the app parked
# exactly where it means to park and the last row fully visible either way.
#
# Vue 3 attaches `__vueParentComponent` to every element, and the scroller's
# root element is that component's own root, so `exposed` is the real instance.
# Falls back to the DOM edge if the internal handle is unreachable (a
# production build that stripped it, a future template change), so a rename
# degrades to the weaker assertion instead of a null.
_GEOM_SCRIPT = (
    r"""
() => {
  const el = """ + _CHAT_SCROLLER + r""";
  if (!el) return null;
  const domEdge = el.scrollHeight - el.clientHeight;
  let appBottom = domEdge;
  let appRulerSource = 'dom-fallback';
  try {
    const inst = el.__vueParentComponent;
    const exposed = inst && inst.exposed;
    if (exposed && typeof exposed.bottomScrollTop === 'function') {
      const v = exposed.bottomScrollTop();
      if (typeof v === 'number' && isFinite(v)) {
        appBottom = v;
        appRulerSource = 'exposed';
      }
    }
  } catch (e) {
    appBottom = domEdge;
  }
  return {
    scrollTop: el.scrollTop,
    scrollHeight: el.scrollHeight,
    clientHeight: el.clientHeight,
    maxScrollTop: domEdge,
    appBottom: appBottom,
    appRulerSource: appRulerSource,
    // How far the two rulers disagree — the quantity the app creates on purpose.
    rulerGap: domEdge - appBottom,
    arrow: !!document.querySelector('.chat-scroll-to-bottom'),
  };
}
"""
)


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "chat message scroller not found"
    return g


def _open_chat(page, h, session_id: str) -> None:
    # Route shape note. `/app?view=chat&session=…` only opens the transcript
    # when the app already has a workspace in context; with none it silently
    # lands on the workspace-selection home screen, and every assertion after
    # this point would be about the wrong scroller. The workspace-path shape
    # carries its own context and is what chatview_tail_gap_probe_test.py uses.
    workspace_id = h.http(
        "POST",
        "/api/workspaces",
        json_body={"name": f"send-scroll-{session_id}"},
        expect=(200, 201),
    ).json()["id"]
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=30000,
    )
    page.wait_for_function(
        f"() => !!({_CHAT_SCROLLER}) && "
        f"({_CHAT_SCROLLER}).scrollHeight > ({_CHAT_SCROLLER}).clientHeight",
        timeout=30000,
    )
    # Let the initial-load branch (restore-or-bottom) and the scroller's
    # measurement pass settle before anything is measured.
    page.wait_for_timeout(1200)


def _park_in_history(page) -> dict:
    """Scroll the reader up into history and prove the stick disengaged."""
    page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; el.scrollTop = el.scrollHeight * "
        + str(HISTORY_FRACTION)
        + "; }"
    )
    # The arrow appearing IS the proof: ChatView renders it only when
    # `isAtBottom` is false, so waiting for it is waiting for the flag to flip
    # rather than for a scroll position to look right.
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')",
        timeout=10000,
    )
    page.wait_for_timeout(400)
    g = _geom(page)
    assert g["arrow"], "precondition failed: the reader is not treated as scrolled up"
    assert g["scrollTop"] < g["appBottom"] - BOTTOM_TOL_PX, (
        f"precondition failed: the reader is already at the bottom: {g}"
    )
    return g


def _send(page, text: str) -> None:
    """Submit through the real composer, exactly as a user would."""
    page.wait_for_selector(".file-input-wrapper textarea", timeout=15000)
    page.fill(".file-input-wrapper textarea", text)
    page.click("[data-testid='send-message-button']")
    # The draft is cleared synchronously by FileInput before the emit, so this
    # is the cheapest proof the submit actually went through.
    page.wait_for_function(
        "() => { const t = document.querySelector('.file-input-wrapper textarea');"
        " return t && t.value.trim() === ''; }",
        timeout=10000,
    )


def _echo_user_turn(h, session_id: str, text: str, *, index: int = ECHO_INDEX) -> None:
    """The row the server sends back over SSE when it accepts the turn.

    There is no optimistic bubble by design (see the 2026-08-23 note in
    `handleFileInputSubmit`), so this frame is the only thing that makes the
    sent turn exist — and it is therefore the thing the follow has to survive
    until. A queued turn is the same story later and slower: the row appears
    when the worker drains the queue, not when the reader asked.
    """
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={
            "type": "full",
            "session_id": session_id,
            "role": "user",
            "content": text,
            "finish_reason": "stop",
            "index": index,
        },
        expect=200,
    )


def _wait_parked_at_bottom(page, *, what: str) -> dict:
    """Wait for the stick to be armed AND the viewport to be at the bottom.

    The two conditions are asserted together on purpose. `scrollTop` at the
    bottom can be true of a scroller that has not yet been told it is at the
    bottom — that is the state every follow gate reads, and the state the
    pre-fix code leaves behind.

    Measured against the app's OWN bottom (`appBottom`), not the DOM's. See the
    `_GEOM_SCRIPT` note: the DOM max is up to `maxTailGap` below the real
    content bottom by design, so a DOM-ruler assertion fails on a correct stick
    whenever the height model has not fully converged — which is exactly what
    made this suite pass on a fast Linux box and fail on the slower macOS
    runner. The `rulerGap` bound below keeps the assertion honest: it still
    fails if the app parks the reader anywhere the tail-gap cap does not allow.

    30s, not 15s: this wait straddles an SSE echo plus a remeasure, and the
    15s bound was the tightest `wait_for_function` in the suite (30000 is
    what the other 40 use).
    """
    page.wait_for_function(
        "() => {"
        "  const el = " + _CHAT_SCROLLER + ";"
        "  if (!el) return false;"
        "  if (document.querySelector('.chat-scroll-to-bottom')) return false;"
        "  const domEdge = el.scrollHeight - el.clientHeight;"
        "  let appBottom = domEdge;"
        "  try {"
        "    const exposed = el.__vueParentComponent && el.__vueParentComponent.exposed;"
        "    if (exposed && typeof exposed.bottomScrollTop === 'function') {"
        "      const v = exposed.bottomScrollTop();"
        "      if (typeof v === 'number' && isFinite(v)) appBottom = v;"
        "    }"
        "  } catch (e) {}"
        "  return el.scrollTop >= appBottom - " + str(BOTTOM_TOL_PX) + ";"
        "}",
        timeout=30000,
    )
    page.wait_for_timeout(400)
    g = _geom(page)
    assert not g["arrow"], f"{what}: the jump-to-bottom arrow is showing, so isAtBottom is false: {g}"
    assert g["scrollTop"] >= g["appBottom"] - BOTTOM_TOL_PX, (
        f"{what}: not parked at the bottom of the transcript: {g}"
    )
    # The teeth: the app may park short of the DOM max, but only by the tail-gap
    # cap. A larger gap means the stick aimed somewhere it should not have.
    assert g["rulerGap"] <= MAX_TAIL_GAP_PX + BOTTOM_TOL_PX, (
        f"{what}: the DOM bottom sits {g['rulerGap']}px above the app's bottom, "
        f"past the {MAX_TAIL_GAP_PX}px tail-gap cap: {g}"
    )
    return g


def _seed_session(h, session_id: str, count: int = TURN_COUNT) -> None:
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"Send-scroll {count}")
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            body = (
                f"Turn {i}. A paragraph long enough that the bubble has real "
                "height in the virtual scroller, so the transcript is far "
                "taller than the viewport and scrolling up is a real place to "
                "be rather than a rounding error."
            )
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


# ─── The tests ───────────────────────────────────────────────────────────────


def test_sending_from_history_lands_on_the_newest_turn(ui_harness, page) -> None:
    """The report: send a message from up in the history, end up at the bottom.

    The bottom this asserts against is the one that exists AFTER the sent turn
    has been echoed back. A pin aimed at the pre-send bottom moves the scroller
    and still leaves the turn the reader just asked for below the fold.
    """
    h = ui_harness
    session_id = "chat-send-scroll-send"
    _seed_session(h, session_id)
    _open_chat(page, h, session_id)

    before = _geom(page)
    assert before["maxScrollTop"] > 2000, f"transcript is not scrollable: {before}"
    assert not before["arrow"], f"a chat should open on its newest turn: {before}"

    history = _park_in_history(page)
    assert history["scrollTop"] < history["appBottom"] - BOTTOM_TOL_PX

    text = "and then open a PR for the scroll fix"
    _send(page, text)
    _echo_user_turn(h, session_id, text)

    after = _wait_parked_at_bottom(page, what="after sending from history")

    # The turn is not merely accounted for in the scroll range — it is on
    # screen. This is the user's actual complaint: the message they just sent
    # was somewhere they could not see it.
    assert after["appBottom"] > history["appBottom"], (
        "the sent turn did not grow the transcript at all, so this test proved "
        f"nothing: {history} -> {after}"
    )
    on_screen = page.evaluate(
        "() => {"
        "  const el = " + _CHAT_SCROLLER + ";"
        "  const rows = [...document.querySelectorAll('[data-group-key]')];"
        "  if (!rows.length) return {found: false};"
        "  const elBox = el.getBoundingClientRect();"
        "  const box = rows[rows.length - 1].getBoundingClientRect();"
        "  return {"
        "    found: true,"
        "    visible: box.bottom > elBox.top && box.top < elBox.bottom,"
        "    text: (rows[rows.length - 1].textContent || '').slice(0, 200),"
        "  };"
        "}"
    )
    assert on_screen.get("found"), "no transcript rows rendered"
    assert on_screen.get("visible"), (
        "the scroller reports the bottom but the newest row is off screen: "
        f"{on_screen}"
    )


def test_sending_twice_in_a_row_keeps_following(ui_harness, page) -> None:
    """The follow survives a second turn, not just the first.

    The pin is a one-shot act. What has to hold is the STATE it leaves behind:
    the next turn has to be followed too, which is only true if the stick was
    armed rather than merely scrolled to once.
    """
    h = ui_harness
    session_id = "chat-send-scroll-twice"
    _seed_session(h, session_id)
    _open_chat(page, h, session_id)

    _park_in_history(page)
    first = "first follow-up"
    _send(page, first)
    _echo_user_turn(h, session_id, first)
    _wait_parked_at_bottom(page, what="after the first turn")

    # Read history again — this time while the transcript is already following.
    page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; el.scrollTop = el.scrollHeight * 0.4; }"
    )
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')", timeout=10000
    )

    second = "second follow-up"
    _send(page, second)
    _echo_user_turn(h, session_id, second)

    _wait_parked_at_bottom(page, what="after the second turn")
