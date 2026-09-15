"""Functional wire tests for sessions.pr_url + pr_provider (Migration 086).

Proves the column + wire passthrough the ChatView right panel will
consume for PR-changes mode (set_pull_request tool + pr/diff endpoint
land in later phases; this file pins the foundation):

  1. Fresh session messages response carries empty pr_url/pr_provider.
  2. Direct UPDATE sessions SET pr_url/pr_provider is reflected in
     the messages response — even with zero messages, via the
     handler's direct sessions-row fallback (same pattern as the
     profile-chip zero-message fix).
"""

from __future__ import annotations

import sqlite3

from harness import FunctionalHarness

PR_URL = "https://github.com/acme/app/pull/42"
PR_PROVIDER = "github"


def _create_session(harness: FunctionalHarness) -> str:
    r = harness.http(
        "POST", "/api/llm/session", json_body={"name": "pr-url-probe"}, expect=201
    )
    return r.json()["id"]


def _messages(harness: FunctionalHarness, session_id: str) -> dict:
    return harness.http(
        "GET", f"/api/llm/session/{session_id}/messages?limit=10", expect=200
    ).json()


def test_messages_response_carries_pr_defaults(
    harness: FunctionalHarness,
) -> None:
    """New session → pr_url/pr_provider empty (None on zero messages)."""
    body = _messages(harness, _create_session(harness))
    assert body.get("pr_url") in (None, ""), f"got: {body!r}"
    assert body.get("pr_provider") in (None, ""), f"got: {body!r}"


def test_direct_update_reflected_in_messages_response(
    harness: FunctionalHarness,
) -> None:
    """UPDATE sessions SET pr_url/pr_provider → messages response shows them."""
    session_id = _create_session(harness)
    db_path = harness.temp_dir / ".config" / "nalar" / "agent.db"
    conn = sqlite3.connect(str(db_path))
    try:
        conn.execute(
            "UPDATE sessions SET pr_url = ?, pr_provider = ? WHERE id = ?",
            (PR_URL, PR_PROVIDER, session_id),
        )
        conn.commit()
    finally:
        conn.close()

    body = _messages(harness, session_id)
    assert body.get("pr_url") == PR_URL, f"got: {body!r}"
    assert body.get("pr_provider") == PR_PROVIDER, f"got: {body!r}"
