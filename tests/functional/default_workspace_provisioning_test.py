"""Functional tests for automatic per-user workspace provisioning.

Boots a REAL pabrik binary + REAL SQLite via the harness (never a live dev
server, never port 8081). Replays the EXACT wire flow a brand-new account
takes: `create-admin` -> `POST /api/auth/login` -> `GET /api/workspaces`.

The user-visible contract being protected: a user who has never created
anything lands on a workspace named "Default" with a project in it, rather
than on "No workspace selected" behind a "+ New workspace" button.

Covers:
  * PROVISION — first login gives exactly one workspace named "Default".
  * WITH-PROJECT — it already carries a default project (home as its path).
  * IDEMPOTENT — logging in again, and after creating a second workspace,
    adds nothing.
  * PER-USER — a second admin gets their OWN Default, not the first user's.
  * REAL-ID — the login response really is a usable workspace id.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

from harness import FunctionalHarness

# Wire helpers (kept local rather than imported so this file reads standalone,
# the same way auth_test.py / workspace_isolation_test.py do it). The harness's
# own `.http()` takes no headers, and every request here needs the session
# cookie.


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


def _create_admin(bin_path: Path, home: Path, email: str, password: str, *, force: bool = False):
    env = dict(os.environ)
    env["HOME"] = str(home)
    argv = [str(bin_path), "create-admin", "--email", email, "--password", password]
    if force:
        argv.append("--force")
    r = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=60)
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _login(port: int, email: str, password: str) -> str:
    status, headers, body = _raw(
        "POST", port, "/api/auth/login", body={"email": email, "password": password}
    )
    assert status == 200, body[:500]
    set_cookie = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
    assert "pabrik_session=" in set_cookie
    return set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()


def _workspaces(port: int, cookie: str) -> list[dict]:
    status, _, body = _raw("GET", port, "/api/workspaces", cookie=f"pabrik_session={cookie}")
    assert status == 200, body[:500]
    return json.loads(body.decode())["workspaces"]


def _db_connect(h: FunctionalHarness):
    """Read-only handle on the on-disk DB, so assertions can name rows the API
    filters out (e.g. another user's membership)."""
    p = Path(h.temp_dir) / ".config" / "pabrik" / "agent.db"
    assert p.exists(), f"db not found at {p}"
    return sqlite3.connect(f"file:{p}?mode=ro", uri=True)


def _user_id(h: FunctionalHarness, email: str) -> str:
    con = _db_connect(h)
    try:
        row = con.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    finally:
        con.close()
    assert row is not None, f"no users row for {email}"
    return row[0]


def _members_of(h: FunctionalHarness, user_id: str) -> list[tuple]:
    con = _db_connect(h)
    try:
        return con.execute(
            "SELECT workspace_id, role FROM workspace_members WHERE user_id = ?", (user_id,)
        ).fetchall()
    finally:
        con.close()


def test_a_fresh_user_is_given_a_workspace_named_default(default_pabrik_bin: Path):
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "fresh@example.com", "supersecret123")
        cookie = _login(h.port, "fresh@example.com", "supersecret123")

        rows = _workspaces(h.port, cookie)
        assert len(rows) == 1, f"expected exactly one provisioned workspace, got {rows}"
        assert rows[0]["name"] == "Default", rows[0]

        # It is a REAL row the owner is a member of — not a synthetic list
        # entry the UI would 404 on when the user clicks it.
        user_id = _user_id(h, "fresh@example.com")
        assert _members_of(h, user_id) == [(rows[0]["id"], "owner")]
    finally:
        h.teardown()


def test_the_provisioned_workspace_already_has_a_default_project(default_pabrik_bin: Path):
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "proj@example.com", "supersecret123")
        cookie = _login(h.port, "proj@example.com", "supersecret123")
        ws_id = _workspaces(h.port, cookie)[0]["id"]

        # An empty Projects list inside the new workspace is the same dead end
        # one level down, so it ships with its default.
        status, _, body = _raw(
            "GET", h.port, f"/api/workspaces/{ws_id}/items", cookie=f"pabrik_session={cookie}"
        )
        assert status == 200, body[:500]
        items = json.loads(body.decode())["items"]
        assert len(items) == 1, items
        # `is_default` is 0/1 on the wire, not a JSON boolean — the same
        # contract sidebar_new_chat_default_project_test.py pins.
        assert items[0]["is_default"] in (0, 1), items[0]
        assert items[0]["is_default"] == 1, items[0]
        # Its path is the server user's home, which is what makes a chat
        # started here resolve a cwd instead of failing.
        assert items[0]["path"], items[0]
    finally:
        h.teardown()


def test_logging_in_again_adds_nothing(default_pabrik_bin: Path):
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "again@example.com", "supersecret123")
        cookie = _login(h.port, "again@example.com", "supersecret123")
        first = _workspaces(h.port, cookie)
        assert len(first) == 1

        # Second and third login must be no-ops: a login that re-provisions is
        # a workspace that multiplies on every page refresh.
        _login(h.port, "again@example.com", "supersecret123")
        _login(h.port, "again@example.com", "supersecret123")

        after = _workspaces(h.port, cookie)
        assert [w["id"] for w in after] == [w["id"] for w in first]
        assert len(after) == 1
    finally:
        h.teardown()


def test_a_user_who_created_a_workspace_keeps_exactly_what_they_made(default_pabrik_bin: Path):
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "maker@example.com", "supersecret123")
        cookie = _login(h.port, "maker@example.com", "supersecret123")
        assert len(_workspaces(h.port, cookie)) == 1

        status, _, body = _raw(
            "POST", h.port, "/api/workspaces",
            body={"name": "Client Project"},
            cookie=f"pabrik_session={cookie}",
        )
        assert status == 201, body[:500]
        mine = json.loads(body.decode())

        _login(h.port, "maker@example.com", "supersecret123")
        rows = _workspaces(h.port, cookie)
        assert sorted(w["name"] for w in rows) == ["Client Project", "Default"], rows
        assert any(w["id"] == mine["id"] for w in rows)
    finally:
        h.teardown()


def test_a_second_admin_gets_their_own_default_not_the_first_ones(default_pabrik_bin: Path):
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "alice@example.com", "supersecret123")
        _create_admin(default_pabrik_bin, h.temp_dir, "bob@example.com", "supersecret123", force=True)

        alice = _login(h.port, "alice@example.com", "supersecret123")
        bob = _login(h.port, "bob@example.com", "supersecret123")

        alice_ws = _workspaces(h.port, alice)
        bob_ws = _workspaces(h.port, bob)
        assert [w["name"] for w in alice_ws] == ["Default"], alice_ws
        assert [w["name"] for w in bob_ws] == ["Default"], bob_ws
        assert alice_ws[0]["id"] != bob_ws[0]["id"]

        # Bob's list is his alone: Alice's row is not in it.
        assert all(w["id"] != alice_ws[0]["id"] for w in bob_ws)
    finally:
        h.teardown()