"""Functional contract: session metadata must NOT require the messages endpoint.

Screenshot (task_1791399426983_3): opening a chat fired 3 requests against
the messages endpoint — 2x ``messages?limit=1`` (~194 kB each, ~4 s each)
plus the real transcript fetch. The two ``limit=1`` calls were metadata
reads in disguise:

* ``AppLayout.fetchChatSessionCwd`` -> ``getSession()`` (session cwd)
* ``ChatView.onSessionChanged`` -> ``getSession()`` (profile selection)

both fired concurrently on mount for the SAME session. ``getSession()``
used ``GET .../messages?limit=1``, whose backend defaults (``sort_by=
created_at&direction=asc``) return the OLDEST message — one row carrying
full tool JSON / base64 that routinely weighs ~194 kB. The session fields
(cwd, profile) piggybacked on that payload.

The fix points ``getSession()`` at the lightweight
``GET /api/llm/session/:session_id`` detail endpoint (sessions row only,
no message JOIN). This test pins the wire contract the frontend now
depends on:

1. The detail endpoint returns every metadata field ``getSession()``
   reads (cwd, name, selected_profile_model, sub_agent_name,
   parent_session_id, git_worktree_cwd, pr_url, pr_provider) with NO
   ``messages`` key — so the response stays ~1 kB, not ~194 kB.
2. It works for a ZERO-message session (the case where the old
   ``messages?limit=1`` JOIN yielded no rows and AppLayout fired a
   second ``getChatHistory(_, 1)`` fallback — the duplicate).
3. Positive control: a profile persisted via PUT is echoed back, proving
   the profile chip's read path.

Port selection is the harness's (never 8081).
"""

from __future__ import annotations

import sqlite3
from typing import Any

from harness import FunctionalHarness

SESSION_ID = "sess_detail_metadata_1"


def _put_session(harness: FunctionalHarness, body: dict[str, Any]) -> None:
    harness.http(
        "PUT",
        f"/api/llm/session/{SESSION_ID}",
        json_body=body,
        expect=200,
    )


def test_session_detail_returns_metadata_without_messages_payload(
    default_pabrik_bin: Any,
) -> None:
    """Detail endpoint carries all getSession() fields, no messages key."""
    harness = FunctionalHarness.boot(default_pabrik_bin)
    try:
        _put_session(
            harness,
            {"name": "detail-contract-chat", "selected_profile_model": "900ribu"},
        )

        r = harness.http("GET", f"/api/llm/session/{SESSION_ID}", expect=200)
        data = r.json()

        # Every field the frontend's getSession() maps.
        assert data["session_id"] == SESSION_ID
        assert data["name"] == "detail-contract-chat"
        assert data["selected_profile_model"] == "900ribu"
        for key in (
            "cwd",
            "created_at",
            "git_worktree_cwd",
            "pr_url",
            "pr_provider",
            "sub_agent_name",
            "parent_session_id",
        ):
            assert key in data, f"detail response missing {key!r}: {sorted(data)}"

        # The whole point: no message payload rides along.
        assert "messages" not in data, (
            f"detail endpoint must not embed messages: {sorted(data)}"
        )
        assert len(r.body) < 4096, (
            f"detail response should be ~1 kB, got {len(r.body)} bytes"
        )
    finally:
        try:
            harness.teardown()
        except Exception:
            pass


def test_session_detail_works_with_zero_messages(
    default_pabrik_bin: Any,
) -> None:
    """Zero-message session: detail has the row, messages?limit=1 has none.

    This is the case that used to fire AppLayout's getChatHistory(_, 1)
    fallback (call #2 in the screenshot): the messages JOIN yields no rows
    for a fresh session, so the metadata read came back empty and the
    caller fetched the same endpoint again. The detail endpoint reads the
    sessions row directly, so no fallback is ever needed.
    """
    harness = FunctionalHarness.boot(default_pabrik_bin)
    try:
        _put_session(harness, {"name": "fresh-no-messages-yet"})

        detail = harness.http("GET", f"/api/llm/session/{SESSION_ID}", expect=200).json()
        assert detail["name"] == "fresh-no-messages-yet"

        msgs = harness.http(
            "GET",
            f"/api/llm/session/{SESSION_ID}/messages",
            params={"limit": "1"},
            expect=200,
        ).json()
        assert msgs["messages"] == [], (
            "fresh session must have no message rows for the old path to read"
        )
    finally:
        try:
            harness.teardown()
        except Exception:
            pass


def test_old_limit1_path_carries_message_weight_detail_does_not(
    default_pabrik_bin: Any,
) -> None:
    """Reproduce the screenshot: limit=1 returns ~194 kB, detail stays ~1 kB.

    Seeds one 200 kB message row (tool JSON / base64 ballast, like the
    oldest message in the screenshot's session), then fetches both the old
    metadata path (``messages?limit=1``) and the new one (detail endpoint).
    The old path drags the full message; the new path is unaffected.
    """
    harness = FunctionalHarness.boot(default_pabrik_bin)
    try:
        _put_session(harness, {"name": "heavy-oldest-message"})

        db_path = harness.temp_dir / ".config" / "pabrik" / "agent.db"
        conn = sqlite3.connect(str(db_path))
        try:
            conn.execute(
                "INSERT INTO llm_history (id, session_id, model, role, response_content)"
                " VALUES (?, ?, 'stub-model', 'user', ?)",
                (f"{SESSION_ID}-m1", SESSION_ID, "x" * 200_000),
            )
            conn.commit()
        finally:
            conn.close()

        old = harness.http(
            "GET",
            f"/api/llm/session/{SESSION_ID}/messages",
            params={"limit": "1"},
            expect=200,
        )
        assert len(old.body) > 100_000, (
            f"expected the old limit=1 path to drag the message weight, "
            f"got {len(old.body)} bytes"
        )

        new = harness.http("GET", f"/api/llm/session/{SESSION_ID}", expect=200)
        assert "messages" not in new.json()
        assert len(new.body) < 4096, (
            f"detail must stay small with a heavy message present, "
            f"got {len(new.body)} bytes"
        )
        assert len(new.body) * 25 < len(old.body), (
            f"detail ({len(new.body)} B) should be an order of magnitude "
            f"smaller than limit=1 ({len(old.body)} B)"
        )
    finally:
        try:
            harness.teardown()
        except Exception:
            pass
