"""POST /api/llm/session/:id/touched — mark-as-seen clears the amber stale dot.

Replays the exact wire the sidebar sends on click:
  POST /api/llm/session/:session_id/touched  body {}

Cases:
  1. touched returns 200 {success:true} and stamps the column.
  2. GET list shows last_human_touched_at as SQLite datetime (dot clears:
     updated_at <= last_human_touched_at).
  3. Empty session_id -> 400 (route with empty id can't match, so test the
     dual /api/session alias instead for parity).
  4. Dual-route parity: POST /api/session/:id/touched also 200.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from harness import FunctionalHarness


def _db_val(harness: FunctionalHarness, session_id: str) -> str | None:
    db_path = Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        row = conn.execute(
            "SELECT last_human_touched_at_nano FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        if row is None:
            return None
        return None if row[0] is None else str(row[0])
    finally:
        conn.close()


def _find_in_list(harness: FunctionalHarness, session_id: str) -> dict[str, Any]:
    r = harness.http("GET", "/api/llm/session", expect=200)
    sessions = r.json().get("sessions", [])
    matches = [s for s in sessions if s.get("session_id") == session_id]
    assert len(matches) == 1, f"expected 1 match for {session_id}, got {len(matches)}"
    return matches[0]


def test_touched_stamps_column(harness: FunctionalHarness):
    sid = "sess_touch_1"
    # Ensure row exists via existing PUT (auto-creates).
    harness.http("PUT", f"/api/llm/session/{sid}", json_body={"name": "touch me"}, expect=200)
    r = harness.http("POST", f"/api/llm/session/{sid}/touched", json_body={}, expect=200)
    body = r.json()
    assert body.get("success") is True
    assert body.get("session_id") == sid
    assert _db_val(harness, sid) is not None


def test_touched_clears_stale_dot(harness: FunctionalHarness):
    sid = "sess_touch_2"
    harness.http("PUT", f"/api/llm/session/{sid}", json_body={"name": "dot clear"}, expect=200)
    harness.http("POST", f"/api/llm/session/{sid}/touched", json_body={}, expect=200)
    entry = _find_in_list(harness, sid)
    human = entry.get("last_human_touched_at") or ""
    updated = entry.get("updated_at") or ""
    assert human != "", "touched must populate wire field"
    # Dot condition is updated > human; after touch, human is now so dot clears.
    assert not (updated > human), f"dot should clear: updated={updated} human={human}"


def test_touched_dual_route_parity(harness: FunctionalHarness):
    sid = "sess_touch_3"
    harness.http("PUT", f"/api/session/{sid}", json_body={"name": "parity"}, expect=200)
    r = harness.http("POST", f"/api/session/{sid}/touched", json_body={}, expect=200)
    assert r.json().get("success") is True
    assert _db_val(harness, sid) is not None
