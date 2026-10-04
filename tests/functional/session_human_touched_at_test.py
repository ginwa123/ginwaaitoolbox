"""Functional tests for Migration 082 — `sessions.last_human_touched_at_nano`.

Exercises the chat-side human-touched stamp from the HTTP wire +
direct DB inspection. Five cases:

  1. PUT session_update stamps `last_human_touched_at_nano` (the
     column is populated post-PUT).
  2. The GET /api/llm/session list response includes the wire field
     `last_human_touched_at` as a SQLite datetime UTC string
     (SELECT-layer conversion via strftime()).
  3. A legacy session (created before Migration 082 ran, OR
     inserted via raw SQL bypassing the migration) returns
     `last_human_touched_at: ""` and the SELECT falls back to
     `updated_at` on the frontend.
  4. GET /api/llm/session (list) includes the new field for every
     session.
  5. Subsequent PUTs overwrite the stamp (most-recent-wins).

Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
Task 9.
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_session_via_update(
    harness: FunctionalHarness, session_id: str, name: str = "human-touched-session"
) -> dict[str, Any]:
    """session_update.zig auto-creates the row via `ensureSessionExists`
    then UPDATEs it. Use this helper to spin up a session row for the
    stamp tests without invoking /api/llm/session (which needs a real LLM).
    """
    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": name},
        expect=200,
    )
    return r.json()


def _select_human_touched(harness: FunctionalHarness, session_id: str) -> str | None:
    """Read the raw column directly from the SQLite DB (bypassing the
    SELECT-layer conversion). Returns the unix-ms integer string, or
    None when the column is NULL (pre-Migration-082 or never touched).
    """
    db_path = Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"
    # Migrate to the latest schema first so we know Migration 082 ran.
    # (boot() runs migrations, but a direct sqlite3 connect can race
    # with pabrik's open handle - WAL mode makes that safe.)
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        cur = conn.execute(
            "SELECT last_human_touched_at_nano FROM sessions WHERE id = ?",
            (session_id,),
        )
        row = cur.fetchone()
        if row is None:
            return None
        val = row[0]
        return None if val is None else str(val)
    finally:
        conn.close()


def _find_session_in_list(
    harness: FunctionalHarness, session_id: str
) -> dict[str, Any]:
    """Read the GET /api/llm/session list and return the single matching
    session entry (raises if 0 or >1 match). The list endpoint is the
    only GET shape pabrik exposes (no single-GET /api/llm/session/:id).
    """
    r = harness.http("GET", "/api/llm/session?limit=100", expect=200).json()
    sessions = r["sessions"]
    matches = [s for s in sessions if s["session_id"] == session_id]
    assert len(matches) == 1, (
        f"expected exactly 1 match for {session_id!r}, found {len(matches)}"
    )
    return matches[0]


# ─── Test 1: PUT stamps the column ─────────────────────────────────────────


def test_put_session_stamps_last_human_touched_at_nano(
    harness: FunctionalHarness,
) -> None:
    """PUT /api/llm/session/:session_id (any field) bumps the
    sessions.last_human_touched_at_nano column. Task 4 invariant.
    """
    session_id = "sess_human_touched_put_001"

    # Insert a row directly with NULL stamp (bypasses the helper which
    # always triggers a stamp via the PUT path - we need a NULL column
    # as the baseline to assert "PUT bumps it").
    db_path = Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"
    conn = sqlite3.connect(f"file:{db_path}?mode=rw", uri=True)
    try:
        conn.execute(
            "INSERT INTO sessions (id, name, status) VALUES (?, ?, 'active')",
            (session_id, "Baseline row"),
        )
        conn.commit()
    finally:
        conn.close()
    assert _select_human_touched(harness, session_id) is None

    # First PUT sets the stamp (any field triggers it - the handler
    # stamps AFTER applying the update, so even a no-op body works).
    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": "renamed"},
        expect=200,
    )
    first_stamp = _select_human_touched(harness, session_id)
    assert first_stamp is not None, "PUT should stamp last_human_touched_at_nano"
    # unix-ms integer string: 10+ digits.
    assert first_stamp.isdigit() and len(first_stamp) >= 10, (
        f"stamp should be unix-ms integer string, got {first_stamp!r}"
    )


# ─── Test 2: GET surfaces the wire field as SQLite datetime UTC ──────────


def test_get_session_returns_last_human_touched_as_sqlite_datetime(
    harness: FunctionalHarness,
) -> None:
    """GET /api/llm/session (the list endpoint - pabrik has no single-GET
    `/api/llm/session/:id` route) returns last_human_touched_at
    in the SELECT-layer-converted wire shape: SQLite datetime UTC
    ('YYYY-MM-DD HH:MM:SS'), NOT raw unix-ms. The frontend's
    `formatRelativeTime` helper only parses the datetime shape.
    """
    session_id = "sess_human_touched_get_001"
    _create_session_via_update(harness, session_id)
    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": "stamped"},
        expect=200,
    )

    session = _find_session_in_list(harness, session_id)
    human = session["last_human_touched_at"]

    # Wire shape: exactly 19 chars ('YYYY-MM-DD HH:MM:SS').
    assert isinstance(human, str), f"expected string, got {type(human).__name__}"
    assert len(human) == 19, f"expected 19 chars, got {len(human)}: {human!r}"
    # Format: digits + hyphens + space + colon separators, no unix-ms digits.
    assert human[4] == "-" and human[7] == "-" and human[10] == " " and human[13] == ":" and human[16] == ":"
    # Not the raw unix-ms integer (which would be a long string of digits).
    assert not human.isdigit(), (
        f"wire field should be SQLite datetime, not raw unix-ms: {human!r}"
    )


# ─── Test 3: legacy NULL rows return empty string on the wire ────────────


def test_get_session_returns_empty_when_last_human_touched_never_stamped(
    harness: FunctionalHarness,
) -> None:
    """A legacy row (column is NULL because the row existed before
    Migration 082 ran, or was created via raw SQL bypassing the
    migration) returns `last_human_touched_at: ""` on the wire.

    The frontend `ChatsList.vue` treats empty string as a defined
    fallback to `updated_at` (the same `?? updated_at` shape, just
    a string-coerce check on the field).
    """
    session_id = "sess_legacy_null_001"

    # Insert a row with NULL stamp directly via SQL (bypasses the
    # helper which always triggers a stamp). Note: the bare INSERT
    # gives the column DEFAULT (NULL per Migration 082).
    db_path = Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"
    conn = sqlite3.connect(f"file:{db_path}?mode=rw", uri=True)
    try:
        conn.execute(
            "INSERT INTO sessions (id, name, status) VALUES (?, ?, 'active')",
            (session_id, "Legacy NULL row"),
        )
        conn.commit()
    finally:
        conn.close()

    session = _find_session_in_list(harness, session_id)
    # Wire field is "" (empty string) for NULL column - the SELECT-layer
    # uses `CASE WHEN ... IS NULL ... THEN ''` so the JSON serializer
    # emits a JSON empty string (not null). The frontend `ChatsList.vue`
    # treats `''` as falsy and falls back to `updated_at`.
    assert session["last_human_touched_at"] == "", (
        f"expected empty string for legacy row, got "
        f"{session['last_human_touched_at']!r}"
    )


# ─── Test 4: GET /api/llm/session (list) includes the new field ──────────


def test_list_sessions_includes_last_human_touched(
    harness: FunctionalHarness,
) -> None:
    """GET /api/llm/session (the list endpoint) returns last_human_touched_at
    on every session. Same SELECT-layer conversion as the single-GET
    path, so the wire shape is consistent across endpoints.
    """
    session_id = "sess_human_touched_list_001"
    _create_session_via_update(harness, session_id)
    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": "stamped-for-list"},
        expect=200,
    )

    r = harness.http("GET", "/api/llm/session?limit=50", expect=200).json()
    sessions = r["sessions"]
    assert isinstance(sessions, list)
    matching = [s for s in sessions if s["session_id"] == session_id]
    assert len(matching) == 1, f"expected 1 match, found {len(matching)}"
    session = matching[0]
    # Field is present (even if value is null/empty for legacy rows).
    assert "last_human_touched_at" in session, (
        "list endpoint must include last_human_touched_at on every session"
    )
    # For our stamped session, the value is the wire datetime string.
    assert isinstance(session["last_human_touched_at"], str)
    assert len(session["last_human_touched_at"]) == 19


# ─── Test 5: subsequent PUTs overwrite (most-recent-wins) ─────────────────


def test_subsequent_puts_overwrite_last_human_touched(
    harness: FunctionalHarness,
) -> None:
    """A second PUT bumps the stamp forward - the helper is idempotent
    but always overwrites with `now_unix_ms` (null arg). Plan D1.
    """
    session_id = "sess_overwrite_stamp_001"
    _create_session_via_update(harness, session_id)
    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": "first"},
        expect=200,
    )
    first_stamp = _select_human_touched(harness, session_id)
    assert first_stamp is not None

    # Brief sleep so the second timestamp is strictly greater
    # (unix-ms resolution, so even 1ms is enough on most systems).
    import time
    time.sleep(0.05)

    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": "second"},
        expect=200,
    )
    second_stamp = _select_human_touched(harness, session_id)
    assert second_stamp is not None
    assert int(second_stamp) > int(first_stamp), (
        f"second stamp {second_stamp} should be > first stamp {first_stamp}"
    )