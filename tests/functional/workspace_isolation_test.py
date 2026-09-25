"""Functional tests for per-user workspace isolation (plan 2026-09-25, W1 + W2.1).

Boots a REAL nalar binary + REAL SQLite via the harness (never a live dev
server, never port 8081). Two authenticated admins share ONE database, so
this is the wire-level proof that user A cannot see user B's workspaces.

Why a wire test and not only a unit test: the isolation rule lives in the
route handler plus the SQL predicate, and only a real round-trip exercises
the server-derived owner end to end (cookie -> auth_sessions -> users.id).
A unit test that passes an owner string straight into the query cannot catch
a handler that forgets to resolve one, or a predicate that binds the wrong
parameter.

Covers:
  * LIST-ISOLATION   — A's workspace never appears in B's GET /api/workspaces.
  * GET-ISOLATION    — B's GET of A's workspace id is 404 (not 403, so B
                       cannot probe for the existence of A's ids).
  * OWN-READ         — A can still read the workspace it created (guards
                       against an "empty list for everyone" false pass).
  * AUTH-OFF-REGRESS — without `--auth` the same routes still work and list
                       what was just created.

Both users are created with `create-admin`, so the isolation assertions here
are also the admin-vs-admin assertions: `admin` grants NO cross-user
visibility (user decision 2026-09-25).
"""

from __future__ import annotations

import json
import os
import subprocess
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


def _create_workspace(port: int, name: str, cookie: str) -> str:
    status, _, body = _raw("POST", port, "/api/workspaces", body={"name": name}, cookie=cookie)
    assert status == 201, body[:500]
    return json.loads(body.decode())["id"]


def _list_workspace_ids(port: int, cookie: str) -> list[str]:
    status, _, body = _raw("GET", port, "/api/workspaces?is_include_items=false", cookie=cookie)
    assert status == 200, body[:500]
    return [w["id"] for w in json.loads(body.decode())["workspaces"]]


def _two_users(bin_path: Path):
    """Boot auth mode with two admins in the SAME database."""
    h = _boot_auth(bin_path)
    _create_admin(bin_path, h.temp_dir, "a@example.com", "supersecret123")
    _create_admin(bin_path, h.temp_dir, "b@example.com", "supersecret123", force=True)
    tok_a = _login(h.port, "a@example.com", "supersecret123")
    tok_b = _login(h.port, "b@example.com", "supersecret123")
    return h, tok_a, tok_b


def test_workspaces_list_is_per_user(default_nalar_bin: Path):
    """A's workspace must not appear in B's list, and vice versa."""
    h, tok_a, tok_b = _two_users(default_nalar_bin)
    try:
        ws_a = _create_workspace(h.port, "A private", f"nalar_session={tok_a}")
        ws_b = _create_workspace(h.port, "B private", f"nalar_session={tok_b}")

        ids_a = _list_workspace_ids(h.port, f"nalar_session={tok_a}")
        ids_b = _list_workspace_ids(h.port, f"nalar_session={tok_b}")

        assert ws_a in ids_a, "A must see the workspace A created"
        assert ws_b in ids_b, "B must see the workspace B created"
        assert ws_b not in ids_a, "A must NOT see B's workspace"
        assert ws_a not in ids_b, "B must NOT see A's workspace"
    finally:
        h.teardown()


def test_workspace_get_by_foreign_id_is_404(default_nalar_bin: Path):
    """404 rather than 403: B must not learn that A's id exists."""
    h, tok_a, tok_b = _two_users(default_nalar_bin)
    try:
        ws_a = _create_workspace(h.port, "A only", f"nalar_session={tok_a}")

        own, _, body = _raw("GET", h.port, f"/api/workspaces/{ws_a}", cookie=f"nalar_session={tok_a}")
        assert own == 200, body[:300]

        status, _, _ = _raw("GET", h.port, f"/api/workspaces/{ws_a}", cookie=f"nalar_session={tok_b}")
        assert status == 404, f"expected 404 for a foreign workspace, got {status}"
    finally:
        h.teardown()


def test_auth_off_is_unchanged(default_nalar_bin: Path):
    """Regression: without `--auth` the create + list round-trip still works.

    No identity means the shared sentinel owns the row, so the same request
    that created it still sees it — the pre-isolation behaviour.
    """
    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        ws = _create_workspace(h.port, "No-auth workspace", "")
        assert ws in _list_workspace_ids(h.port, "")
    finally:
        h.teardown()


def test_foreign_delete_and_rename_are_refused(default_nalar_bin: Path):
    """B must not be able to DESTROY or rename A's workspace by guessing its id.

    This is the destructive half of "A must not interfere with B": a scoped
    list alone is not enough if DELETE still acts on a raw id.
    """
    h, tok_a, tok_b = _two_users(default_nalar_bin)
    try:
        ws_a = _create_workspace(h.port, "A do not touch", f"nalar_session={tok_a}")

        status, _, _ = _raw(
            "PUT", h.port, f"/api/workspaces/{ws_a}",
            body={"name": "hijacked"}, cookie=f"nalar_session={tok_b}",
        )
        assert status == 404, f"expected 404 on a foreign rename, got {status}"

        status, _, _ = _raw(
            "DELETE", h.port, f"/api/workspaces/{ws_a}", cookie=f"nalar_session={tok_b}"
        )
        assert status == 404, f"expected 404 on a foreign delete, got {status}"

        # A's workspace survived both attempts, with its original name.
        status, _, body = _raw(
            "GET", h.port, f"/api/workspaces/{ws_a}", cookie=f"nalar_session={tok_a}"
        )
        assert status == 200, body[:300]
        assert json.loads(body.decode())["name"] == "A do not touch"

        # And A can still delete its own workspace.
        status, _, _ = _raw(
            "DELETE", h.port, f"/api/workspaces/{ws_a}", cookie=f"nalar_session={tok_a}"
        )
        assert status == 200, "A must still be able to delete its own workspace"
    finally:
        h.teardown()


def test_items_of_a_foreign_workspace_are_refused(default_nalar_bin: Path):
    """B cannot list, create in, or delete inside A's workspace.

    These routes carry `:workspace_id` and previously never checked it, so a
    workspace being invisible did NOT stop B from adding or deleting items in
    it. The check now lives in one middleware choke point, which is why a
    single assertion here covers every child route.
    """
    h, tok_a, tok_b = _two_users(default_nalar_bin)
    try:
        ws_a = _create_workspace(h.port, "A items", f"nalar_session={tok_a}")
        items_url = f"/api/workspaces/{ws_a}/items"

        # A can list its own items — proves the gate is not a blanket 404.
        status, _, before = _raw("GET", h.port, items_url, cookie=f"nalar_session={tok_a}")
        assert status == 200, before[:300]

        # B cannot list them.
        status, _, _ = _raw("GET", h.port, items_url, cookie=f"nalar_session={tok_b}")
        assert status == 404, f"expected 404 listing a foreign workspace's items, got {status}"

        # B cannot add an item (the middleware rejects before the body is parsed).
        status, _, _ = _raw(
            "POST", h.port, items_url, body={"name": "intruder"}, cookie=f"nalar_session={tok_b}"
        )
        assert status == 404, f"expected 404 adding to a foreign workspace, got {status}"

        # B cannot act on an item id inside A's workspace either.
        status, _, _ = _raw(
            "DELETE", h.port, f"{items_url}/whatever", cookie=f"nalar_session={tok_b}"
        )
        assert status == 404, f"expected 404 deleting inside a foreign workspace, got {status}"

        # A's items are byte-identical before and after B's attempts.
        status, _, after = _raw("GET", h.port, items_url, cookie=f"nalar_session={tok_a}")
        assert status == 200, after[:300]
        assert before == after, "A's items changed after B's attempts"
    finally:
        h.teardown()
