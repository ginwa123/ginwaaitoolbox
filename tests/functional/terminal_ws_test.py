"""Functional e2e for the terminal duplex WebSocket.

Replays the EXACT wire bytes the frontend sends (no WS library — raw
socket + RFC 6455 framing, so the handshake, masking, and opcodes are
all exercised):

  * GET /api/terminal/ws?id=<id> with Upgrade: websocket
    -> 101 Switching Protocols (accept key verified)
  * C→S masked text {"type":"input","data":"echo <MARK>\n"}
  * S→C binary PTY bytes polled until <MARK> arrives
  * C→S masked close -> server closes cleanly

Plus: unknown ?id= is rejected (close frame or EOF, no PTY bytes),
and the REST output endpoint keeps working alongside the socket
(fallback path from Phase 2 is untouched).
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import time
from typing import Any

from harness import FunctionalHarness

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# ─── Minimal RFC 6455 client ─────────────────────────────────────────────


class WsConn:
    """Blocking raw-socket WebSocket client (test-only, IPv4)."""

    def __init__(self, port: int, path: str) -> None:
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {self.key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.sock.sendall(req.encode())
        self.buf = b""

    def read_http_response(self) -> tuple[str, dict[str, str]]:
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise AssertionError("EOF during WS handshake")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.decode("latin1").split("\r\n")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        return lines[0], headers

    def _fill(self, n: int) -> None:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise AssertionError("EOF during WS frame read")
            self.buf += chunk

    def read_frame(self, deadline_s: float = 15.0) -> tuple[int, bytes]:
        """Next frame -> (opcode, payload). Server frames are unmasked."""
        deadline = time.time() + deadline_s
        while True:
            if len(self.buf) >= 2:
                b1 = self.buf[1]
                length = b1 & 0x7F
                header = 2
                if length == 126:
                    header = 4
                elif length == 127:
                    header = 10
                if len(self.buf) >= header:
                    if length == 126:
                        (length,) = struct.unpack("!H", self.buf[2:4])
                    elif length == 127:
                        (length,) = struct.unpack("!Q", self.buf[2:10])
                    if len(self.buf) >= header + length:
                        opcode = self.buf[0] & 0x0F
                        payload = self.buf[header : header + length]
                        self.buf = self.buf[header + length :]
                        return opcode, bytes(payload)
            if time.time() > deadline:
                raise AssertionError("timed out waiting for WS frame")
            self.sock.settimeout(max(0.1, deadline - time.time()))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                raise AssertionError("timed out waiting for WS frame")
            if not chunk:
                raise AssertionError("EOF during WS frame read")
            self.buf += chunk

    def send_text(self, text: str) -> None:
        payload = text.encode()
        mask = os.urandom(4)
        header = bytes([0x81, 0x80 | len(payload)]) + mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + masked)

    def send_close(self) -> None:
        mask = os.urandom(4)
        self.sock.sendall(bytes([0x88, 0x80]) + mask)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_session(harness: FunctionalHarness) -> dict[str, Any]:
    r = harness.http(
        "POST",
        "/api/terminal/sessions",
        json_body={"cwd": str(harness.temp_dir), "shell": "/bin/sh"},
        expect=201,
    )
    return r.json()


def _collect_until(
    ws: WsConn, marker: bytes, deadline_s: float = 20.0
) -> tuple[bytes, dict[str, Any] | None]:
    """Read frames until a binary payload contains `marker`."""
    seen = b""
    exit_event: dict[str, Any] | None = None
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        opcode, payload = ws.read_frame(deadline_s=max(1.0, deadline - time.time()))
        if opcode == 0x2:  # binary — PTY bytes
            seen += payload
            if marker in seen:
                return seen, exit_event
        elif opcode == 0x1:  # text — JSON events
            try:
                exit_event = json.loads(payload.decode())
            except (ValueError, UnicodeDecodeError):
                pass
        elif opcode == 0x8:  # close
            break
    raise AssertionError(f"marker {marker!r} never arrived; seen={seen!r}")


# ─── Tests ─────────────────────────────────────────────────────────────────


def test_ws_echo_round_trip(harness: FunctionalHarness) -> None:
    """Handshake (101 + valid accept) -> masked input -> binary echo."""
    created = _create_session(harness)
    session_id = created["id"]
    try:
        ws = WsConn(harness.port, f"/api/terminal/ws?id={session_id}")
        try:
            status, headers = ws.read_http_response()
            assert "101" in status, f"expected 101, got {status!r}"
            expected = base64.b64encode(
                hashlib.sha1((ws.key + WS_MAGIC).encode()).digest()
            ).decode()
            assert headers.get("sec-websocket-accept") == expected, (
                f"bad accept key: {headers!r}"
            )

            marker = b"WS-MARK-4f8e2a"
            ws.send_text(json.dumps({"type": "input", "data": f"echo {marker.decode()}\n"}))
            seen, _ = _collect_until(ws, marker)
            assert marker in seen

            ws.send_close()
        finally:
            ws.close()
    finally:
        harness.http("DELETE", f"/api/terminal/sessions/{session_id}", expect=200)


def test_ws_unknown_id_rejected(harness: FunctionalHarness) -> None:
    """Attaching to an unknown id yields no PTY bytes — the server
    runs the close handshake (close frame) or drops the socket."""
    ws = WsConn(harness.port, "/api/terminal/ws?id=term-does-not-exist")
    try:
        status, _ = ws.read_http_response()
        assert "101" in status, f"expected 101 upgrade, got {status!r}"
        ws.sock.settimeout(5.0)
        try:
            opcode, _ = ws.read_frame(deadline_s=5.0)
            assert opcode == 0x8, f"expected close frame, got opcode {opcode:#x}"
        except AssertionError as e:
            # EOF/timeout also acceptable: no PTY bytes must arrive.
            assert "timed out" in str(e) or "EOF" in str(e), f"unexpected: {e}"
    finally:
        ws.close()


def test_ws_resize_and_rest_fallback(harness: FunctionalHarness) -> None:
    """Resize over the socket is accepted; the REST output endpoint
    keeps serving the same session (fallback path intact)."""
    created = _create_session(harness)
    session_id = created["id"]
    try:
        ws = WsConn(harness.port, f"/api/terminal/ws?id={session_id}")
        try:
            status, _ = ws.read_http_response()
            assert "101" in status, f"expected 101, got {status!r}"

            ws.send_text(json.dumps({"type": "resize", "cols": 100, "rows": 40}))
            marker = b"WS-RESIZE-7b3d"
            ws.send_text(json.dumps({"type": "input", "data": f"echo {marker.decode()}\n"}))
            _collect_until(ws, marker)
            ws.send_close()
        finally:
            ws.close()

        # REST fallback still works on the same session afterwards.
        r = harness.http(
            "GET", f"/api/terminal/sessions/{session_id}/output?cursor=0", expect=200
        )
        assert r.json().get("cursor", 0) > 0
    finally:
        harness.http("DELETE", f"/api/terminal/sessions/{session_id}", expect=200)
