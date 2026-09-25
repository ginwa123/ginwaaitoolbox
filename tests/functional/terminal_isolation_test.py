"""Functional tests for per-user terminal isolation (plan 2026-09-25, W2.5).

Boots a REAL nalar binary via the harness (never a live dev server, never
port 8081). Two authenticated admins share ONE server process, so this is
the wire-level proof that user A cannot attach to, read, type into, resize,
or kill user B's PTY session.

Why a wire test and not only a unit test: the terminal registry is
in-memory and process-global (`terminal_session.zig`), and the owner is
resolved from the request cookie at the handler. Only a real two-cookie
round-trip exercises cookie -> auth_sessions -> users.id -> registry owner
-> attach rejection. A unit test that passes an owner straight into the
registry cannot catch a handler that forgets to resolve one.

Covers:
  * ATTACH-ISOLATION — B's input/output/resize/delete against A's terminal
                       id are all 404 (not 403, so B cannot probe for the
                       existence of A's ids).
  * OWN-ACCESS       — A can still drive its own terminal (guards against an
                       "everyone gets 404" false pass).
  * AUTH-OFF-REGRESS — without `--auth` the same create + output round-trip
                       still works.

Both users are created with `create-admin`, so the isolation assertions here
are also the admin-vs-admin assertions: `admin` grants NO cross-user
visibility (user decision 2026-09-25).
"""

from __future__ import annotations

import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from harness import FunctionalHarness


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
    assert "nalar_session=" in set_cookie
    return set_cookie.split("nalar_session=", 1)[1].split(";", 1)[0].strip()


def _create_terminal(port: int, cookie: str) -> str:
    status, _, body = _raw(
        "POST", port, "/api/terminal/sessions", body={"cwd": "/tmp"}, cookie=cookie
    )
    assert status == 201, body[:500]
    return json.loads(body.decode())["id"]


def _two_users(bin_path: Path):
    """Boot auth mode with two admins in the SAME server process."""
    h = _boot_auth(bin_path)
    _create_admin(bin_path, h.temp_dir, "a@example.com", "supersecret123")
    _create_admin(bin_path, h.temp_dir, "b@example.com", "supersecret123", force=True)
    tok_a = _login(h.port, "a@example.com", "supersecret123")
    tok_b = _login(h.port, "b@example.com", "supersecret123")
    return h, tok_a, tok_b


def test_foreign_terminal_attach_is_refused(default_nalar_bin: Path):
    """B must not be able to drive A's PTY by guessing its id.

    Every terminal route is keyed by a raw in-memory session id, so before
    the owner check B could read A's shell output, type into it, resize it,
    or kill it. All four are 404 for a foreign id.
    """
    h, tok_a, tok_b = _two_users(default_nalar_bin)
    try:
        term_a = _create_terminal(h.port, f"nalar_session={tok_a}")

        # A can drive its own terminal — proves the gate is not a blanket 404.
        status, _, body = _raw(
            "GET", h.port, f"/api/terminal/sessions/{term_a}/output", cookie=f"nalar_session={tok_a}"
        )
        assert status == 200, body[:300]

        # B cannot read A's output.
        status, _, _ = _raw(
            "GET", h.port, f"/api/terminal/sessions/{term_a}/output", cookie=f"nalar_session={tok_b}"
        )
        assert status == 404, f"expected 404 reading a foreign terminal, got {status}"

        # B cannot type into A's shell.
        status, _, _ = _raw(
            "POST", h.port, f"/api/terminal/sessions/{term_a}/input",
            body={"data": "echo pwned\n"}, cookie=f"nalar_session={tok_b}",
        )
        assert status == 404, f"expected 404 writing to a foreign terminal, got {status}"

        # B cannot resize A's PTY.
        status, _, _ = _raw(
            "POST", h.port, f"/api/terminal/sessions/{term_a}/resize",
            body={"cols": 100, "rows": 40}, cookie=f"nalar_session={tok_b}",
        )
        assert status == 404, f"expected 404 resizing a foreign terminal, got {status}"

        # B cannot kill A's shell.
        status, _, _ = _raw(
            "DELETE", h.port, f"/api/terminal/sessions/{term_a}", cookie=f"nalar_session={tok_b}"
        )
        assert status == 404, f"expected 404 deleting a foreign terminal, got {status}"

        # A's terminal survived every attempt and is still usable.
        status, _, body = _raw(
            "GET", h.port, f"/api/terminal/sessions/{term_a}/output", cookie=f"nalar_session={tok_a}"
        )
        assert status == 200, body[:300]
    finally:
        h.teardown()


def test_own_terminal_still_works_for_each_user(default_nalar_bin: Path):
    """Both users can drive their OWN terminals — no over-filtering."""
    h, tok_a, tok_b = _two_users(default_nalar_bin)
    try:
        term_a = _create_terminal(h.port, f"nalar_session={tok_a}")
        term_b = _create_terminal(h.port, f"nalar_session={tok_b}")

        for who, tok, term in (("A", tok_a, term_a), ("B", tok_b, term_b)):
            status, _, body = _raw(
                "GET", h.port, f"/api/terminal/sessions/{term}/output",
                cookie=f"nalar_session={tok}",
            )
            assert status == 200, f"{who} must read its own terminal: {body[:300]}"
            status, _, body = _raw(
                "POST", h.port, f"/api/terminal/sessions/{term}/input",
                body={"data": "echo ok\n"}, cookie=f"nalar_session={tok}",
            )
            assert status == 200, f"{who} must write to its own terminal: {body[:300]}"
    finally:
        h.teardown()


def test_terminal_auth_off_is_unchanged(default_nalar_bin: Path):
    """Regression: without `--auth` the create + output round-trip still works."""
    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        term = _create_terminal(h.port, "")
        status, _, body = _raw("GET", h.port, f"/api/terminal/sessions/{term}/output")
        assert status == 200, body[:300]
        status, _, body = _raw(
            "POST", h.port, f"/api/terminal/sessions/{term}/input", body={"data": "echo hi\n"}
        )
        assert status == 200, body[:300]
    finally:
        h.teardown()
