"""Functional tests for SSE end-to-end.

Open an EventSource on /api/events, trigger a backend event, assert
the event arrives within 1s. The trickiest test in the suite — SSE
has backpressure, the connection must stay open across the test,
and the read loop must use a thread to avoid blocking the test.

Plan: docs/superpowers/plans/2026-07-26-functional-tests-with-real-data.md (Chunk 8)
"""

from __future__ import annotations

import json
import queue
import threading
import time
import urllib.error
import urllib.request
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _open_sse(harness: FunctionalHarness, channels: str = "kanban") -> tuple[Any, threading.Thread, queue.Queue]:
    """Open an SSE connection in a background thread. Returns
    (response, thread, events_queue). The thread reads lines from
    the response and pushes parsed events onto the queue.

    The caller MUST call .close() on the response to stop the thread.
    """
    events_q: queue.Queue = queue.Queue()
    stop_event = threading.Event()

    url = f"http://127.0.0.1:{harness.port}/api/events?channels={channels}"
    req = urllib.request.Request(url)
    # Disable urllib's default buffering — we want raw stream.
    response = urllib.request.urlopen(req, timeout=30.0)

    def reader() -> None:
        try:
            current_event: str | None = None
            current_data: list[str] = []
            for raw_line in iter(lambda: response.readline().decode("utf-8", errors="replace"), ""):
                if stop_event.is_set():
                    break
                if raw_line.startswith("event:"):
                    current_event = raw_line[len("event:"):].strip()
                elif raw_line.startswith("data:"):
                    current_data.append(raw_line[len("data:"):].strip())
                elif raw_line == "\n" or raw_line == "\r\n":
                    # Event boundary — emit if we have one.
                    if current_event is not None:
                        data_str = "\n".join(current_data)
                        try:
                            data_obj = json.loads(data_str) if data_str else None
                        except json.JSONDecodeError:
                            data_obj = data_str
                        events_q.put((current_event, data_obj))
                    current_event = None
                    current_data = []
        except (urllib.error.URLError, ConnectionError, OSError, AttributeError, ValueError):
            # Connection closed mid-read — normal during teardown.
            pass

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    return response, thread, events_q, stop_event


def _drain_until(events_q: queue.Queue, predicate, timeout_s: float = 2.0) -> tuple[str, Any] | None:
    """Block until an event matching `predicate(event_name, data)` is
    received, or timeout. Returns the matching (event, data) or None.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            event, data = events_q.get(timeout=0.1)
        except queue.Empty:
            continue
        if predicate(event, data):
            return (event, data)
    return None


def _create_workspace(harness: FunctionalHarness, name: str = "sse-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, ws_id: str, name: str = "sse-kanban") -> str:
    # Backend returns the wrapped `{item, columns}` envelope (the
    # frontend's `api.createKanban` destructure relies on it). See
    # `workspace_items_create_kanban.zig::CreateKanbanResponseFull`.
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


# ─── Test 1: /api/events returns 200 with text/event-stream ─────────────


def test_sse_handshake_returns_200(harness: FunctionalHarness) -> None:
    """GET /api/events?channels=workers returns 200 with the SSE content type."""
    req = urllib.request.Request(
        f"http://127.0.0.1:{harness.port}/api/events?channels=workers"
    )
    with urllib.request.urlopen(req, timeout=5.0) as response:
        assert response.status == 200
        ctype = response.headers.get("Content-Type", "")
        assert "text/event-stream" in ctype, (
            f"SSE should have text/event-stream content-type, got {ctype!r}"
        )


# ─── Test 2: connected event fires on subscribe ───────────────────────


def test_sse_connected_event_fires_on_subscribe(
    harness: FunctionalHarness,
) -> None:
    """Opening /api/events emits a `connected` event."""
    response, thread, events_q, stop = _open_sse(harness, "workers")
    try:
        result = _drain_until(
            events_q,
            lambda e, d: e == "connected",
            timeout_s=3.0,
        )
        assert result is not None, (
            "expected 'connected' event within 3s of subscribing"
        )
        event, data = result
        assert event == "connected"
    finally:
        stop.set()
        response.close()


# ─── Test 3: kanban create emits a kanban_column event ─────────────────


def test_kanban_create_emits_sse_event(harness: FunctionalHarness) -> None:
    """Open SSE on kanban channel; POST kanban; assert kanban_column event."""
    response, thread, events_q, stop = _open_sse(harness, "kanban")
    try:
        # Wait for the connected event to be sure the stream is open.
        _drain_until(events_q, lambda e, d: e == "connected", timeout_s=2.0)

        # Trigger: create a kanban (seeds 3 columns → 3 events).
        ws_id = _create_workspace(harness)
        _create_kanban(harness, ws_id)

        # Expect at least one kanban_column event.
        result = _drain_until(
            events_q,
            lambda e, d: e == "kanban_column",
            timeout_s=3.0,
        )
        assert result is not None, (
            "expected a kanban_column SSE event within 3s of kanban create"
        )
    finally:
        stop.set()
        response.close()


# ─── Test 4: kanban column add emits another kanban_column event ───────


def test_kanban_add_column_emits_event(harness: FunctionalHarness) -> None:
    """POST /columns emits a kanban_column event."""
    response, thread, events_q, stop = _open_sse(harness, "kanban")
    try:
        _drain_until(events_q, lambda e, d: e == "connected", timeout_s=2.0)

        # Set up: create workspace + kanban.
        ws_id = _create_workspace(harness)
        kanban_id = _create_kanban(harness, ws_id)

        # Drain the initial 3 events from kanban create.
        for _ in range(5):
            try:
                events_q.get(timeout=0.3)
            except queue.Empty:
                break

        # Trigger: add a 4th column.
        harness.http(
            "POST",
            f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns",
            json_body={"name": "extra"},
            expect=201,
        )

        result = _drain_until(
            events_q,
            lambda e, d: e == "kanban_column",
            timeout_s=3.0,
        )
        assert result is not None, (
            "expected a kanban_column SSE event after add-column"
        )
    finally:
        stop.set()
        response.close()


# ─── Test 5: SSE client disconnect does not crash pabrik ───────────────


def test_sse_drops_quietly_when_client_closes(
    harness: FunctionalHarness,
) -> None:
    """Open SSE, close it, pabrik does not crash. Subsequent API call works."""
    response, thread, events_q, stop = _open_sse(harness, "workers")
    # Wait briefly to ensure the SSE connection is registered.
    time.sleep(0.2)
    # Close the client side.
    stop.set()
    response.close()
    # Give the server a moment to notice.
    time.sleep(0.2)

    # Subsequent API call should still work (server didn't crash).
    r = harness.http("GET", "/api/workspaces", expect=200)
    assert "workspaces" in r.json()
