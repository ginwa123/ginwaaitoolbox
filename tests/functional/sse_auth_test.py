"""SSE auth-rejection must terminate the stream, never hang it.

Wire regression for "SSE always connecting on app launch": kabelweb
sends the SSE 200 headers BEFORE the handler runs, so the handler's
`res.jsonResponse(401)` on auth failure never reached the wire. The
client stayed registered and received heartbeats forever without ever
seeing `event: connected` — SseClient sat in 'connecting' forever.

Contract pinned here:
  * `--auth` on, no cookie: stream carries `event: auth_error`, then
    ENDS promptly (EOF). No immortal `data: ping` tail, no `connected`.
  * `--auth` on, valid cookie: `event: connected` arrives (happy path).
  * unknown `?channels=` token: stream ENDS promptly (same zombie
    pattern lived on the 400 paths).

Boots a real binary against an isolated tmpdir HOME (never port 8081).
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


def _raw(method: str, port: int, path: str, *, body=None, cookie: str | None = None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers: dict[str, str] = {}
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


def _boot_auth(bin_path: Path):
    return FunctionalHarness.boot(bin_path, extra_args=("--auth",))


def _create_admin(bin_path: Path, home: Path, email: str, password: str):
    env = dict(os.environ)
    env["HOME"] = str(home)
    r = subprocess.run(
        [str(bin_path), "create-admin", "--email", email, "--password", password],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _login(bin_path_port: int, email: str, password: str) -> str:
    status, headers, body = _raw(
        "POST", bin_path_port, "/api/auth/login",
        body={"email": email, "password": password},
    )
    assert status == 200, body[:500]
    set_cookie = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
    assert "nalar_session=" in set_cookie
    return set_cookie.split("nalar_session=", 1)[1].split(";", 1)[0].strip()


def _read_sse(port: int, channels: str, cookie: str | None, timeout_s: float):
    """Read an SSE stream until EOF or timeout.

    Returns (events, eof, raw_lines) where events is a list of
    (event_name, data) and eof is True when the server closed the
    stream before the deadline.
    """
    url = f"http://127.0.0.1:{port}/api/events?channels={channels}"
    headers: dict[str, str] = {}
    if cookie is not None:
        headers["Cookie"] = cookie
    req = urllib.request.Request(url, headers=headers)
    events: list[tuple[str | None, Any]] = []
    raw_lines: list[str] = []
    result: dict[str, Any] = {"eof": False}

    def reader() -> None:
        try:
            with urllib.request.urlopen(req, timeout=timeout_s + 5) as resp:
                assert "text/event-stream" in resp.headers.get("Content-Type", "")
                cur_event: str | None = None
                cur_data: list[str] = []
                while True:
                    line = resp.readline().decode("utf-8", errors="replace")
                    if line == "":
                        result["eof"] = True
                        break
                    raw_lines.append(line)
                    if line.startswith("event:"):
                        cur_event = line[len("event:"):].strip()
                    elif line.startswith("data:"):
                        cur_data.append(line[len("data:"):].strip())
                    elif line in ("\n", "\r\n"):
                        if cur_event is not None:
                            data_str = "\n".join(cur_data)
                            try:
                                data_obj = json.loads(data_str) if data_str else None
                            except json.JSONDecodeError:
                                data_obj = data_str
                            events.append((cur_event, data_obj))
                        cur_event = None
                        cur_data = []
        except Exception as e:  # noqa: BLE001 — teardown races are normal
            result["error"] = repr(e)

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    t.join(timeout=timeout_s)
    return events, result["eof"], raw_lines


def test_unauth_sse_terminates_with_auth_error(default_nalar_bin: Path):
    """--auth on, no cookie: auth_error event, then EOF. Never a hang."""
    h = _boot_auth(default_nalar_bin)
    try:
        events, eof, raw = _read_sse(h.port, "workers", None, timeout_s=10.0)
        names = [name for name, _ in events]
        assert "auth_error" in names, f"expected auth_error, got events={names} raw={raw[:10]}"
        assert "connected" not in names, "rejected stream must never handshake"
        assert eof, (
            "rejected SSE stream must END (server closes it); "
            f"got {len(raw)} lines with no EOF — zombie ping stream is back"
        )
    finally:
        h.teardown()


def test_authed_sse_gets_connected(default_nalar_bin: Path):
    """--auth on, valid cookie: the connected handshake arrives."""
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "sse@example.com", "supersecret123")
        token = _login(h.port, "sse@example.com", "supersecret123")
        events, _, _ = _read_sse(h.port, "workers", f"nalar_session={token}", timeout_s=8.0)
        names = [name for name, _ in events]
        assert "connected" in names, f"expected connected handshake, got {names}"
    finally:
        h.teardown()


def test_unknown_channel_terminates(harness: FunctionalHarness):
    """Unknown ?channels= token: stream ends promptly instead of hanging."""
    events, eof, raw = _read_sse(harness.port, "nope_not_a_channel", None, timeout_s=10.0)
    names = [name for name, _ in events]
    assert "connected" not in names
    assert eof, (
        "400-path SSE stream must END; "
        f"got {len(raw)} lines with no EOF — zombie stream is back"
    )
