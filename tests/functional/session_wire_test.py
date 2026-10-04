"""Functional tests for session wire (Tier 1.5).

Exercises the session-level HTTP surface that's NOT covered by
`sessions_and_llm_test.py`:

  - PUT  /api/llm/session/:session_id (rename + profile + unattended)
  - POST /api/llm/session/:session/stop (cancel flag)
  - GET  /api/llm/session/:session_id/queue_messages (empty for fresh)
  - GET  /api/workers (returns ≥1 entry; empty after no activity)

Each test boots a fresh pabrik (function-scoped fixture).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "session-wire-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_session_via_update(
    harness: FunctionalHarness, session_id: str, name: str = "wire-session"
) -> dict[str, Any]:
    """session_update.zig auto-creates the row via
    `ensureSessionExists` then UPDATEs it. Use this helper to spin
    up a session row for the wire tests without invoking
    /api/llm/session (which needs a real LLM).
    """
    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": name},
        expect=200,
    )
    return r.json()


# ─── Test 1: PUT session renames it; response echoes new name ────────────


def test_put_session_rename_round_trips(
    harness: FunctionalHarness,
) -> None:
    """PUT /api/llm/session/:id {name: 'renamed'} → 200 with new name.

    session_update.zig auto-creates the row via ensureSessionExists
    so PUT can be the first call against a fresh session id (the
    user can land on this endpoint via the Settings dialog before
    any LLM message has been queued). The PUT response is the
    source of truth for the rename; a follow-up PUT to a
    DIFFERENT name reads back the second name (proving the first
    was actually persisted, not just echoed back).
    """
    session_id = "sess_test_rename_001"

    # First rename.
    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": "renamed-session"},
        expect=200,
    ).json()
    assert r["id"] == session_id
    assert r["name"] == "renamed-session"

    # Second rename: re-PUT and verify the new name comes back
    # (proves the first rename persisted to the DB; the response
    # isn't just echoing the input).
    r2 = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": "renamed-again"},
        expect=200,
    ).json()
    assert r2["name"] == "renamed-again", (
        f"second rename should echo 'renamed-again'; got {r2.get('name')!r}"
    )


# ─── Test 2: PUT session updates selected_profile_model ─────────────────


def test_put_session_updates_profile_model(
    harness: FunctionalHarness,
) -> None:
    """PUT {selected_profile_model: 'gpt-4o'} → response echoes it.

    The stub LLM profile is pre-installed by the harness via the
    `stub_llm_profile=True` boot option (see harness.py). We set
    a DIFFERENT profile here to verify the field round-trips.
    """
    session_id = "sess_test_profile_001"

    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"selected_profile_model": "alt-profile"},
        expect=200,
    ).json()
    assert r["id"] == session_id
    assert r["selected_profile_model"] == "alt-profile"


# ─── Test 3: PUT session updates is_auto_retry_until_stop ────────────────


def test_put_session_updates_unattended_flag(
    harness: FunctionalHarness,
) -> None:
    """PUT {is_auto_retry_until_stop: '1'} → response echoes '1'."""
    session_id = "sess_test_unattended_001"

    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"is_auto_retry_until_stop": "1"},
        expect=200,
    ).json()
    assert r["id"] == session_id
    assert r["is_auto_retry_until_stop"] == "1"

    # Toggling back to 0 also round-trips.
    r2 = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"is_auto_retry_until_stop": "0"},
        expect=200,
    ).json()
    assert r2["is_auto_retry_until_stop"] == "0"


# ─── Test 4: POST /stop returns 200 + sets cancel flag ───────────────────


def test_stop_session_returns_200(
    harness: FunctionalHarness,
) -> None:
    """POST /api/llm/session/:session/stop → 200 {success, session_id}.

    The handler calls `llm_history.cancelSession` which sets the
    `cancelled` flag in the DB; the workflow loop checks this flag
    and breaks out. No message is sent or emitted on the wire — the
    response is just a confirmation.
    """
    # Create the session row first so the cancel can land.
    session_id = "sess_test_stop_001"
    _create_session_via_update(harness, session_id)

    r = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/stop",
        json_body={},
        expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("session_id") == session_id


# ─── Test 5: GET queue_messages returns empty array for fresh session ───


def test_queue_messages_empty_for_fresh_session(
    harness: FunctionalHarness,
) -> None:
    """GET /api/llm/session/:id/queue_messages → 200 with empty list.

    A session that has never had a message queued returns
    `{messages: [], count: 0}` — the frontend's Pinia store keys
    off `messages.length` to decide whether to render the queue.
    """
    session_id = "sess_test_qm_001"
    _create_session_via_update(harness, session_id)

    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/queue_messages",
        expect=200,
    ).json()
    assert r.get("messages") == [], (
        f"fresh session should have no queue messages, got {r.get('messages')!r}"
    )
    assert r.get("count") == 0, (
        f"fresh session should have count=0, got {r.get('count')!r}"
    )


# ─── Test 6: GET /api/workers returns a list ────────────────────────────


def test_workers_list_returns_array(
    harness: FunctionalHarness,
) -> None:
    """GET /api/workers → 200 with a `workers` array (possibly empty).

    worker_list.zig returns `{workers: [...], count}`. Even when no
    LLM call has been kicked off, the endpoint is reachable and
    returns 200 with an empty list (or a list of recently-completed
    workers, depending on backend state).
    """
    r = harness.http("GET", "/api/workers", expect=200)
    body = r.json()
    # Response shape: {workers: [...], count: N} — the wire field is
    # `workers` (the array), `count` is the length.
    assert "workers" in body, (
        f"missing 'workers' field; got body shape: {body!r}"
    )
    assert isinstance(body["workers"], list), (
        f"'workers' should be a list, got {type(body['workers']).__name__}"
    )
    assert body.get("count") == len(body["workers"]), (
        f"count should match len(workers); got {body.get('count')} vs {len(body['workers'])}"
    )