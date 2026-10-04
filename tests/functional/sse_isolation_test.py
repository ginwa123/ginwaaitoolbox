"""Functional tests for per-user SSE channel isolation (plan 2026-09-25, W3).

Boots a REAL pabrik binary + REAL SQLite via the harness (never a live dev
server, never port 8081). Two authenticated admins share ONE database and
BOTH open `/api/events?channels=sessions,workers`, so this is the wire-level
proof that user A's live events never reach user B's EventSource.

Why a wire test and not only a unit test: the leak lives in the fan-out loop
of `unified_events_sse.zig` — the bus broadcasts by *family routing key*
(`sessions`, `workers`, `llm`, …), so every connected client receives every
user's events. A unit test that calls the filter directly cannot catch a
handler that forgets to record the client's owner at connect time, nor a
fan-out that skips the filter. Only a real two-cookie round-trip exercises
cookie -> auth_sessions -> users.id -> client registry -> fan-out.

Covers:
  * SESSIONS-CHANNEL — A renames its session; B's stream must see ZERO frames
                       mentioning A's session id, while A's own stream does.
  * OWN-EVENTS       — B still receives its OWN session events (guards against
                       an "everyone gets nothing" false pass).
  * AUTH-OFF-REGRESS — without `--auth` the same rename still reaches a
                       connected client (byte-identical legacy behaviour).

Both users are created with `create-admin`, so the isolation assertions here
are also the admin-vs-admin assertions: `admin` grants NO cross-user
visibility (user decision 2026-09-25).
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from harness import FunctionalHarness


# ─── raw HTTP (cookie jars are just strings here) ─────────────────────────


def _raw(method: str, port: int, path: str, *, body=None, cookie: str | None = None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if cookie is not None:
        headers["Cookie"] = cookie
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict((e.headers.items() if e.headers else [])), e.read()


def _boot_auth(bin_path: Path) -> FunctionalHarness:
    return FunctionalHarness.boot(bin_path, extra_args=("--auth",))


def _create_admin(bin_path: Path, home: Path, email: str, password: str, *, force: bool = False) -> None:
    env = dict(os.environ)
    env["HOME"] = str(home)
    args = [str(bin_path), "create-admin", "--email", email, "--password", password]
    if force:
        args.append("--force")
    r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=30)
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _login(port: int, email: str, password: str) -> str:
    status, headers, body = _raw(
        "POST", port, "/api/auth/login", body={"email": email, "password": password}
    )
    assert status == 200, body[:500]
    set_cookie = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
    assert "pabrik_session=" in set_cookie
    return set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()


def _create_session(port: int, cookie: str, session_id: str) -> str:
    """Create a session with an EXPLICIT id.

    The auto-generated id is timestamp-based (`sess_<unix>_<rand>`), so two
    creates in the same second can collide — and a colliding second create is
    an `INSERT OR IGNORE` no-op on the first user's row, which then 404s for
    the second user. Explicit ids keep the two users' sessions distinct.
    """
    status, _, body = _raw(
        "POST", port, "/api/session", body={"session_id": session_id}, cookie=cookie
    )
    assert status == 201, body[:500]
    return json.loads(body.decode())["id"]


def _rename_session(port: int, session_id: str, name: str, cookie: str) -> None:
    """Rename a session, waiting for its row to exist.

    `POST /api/session` returns before the row is INSERTed: the insert runs
    in the concurrent `emit_run_agent` task (`root.zig::insert_worker`). The
    `:session_id` middleware choke point 404s a not-yet-existing row, so a
    rename issued immediately after create can race the insert. Retry until
    the row lands (bounded), then assert the rename succeeded.
    """
    deadline = time.monotonic() + 10.0
    last = (0, b"")
    while time.monotonic() < deadline:
        status, _, body = _raw(
            "PUT", port, f"/api/session/{session_id}", body={"name": name}, cookie=cookie
        )
        if status == 200:
            return
        last = (status, body)
        time.sleep(0.1)
    raise AssertionError(f"rename never succeeded: {last[0]} {last[1][:300]!r}")


def _two_users(bin_path: Path):
    """Boot auth mode with two admins in the SAME database."""
    h = _boot_auth(bin_path)
    _create_admin(bin_path, h.temp_dir, "a@example.com", "supersecret123")
    _create_admin(bin_path, h.temp_dir, "b@example.com", "supersecret123", force=True)
    tok_a = _login(h.port, "a@example.com", "supersecret123")
    tok_b = _login(h.port, "b@example.com", "supersecret123")
    return h, tok_a, tok_b


# ─── SSE reader ───────────────────────────────────────────────────────────
#
# A raw socket reader, not urllib: the stream never ends, so `urlopen`
# would block forever. We read bytes in a background thread into a list
# and let the test poll that list. The connection is closed on teardown.


class SseReader:
    """Reads an SSE stream over a raw socket into a growing byte buffer."""

    def __init__(self, port: int, path: str, cookie: str | None):
        self.port = port
        self.path = path
        self.cookie = cookie
        self.buf = bytearray()
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self.connected = threading.Event()

    def start(self) -> "SseReader":
        self._sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        self._sock.settimeout(0.5)
        req = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.port}\r\n"
            "Accept: text/event-stream\r\n"
            "Connection: keep-alive\r\n"
        )
        if self.cookie:
            req += f"Cookie: {self.cookie}\r\n"
        req += "\r\n"
        self._sock.sendall(req.encode())
        self._thread = threading.Thread(target=self._pump, daemon=True)
        self._thread.start()
        return self

    def _pump(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                return
            self.buf.extend(chunk)
            if b"event: connected" in self.buf:
                self.connected.set()

    def text(self) -> str:
        return self.buf.decode("utf-8", errors="replace")

    def wait_connected(self, timeout_s: float = 10.0) -> bool:
        return self.connected.wait(timeout_s)

    def wait_for(self, needle: str, timeout_s: float = 10.0) -> bool:
        """Wait until `needle` appears in the stream. False on timeout."""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if needle in self.text():
                return True
            time.sleep(0.05)
        return False

    def close(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=2)


def _open_stream(port: int, cookie: str | None, channels: str = "sessions,workers") -> SseReader:
    r = SseReader(port, f"/api/events?channels={channels}", cookie).start()
    assert r.wait_connected(), "SSE stream never emitted the `connected` handshake"
    return r


# ─── tests ────────────────────────────────────────────────────────────────


def test_sse_does_not_deliver_foreign_session_events(default_pabrik_bin: Path):
    """A's session rename must never reach B's EventSource.

    This is the W3 leak: the bus fans out by family routing key, so before
    the fix B's `?channels=sessions` stream received A's `session_updated`
    frame verbatim. The assertion is on A's session id appearing anywhere in
    B's stream — the payload carries `id`, so a leak is unmistakable.
    """
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    stream_a = stream_b = None
    try:
        sess_a = _create_session(h.port, f"pabrik_session={tok_a}", "sess_iso_a_1")
        sess_b = _create_session(h.port, f"pabrik_session={tok_b}", "sess_iso_b_1")

        stream_a = _open_stream(h.port, f"pabrik_session={tok_a}")
        stream_b = _open_stream(h.port, f"pabrik_session={tok_b}")

        # A renames its own session — this emits `session_updated` on the
        # `sessions` routing key with A's session id in the payload.
        _rename_session(h.port, sess_a, "A renamed this", f"pabrik_session={tok_a}")

        # A's own stream must receive it (proves the event was actually
        # published, so B's silence is isolation and not a dead bus).
        assert stream_a.wait_for(sess_a), (
            "A's own stream never received its session event — the event was "
            "not published, so this test cannot prove isolation.\n"
            f"A stream tail:\n{stream_a.text()[-2000:]}"
        )

        # B must receive ZERO frames mentioning A's session id.
        time.sleep(1.0)
        assert sess_a not in stream_b.text(), (
            "LEAK: B's SSE stream received A's session event.\n"
            f"B stream tail:\n{stream_b.text()[-2000:]}"
        )
    finally:
        if stream_a is not None:
            stream_a.close()
        if stream_b is not None:
            stream_b.close()
        h.teardown()


def test_sse_still_delivers_own_events_to_each_user(default_pabrik_bin: Path):
    """Both users receive their OWN session events — no over-filtering.

    Guards the false pass where the filter drops everything: B must still
    see B's rename, and A must still see A's.
    """
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    stream_a = stream_b = None
    try:
        sess_a = _create_session(h.port, f"pabrik_session={tok_a}", "sess_iso_a_2")
        sess_b = _create_session(h.port, f"pabrik_session={tok_b}", "sess_iso_b_2")

        stream_a = _open_stream(h.port, f"pabrik_session={tok_a}")
        stream_b = _open_stream(h.port, f"pabrik_session={tok_b}")

        _rename_session(h.port, sess_a, "A own rename", f"pabrik_session={tok_a}")
        _rename_session(h.port, sess_b, "B own rename", f"pabrik_session={tok_b}")

        assert stream_a.wait_for(sess_a), "A must receive its own session event"
        assert stream_b.wait_for(sess_b), "B must receive its own session event"

        # And neither sees the other's.
        time.sleep(0.5)
        assert sess_b not in stream_a.text(), "A received B's session event"
        assert sess_a not in stream_b.text(), "B received A's session event"
    finally:
        if stream_a is not None:
            stream_a.close()
        if stream_b is not None:
            stream_b.close()
        h.teardown()


def test_sse_auth_off_still_delivers_events(default_pabrik_bin: Path):
    """Regression: without `--auth` the stream still delivers session events.

    With auth off there is no identity, so the system user sees everything
    and the fan-out filter must be a no-op — the pre-isolation behaviour.
    """
    h = FunctionalHarness.boot(default_pabrik_bin)
    stream = None
    try:
        sess = _create_session(h.port, "", "sess_iso_noauth")
        stream = _open_stream(h.port, None)
        _rename_session(h.port, sess, "no-auth rename", "")
        assert stream.wait_for(sess), (
            "auth-off stream must still receive session events\n"
            f"stream tail:\n{stream.text()[-2000:]}"
        )
    finally:
        if stream is not None:
            stream.close()
        h.teardown()
