"""Wire test: an anthropic-style CHAT turn sends `x-api-key` +
`anthropic-version` (and `x-opencode-session`), not Bearer.

Regression for the follow-up to the Test-button fix (PR #542): the
probe worked ("Connected — ok") but a real chat turn against
`https://opencode.ai/zen/go/v1/messages` failed with
`StreamInterrupted (callDynamicAgentNew)` ... `{"type":"error",
"error":{"type":"AuthError","message":"Missing API key."}}`.
`Agent.callStreaming` sent only `Authorization: Bearer`, which
Anthropic-style upstreams ignore.

Plan: boot the harness, PUT an anthropic profile pointing at a stub
SSE server, POST /api/llm/session with a queue_message (the exact
`sendChatMessage` wire), poll until the assistant reply lands, then
assert EVERY stub request carried the Anthropic auth headers.

Run:
    uv run --with pytest pytest tests/functional/anthropic_chat_headers_test.py -v
"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── stub Anthropic SSE upstream ────────────────────────────────────────

SSE_STREAM = (
    'event: message_start\n'
    'data: {"type":"message_start","message":{"id":"msg_1","type":"message",'
    '"role":"assistant","content":[],"model":"stub-claude","stop_reason":null,'
    '"stop_sequence":null,"usage":{"input_tokens":8,"output_tokens":1}}}\n'
    '\n'
    'event: content_block_start\n'
    'data: {"type":"content_block_start","index":0,'
    '"content_block":{"type":"text","text":""}}\n'
    '\n'
    'event: content_block_delta\n'
    'data: {"type":"content_block_delta","index":0,'
    '"delta":{"type":"text_delta","text":"hello from stub"}}\n'
    '\n'
    'event: content_block_stop\n'
    'data: {"type":"content_block_stop","index":0}\n'
    '\n'
    'event: message_delta\n'
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn",'
    '"stop_sequence":null},"usage":{"output_tokens":4}}\n'
    '\n'
    'event: message_stop\n'
    'data: {"type":"message_stop"}\n'
    '\n'
)


class _StubState:
    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []
        self.lock = threading.Lock()


class _StubHandler(BaseHTTPRequestHandler):
    state: _StubState  # set on the server instance

    def log_message(self, *args: Any) -> None:  # silence stderr noise
        pass

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        headers = {k.lower(): v for k, v in self.headers.items()}
        with self.server.state.lock:  # type: ignore[attr-defined]
            self.server.state.requests.append(  # type: ignore[attr-defined]
                {"headers": headers, "body": body}
            )
        raw = SSE_STREAM.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def _start_stub() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    server.state = _StubState()  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


# ─── fixture ────────────────────────────────────────────────────────────


@pytest.fixture
def chat_harness(default_pabrik_bin: Any) -> Any:
    h = FunctionalHarness.boot(default_pabrik_bin, stub_llm_profile=True)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


# ─── the test ───────────────────────────────────────────────────────────


def test_anthropic_chat_turn_sends_x_api_key_not_bearer(
    chat_harness: FunctionalHarness,
) -> None:
    """Full worker turn against a stub Anthropic SSE upstream.

    Pre-fix every chat POST carried `Authorization: Bearer ...` and no
    `x-api-key`, so the upstream answered `AuthError: Missing API key`
    with 0 chunks. Post-fix every POST carries `x-api-key` +
    `anthropic-version` (+ `x-opencode-session`) and the turn completes
    with the stub's text.
    """
    server = _start_stub()
    try:
        stub_port = server.server_address[1]
        stub_url = f"http://127.0.0.1:{stub_port}/v1/messages"

        # 1. Install an anthropic profile pointing at the stub (mirrors
        # the pabrik_config PUT shape; url_style is what selects the
        # Anthropic body + header path in Agent.callStreaming).
        chat_harness.http(
            "PUT",
            "/api/config/pabrik",
            json_body={
                "api_endpoint": stub_url,
                "api_key": "sk-ant-test",
                "model": "stub-claude",
                "url_style": "anthropic",
                "profiles": {
                    "ant-stub": {
                        "model": "stub-claude",
                        "base_url": stub_url,
                        "api_key": "sk-ant-test",
                        "url_style": "anthropic",
                    },
                },
                "active_profile": "ant-stub",
            },
            expect=200,
        )

        # 2. Send the first chat message — the exact sendChatMessage
        # wire (session_id + queue_message + profile selection).
        session_id = f"sess_anthropic_hdr_{int(time.time())}"
        chat_harness.http(
            "POST",
            "/api/llm/session",
            json_body={
                "session_id": session_id,
                "queue_message": "say hi",
                "cwd_session": "",
                "image_urls": "",
                "selected_profile_model": "ant-stub",
                "is_auto_retry_until_stop": "",
            },
            expect=(200, 201, 500),
        )

        # 3. Poll until the assistant reply lands (the worker turn
        # completes against the stub).
        assistant_text: str | None = None
        deadline = time.monotonic() + 60.0
        while time.monotonic() < deadline:
            r = chat_harness.http(
                "GET",
                f"/api/llm/session/{session_id}/messages",
                params={
                    "sort_by": "created_at",
                    "direction": "asc",
                    "limit": 100,
                },
                expect=200,
            )
            for m in r.json().get("messages", []):
                if m.get("role") == "assistant" and m.get("content"):
                    assistant_text = m["content"]
                    break
            if assistant_text:
                break
            time.sleep(0.5)
        assert assistant_text is not None, (
            "worker turn never produced an assistant message within 60s; "
            "the stub may not have been hit or the SSE did not parse"
        )
        assert "hello from stub" in assistant_text, (
            f"assistant reply should be the stub text, got: {assistant_text!r}"
        )

        # 4. Header contract on EVERY stub request (chat turn +
        # session auto-naming all go through Agent.callStreaming).
        state: _StubState = server.state  # type: ignore[attr-defined]
        with state.lock:
            seen = list(state.requests)
        assert seen, "stub upstream received no requests"
        for i, req in enumerate(seen):
            headers = req["headers"]
            assert headers.get("x-api-key") == "sk-ant-test", (
                f"request {i}: anthropic chat must send x-api-key, got: {headers}"
            )
            assert headers.get("anthropic-version") == "2023-06-01", (
                f"request {i}: anthropic chat must send anthropic-version, "
                f"got: {headers}"
            )
            assert "authorization" not in headers, (
                f"request {i}: anthropic chat must NOT send Bearer auth, "
                f"got: {headers}"
            )
            assert headers.get("x-opencode-session"), (
                f"request {i}: chat must send x-opencode-session, got: {headers}"
            )
    finally:
        server.shutdown()
