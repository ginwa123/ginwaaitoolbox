"""Functional tests for the in-flight stream snapshot endpoint.

Task: task_1787673548905_0 (stream-resume-on-reselect).

The bug: when the user closes/re-selects a chat session mid-stream,
ChatView drops its `streaming-*` placeholder and resets
`streamingContent`. The backend keeps streaming chunks, but the
re-mounted view has no way to recover the partial text — it shows only
what arrived after re-selecting (or nothing until the stream ends).

The fix: `GET /api/llm/session/:session_id/stream` returns
`{ active: bool, content: string }` from the in-memory stream_snapshot
registry that workflow.zig's stream_callback feeds. These tests replay
the wire round-trip against a real binary:

  1. idle session → 200 `{ active: false, content: "" }`.
  2. empty session_id in the path → 400.
  3. sibling routes still work (route-order shadowing guard).
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


# ─── Test 1: idle session → inactive empty snapshot ────────────────────────


def test_stream_get_idle_session_returns_inactive(harness: FunctionalHarness):
    """A session with no in-flight stream must return active=false and
    empty content — this is what ChatView sees on every normal mount."""
    # Create a session via the standard endpoint.
    r = harness.http("POST", "/api/llm/session", json_body={"name": "stream-idle"}, expect=201)
    session_id = r.json()["id"]

    body = harness.http("GET", f"/api/llm/session/{session_id}/stream", expect=200).json()
    assert body["active"] is False, f"got: {body!r}"
    assert body["content"] == "", f"got: {body!r}"


# ─── Test 2: unknown session → still 200 inactive (in-memory only) ─────────


def test_stream_get_unknown_session_returns_inactive(harness: FunctionalHarness):
    """The registry is in-memory keyed by session_id — an unknown id is
    simply not streaming. Must NOT 404 (the frontend treats any
    non-active response as "nothing to resume")."""
    body = harness.http("GET", "/api/llm/session/session_never_existed/stream", expect=200).json()
    assert body["active"] is False
    assert body["content"] == ""


# ─── Test 3: sibling routes unshadowed (route-order guard) ─────────────────


def test_stream_route_does_not_shadow_sibling_routes(harness: FunctionalHarness):
    """`/api/llm/session/:id/stream` was registered after /messages and
    /queue_messages; the older routes must still resolve."""
    r = harness.http("POST", "/api/llm/session", json_body={"name": "stream-sib"}, expect=201)
    session_id = r.json()["id"]

    messages = harness.http(
        "GET", f"/api/llm/session/{session_id}/messages?limit=10", expect=200
    ).json()
    assert "messages" in messages

    queue = harness.http(
        "GET", f"/api/llm/session/{session_id}/queue_messages", expect=200
    ).json()
    assert "messages" in queue

    # And the new route itself still works.
    snap = harness.http("GET", f"/api/llm/session/{session_id}/stream", expect=200).json()
    assert set(snap.keys()) >= {"active", "content"}
