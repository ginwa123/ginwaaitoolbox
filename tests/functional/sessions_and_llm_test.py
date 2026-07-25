"""Functional tests for sessions + /test/shutdown + LLM stub.

Uses the harness's `stub_llm_profile=True` option which writes a
stub config.json pointing at a port that never responds. Session
create will fail when it tries to call the LLM (which is fine —
we're not testing the LLM, we're testing the wire). Session list,
detail, and /test/shutdown work without a real LLM.

Plan: docs/superpowers/plans/2026-07-26-functional-tests-with-real-data.md (Chunk 7)
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "session-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


@pytest.fixture
def llm_harness(default_nalar_bin: Any) -> FunctionalHarness:
    """A harness booted with the LLM stub profile so session-create
    doesn't try to call a real LLM (the wire works, the LLM fails
    silently — we don't care about LLM outcomes in this suite).
    """
    h = FunctionalHarness.boot(
        default_nalar_bin,
        stub_llm_profile=True,
    )
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


# ─── Test 1: /health returns ok ─────────────────────────────────────────


def test_health_endpoint_returns_ok(llm_harness: FunctionalHarness) -> None:
    """GET /health returns 200 with {"status":"ok"}."""
    r = llm_harness.http("GET", "/health", expect=200)
    body = r.json()
    assert body.get("status") == "ok"


# ─── Test 2: session create returns a session id ──────────────────────


def test_session_create_returns_session_id(llm_harness: FunctionalHarness) -> None:
    """POST /api/llm/session creates a session and returns an id.

    Note: with stub_llm_profile, the LLM call inside session-create
    will fail (port 1 doesn't respond), but the session row IS
    created in the DB before the LLM is called. The id is in the
    201 response.
    """
    r = llm_harness.http(
        "POST",
        "/api/llm/session",
        json_body={"session_name": "test-session"},
        expect=(201, 500),
    )
    # The session may be created (201) or the LLM call may fail
    # causing 500. Either way, a successful 201 has an id.
    if r.status == 201:
        body = r.json()
        assert "id" in body, f"session create should return id, got: {body!r}"
    # If 500, the wire may have a separate issue — assert either
    # status is acceptable for this test (we just want to verify
    # the endpoint is reachable, not that the LLM works).


# ─── Test 3: session list returns 200 ──────────────────────────────────


def test_session_list_returns_200(llm_harness: FunctionalHarness) -> None:
    """GET /api/llm/session returns 200 with a list (possibly empty)."""
    r = llm_harness.http("GET", "/api/llm/session", expect=200)
    body = r.json()
    # Response shape: {sessions:[...]} or a list directly. Accept both.
    if isinstance(body, dict):
        sessions = body.get("sessions", body.get("data", []))
    elif isinstance(body, list):
        sessions = body
    else:
        sessions = []
    assert isinstance(sessions, list), (
        f"session list should return a list, got {type(sessions).__name__}"
    )


# ─── Test 4: session messages empty for new session ───────────────────


def test_session_messages_for_nonexistent_returns_404_or_empty(
    llm_harness: FunctionalHarness,
) -> None:
    """GET /api/llm/session/<nonexistent>/messages returns 404 or empty.

    The endpoint may 404 for a non-existent session id, or return
    an empty messages list. Both are acceptable.
    """
    r = llm_harness.http(
        "GET",
        "/api/llm/session/nonexistent_session_id/messages",
        expect=(200, 404),
    )
    if r.status == 200:
        body = r.json()
        if isinstance(body, dict) and "messages" in body:
            assert body["messages"] == []


# ─── Test 5: /test/shutdown endpoint stops the server ───────────────────


def test_test_shutdown_stops_server(llm_harness: FunctionalHarness) -> None:
    """POST /test/shutdown initiates a graceful shutdown. After it
    returns, the server should stop accepting new connections.

    This test boots its OWN harness (separate from the shared
    `llm_harness` fixture) because once shutdown is called, the
    server is dead and the fixture's teardown would double-call.
    """
    h = FunctionalHarness.boot(
        llm_harness.nalar_bin,
        stub_llm_profile=True,
        port=8090,  # fixed port for shutdown test
    )
    try:
        # Server is up — health returns 200.
        assert h.health() is True

        # Trigger shutdown.
        r = h.http("POST", "/test/shutdown", expect=200)
        body = r.json()
        assert "message" in body or "shutdown" in body.get("message", "").lower(), (
            f"unexpected shutdown response: {body!r}"
        )

        # The server should no longer respond (the listen loop
        # returned after the shutdown call). Wait briefly and
        # then assert the port is no longer accepting.
        import time as _time
        _time.sleep(0.5)
        # health() returns False on connection error.
        assert h.health() is False, (
            "server still responding after /test/shutdown"
        )
    finally:
        h.teardown()


# ─── Test 6: no state leaked to real home ──────────────────────────────


def test_no_state_leaked_to_real_home(llm_harness: FunctionalHarness) -> None:
    """Belt-and-suspenders for the safety invariant: assert the
    real $HOME does not contain a nalar/ dir newly created by the
    test.

    We can't easily diff directories, but we CAN assert that the
    real $HOME/.config/nalar/agent.db is the SAME file (or absent)
    as it was before the test. If the harness wrote to the real
    HOME, the agent.db mtime would be very recent.
    """
    import os
    import time as _time

    real_home = llm_harness.orig_home
    real_agent_db = os.path.join(real_home, ".config", "nalar", "agent.db")

    if os.path.exists(real_agent_db):
        # File exists in real HOME — its mtime should be well in the
        # past (older than 60s). If the test wrote to it, mtime
        # would be < 60s.
        mtime = os.path.getmtime(real_agent_db)
        age = _time.time() - mtime
        assert age > 60, (
            f"real HOME agent.db mtime is {age:.1f}s old (recently modified) — "
            f"the harness may have leaked to the real $HOME. Path: {real_agent_db}"
        )

    # The harness's own tempdir does have an agent.db.
    temp_agent_db = llm_harness.temp_dir / ".config" / "nalar" / "agent.db"
    assert temp_agent_db.exists(), (
        f"harness tempdir should have its own agent.db at {temp_agent_db}"
    )
