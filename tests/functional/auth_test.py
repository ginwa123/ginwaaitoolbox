"""Functional tests for opt-in `--auth` mode.

Boots a REAL nalar binary + REAL SQLite via the harness (never a live
dev server, never port 8081). Replays the EXACT wire flows the login
page uses: unauthenticated API -> 401, login -> Set-Cookie, authed
request -> 200, logout -> clear, empty cookie -> 401.

Covers:
  * OPEN-BY-DEFAULT — no `--auth` flag: /api/workspaces 200, no cookie.
  * GATE — with `--auth`: /api/workspaces without cookie -> 401.
  * LOGIN-FLOW — create-admin -> login -> Set-Cookie (HttpOnly) ->
    authed GET works -> /api/auth/me 200 -> logout clears.
  * EMPTY-COOKIE — `Cookie: nalar_session=` -> 401 (not 500).
  * EXEMPT — /health + /api/auth/login reachable without cookie when on.
"""

from __future__ import annotations

import json
import os
import subprocess
import urllib.parse
import urllib.request
import urllib.error
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


def test_open_by_default(harness: FunctionalHarness):
    r = harness.http("GET", "/api/workspaces", expect=200)
    assert isinstance(r.json(), (list, dict))


def test_gate_without_cookie(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        status, _, _ = _raw("GET", h.port, "/api/workspaces")
        assert status == 401
    finally:
        h.teardown()


def test_exempt_routes_without_cookie(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        status, _, _ = _raw("GET", h.port, "/health")
        assert status == 200
        status, _, _ = _raw("POST", h.port, "/api/auth/login", body={"email": "x@y.z", "password": "nope"})
        assert status in (401, 400)
    finally:
        h.teardown()


def test_empty_cookie_is_401(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        status, _, _ = _raw("GET", h.port, "/api/workspaces", cookie="nalar_session=")
        assert status == 401
    finally:
        h.teardown()


def test_login_flow(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "admin@example.com", "supersecret123")
        status, headers, body = _raw(
            "POST", h.port, "/api/auth/login",
            body={"email": "admin@example.com", "password": "supersecret123"},
        )
        assert status == 200, body[:500]
        set_cookie = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
        assert "nalar_session=" in set_cookie
        assert "HttpOnly" in set_cookie
        # Extract raw token for subsequent requests.
        token = set_cookie.split("nalar_session=", 1)[1].split(";", 1)[0].strip()
        assert len(token) > 16

        status, _, _ = _raw("GET", h.port, "/api/workspaces", cookie=f"nalar_session={token}")
        assert status == 200

        status, _, me_body = _raw("GET", h.port, "/api/auth/me", cookie=f"nalar_session={token}")
        assert status == 200
        me = json.loads(me_body.decode())
        assert me["authenticated"] is True
        assert me["user"]["email"] == "admin@example.com"

        # Wrong password stays 401 with no user enumeration.
        status, _, _ = _raw(
            "POST", h.port, "/api/auth/login",
            body={"email": "admin@example.com", "password": "wrongpass1"},
        )
        assert status == 401

        # Logout clears the session server-side.
        status, logout_headers, _ = _raw("POST", h.port, "/api/auth/logout", cookie=f"nalar_session={token}")
        assert status == 200
        assert "Max-Age=0" in (logout_headers.get("Set-Cookie") or "")
        status, _, _ = _raw("GET", h.port, "/api/workspaces", cookie=f"nalar_session={token}")
        assert status == 401
    finally:
        h.teardown()


def test_create_admin_refuses_second_without_force(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "one@example.com", "supersecret123")
        env = dict(os.environ)
        env["HOME"] = str(h.temp_dir)
        r = subprocess.run(
            [str(default_nalar_bin), "create-admin", "--email", "two@example.com", "--password", "supersecret123"],
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
        )
        assert r.returncode != 0
    finally:
        h.teardown()
