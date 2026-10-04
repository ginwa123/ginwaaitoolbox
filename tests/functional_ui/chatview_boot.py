"""Shared chatview boot helpers — the workspace-scoped deep link contract.

Why this module exists
----------------------
Plan ``2026-09-22-revamp-ui-chats`` (commit ``6b0d2b36``, 2026-09-23) moved
the app from ``?view=chat&session=<id>`` query URLs to path URLs and made
``AppLayout.bootLegacyChat`` **fail closed**: a legacy chat URL is only
rewritten to ``/app/<workspaceId>/chat/<sessionId>`` when
``GET /api/llm/session/:id`` resolves an owning ``workspace_id``. An
unresolvable session redirects to ``/app`` and the app renders the
"Create a workspace" landing instead of ``<ChatView>``.

The chatview UI tests predate that change and seeded a bare ``sessions``
row with no ``workspace_id``, so every one of them booted the landing page
and timed out waiting for message text — deterministically, on every
machine, in CI and locally alike. Three helpers live here so the
migration is one import per test file instead of a hand-copied block that
drifts again on the next routing change:

1. ``create_workspace`` — mint a real workspace through the backend API
   (workspaces are files on disk, not rows, so they cannot be seeded
   straight into SQLite the way sessions are).
2. ``bind_session_workspace`` — point the seeded ``sessions`` row at that
   workspace so the session-detail endpoint agrees with the deep link.
3. ``open_chatview`` — navigate the canonical path URL, which
   ``parseAppPath`` classifies as ``kind: 'chat'`` and ``handleBootUrl``
   adopts synchronously.

``chatview_slow_server_empty_state_ui_test.py`` and
``chatview_send_scrolls_to_bottom_ui_test.py`` already carried private
copies of this trio; they now import from here.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from ui_harness import UIHarness

__all__ = [
    "bind_session_workspace",
    "create_workspace",
    "open_chatview",
    "seed_db_path",
]


def seed_db_path(h: UIHarness) -> Path:
    """Path to the harness's isolated ``agent.db``.

    The harness's tempdir passed ``is_safe_tmp`` validation before boot;
    ``DbSeed`` re-validates as belt-and-suspenders.
    """
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def create_workspace(h: UIHarness, name: str = "ui-chat-ws") -> str:
    """Create a workspace via the backend API and return its id.

    Workspaces are directory entries under the harness's isolated
    ``HOME``, so the HTTP API is the only way to mint one; a SQLite
    INSERT would leave ``initializeFromSystemFolder`` with nothing to
    load. Same shape as ``kanban_lifecycle_ui_test.py``.
    """
    r: Any = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return str(r.json()["id"])


def bind_session_workspace(
    conn: sqlite3.Connection, workspace_id: str, session_id: str
) -> None:
    """Attach ``session_id`` to ``workspace_id`` inside an open seed tx.

    The deep link already names the workspace, but ``sessions.workspace_id``
    is what ``GET /api/llm/session/:id`` reads, so a reload or a
    legacy-URL visit must resolve the same workspace instead of bouncing
    to ``/app``.
    """
    conn.execute(
        "UPDATE sessions SET workspace_id = ? WHERE id = ?",
        (workspace_id, session_id),
    )


def open_chatview(
    page,
    h: UIHarness,
    workspace_id: str,
    session_id: str,
    timeout_ms: int = 30000,
) -> None:
    """Navigate to the canonical chat deep link and wait for ``load``.

    ``/app/<workspaceId>/chat/<sessionId>`` is what ``parseAppPath``
    classifies as ``kind: 'chat'``, so ``AppLayout.handleBootUrl`` adopts
    the chat synchronously and stays on the URL. The legacy
    ``?view=chat&session=`` shape needs a session-detail round-trip and
    fails closed when it cannot resolve a workspace, which silently
    renders the workspace landing page instead.
    """
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=timeout_ms,
    )
