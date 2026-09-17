"""Functional UI tests for the right-sidebar terminal.

Drives a real headless Chromium against a real backend (isolated
tmpdir HOME, random ports — never :8081) and verifies the full
stack: ChatView -> ChatRightSidebar -> TerminalTab (xterm) ->
POST /api/terminal/sessions -> PTY -> WS frames -> canvas.

xterm renders to <canvas> (no DOM text), so output assertions read
the live buffer through the dev-only ``window.__nalarTerm`` hook
(see TerminalTab.vue). The hook exists only under Vite dev
(``import.meta.env.DEV``), which is what the UI harness serves.

1. ``test_sidebar_terminal_runs_command`` — open the sidebar,
   switch to the Terminal tab, type ``echo <MARK>``, and see MARK
   come back through the real PTY + socket.
2. ``test_sidebar_terminal_multi_session`` — open a second session,
   run a marker there, switch back: the first marker is visible
   again (attach-flush scrollback restore, no cross-talk).

Run:
    NALAR_BIN=./zig-out/bin/nalarcore-linux-x86_64 \
      /tmp/term_venv/bin/python -m pytest \
      tests/functional_ui/terminal_sidebar_ui_test.py -v -s
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from ui_harness import UIHarness

#: JS predicate for page.wait_for_function: true once the xterm buffer
#: (last 300 lines) contains the marker passed as arg.
BUFFER_HAS_MARKER_JS = """(marker) => {
  const t = window.__nalarTerm;
  if (!t) return false;
  const b = t.buffer.active;
  let out = '';
  const n = b.length;
  for (let y = Math.max(0, n - 300); y < n; y++) {
    const line = b.getLine(y);
    if (line) out += line.translateToString(true);
  }
  return out.includes(marker);
}"""


def _create_session(h: UIHarness, name: str, cwd: str) -> str:
    r = h.http(
        "POST",
        "/api/llm/session",
        json_body={"name": name, "cwd_session": cwd},
        expect=201,
    )
    return r.json()["id"]


def _collect_errors(page) -> list[str]:
    errors: list[str] = []
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
    page.on("pageerror", lambda exc: errors.append(str(exc)))
    return errors


def _print_errors(errors: list[str]) -> None:
    if errors:
        print("\n[console errors]")
        for e in errors:
            print(f"  - {e[:300]}")


def _open_chat_and_terminal(page, h: UIHarness, session_id: str) -> list[str]:
    """Navigate to a standalone ChatView and open the Terminal tab.

    Returns the console-error collector (printed by the caller).
    """
    errors = _collect_errors(page)
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="load",
        timeout=30000,
    )
    # Standalone ChatView mount signal (empty session, no header).
    page.locator("text=How can I help you?").first.wait_for(timeout=20000, state="visible")

    # Headerless layout: floating ◫ button opens the sidebar.
    page.locator('[data-testid="chat-sidebar-open"]').click()
    page.locator('[data-testid="chat-right-sidebar"]').wait_for(timeout=10000, state="visible")

    page.locator('[data-testid="chat-right-sidebar-tab-terminal"]').click()
    page.locator('[data-testid="terminal-xterm"]').wait_for(timeout=10000, state="visible")
    # First session connected: chip shows the live dot.
    page.locator('[data-testid="terminal-session-chip"]', has_text="●").first.wait_for(
        timeout=20000, state="visible"
    )
    return errors


def _type_command(page, command: str) -> None:
    """Focus the xterm canvas and type a command + Enter."""
    page.locator('[data-testid="terminal-xterm"]').click()
    page.keyboard.type(command, delay=15)
    page.keyboard.press("Enter")


def test_sidebar_terminal_runs_command(ui_harness: UIHarness, page) -> None:
    """Typing echo <MARK> in the sidebar terminal shows MARK back."""
    h = ui_harness
    cwd = Path(h.temp_dir) / "term-cwd"
    cwd.mkdir(exist_ok=True)
    session_id = _create_session(h, "ui-terminal", str(cwd))

    errors = _open_chat_and_terminal(page, h, session_id)
    marker = "UI-MARK-7d2b91"
    try:
        _type_command(page, f"echo {marker}")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=marker, timeout=25000)
    finally:
        _print_errors(errors)


def test_sidebar_terminal_multi_session(ui_harness: UIHarness, page) -> None:
    """Two sidebar sessions stay isolated; switching restores scrollback."""
    h = ui_harness
    cwd = Path(h.temp_dir) / "term-cwd-multi"
    cwd.mkdir(exist_ok=True)
    session_id = _create_session(h, "ui-terminal-multi", str(cwd))

    errors = _open_chat_and_terminal(page, h, session_id)
    try:
        marker_a = "UI-MULTI-A-3f8c"
        _type_command(page, f"echo {marker_a}")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=marker_a, timeout=25000)

        # Second session: its own marker, invisible to the first.
        page.locator('[data-testid="terminal-new"]').click()
        page.locator('[data-testid="terminal-session-chip"]', has_text="●").nth(1).wait_for(
            timeout=20000, state="visible"
        )
        marker_b = "UI-MULTI-B-91de"
        _type_command(page, f"echo {marker_b}")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=marker_b, timeout=25000)

        # Switch back: the first marker is visible again (attach flush
        # replays the session buffer into the cleared view).
        chips = page.locator('[data-testid="terminal-session-chip"]')
        assert chips.count() == 2, f"expected 2 session chips, got {chips.count()}"
        chips.first.click()
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=marker_a, timeout=25000)
    finally:
        _print_errors(errors)


def test_sidebar_terminal_persists_across_chat_switch(ui_harness: UIHarness, page) -> None:
    """Leaving the chat and coming back restores the terminal session.

    The shell keeps running server-side while the chat is closed
    (ids persist per chat in localStorage); returning re-attaches the
    socket and the attach-flush replays the scrollback, so the marker
    from before is visible again without retyping.
    """
    h = ui_harness
    cwd = Path(h.temp_dir) / "term-cwd-persist"
    cwd.mkdir(exist_ok=True)
    session_id = _create_session(h, "ui-terminal-persist", str(cwd))
    chat_url = f"/app?view=chat&session={session_id}"

    errors = _open_chat_and_terminal(page, h, session_id)
    try:
        marker = "UI-PERSIST-5a7e"
        _type_command(page, f"echo {marker}")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=marker, timeout=25000)

        # Leave the chat (sidebar + tab unmount; sessions must survive).
        page.goto(h.web_url("/app"), wait_until="load", timeout=30000)
        page.wait_for_timeout(1000)

        # Return: the marker is back without retyping.
        page.goto(h.web_url(chat_url), wait_until="load", timeout=30000)
        page.locator("text=How can I help you?").first.wait_for(timeout=20000, state="visible")
        # Sidebar open-state persists per chat type — it may already be open.
        try:
            page.locator('[data-testid="chat-sidebar-open"]').wait_for(
                timeout=3000, state="visible"
            )
            page.locator('[data-testid="chat-sidebar-open"]').click()
        except Exception:
            pass
        page.locator('[data-testid="chat-right-sidebar"]').wait_for(timeout=10000, state="visible")
        # Panel tab persists too — clicking terminal is a no-op if active.
        page.locator('[data-testid="chat-right-sidebar-tab-terminal"]').click()
        page.locator('[data-testid="terminal-xterm"]').wait_for(timeout=10000, state="visible")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=marker, timeout=25000)
    finally:
        _print_errors(errors)
