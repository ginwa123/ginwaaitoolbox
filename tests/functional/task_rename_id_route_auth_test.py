"""Renaming a chat from the sidebar context menu — "Workspace not found".

Replays the EXACT wire the chat-row context menu sends (ChatsList.vue
`confirmRename` → `api.updateTaskSimple`):

    PUT /api/workspaces/tasks/<task_id>   body {"name": "<new name>"}

That path is id-only on purpose (task.id == session_id, Migration 052) so a
rename never has to carry a workspace/item scope. With `--auth` on it was
answering 404 `{"error": "Workspace not found"}` and the sidebar showed a
toast instead of renaming.

Root cause: `matchRoute` (kabelweb router.zig) walks the route table in
REGISTRATION order and `matchPathWithParams` writes each `:param` into the
shared `req.params` map BEFORE it knows the route matches — a pattern that
fails part-way leaves its partial params behind. `PUT
/api/workspaces/:workspace_id/items/:item_id` (main.zig) was registered
before `PUT /api/workspaces/tasks/:task_id`, so a rename request first
matched `:workspace_id` = "tasks" and then fell through at the `items`
literal. auth_middleware's choke point read that stale `workspace_id`,
`canSeeWorkspace("tasks")` was false, and the request 404'd before the
handler ever ran.

Covers:
  * ID-ONLY-RENAME — auth-on, PUT /api/workspaces/tasks/:id → 200 and BOTH
    `workspace_item_tasks.name` and `sessions.name` carry the new name.
  * NO-STRAY-PARAM — a rename must not be rejected as a workspace lookup;
    asserted on the exact 404 body so a regression names itself.
  * SCOPED-RENAME-STILL-GUARDED — the workspace-scoped PUT keeps working,
    and a foreign user's workspace id still 404s (isolation not weakened).
  * AUTH-OFF — same rename is 200 with no cookie (the common dev setup).
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
    assert "pabrik_session=" in set_cookie
    return set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()


def _seed_workspace_item_task(port: int, cookie: str, *, name: str = "Investigate settings bug"):
    """workspace → kanban item → task(+session). Mirrors the frontend's seed path."""
    status, _, body = _raw("POST", port, "/api/workspaces", body={"name": "rename-ws"}, cookie=cookie)
    assert status == 201, body[:500]
    ws_id = json.loads(body)["id"]

    status, _, body = _raw(
        "POST", port, f"/api/workspaces/{ws_id}/items/kanban", body={"name": "sprint-rename"}, cookie=cookie
    )
    assert status == 201, body[:500]
    item_id = json.loads(body)["item"]["id"]

    status, _, body = _raw(
        "POST",
        port,
        f"/api/workspaces/{ws_id}/items/{item_id}/kanban/tasks",
        body={"mode": "create_session", "name": name, "description": "desc"},
        cookie=cookie,
    )
    assert status == 201, body[:500]
    resp = json.loads(body)
    task_id = resp["task"]["id"]
    # task.id IS the session id (Migration 052 dropped the redundant column).
    assert resp["session"]["id"] == task_id
    return ws_id, item_id, task_id


def _task_name(port: int, cookie: str, ws_id: str, item_id: str, task_id: str) -> str:
    status, _, body = _raw(
        "GET", port, f"/api/workspaces/{ws_id}/items/{item_id}/tasks/{task_id}", cookie=cookie
    )
    assert status == 200, body[:500]
    return json.loads(body)["task"]["name"]


def _session_name(port: int, cookie: str, task_id: str) -> str:
    status, _, body = _raw("GET", port, f"/api/llm/session/{task_id}", cookie=cookie)
    assert status == 200, body[:500]
    return json.loads(body)["name"]


def test_id_only_rename_works_with_auth_on(default_pabrik_bin: Path):
    """The context menu's wire body must rename, not 404, when --auth is on."""
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "rename@example.com", "supersecret123")
        cookie = f"pabrik_session={_login(h.port, 'rename@example.com', 'supersecret123')}"
        ws_id, item_id, task_id = _seed_workspace_item_task(h.port, cookie)

        status, _, body = _raw(
            "PUT", h.port, f"/api/workspaces/tasks/{task_id}", body={"name": "AFTER RENAME"}, cookie=cookie
        )
        assert status == 200, f"rename returned {status}: {body[:500]}"
        assert json.loads(body)["success"] is True

        assert _task_name(h.port, cookie, ws_id, item_id, task_id) == "AFTER RENAME"
        assert _session_name(h.port, cookie, task_id) == "AFTER RENAME"
    finally:
        h.teardown()


def test_id_only_rename_is_not_a_workspace_lookup(default_pabrik_bin: Path):
    """Pins the exact failure: a stale `workspace_id` param must not 404 a rename.

    Asserted on the response BODY so a regression names itself instead of
    reading as "some 404 happened".
    """
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "stray@example.com", "supersecret123")
        cookie = f"pabrik_session={_login(h.port, 'stray@example.com', 'supersecret123')}"
        _, _, task_id = _seed_workspace_item_task(h.port, cookie)

        status, _, body = _raw(
            "PUT", h.port, f"/api/workspaces/tasks/{task_id}", body={"name": "no stray param"}, cookie=cookie
        )
        assert status != 404, f"rename 404'd: {body[:500]}"
        assert b"Workspace not found" not in body, (
            "the auth middleware read a `workspace_id` param the id-only route "
            f"never declared — a failed earlier route pattern leaked it: {body[:500]}"
        )
    finally:
        h.teardown()


def test_scoped_rename_still_isolated_between_users(default_pabrik_bin: Path):
    """Moving the id-only route earlier must not weaken the workspace guard."""
    h = _boot_auth(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir, "owner@example.com", "supersecret123")
        owner = f"pabrik_session={_login(h.port, 'owner@example.com', 'supersecret123')}"
        ws_id, item_id, task_id = _seed_workspace_item_task(h.port, owner)

        # Owner's own workspace: the scoped PUT still resolves and renames.
        status, _, body = _raw(
            "PUT",
            h.port,
            f"/api/workspaces/{ws_id}/items/{item_id}/tasks/{task_id}",
            body={"name": "SCOPED RENAME"},
            cookie=owner,
        )
        assert status == 200, f"scoped rename returned {status}: {body[:500]}"
        assert _task_name(h.port, owner, ws_id, item_id, task_id) == "SCOPED RENAME"

        # A second user must not be able to reach it by raw id.
        _create_admin(
            default_pabrik_bin, h.temp_dir, "intruder@example.com", "supersecret123", force=True
        )
        intruder = f"pabrik_session={_login(h.port, 'intruder@example.com', 'supersecret123')}"
        status, _, body = _raw(
            "PUT",
            h.port,
            f"/api/workspaces/{ws_id}/items/{item_id}/tasks/{task_id}",
            body={"name": "HIJACKED"},
            cookie=intruder,
        )
        assert status == 404, f"foreign scoped rename returned {status}: {body[:500]}"
        assert _task_name(h.port, owner, ws_id, item_id, task_id) == "SCOPED RENAME"
    finally:
        h.teardown()


def test_id_only_rename_with_auth_off(harness: FunctionalHarness):
    """Auth-off (the default dev setup) keeps renaming — the fix is not auth-specific."""
    ws = harness.http("POST", "/api/workspaces", json_body={"name": "rename-ws"}, expect=201).json()
    ws_id = ws["id"]
    kanban = harness.http(
        "POST", f"/api/workspaces/{ws_id}/items/kanban", json_body={"name": "sprint-rename"}, expect=201
    ).json()
    item_id = kanban["item"]["id"]
    created = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{item_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": "auth off chat"},
        expect=201,
    ).json()
    task_id = created["task"]["id"]

    put = harness.http("PUT", f"/api/workspaces/tasks/{task_id}", json_body={"name": "AFTER RENAME"}, expect=200).json()
    assert put["success"] is True

    got = harness.http(
        "GET", f"/api/workspaces/{ws_id}/items/{item_id}/tasks/{task_id}", expect=200
    ).json()["task"]
    assert got["name"] == "AFTER RENAME"
