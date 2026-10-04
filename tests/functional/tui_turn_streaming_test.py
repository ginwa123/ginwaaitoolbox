"""Functional regression for "the second turn never shows up in pabrik-tui".

User report (2026-09-13): the first exchange renders fine, but a *second*
message in the same session produces nothing in the TUI, even though the reply
exists — the desktop client (SSE) shows it.

Root cause: `App.onMessages` decided "this turn is over" by scanning the WHOLE
polled message array for *any* assistant row with `finish_reason="stop"`. The
poll returns the session's last 100 messages, which includes the previous
turn's completed reply. So the first poll of turn 2 found turn 1's `stop`,
flipped `is_streaming = false`, and the poll loop stopped before any of turn
2's rows arrived. Turn 1 only worked because the array contained no earlier
`stop`.

This suite drives the real binary in a pty against a fake backend that serves
two turns, and asserts that turn 2's user text and reply both reach the
terminal.
"""

from __future__ import annotations

import fcntl
import http.server
import json
import os
import pty
import re
import shutil
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

import pytest

TURN1_USER = "first question"
TURN1_REPLY = "FIRST-TURN-REPLY"
TURN2_USER = "second question"
TURN2_REPLY = "SECOND-TURN-REPLY"

# What the fake backend serves. It advances one step per GET so the client
# observes: turn 1 streaming -> turn 1 stop -> turn 2 user -> turn 2 stop.
TURN1 = [
    {"id": "u1", "role": "user", "content": TURN1_USER},
    {"id": "a1", "role": "assistant", "content": TURN1_REPLY, "finish_reason": "stop"},
]
TURN2_STREAMING = TURN1 + [
    {"id": "u2", "role": "user", "content": TURN2_USER},
]
TURN2_DONE = TURN2_STREAMING + [
    {"id": "a2", "role": "assistant", "content": TURN2_REPLY, "finish_reason": "stop"},
]

# Only reached once the client sends its SECOND message — a client that stops
# polling (the bug) never asks for these.
SEQUENCE_AFTER_POST_1 = [TURN1[:1], TURN1, TURN1, TURN1]
SEQUENCE_AFTER_POST_2 = [TURN2_STREAMING, TURN2_STREAMING, TURN2_DONE, TURN2_DONE]


class _State:
    def __init__(self):
        self.posts = 0
        self.gets = 0


def _make_handler(state: _State):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send(self, body):
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0) or 0)
            req = {}
            if n:
                try:
                    req = json.loads(self.rfile.read(n) or b"{}")
                except Exception:
                    req = {}
            state.posts += 1
            if state.posts == 1:
                self._send({"session_id": req.get("session_id") or "sid"})
            else:
                # Turn 2 begins: reset the GET sequence.
                state.gets = 0
                self._send({"session_id": req.get("session_id") or "sid"})

        def do_GET(self):
            if state.posts <= 1:
                seq = SEQUENCE_AFTER_POST_1
            else:
                seq = SEQUENCE_AFTER_POST_2
            idx = min(state.gets, len(seq) - 1)
            state.gets += 1
            self._send({"messages": seq[idx]})

    return Handler


class _Backend:
    def __init__(self):
        self.state = _State()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _make_handler(self.state))
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def _binary() -> str:
    for cand in (
        os.environ.get("PABRIK_TUI_BIN"),
        "zig-out/bin/pabrik-tui",
        "zig-out/bin/pabrik-tui.exe",
        shutil.which("pabrik-tui"),
    ):
        if cand and os.path.exists(cand):
            return cand
    pytest.skip("pabrik-tui not built — run `zig build install:tui` (or set PABRIK_TUI_BIN)")


class _Tui:
    def __init__(self, binary: str, port: int):
        self.master, slave = pty.openpty()
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
        self.proc = subprocess.Popen(
            [binary, "--server", "http://127.0.0.1:%d" % port],
            stdin=slave, stdout=slave, stderr=slave,
            preexec_fn=os.setsid, close_fds=True,
        )
        os.close(slave)
        self._stop = False
        self.chunks = []
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        while not self._stop:
            try:
                data = os.read(self.master, 1 << 20)
            except OSError:
                return
            if not data:
                return
            self.chunks.append(data)

    def text(self) -> str:
        return b"".join(self.chunks).decode("utf-8", "replace")

    def plain(self) -> str:
        """Terminal output with CSI/OSC escape sequences stripped."""
        return re.sub(r"\x1b(\[[0-9;?]*[A-Za-z]|\][^\x07]*\x07)", "", self.text())

    def type_and_send(self, text: str, settle: float = 6.0) -> None:
        for ch in text:
            os.write(self.master, ch.encode())
            time.sleep(0.02)
        os.write(self.master, b"\r")
        time.sleep(settle)

    def close(self):
        self._stop = True
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            os.close(self.master)
        except OSError:
            pass


@pytest.fixture
def two_turn_session():
    backend = _Backend()
    tui = _Tui(_binary(), backend.port)
    try:
        time.sleep(1.5)
        yield tui, backend
    finally:
        tui.close()
        backend.close()


def test_first_turn_renders(two_turn_session):
    """Control: the turn that worked before must keep working."""
    tui, _ = two_turn_session
    tui.type_and_send(TURN1_USER)
    assert TURN1_USER in tui.plain(), "turn-1 user message missing"
    assert TURN1_REPLY in tui.plain(), "turn-1 reply missing"


def test_second_turn_renders_after_the_previous_turn_finished(two_turn_session):
    """The regression: a completed previous turn must not end the next one.

    The poll response always contains the whole session, so turn 1's
    `finish_reason="stop"` row is present during turn 2. Only a stop row that
    is *new* may end the turn.
    """
    tui, backend = two_turn_session
    tui.type_and_send(TURN1_USER)
    assert TURN1_REPLY in tui.plain()

    tui.type_and_send(TURN2_USER, settle=8.0)
    plain = tui.plain()
    assert TURN2_USER in plain, (
        "turn-2 user message never reached the viewport — the TUI stopped "
        "polling after it saw turn 1's finish_reason=stop"
    )
    assert TURN2_REPLY in plain, "turn-2 reply never reached the viewport"
    # The fake backend only serves turn 2's payloads once the client has sent
    # its second message, so reaching them proves polling continued.
    assert backend.state.posts == 2
