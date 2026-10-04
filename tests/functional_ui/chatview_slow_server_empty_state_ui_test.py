"""Slow/failed ``/messages`` must never be rendered as "How can I help you?".

The bug this file locks down
----------------------------
``ChatView`` used to funnel a failed (or slow) transcript fetch into the
SAME state as a genuinely empty session: the history loader swallowed the
error and handed back ``messages: []``. ``isLoading`` went false, ``error``
stayed ``null`` (it was write-only — nothing rendered it), and the empty-state
block's ``v-if`` — which only asked "are there zero messages?" — was true. A
session holding hundreds of messages showed 💬 "How can I help you?" /
"Start a conversation by typing a message below", and the user was actively
invited to start over on a chat that already had content.

The fix has two halves, and this test asserts both:

1. **Keep awaiting.** ``loadChatHistory`` holds ``isLoading`` across the whole
   retry schedule (``src/helpers/chatHistoryRetry.ts``:
   ``INITIAL_HISTORY_RETRY_DELAYS_MS = [0, 750, 2000, 5000]``), so
   ``isInitializing`` keeps the ``chat-initializing-skeleton`` up for the
   entire wait.
2. **Never claim "empty" from a failure.** The empty state is gated on
   ``historyConfirmed``, set only by a *successful* attempt, and the exhausted
   schedule lands in the inline error state (``chat-load-error``) with its
   Retry button.

How the slowness is induced
---------------------------
The seeded session really does have two ``llm_history`` rows. Playwright's
``page.route`` then intercepts the app's own
``GET /api/llm/session/<id>/messages?...`` (``API_BASE = '/api'`` in
``src/apps/desktop/src/api/index.ts``) and fulfils it with ``503`` on every
attempt, so the frontend sees a backend that is permanently down. The route is
registered *before* ``page.goto`` so the very first mount fetch is already
failing. The sibling ``GET /api/llm/session/<id>`` (no ``/messages``) that
``getSessionWorkspaceId`` uses is NOT matched, so workspace resolution still
succeeds.

Because the intercepted attempts fail instantly, the 4-attempt schedule
elapses in ~7.75 s of pure backoff (0 + 750 + 2000 + 5000) — no 45 s
per-attempt timeout is burned — which keeps the whole test bounded even though
the app's own timeouts are generous.

The three template blocks under test live in
``src/apps/desktop/src/components/views/ChatView.vue``: the skeleton
(``chat-initializing-skeleton``), the error state (``chat-load-error``), and
the empty state gated on ``historyConfirmed``.

⚠️  URL shape — why not ``?view=chat&session=``
----------------------------------------------
``chatview_ui_test.py::_open_chatview`` navigates to the legacy query URL
``/app?view=chat&session=<id>``. That route is an ASYNC boot: ``AppLayout``'s
``bootLegacyChat`` first resolves the owning workspace via
``GET /api/llm/session/<id>`` and then rewrites the URL. With a NULL
``sessions.workspace_id`` it fails closed to ``/app`` and the chatview never
mounts at all (no skeleton, no empty state, no error state — every DOM
assertion would pass vacuously). This test therefore uses the canonical
deep link ``/app/<workspaceId>/chat/<sessionId>``, which ``handleBootUrl``
adopts synchronously via ``parseAppPath(...).kind === 'chat'`` and never
redirects away from.
"""

from __future__ import annotations

import time
from pathlib import Path

from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Constants ──────────────────────────────────────────────────────────────

#: ``API_BASE`` is ``/api``; ``api.fetchChatHistory`` requests
#: ``/llm/session/<id>/messages?sort_by=…&direction=…&limit=…``. The trailing
#: ``*`` absorbs the query string; ``*`` does not cross ``/``, so this cannot
#: swallow a sibling endpoint (notably the ``/llm/session/<id>`` session-detail
#: call that workspace resolution depends on).
MESSAGES_URL_GLOB = "**/llm/session/*/messages*"

#: Only ``api.fetchChatHistory(PAGE_SIZE)`` asks for a 1000-row page, so this
#: is the fingerprint of ChatView's own transcript load. Asserting on it means
#: a silently-mismatched glob (or a chatview that never mounted) fails loudly
#: instead of making the "no empty state" assertion pass for the wrong reason.
HISTORY_PAGE_MARKER = "limit=1000"

#: How long to keep sampling the DOM looking for the empty state. Must exceed
#: the app's full backoff schedule (~7.75 s) so the window covers the retry
#: loop, the moment the old code used to surrender, and the final error state.
SAMPLE_WINDOW_S = 14.0

#: Poll cadence. 200 ms is frequent enough to catch a one-render flash of the
#: empty state (the pre-fix code swapped it in within a single tick of the
#: failed fetch) and slow enough not to starve the browser.
SAMPLE_INTERVAL_MS = 200

#: How long to wait for ``chat-load-error`` after the sampling window. The
#: error state is what replaced the empty state; the app only reaches it once
#: the retry schedule is exhausted, hence the generous budget.
ERROR_STATE_TIMEOUT_MS = 25_000

#: The empty-state headline from ChatView.vue's empty-state block.
EMPTY_STATE_TEXT = "How can I help you?"


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    """Path to the harness's isolated ``agent.db`` (already ``is_safe_tmp``-checked)."""
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _create_workspace(h: UIHarness, name: str = "ui-slow-server-ws") -> str:
    """Create a workspace via the backend API (same shape as kanban_lifecycle_ui_test.py)."""
    return h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _open_chatview(page, h: UIHarness, workspace_id: str, session_id: str,
                   timeout_ms: int = 30000) -> None:
    """Navigate to the canonical chat deep link for ``session_id``.

    ``/app/<workspaceId>/chat/<sessionId>`` is what ``parseAppPath`` classifies
    as ``kind: 'chat'``, so ``AppLayout.handleBootUrl`` adopts the chat
    synchronously and stays on the URL. See the module docstring for why the
    legacy ``?view=chat&session=`` query URL is not usable here.
    """
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=timeout_ms,
    )


def _fail_messages(route) -> None:
    """Fulfil the intercepted messages request with a 503."""
    route.fulfill(
        status=503,
        content_type="application/json",
        body='{"error":"slow"}',
    )


# ─── The test ───────────────────────────────────────────────────────────────


def test_slow_history_fetch_never_shows_empty_state(
    ui_harness: UIHarness,
    page,
    artifacts_dir: Path,
) -> None:
    """A dead ``/messages`` endpoint must show skeleton → error, never "empty".

    Against the pre-fix source the first thing to blow up is
    ``assert not offenders, …`` — the empty state renders the moment the
    swallowed failure resolves, i.e. on the very first sample.
    """
    h = ui_harness

    # 1. A session that genuinely HAS messages, so "empty" is a lie here.
    workspace_id = _create_workspace(h)
    session_id = "sess_chatview_slow_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Slow Server Chat")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(
            conn, session_id, "hi from a slow server", created_at=ts[0],
        )
        seed.seed_assistant_message(
            conn, session_id, "this reply is already in the database", created_at=ts[1],
        )
        # The chat deep link carries the workspace id, but the session-detail
        # endpoint that `bootLegacyChat` consults reads this column — keep the
        # two in agreement so a refresh resolves the same workspace.
        conn.execute(
            "UPDATE sessions SET workspace_id = ? WHERE id = ?",
            (workspace_id, session_id),
        )

    # 2. Make every attempt at the transcript fail, BEFORE the app mounts.
    intercepted: list[str] = []

    def _record_and_fail(route) -> None:
        intercepted.append(route.request.url)
        _fail_messages(route)

    page.route(MESSAGES_URL_GLOB, _record_and_fail)

    empty_locator = page.get_by_text(EMPTY_STATE_TEXT)
    skeleton_locator = page.locator('[data-testid="chat-initializing-skeleton"]')
    error_locator = page.locator('[data-testid="chat-load-error"]')

    # 3. Open the chatview.
    _open_chatview(page, h, workspace_id, session_id)

    # Wait until ChatView's own transcript fetch has been intercepted at least
    # once. This is the test's "the chatview is really running" precondition:
    # without it, an unmounted chatview would make every DOM assertion below
    # pass for the wrong reason.
    history_deadline = time.monotonic() + 20.0
    while (
        not any(HISTORY_PAGE_MARKER in u for u in intercepted)
        and time.monotonic() < history_deadline
    ):
        page.wait_for_timeout(100)
    assert any(HISTORY_PAGE_MARKER in u for u in intercepted), (
        f"page.route({MESSAGES_URL_GLOB!r}) never intercepted ChatView's own "
        f"history page (expected a {HISTORY_PAGE_MARKER!r} request). "
        f"Intercepted instead: {intercepted!r}. The chatview may not have "
        f"mounted — the assertions below would then pass vacuously."
    )

    # 4. Poll the DOM for the whole window.
    start = time.monotonic()
    empty_state_samples: list[tuple[float, int]] = []
    skeleton_samples: list[tuple[float, int]] = []
    error_samples: list[tuple[float, int]] = []
    while time.monotonic() - start < SAMPLE_WINDOW_S:
        elapsed = time.monotonic() - start
        empty_state_samples.append((elapsed, empty_locator.count()))
        skeleton_samples.append((elapsed, skeleton_locator.count()))
        error_samples.append((elapsed, error_locator.count()))
        page.wait_for_timeout(SAMPLE_INTERVAL_MS)

    # 4a. The headline claim: the empty state must NEVER appear — not once, not
    #     for a single sample. Asserted FIRST because this is the bug the user
    #     reported; a pre-fix build fails here. (The "we intercepted the
    #     chatview's own history page" precondition above is what keeps this
    #     from passing vacuously on an unmounted chatview, so the skeleton
    #     check below does not have to come first.)
    offenders = [(t, n) for t, n in empty_state_samples if n > 0]
    assert not offenders, (
        f"The empty state {EMPTY_STATE_TEXT!r} rendered while the /messages "
        f"endpoint was failing — a failed fetch was presented as a "
        f"successfully-empty session. It was present in {len(offenders)} of "
        f"{len(empty_state_samples)} samples, first at t+{offenders[0][0]:.2f}s "
        f"(count={offenders[0][1]})."
    )

    # 4b. The "keep awaiting" half: the loading skeleton must actually have
    #     been on screen during that window.
    assert any(n > 0 for _, n in skeleton_samples), (
        "The loading skeleton [data-testid=chat-initializing-skeleton] never "
        f"appeared across {len(skeleton_samples)} samples over "
        f"{SAMPLE_WINDOW_S}s. Expected it to stay up for the whole retry "
        f"schedule (delays 0/750/2000/5000 ms). "
        f"error-state samples: {error_samples[:6]}…"
    )

    # 4c. Once the schedule is exhausted the app must land in the error state
    #     with a Retry button — that is what replaced the empty state.
    error_locator.wait_for(state="visible", timeout=ERROR_STATE_TIMEOUT_MS)
    page.get_by_role("button", name="Retry").wait_for(
        state="visible", timeout=ERROR_STATE_TIMEOUT_MS,
    )

    # The empty state must still be absent after the error state settled
    # (the template gates it on `historyConfirmed && !error`).
    assert empty_locator.count() == 0, (
        f"The empty state {EMPTY_STATE_TEXT!r} is present alongside the error "
        f"state after the retry schedule was exhausted."
    )

    # 5. Evidence.
    page.screenshot(
        path=str(artifacts_dir / "slow_history_error_state.png"), full_page=True,
    )
    (artifacts_dir / "intercepted_urls.txt").write_text(
        "\n".join(intercepted) + "\n", encoding="utf-8",
    )
