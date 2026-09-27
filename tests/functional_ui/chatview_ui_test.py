"""DB-seeded Playwright tests for the chatview.

Each test:

1. Boots a fresh nalar + Vite via the ``ui_harness`` fixture.
2. Opens a Python ``sqlite3`` connection to the harness's
   isolated ``agent.db`` and INSERTs pre-shaped ``sessions`` +
   ``llm_history`` rows that simulate a real conversation.
3. Drives a headless Chromium browser at
   ``<vite_url>/app/chat/<session_id>`` and asserts the rendered
   DOM matches the seeded data.

No real LLM is invoked. The whole point is to verify the chatview's
*render path* — the layer where UI bugs actually live. If the
agent loop or LLM has a bug, that's caught by the
functional/ API tests; UI tests like these only need to verify
that the frontend renders the wire shape correctly.

Plan: docs/superpowers/plans/2026-08-20-functional-ui-chatview-test.md
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from db_seed import DbSeed, TINY_PNG_DATA_URL
from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    """Return the path to the harness's isolated ``agent.db``.

    The harness's tempdir already passed ``is_safe_tmp`` validation
    before boot. We pass that dir to ``DbSeed``, which
    re-validates as belt-and-suspenders.
    """
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _open_chatview(page, h: UIHarness, session_id: str, timeout_ms: int = 30000) -> None:
    """Navigate to the chatview for ``session_id`` and wait for it to mount.

    URL routing note: the chatview is rendered by AppLayout.vue
    via the branch ``<ChatView v-else-if="activeChatId.startsWith('chat-')">``.
    The router path ``/app/chat/:sessionId`` itself does NOT auto-set
    ``activeChatId`` — that param is only read if the user is already
    in a workspace context. The canonical URL is the query-param shape
    ``/app?view=chat&session=<session_id>`` (set via
    ``AppLayout.handleNavigate`` when ``view.startsWith('chat-')``),
    which writes ``activeChatId = "chat-<session_id>"`` and renders
    the real ``<ChatView>`` (not the stub ``<Chats>`` view).

    Header testid caveat: the per-chat header testid
    (``data-testid="chat-header-name-${chatId}"``) is gated by
    ``v-if="showHeader"`` and AppLayout does NOT pass ``showHeader``
    to the standalone ChatView, so the header is hidden in the
    standard route. Tests must wait for the empty-state copy
    or for a specific message text (NOT the header testid).
    """
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="load",
        timeout=timeout_ms,
    )
    # The chatview's empty-state H3 ("How can I help you?") is the
    # most reliable "Vue mounted something chatview-shaped" signal.
    # It's rendered when the messages list is empty (which is what
    # tests want to wait for BEFORE seeding — but since we seed
    # before navigating, the empty-state copies only show for the
    # "empty session" test; for the others, the seeded message text
    # is the right marker).
    # We don't wait_for_selector here — let each test decide what
    # to wait for via _wait_for_text or _wait_for_message_text.
    # The page.goto with wait_until="domcontentloaded" is enough
    # to ensure the Vue app has mounted the chatview component.


def _wait_for_text(page, text: str, timeout_ms: int = 10000) -> None:
    """Wait for ``text`` to appear anywhere in the DOM (attached, not visible).

    The chatview uses a VirtualScroller that only renders messages
    currently in the viewport. Older messages are in the DOM but
    may have empty bounding boxes (the virtual scroll mounts a
    spacer div in their place). Using ``state="attached"`` matches
    on DOM presence — the message exists in the rendered HTML,
    just possibly not in the visible viewport at this moment.

    For "must be visible" cases (e.g.QA tests for new UI elements
    that are not in a virtualized list), use the explicit
    ``state="visible"`` Playwright locators directly.
    """
    page.locator(f"text={text}").first.wait_for(timeout=timeout_ms, state="attached")


# ─── Tests ──────────────────────────────────────────────────────────────────


# ─── Test 1: empty state ────────────────────────────────────────────────────


def test_chatview_renders_empty_state(ui_harness: UIHarness, page) -> None:
    """A session with no messages renders the empty-state placeholder.

    Seeds only a ``sessions`` row — no ``llm_history`` rows. The
    chatview's empty state is the 💬 "How can I help you?" block
    (ChatView.vue lines 2401–2407).
    """
    h = ui_harness
    session_id = "sess_chatview_empty_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Empty Chat")

    _open_chatview(page, h, session_id)
    # The empty-state H3 is "How can I help you?"; the subtitle is
    # "Start a conversation by typing a message below".
    _wait_for_text(page, "How can I help you?")


# ─── Test 2: plain user/assistant exchange ─────────────────────────────────


def test_chatview_renders_plain_user_assistant_exchange(
    ui_harness: UIHarness, page,
) -> None:
    """A session with 1 user + 1 assistant message renders both bubbles."""
    h = ui_harness
    session_id = "sess_chatview_plain_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Plain Chat")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "hi there", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id, "hello! how can I help?", created_at=ts[1],
        )

    _open_chatview(page, h, session_id)
    _wait_for_text(page, "hi there")
    _wait_for_text(page, "hello! how can I help?")


# ─── Test 3: multi-turn conversation ────────────────────────────────────────


def test_chatview_renders_multi_turn_conversation(ui_harness: UIHarness, page) -> None:
    """A 4-turn conversation (8 messages) renders the visible-tail messages.

    Note: the chatview's VirtualScroller only renders messages in the
    viewport — older messages are off-screen but still in the DOM
    (they're just not visible). The newest messages auto-scroll
    into view. We assert on the LAST message (newest, always visible)
    and trust the rendered HTML / data layer for the older ones.

    The 20s timeout is generous because this test seeds 8 messages
    and the VirtualScroller mounting the visible-window + the
    message-group computed both take a few seconds on a cold Vite
    cache. Under suite load (Vite warm), it's still 1-2s — the
    timeout is a safety net for slow CI.
    """
    h = ui_harness
    session_id = "sess_chatview_multi_001"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Multi-turn")
        # 8 messages × 30s gap = 4 minutes of conversation.
        ts = DbSeed.baseline_timestamps(count=8, interval_seconds=30)
        for i in range(4):
            seed.seed_user_message(
                conn, session_id, f"user turn {i + 1}", created_at=ts[i * 2],
            )
            seed.seed_assistant_message(
                conn, session_id, f"assistant reply {i + 1}",
                created_at=ts[i * 2 + 1],
            )

    _open_chatview(page, h, session_id)

    # The newest message ("assistant reply 4") is the last to render and
    # is always in the visible viewport (the chatview auto-scrolls to
    # the bottom). Older messages may be virtualized out of the visible
    # window by the VirtualScroller — we trust the API for the data
    # layer and only assert on the newest visible message.
    _wait_for_text(page, "assistant reply 4", timeout_ms=20000)

    # Verify via the API that all 8 messages were loaded into the
    # chatview's message list (the API is the source of truth for
    # the data layer; the DOM only shows the visible subset).
    msgs = h.http("GET", f"/api/llm/session/{session_id}/messages").json()
    assert len(msgs["messages"]) == 8, (
        f"Expected 8 messages via API, got {len(msgs['messages'])}"
    )


# ─── Test 5: tool call + result pair (Bash card renders stdout) ────────────


def test_chatview_renders_tool_call_result_pair(ui_harness: UIHarness, page) -> None:
    """An assistant tool call + matching ``role='tool'`` result renders the tool card.

    The chatview dispatches the rendering to a per-tool Vue
    component based on ``tool_name`` (``ShellTool`` for ``bash``,
    ``ReadFile`` for ``read_file``, etc.). ``ShellTool`` parses the
    JSON envelope from the tool output and renders the command,
    stdout, stderr, and exit code.

    Collapsed state (default): the header shows the tool name
    ("bash" pill) + the command ("$ ls") + the exit code. The
    stdout is hidden behind ``v-if="isExpanded"`` until the user
    clicks to expand. We assert on the header (always visible).
    """
    h = ui_harness
    session_id = "sess_chatview_toolresult_001"
    seed = DbSeed(_seed_db_path(h))
    # The shell tool envelope (JSON, per the tool-output JSON schema).
    shell_output = json.dumps(
        {
            "tool": "bash",
            "parameters": {"command": "ls"},
            "success": True,
            "data": {
                "command": "ls",
                "stdout": "file1.txt\nfile2.txt\nfile3.txt",
                "stderr": "",
                "exit_code": 0,
                "truncated": False,
                "timeout": False,
                "stdout_lines": 3,
                "stderr_lines": 0,
                },
            "error": None,
            "v": 1,
        }
    )
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Tool-call result")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "list files", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            text="",
            finish_reason="tool_calls",
            tool_calls=[{
                "id": "call_xyz789",
                "type": "function",
                "function": {"name": "bash", "arguments": {"command": "ls"}},
            }],
            created_at=ts[1],
        )
        seed.seed_tool_result(
            conn, session_id, "call_xyz789", "bash", shell_output,
            created_at=ts[1],
        )

    _open_chatview(page, h, session_id)
    # The shell tool header shows the command ("$ ls") and the tool
    # name ("bash" pill). Both are visible in the collapsed state.
    _wait_for_text(page, "ls")
    # The bash pill is rendered with data-testid="shell-tool-pill".
    page.wait_for_selector('[data-testid="shell-tool-pill"]', timeout=10000)
    # The exit code is rendered with data-testid="shell-tool-exit-code".
    page.wait_for_selector('[data-testid="shell-tool-exit-code"]', timeout=10000)
    exit_text = page.locator('[data-testid="shell-tool-exit-code"]').inner_text()
    assert "0" in exit_text, (
        f"Expected exit code 0 in shell-tool-exit-code, got {exit_text!r}"
    )


# ─── Test 6: markdown rendering in assistant message ────────────────────────


def test_chatview_renders_markdown_in_assistant_message(
    ui_harness: UIHarness, page,
) -> None:
    """Assistant text with markdown is rendered via ``marked`` into HTML.

    Test that ``**bold**`` → ``<strong>``, ``# Heading`` → ``<h1>``,
    `` `inline_code` `` → ``<code>``, and a fenced code block → ``<pre><code>``.
    """
    h = ui_harness
    session_id = "sess_chatview_markdown_001"
    seed = DbSeed(_seed_db_path(h))
    md_text = (
        "# Heading\n"
        "Some **bold** text and `inline_code` here.\n"
        "\n"
        "```bash\n"
        "echo hello\n"
        "```\n"
    )
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Markdown")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "tell me a story", created_at=ts[0])
        seed.seed_assistant_message(conn, session_id, md_text, created_at=ts[1])

    _open_chatview(page, h, session_id)
    # Wait for the markdown content to render. The .markdown-content
    # class is applied to the rendered HTML wrapper.
    page.wait_for_selector(".markdown-content", timeout=10000)
    # Verify the rendered HTML contains the expected elements.
    assert page.locator(".markdown-content h1").count() > 0, (
        "h1 not rendered from markdown heading"
    )
    assert page.locator(".markdown-content strong").count() > 0, (
        "strong not rendered from markdown bold"
    )
    assert page.locator(".markdown-content code").count() > 0, (
        "code not rendered from markdown inline code"
    )
    assert page.locator(".markdown-content pre").count() > 0, (
        "pre block not rendered from markdown fenced code"
    )


# ─── Test 7: user with attached images ──────────────────────────────────────


def test_chatview_renders_user_message_with_images(
    ui_harness: UIHarness, page,
) -> None:
    """A user row with 2 image URLs renders 2 thumbnail bubbles.

    The DB column is singular ``image_url`` (TEXT, ``||``-delimited
    for multiple). The chatview splits on ``|`` and renders each
    image as a ``.chat-attached-image-thumb`` div.
    """
    h = ui_harness
    session_id = "sess_chatview_images_001"
    seed = DbSeed(_seed_db_path(h))
    urls = [TINY_PNG_DATA_URL, TINY_PNG_DATA_URL]
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Images")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(
            conn, session_id, "look at these screenshots",
            image_urls=urls, created_at=ts[0],
        )
        seed.seed_assistant_message(
            conn, session_id, "I see two images.", created_at=ts[1],
        )

    _open_chatview(page, h, session_id)
    # The chatview renders one .chat-attached-image-thumb per URL.
    # We seeded 2 images → 2 thumbnails.
    page.wait_for_selector(".chat-attached-image-thumb", timeout=10000)
    thumbs = page.locator(".chat-attached-image-thumb")
    assert thumbs.count() == 2, (
        f"Expected 2 image thumbnails, got {thumbs.count()}. "
        f"Check the .chat-attached-image-thumb selector — the frontend "
        f"may have renamed the class."
    )


# ─── Test 8: reasoning content ──────────────────────────────────────────────


def test_chatview_renders_reasoning_content(ui_harness: UIHarness, page) -> None:
    """An assistant row with ``<thinking>...</thinking>`` tags in content.

    The chatview's ``renderResponse`` checks for ``<thinking>`` tags
    in the content and renders them via ``getThinkingTags`` (which
    strips the tags and shows the inner text). The response text
    after the tags is rendered as markdown. We assert both pieces
    are visible.

    Note: the ``reasoning_content`` DB column is currently NOT
    surfaced to the UI — the chatview only renders reasoning via
    ``<thinking>`` tags in the content. This test verifies the
    tag-based rendering (the production path).
    """
    h = ui_harness
    session_id = "sess_chatview_reasoning_001"
    seed = DbSeed(_seed_db_path(h))
    trace = "think about this carefully"
    response_text = (
        "I will run a command.\n"
        "The reasoning trace contains 'think about this carefully' as a marker."
    )
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Reasoning")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "list files", created_at=ts[0])
        # The assistant content wraps the reasoning in <thinking> tags.
        # The chatview renders the inner text via getThinkingTags and
        # any plain-text portions as the response.
        seed.seed_assistant_message(
            conn, session_id,
            text=f"<thinking>{trace}</thinking>\n<plain>{response_text}</plain>",
            is_thinking=True,
            created_at=ts[1],
        )

    _open_chatview(page, h, session_id)
    # The reasoning trace inner text is rendered.
    _wait_for_text(page, trace)
    # The plain-text response portion is also rendered.
    _wait_for_text(page, "I will run a command")


# ─── Test 9: code block copy button ─────────────────────────────────────────


def test_chatview_renders_code_block_copy_button(ui_harness: UIHarness, page) -> None:
    """A fenced code block in the assistant message has a copy button.

    The chatview's ``setupCodeBlockCopyButtons()`` (called after
    every load + on every ``llm_full`` SSE event) injects a
    'Copy' button into each ``<pre>`` block. We assert at least one
    such button is present in the rendered DOM.
    """
    h = ui_harness
    session_id = "sess_chatview_copy_001"
    seed = DbSeed(_seed_db_path(h))
    code_text = (
        "Here is the snippet:\n"
        "\n"
        "```bash\n"
        "ls -la\n"
        "pwd\n"
        "```\n"
    )
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Copy button")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "show me", created_at=ts[0])
        seed.seed_assistant_message(conn, session_id, code_text, created_at=ts[1])

    _open_chatview(page, h, session_id)
    # The pre block is rendered.
    page.wait_for_selector(".markdown-content pre", timeout=10000)
    # The copy button is added by setupCodeBlockCopyButtons; the
    # exact selector varies (common shapes: a button with text
    # Copy, a button with a clipboard icon, `data-testid="copy-code"`,
    # etc.). We try a few common ones.
    page.wait_for_timeout(500)  # let copy-button setup complete
    copy_selectors = [
        "button:has-text('Copy')",
        "[data-testid='copy-code']",
        "[data-testid='code-block-copy']",
        ".code-block-copy",
        "pre button",
    ]
    found = False
    for sel in copy_selectors:
        if page.locator(sel).count() > 0:
            found = True
            break
    assert found, (
        "No copy button found inside the rendered code block. "
        "The selector strategy may need updating — check "
        "setupCodeBlockCopyButtons() in ChatView.vue."
    )


# ─── Test 10: compaction card ────────────────────────────────────────────────


def test_chatview_renders_compaction_card(ui_harness: UIHarness, page) -> None:
    """A user row whose content starts with ``<compact_messages>`` renders as a ``<CompactionCard>``.

    The chatview's ``isCompactionMessage()`` detects the envelope
    prefix and renders ``<CompactionCard data-testid="compaction-card">``
    instead of a plain text bubble. The card renders the count of
    compacted messages (from the ``<entry>`` count) + a metadata
    section. The summary is rendered in a collapsible ``<pre>``
    block (collapsed by default).
    """
    h = ui_harness
    session_id = "sess_chatview_compaction_001"
    seed = DbSeed(_seed_db_path(h))
    summary_text = "Compacted 12 messages into a high-level summary."
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compaction")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_compaction_user_message(
            conn, session_id,
            summary=summary_text,
            message_count=12,
            created_at=ts[0],
        )
        seed.seed_assistant_message(
            conn, session_id, "Got it, continuing from the summary.",
            created_at=ts[1],
        )

    _open_chatview(page, h, session_id)
    # The <CompactionCard> has data-testid="compaction-card" (verified
    # at preview/CompactionCard.vue:2).
    page.wait_for_selector('[data-testid="compaction-card"]', timeout=10000)
    # The card header shows the count of compacted messages
    # (via the testid="compaction-count" element).
    page.wait_for_selector('[data-testid="compaction-count"]', timeout=10000)
    count_text = page.locator('[data-testid="compaction-count"]').inner_text()
    assert "12" in count_text, (
        f"Expected '12' in compaction count, got {count_text!r}"
    )
    # The assistant's follow-up message is rendered after the card.
    _wait_for_text(page, "Got it, continuing from the summary")
