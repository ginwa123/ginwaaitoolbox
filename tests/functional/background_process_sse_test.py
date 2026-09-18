"""Functional e2e for background_process SSE push.

Replaces the frontend 5s `GET background_processes` poll with server push
(`background_process_created` on spawn, `background_process_completed` on
exit — see src/agentic_loop/background_process_events.zig).

Covers the wire contract the frontend relies on:
  * GET /api/events?channels=background_process -> 200 text/event-stream
    + `connected` handshake (unified_events_sse.zig parseChannels +
    CallbackUnifiedBackgroundProcessStream wiring).
  * GET /api/llm/session/:sid/background_processes still returns the
    list shape (frontend fetches once on mount + on each push event).

Emit-path triggering (spawn via `command background=true`, completion via
watcher/cron) needs an LLM tool run and is covered by Zig unit tests
(background_process_events null-bus no-op) + the frontend vitest
(BackgroundCommandsPopup.spec.ts push refresh). This file pins the
transport so a future channel rename breaks here, not in the browser.
"""

from __future__ import annotations

import json
import queue
import threading
import time
import urllib.request
from typing import Any

from harness import FunctionalHarness


def _open_sse(harness: FunctionalHarness, channels: str):
    events_q: queue.Queue = queue.Queue()
    stop_event = threading.Event()

    url = f"http://127.0.0.1:{harness.port}/api/events?channels={channels}"
    req = urllib.request.Request(url)
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
                    if current_event is not None:
                        data_str = "\n".join(current_data)
                        try:
                            data_obj = json.loads(data_str) if data_str else None
                        except json.JSONDecodeError:
                            data_obj = data_str
                        events_q.put((current_event, data_obj))
                    current_event = None
                    current_data = []
        except Exception:
            pass

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    return response, thread, events_q, stop_event


def _drain_until(events_q: queue.Queue, predicate, timeout_s: float = 3.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            event, data = events_q.get(timeout=0.1)
        except queue.Empty:
            continue
        if predicate(event, data):
            return (event, data)
    return None


def test_background_process_channel_handshake(harness: FunctionalHarness) -> None:
    """GET /api/events?channels=background_process returns 200 SSE + connected."""
    req = urllib.request.Request(
        f"http://127.0.0.1:{harness.port}/api/events?channels=background_process"
    )
    with urllib.request.urlopen(req, timeout=5.0) as response:
        assert response.status == 200
        ctype = response.headers.get("Content-Type", "")
        assert "text/event-stream" in ctype, f"expected SSE content-type, got {ctype!r}"

    response, thread, events_q, stop = _open_sse(harness, "background_process")
    try:
        result = _drain_until(events_q, lambda e, d: e == "connected", timeout_s=3.0)
        assert result is not None, "expected 'connected' event within 3s"
    finally:
        stop.set()
        response.close()


def test_background_process_list_still_serves_initial_fetch(
    harness: FunctionalHarness,
) -> None:
    """Frontend fetches once on mount — list endpoint still 200 with shape."""
    session_id = "sess_bg_sse_001"
    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": f"bg-sse-{session_id}"},
        expect=200,
    )
    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/background_processes",
        expect=200,
    )
    body: dict[str, Any] = r.json()
    assert body.get("processes") == []
    assert body.get("count") == 0
