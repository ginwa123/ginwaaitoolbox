"""Functional wire-replay test for Responses `function_call_output` sanitization.

Regression for: ``input[20].output[0] did not match any supported type``
(muse-spark via Console Go, ``url_style="openai-response"``).

A ``bash`` tool output containing ``cat`` of an ELF binary embedded
invalid UTF-8 bytes into ``function_call_output.output``; the backend
emitted them raw, so the gateway rejected the whole request before
streaming a single chunk
(``stream ended without finish_reason after 0 chunk(s)``).

This test replays the EXACT shape over the real HTTP wire:

  1. A TCP capture server stands in for the LLM endpoint and records the
     raw request bytes the backend sends (then hangs up — the run fails,
     which is fine; we assert on the captured *request*, not the reply).
  2. The harness boots with the stub profile; ``PUT /api/config/nalar``
     (granular ``ProfileChange`` shape) repoints it at the capture server
     with ``url_style="openai-response"`` (live-reload, no restart).
  3. ``PUT /api/llm/session/:id`` creates the session row *without*
     running the agent; poisoned history rows (assistant
     ``tool_calls_json`` + tool output with ELF bytes) are seeded
     straight into ``agent.db``; a single ``POST /api/llm/session``
     replays them into a Responses request aimed at the capture
     server. (One run only — a second sequential run on the same
     session can queue behind the first worker's retry/backoff and
     flake on timing.)
  4. Assert the captured body is valid UTF-8, carries a
     ``function_call_output`` item, has no raw ``0xFF`` byte, and contains
     U+FFFD (the sanitizer's replacement marker).

DONT KILL the port 8081 server — the harness picks ports in 8080..8199
excluding 8081 (see ``harness.py``).
"""

from __future__ import annotations

import json
import socket
import sqlite3
import threading
import time
from typing import Any

import pytest

from harness import FunctionalHarness

CALL_ID = "call_01a06fb93f1878c19cd31a8ad82456e3"
SESSION_ID = "sess_resp_sanitize_001"

# ELF magic + invalid bytes, mimicking `cat` of a binary in tool stdout.
# sqlite3 + the JSON wire must carry these exact bytes pre-fix.
POISONED_STDOUT = (
    b"/home/ginwa/.config/quickshell/default/qs-glauncher-zig:\n"
    b"build.zig\n"
    b"---\n"
    b"\x7fELF\x02\x01\x01\x00\xff\xfe binary \x80\x81 done\n"
)


# ─── Capture server ──────────────────────────────────────────────────────


class CaptureServer:
    """Minimal TCP server that records full HTTP request bodies."""

    def __init__(self) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self._sock.settimeout(0.5)
        self.port: int = self._sock.getsockname()[1]
        self.bodies: list[bytes] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def start(self) -> "CaptureServer":
        self._thread.start()
        return self

    def close(self) -> None:
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass
        self._thread.join(timeout=5.0)

    def _read_exact(self, conn: socket.socket, buf: bytearray, n: int) -> None:
        while len(buf) < n:
            chunk = conn.recv(min(65536, n - len(buf)))
            if not chunk:
                break
            buf.extend(chunk)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except (OSError, socket.timeout):
                continue
            try:
                conn.settimeout(5.0)
                data = bytearray()
                while b"\r\n\r\n" not in data:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data.extend(chunk)
                if b"\r\n\r\n" not in data:
                    continue
                head, rest = bytes(data).split(b"\r\n\r\n", 1)
                length = 0
                for line in head.decode("latin-1").split("\r\n"):
                    if line.lower().startswith("content-length:"):
                        length = int(line.split(":", 1)[1].strip())
                        break
                body = bytearray(rest)
                self._read_exact(conn, body, length)
                with self._lock:
                    self.bodies.append(bytes(body))
            except (OSError, ValueError):
                pass
            finally:
                # Hang up without responding: the LLM run fails fast, but
                # the request bytes are already captured. We assert on the
                # request, not the reply.
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    conn.close()
                except OSError:
                    pass

    def wait_for_body_with_marker(
        self, marker: bytes, timeout_s: float = 120.0
    ) -> bytes | None:
        """Poll until a captured body contains `marker`."""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            with self._lock:
                for body in self.bodies:
                    if marker in body:
                        return body
            time.sleep(0.1)
        return None


# ─── Helpers ─────────────────────────────────────────────────────────────


def _repoint_stub_at_capture(
    harness: FunctionalHarness, port: int
) -> None:
    """PUT granular ProfileChange: stub → capture server + openai-response."""
    harness.http(
        "PUT",
        "/api/config/nalar",
        json_body={
            "profiles": [
                {
                    "name": "stub",
                    "action": "update",
                    "model": "stub-model",
                    "base_url": f"http://127.0.0.1:{port}",
                    "url_style": "openai-response",
                    "api_key": "stub-key-not-real",
                }
            ]
        },
        expect=200,
    )


def _seed_poisoned_history(harness: FunctionalHarness) -> None:
    """Insert assistant tool_calls + ELF-poisoned tool rows for the session.

    Mirrors the production write path (`handle_tool.zig` Phase 2 →
    `llm_history.saveMessage`): the assistant row carries
    `tool_calls_json` in Chat-Completions shape, the tool row carries the
    raw output in `response_content` with `tool_call_id` in the `tools`
    column. Replay only includes rows with `is_feed_to_llm = 1`
    (`get_llm_histories.zig`), ordered by `created_at_nano`.
    """
    db_path = harness.temp_dir / ".config" / "nalar" / "agent.db"
    tool_calls = json.dumps([
        {
            "id": CALL_ID,
            "type": "function",
            "function": {
                "name": "bash",
                "arguments": json.dumps({
                    "command": "timeout 10 ls -R /tmp | head -n 5",
                    "cwd": "/tmp",
                    "mandatory_timeout": 15.0,
                }),
            },
        }
    ])
    now_nano = time.time_ns()
    conn = sqlite3.connect(str(db_path))
    try:
        conn.execute(
            "INSERT INTO llm_history"
            " (id, session_id, model, response_content, tool_calls_json,"
            "  role, tool_call_id, finish_reason, is_feed_to_llm,"
            "  created_at_nano, tool_name)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                "msg_resp_assistant_001",
                SESSION_ID,
                "stub-model",
                "",
                tool_calls,
                "assistant",
                None,
                "tool_calls",
                1,
                now_nano + 1,
                "bash",
            ),
        )
        # NOTE: raw `bytes` (BLOB) on purpose — production rows carry the
        # tool's raw stdout bytes (0xFF/0x80 are NOT valid UTF-8). Passing
        # `str` here would UTF-8-encode them (U+00FF → b"\xc3\xbf") and the
        # test would no longer reproduce the gateway rejection.
        conn.execute(
            "INSERT INTO llm_history"
            " (id, session_id, model, response_content, tool_calls_json,"
            "  role, tool_call_id, finish_reason, is_feed_to_llm,"
            "  created_at_nano, tool_name)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                "msg_resp_tool_001",
                SESSION_ID,
                "stub-model",
                POISONED_STDOUT,
                None,
                "tool",
                CALL_ID,
                None,
                1,
                now_nano + 2,
                "bash",
            ),
        )
        conn.commit()
    finally:
        conn.close()


# ─── Test ────────────────────────────────────────────────────────────────


def test_responses_replay_sanitizes_binary_tool_output(
    harness: FunctionalHarness,
) -> None:
    """Poisoned tool history replays as valid UTF-8 `function_call_output`.

    Pre-fix, the captured Responses body carried the poison through
    without sanitization markers (no U+FFFD) and any strict gateway
    rejected it with ``input[N].output[0] did not match any supported
    type`` (0 chunks). Post-fix, the body is valid UTF-8 with U+FFFD
    markers and the original `call_id` pairing intact.
    """
    server = CaptureServer().start()
    try:
        _repoint_stub_at_capture(harness, server.port)

        # Create the session row WITHOUT running the agent (PUT
        # auto-creates via ensureSessionExists — no LLM call, no worker,
        # so nothing can queue behind a first run's retry/backoff).
        harness.http(
            "PUT",
            f"/api/llm/session/{SESSION_ID}",
            json_body={"name": "resp-sanitize"},
            expect=200,
        )

        # Seed the exact failing shape, then replay it with a single run.
        _seed_poisoned_history(harness)
        harness.http(
            "POST",
            "/api/llm/session",
            json_body={
                "session_id": SESSION_ID,
                "session_name": "resp-sanitize",
                "queue_message": "again",
            },
            expect=(200, 201, 500),
        )

        body = server.wait_for_body_with_marker(b"function_call_output")
        assert body is not None, (
            "backend never POSTed a Responses body containing "
            f"function_call_output; captured {len(server.bodies)} bodies: "
            f"{[b[:80] for b in server.bodies]!r}"
        )

        # 1. The whole body must be valid UTF-8 (gateway JSON parses it).
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError as e:
            pytest.fail(f"captured Responses body is not valid UTF-8: {e}")

        # 2. No raw poison bytes survive on the wire.
        assert b"\xff" not in body, (
            "raw 0xFF byte reached the wire — gateway would reject with "
            "input[N].output[0] type error"
        )

        # 3. The sanitizer marked the replacements + kept the pairing.
        assert "\ufffd" in text, (
            "expected U+FFFD replacement markers in sanitized output"
        )
        assert CALL_ID in text, (
            f"function_call_output lost its call_id pairing ({CALL_ID})"
        )
        payload = json.loads(text)
        kinds = [item.get("type") for item in payload.get("input", [])]
        assert "function_call" in kinds, (
            f"expected a function_call replay item, got input types {kinds!r}"
        )
        assert "function_call_output" in kinds, (
            f"expected a function_call_output replay item, got {kinds!r}"
        )
    finally:
        server.close()
