"""New Chat "Session not found" regression.

Replays the EXACT wire the frontend sends when opening a brand-new chat:
the task row exists (sidebar navigates with task_xxx in the URL) but no
session row exists yet. The sidebar fires:

  POST /api/llm/session/:session_id/touched  body {}

and the profile dropdown may fire:

  PUT /api/llm/session/:session_id  body {selected_profile_model, name, ...}

Before the fix, the auth_middleware choke point 404'd with
{"error": "Session not found"} for the missing row BEFORE the handler's
ensureSessionExists could run — every New Chat open toasted twice.

Covers:
  * TOUCHED-LAZY-CREATE — POST touched on a never-seen id is 200 in auth-on
    mode (handler ensure-creates), not 404.
  * UPDATE-LAZY-CREATE — PUT update on a never-seen id is 200, not 404.
  * ISOLATION-PRESERVED — B touching A's EXISTING session is still 404
    (missing rows pass through, foreign rows do not).
"""

from __future__ import annotations

import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

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


def test_touched_lazy_creates_missing_session(default_nalar_bin: Path):
    """POST touched on a brand-new chat id must 200, not 404 Session not found."""
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "a@example.com", "supersecret123")
        tok = _login(h.port, "a@example.com", "supersecret123")
        cookie = f"nalar_session={tok}"

        # Frontend's New Chat id: task row exists, session row does not.
        new_id = "task_1790361260259_4_newchat"
        status, _, body = _raw("POST", h.port, f"/api/llm/session/{new_id}/touched", body={}, cookie=cookie)
        assert status == 200, f"expected 200 lazy-create, got {status}: {body[:500]}"
        payload = json.loads(body.decode())
        assert payload.get("success") is True
        assert payload.get("session_id") == new_id
    finally:
        h.teardown()


def test_update_lazy_creates_missing_session(default_nalar_bin: Path):
    """PUT update on a brand-new chat id must 200, not 404 session not found."""
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "a@example.com", "supersecret123")
        tok = _login(h.port, "a@example.com", "supersecret123")
        cookie = f"nalar_session={tok}"

        new_id = "task_1790361260259_4_profile"
        status, _, body = _raw(
            "PUT", h.port, f"/api/llm/session/{new_id}",
            body={"selected_profile_model": "", "name": "New Chat"},
            cookie=cookie,
        )
        assert status == 200, f"expected 200 lazy-create, got {status}: {body[:500]}"
    finally:
        h.teardown()


def test_foreign_existing_session_still_404(default_nalar_bin: Path):
    """Isolation preserved: B touching A's existing session is still 404."""
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "a@example.com", "supersecret123")
        _create_admin(default_nalar_bin, h.temp_dir, "b@example.com", "supersecret123", force=True)
        tok_a = _login(h.port, "a@example.com", "supersecret123")
        tok_b = _login(h.port, "b@example.com", "supersecret123")

        sid = "sess_owned_by_a"
        status, _, body = _raw(
            "POST", h.port, "/api/llm/session",
            body={"session_id": sid, "queue_message": "hello from A"},
            cookie=f"nalar_session={tok_a}",
        )
        assert status == 201, body[:500]
        # Wait for the async insert_worker to commit (create is async).
        import time

        deadline = time.time() + 10
        while time.time() < deadline:
            s, _, _ = _raw("GET", h.port, f"/api/llm/session/{sid}", cookie=f"nalar_session={tok_a}")
            if s == 200:
                break
            time.sleep(0.2)

        status_b, _, body_b = _raw(
            "POST", h.port, f"/api/llm/session/{sid}/touched", body={}, cookie=f"nalar_session={tok_b}"
        )
        assert status_b == 404, f"expected 404 for foreign session, got {status_b}: {body_b[:300]}"
        assert b"Session not found" in body_b
    finally:
        h.teardown()
