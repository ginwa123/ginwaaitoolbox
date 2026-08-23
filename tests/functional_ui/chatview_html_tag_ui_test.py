"""DB-seeded Playwright tests for the chatview's ``<html>`` wrapper tag.

Feature (2026-08-23 html-tag-support): the LLM can wrap raw HTML in
``<html>...</html>``; the chatview renders each block as a live
sandboxed iframe (``sandbox="allow-scripts"``, null origin) instead of
markdown. Any text outside the tags still renders as markdown.

Each test:

1. Boots a fresh nalar + Vite via the ``ui_harness`` fixture.
2. Seeds ``sessions`` + ``llm_history`` rows whose ``response_content``
   carries the raw tagged string — the exact wire shape production
   stores (tags included).
3. Drives headless Chromium at
   ``<vite_url>/app?view=chat&session=<id>`` and asserts the rendered
   DOM.

Real Chromium (unlike jsdom vitest) EXECUTES iframe srcdoc content —
that's the point of tests 2 and 3: we prove scripts run inside the
sandbox and clicks land, not just that an iframe tag exists.

Plan: docs/superpowers/plans/2026-08-23-html-tag-support.md (Task 4)
"""

from __future__ import annotations

from pathlib import Path

from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    """Path to the harness's isolated agent.db (DbSeed re-validates)."""
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _open_chatview(page, h: UIHarness, session_id: str, timeout_ms: int = 30000) -> None:
    """Navigate to the chatview for ``session_id``.

    Canonical URL shape (see chatview_ui_test.py): the query-param form
    ``/app?view=chat&session=<id>`` — the router path alone does not set
    AppLayout's activeChatId.
    """
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="load",
        timeout=timeout_ms,
    )


def _wait_for_text(page, text: str, timeout_ms: int = 10000) -> None:
    """Wait for ``text`` anywhere in the DOM (attached — VirtualScroller
    may keep off-viewport messages out of the visible window)."""
    page.locator(f"text={text}").first.wait_for(timeout=timeout_ms, state="attached")


# ─── Test 1: html-only assistant message renders a sandboxed iframe ────────


def test_html_only_message_renders_sandboxed_iframe(
    ui_harness: UIHarness, page,
) -> None:
    """An assistant row of just ``<html>...</html>`` renders one iframe
    with sandbox="allow-scripts" and NO markdown wrapper around it."""
    h = ui_harness
    session_id = "sess_html_tag_iframe_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "HTML tag")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(
            conn, session_id, "show me a button", created_at=ts[0],
        )
        seed.seed_assistant_message(
            conn, session_id,
            "<html><button id=\"probe-btn\">Click me</button></html>",
            created_at=ts[1],
        )

    _open_chatview(page, h, session_id)

    # The iframe appears with the security contract intact.
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    frame_el = page.locator("iframe.chat-html-frame").first
    sandbox = frame_el.get_attribute("sandbox")
    assert sandbox == "allow-scripts", (
        f"Expected sandbox='allow-scripts', got {sandbox!r}. "
        f"allow-same-origin would break the null-origin security boundary."
    )
    # The inner payload must NOT ALSO render as markdown inside the
    # assistant item. (The group container itself carries the
    # .markdown-content class by design — paragraph mode — so assert on
    # the assistant-item's inner HTML instead of the page-wide count.)
    item_html = page.locator(".assistant-item").first.inner_html()
    assert ".markdown-content" not in item_html, (
        "html-only message should render via iframe, not markdown"
    )
    assert "<button" not in item_html, (
        "raw html payload leaked into the DOM outside the iframe srcdoc"
    )


# ─── Test 2: inner HTML actually executes inside the sandbox ───────────────


def test_html_block_scripts_execute_inside_sandbox(
    ui_harness: UIHarness, page,
) -> None:
    """The iframe's srcdoc content is LIVE: the button renders, is
    clickable, and its onclick handler runs (sets document.title).

    This is the real-Chromium advantage — jsdom never executes srcdoc.
    """
    h = ui_harness
    session_id = "sess_html_tag_exec_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "HTML exec")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "make it interactive", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            "<html>"
            "<button id=\"probe-btn\" onclick=\"document.title='CLICKED'\">Click me</button>"
            "</html>",
            created_at=ts[1],
        )

    _open_chatview(page, h, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)

    # Reach INTO the frame (frame_locator works on sandboxed frames for
    # DOM queries) and click the button.
    frame = page.frame_locator("iframe.chat-html-frame")
    btn = frame.locator("#probe-btn")
    btn.wait_for(timeout=10000)
    assert btn.inner_text() == "Click me"
    btn.click()

    # The onclick handler ran → document.title changed inside the frame.
    # Playwright's Frame object can read the title same-process even for
    # null-origin frames (the sandbox restricts the PAGE's access, not
    # the automation protocol). Poll briefly — srcdoc script execution
    # is async relative to the click returning.
    child_frames = [f for f in page.frames if f != page.main_frame]
    assert child_frames, "expected at least one child frame"
    title = ""
    for _ in range(20):  # up to ~2s
        title = child_frames[0].title()
        if title == "CLICKED":
            break
        page.wait_for_timeout(100)
    assert title == "CLICKED", (
        f"Expected onclick to set frame title to 'CLICKED', got {title!r}. "
        f"Scripts did not execute inside the sandboxed iframe."
    )


# ─── Test 3: mixed message — surrounding markdown + html block ─────────────


def test_mixed_markdown_and_html_block_render_together(
    ui_harness: UIHarness, page,
) -> None:
    """Text outside <html> tags renders as markdown; the block itself
    renders as an iframe whose srcdoc carries the inner HTML."""
    h = ui_harness
    session_id = "sess_html_tag_mixed_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Mixed")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "widget please", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            "Here is **your** widget:\n<html><b>live bold</b></html>\nEnjoy!",
            created_at=ts[1],
        )

    _open_chatview(page, h, session_id)

    # Surrounding markdown still renders (bold from ** **).
    _wait_for_text(page, "Here is your widget:")
    assert page.locator(".markdown-content strong").count() > 0, (
        "markdown outside the html block should still render via marked"
    )

    # The iframe exists and its srcdoc contains the inner payload.
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    srcdoc = page.locator("iframe.chat-html-frame").first.get_attribute("srcdoc") or ""
    assert "live bold" in srcdoc, (
        f"srcdoc should carry the inner html payload, got: {srcdoc[:200]!r}"
    )


# ─── Test 4: legacy messages untouched (regression guard) ──────────────────


def test_legacy_markdown_messages_render_without_iframe(
    ui_harness: UIHarness, page,
) -> None:
    """A plain markdown assistant message renders exactly as before —
    zero chat-html-frame iframes on the page."""
    h = ui_harness
    session_id = "sess_html_tag_legacy_001"
    seed = DbSeed(_seed_db_path(h))
    md_text = "# Heading\n\nSome **bold** text.\n"
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Legacy")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "tell me things", created_at=ts[0])
        seed.seed_assistant_message(conn, session_id, md_text, created_at=ts[1])

    _open_chatview(page, h, session_id)
    page.wait_for_selector(".markdown-content h1", timeout=15000)
    assert page.locator(".markdown-content h1").inner_text() == "Heading"
    assert page.locator("iframe.chat-html-frame").count() == 0, (
        "legacy markdown messages must NOT produce iframes"
    )


# ─── Test 5: unclosed <html> degrades safely (no crash, no iframe) ─────────


def test_unclosed_html_tag_degrades_safely(ui_harness: UIHarness, page) -> None:
    """Mid-stream the close tag hasn't arrived yet. The regex requires a
    closed pair, so the raw text falls through to the legacy path — no
    iframe, no crash, no console error blowing up the page."""
    h = ui_harness
    session_id = "sess_html_tag_unclosed_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Unclosed")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "go", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            "<html><div>never closed",
            created_at=ts[1],
        )

    errors: list[str] = []
    page.on("pageerror", lambda exc: errors.append(str(exc)))

    _open_chatview(page, h, session_id)
    # The raw text shows through the legacy path (escaped by marked).
    _wait_for_text(page, "never closed", timeout_ms=15000)
    assert page.locator("iframe.chat-html-frame").count() == 0, (
        "unclosed <html> must not produce an iframe"
    )
    # No uncaught page errors from the render path.
    assert not errors, f"page errors during unclosed-tag render: {errors}"
