"""
End-to-end functional test for `POST /api/llm/test` (the "Test" button
on the Add/Edit profile modal).

What this exercises (NO real api_key — every success case fires
against a stub upstream HTTP server in this file):
  1. **openai-success** — stub returns a canned `choices[0].message`
     payload; assert `{ok: true, reply: "ok"}` + the stub saw the
     `Authorization: Bearer` header and the probe prompt.
  2. **anthropic-success** — stub returns a canned `content[]` payload;
     assert `{ok: true}` + the stub saw the `x-api-key` header.
  3. **responses-success** — stub returns a canned `output[]` payload;
     assert `{ok: true}`.
  4. **missing-model** — assert `{ok: false, error: "model is required"}`.
  5. **bad-style** — assert `{ok: false}` referencing `url_style`.
  6. **unreachable** — `http://127.0.0.1:1/x` (connection refused);
     assert `{ok: false}` fast (never port 8081).
  7. **upstream-401** — stub returns 401 JSON; assert `{ok: false}`
     with `details` containing "http 401".

Why this exists: the probe is the whole point of the kanban task
("test button llm"). Zig unit tests cover validation + body builders
+ reply parsers, but only a wire round-trip proves route registration,
request auth headers per style, and the 200-always envelope.

Run:
    PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 \
    pytest tests/functional/llm_test_test.py -v
"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from harness import FunctionalHarness


# ─── stub upstream ──────────────────────────────────────────────────────


class _StubState:
    """Per-test mutable state shared with the handler via the server."""

    def __init__(self, status: int, payload: dict[str, Any]):
        self.status = status
        self.payload = payload
        self.last_headers: dict[str, str] = {}
        self.last_body: bytes = b""


class _StubHandler(BaseHTTPRequestHandler):
    state: _StubState  # set per test on the server instance

    def log_message(self, *args: Any) -> None:  # silence stderr noise
        pass

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        self.server.state.last_body = self.rfile.read(length)  # type: ignore[attr-defined]
        self.server.state.last_headers = {k.lower(): v for k, v in self.headers.items()}  # type: ignore[attr-defined]
        raw = json.dumps(self.server.state.payload).encode()  # type: ignore[attr-defined]
        self.send_response(self.server.state.status)  # type: ignore[attr-defined]
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def _start_stub(status: int, payload: dict[str, Any]):
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    server.state = _StubState(status, payload)  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


# ─── helpers ────────────────────────────────────────────────────────────


def _post_test(harness: FunctionalHarness, body: dict, timeout_s: float = 30.0):
    """POST /api/llm/test and return the parsed JSON. The endpoint
    always returns HTTP 200 (failure surfaces as `ok: false`).
    """
    resp = harness.http(
        "POST", "/api/llm/test", json_body=body, expect=200, timeout_s=timeout_s,
    )
    result = resp.json()
    if result.get("ok") is False:
        print(f"[llm_test] body: {result}", flush=True)
    return result


def _stub_body(state: _StubState) -> dict:
    assert state.last_body, "stub upstream received no request body"
    return json.loads(state.last_body.decode())


# ─── Test 1: openai success ─────────────────────────────────────────────


def test_llm_test_openai_success_returns_reply() -> None:
    """Stub answers a chat-completions payload; the probe returns
    `{ok: true, reply: "ok"}` and the stub saw Bearer auth + prompt.
    """
    server = _start_stub(200, {
        "id": "chatcmpl-1",
        "choices": [{"message": {"role": "assistant", "content": "ok"},
                     "finish_reason": "stop"}],
    })
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        port = server.server_address[1]
        result = _post_test(harness, {
            "model": "stub-model",
            "base_url": f"http://127.0.0.1:{port}/v1/chat/completions",
            "api_key": "sk-test-stub",
            "url_style": "openai",
        })
        assert result.get("ok") is True, f"unexpected response: {result}"
        assert result["model"] == "stub-model"
        assert result["reply"] == "ok"
        assert isinstance(result.get("latency_ms"), int)

        state: _StubState = server.state  # type: ignore[attr-defined]
        assert state.last_headers.get("authorization") == "Bearer sk-test-stub", (
            f"openai style must send Bearer auth, got: {state.last_headers}"
        )
        sent = _stub_body(state)
        assert sent["model"] == "stub-model"
        assert "Reply with exactly: ok" in json.dumps(sent)
        assert sent.get("stream") is False
    finally:
        harness.teardown()
        server.shutdown()


# ─── Test 2: anthropic success ──────────────────────────────────────────


def test_llm_test_anthropic_success_uses_x_api_key() -> None:
    """Anthropic-style probe sends `x-api-key` (not Bearer) and parses
    the `content[]` text block.
    """
    server = _start_stub(200, {
        "id": "msg_1",
        "content": [{"type": "text", "text": "ok"}],
        "stop_reason": "end_turn",
    })
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        port = server.server_address[1]
        result = _post_test(harness, {
            "model": "stub-claude",
            "base_url": f"http://127.0.0.1:{port}/v1/messages",
            "api_key": "sk-ant-test",
            "url_style": "anthropic",
        })
        assert result.get("ok") is True, f"unexpected response: {result}"
        assert result["reply"] == "ok"

        state: _StubState = server.state  # type: ignore[attr-defined]
        assert state.last_headers.get("x-api-key") == "sk-ant-test", (
            f"anthropic style must send x-api-key, got: {state.last_headers}"
        )
        assert "authorization" not in state.last_headers, (
            "anthropic style must NOT send Bearer auth"
        )
        sent = _stub_body(state)
        assert sent["max_tokens"] == 16
    finally:
        harness.teardown()
        server.shutdown()


# ─── Test 3: openai-response success ────────────────────────────────────


def test_llm_test_openai_response_success_parses_output_items() -> None:
    """Responses-style probe sends `input` and parses `output[]`
    message items.
    """
    server = _start_stub(200, {
        "id": "resp_1",
        "output": [{"type": "message",
                    "content": [{"type": "output_text", "text": "ok"}]}],
    })
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        port = server.server_address[1]
        result = _post_test(harness, {
            "model": "stub-gpt",
            "base_url": f"http://127.0.0.1:{port}/v1/responses",
            "api_key": "sk-test-stub",
            "url_style": "openai-response",
        })
        assert result.get("ok") is True, f"unexpected response: {result}"
        assert result["reply"] == "ok"

        state: _StubState = server.state  # type: ignore[attr-defined]
        sent = _stub_body(state)
        assert "Reply with exactly: ok" in sent.get("input", "")
    finally:
        harness.teardown()
        server.shutdown()


# ─── Test 4: validation failures (no stub needed) ───────────────────────


def test_llm_test_missing_model_returns_clear_error() -> None:
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        result = _post_test(harness, {
            "model": "",
            "base_url": "http://127.0.0.1:9/x",
            "api_key": "sk-test-stub",
            "url_style": "openai",
        })
        assert result.get("ok") is False
        assert "model" in result.get("error", "").lower()
    finally:
        harness.teardown()


def test_llm_test_bad_style_returns_clear_error() -> None:
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        result = _post_test(harness, {
            "model": "m",
            "base_url": "http://127.0.0.1:9/x",
            "api_key": "sk-test-stub",
            "url_style": "weird-thing",
        })
        assert result.get("ok") is False
        assert "url_style" in result.get("error", "").lower()
    finally:
        harness.teardown()


# ─── Test 6: unreachable upstream fails fast ────────────────────────────


def test_llm_test_unreachable_returns_send_failure() -> None:
    """Closed port (connection refused) returns `{ok: false}` quickly.
    Port 1 is used because the kernel refuses it; never port 8081.
    """
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        start = time.monotonic()
        result = _post_test(harness, {
            "model": "m",
            "base_url": "http://127.0.0.1:1/x",
            "api_key": "sk-test-stub",
            "url_style": "openai",
        })
        elapsed = time.monotonic() - start
        assert result.get("ok") is False, f"unexpected response: {result}"
        assert result.get("error"), f"expected non-empty error, got: {result}"
        assert elapsed < 30.0, f"probe took {elapsed:.1f}s (>30s timeout!)"
    finally:
        harness.teardown()


# ─── Test 7: upstream 401 surfaces status in details ────────────────────

def test_llm_test_upstream_401_returns_status_in_details() -> None:
    """A 401 from upstream (e.g. revoked key) returns `{ok: false}`
    with `details` naming the status so the modal shows WHY.
    """
    server = _start_stub(401, {"error": {"message": "invalid key", "type": "auth"}})
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        port = server.server_address[1]
        result = _post_test(harness, {
            "model": "stub-model",
            "base_url": f"http://127.0.0.1:{port}/v1/chat/completions",
            "api_key": "sk-revoked",
            "url_style": "openai",
        })
        assert result.get("ok") is False, f"unexpected response: {result}"
        assert "http 401" in result.get("details", ""), (
            f"details should name the status, got: {result}"
        )
    finally:
        harness.teardown()
        server.shutdown()


# ─── Test 8: probe sends x-opencode-session (all styles) ────────────────


def test_llm_test_probe_sends_opencode_session_anthropic() -> None:
    """Regression for the Edit-profile Test button 400
    `{"type":"error","error":{"type":"MissingSessionID",...}}`:
    the anthropic-style probe must carry `x-opencode-session` or
    Console Go rejects it before routing. Replays the EXACT JSON body
    the frontend sends (see LlmConfigModal.vue onTest).
    """
    server = _start_stub(200, {
        "id": "msg_1",
        "content": [{"type": "text", "text": "ok"}],
        "stop_reason": "end_turn",
    })
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        port = server.server_address[1]
        result = _post_test(harness, {
            "model": "stub-claude",
            "base_url": f"http://127.0.0.1:{port}/v1/messages",
            "api_key": "sk-ant-test",
            "url_style": "anthropic",
        })
        assert result.get("ok") is True, f"unexpected response: {result}"
        state: _StubState = server.state  # type: ignore[attr-defined]
        assert state.last_headers.get("x-opencode-session"), (
            f"anthropic probe must send x-opencode-session, got: {state.last_headers}"
        )
    finally:
        harness.teardown()
        server.shutdown()


def test_llm_test_probe_sends_opencode_session_openai() -> None:
    """Same header contract for the openai style — the gateway may
    require it there too, and the extra header is ignored by direct
    providers.
    """
    server = _start_stub(200, {
        "id": "chatcmpl-1",
        "choices": [{"message": {"role": "assistant", "content": "ok"},
                     "finish_reason": "stop"}],
    })
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        port = server.server_address[1]
        result = _post_test(harness, {
            "model": "stub-model",
            "base_url": f"http://127.0.0.1:{port}/v1/chat/completions",
            "api_key": "sk-test-stub",
            "url_style": "openai",
        })
        assert result.get("ok") is True, f"unexpected response: {result}"
        state: _StubState = server.state  # type: ignore[attr-defined]
        assert state.last_headers.get("x-opencode-session"), (
            f"openai probe must send x-opencode-session, got: {state.last_headers}"
        )
    finally:
        harness.teardown()
        server.shutdown()
