"""Wire-level proof that workspace visibility is driven by `workspace_members`.

Implements docs/plans/2026-10-02-workspace-members-shared-workspaces.md
(Migration 100). The unit tests in migration.zig and workspaces_list.zig prove
the SQL and the mapping; these prove the parts a unit test structurally
cannot:

  * the create handler's TRANSACTION really commits BOTH the workspace row and
    the membership row — if it did not, a user could not see the workspace it
    just created, which is the failure the whole feature lives or dies on;
  * `normaliseOwnerId` is reached on the auth-off path, where the resolved
    owner is the sentinel and the NOT NULL column is the thing at risk;
  * delete really removes the membership row instead of orphaning it
    (`PRAGMA foreign_keys` is OFF, so nothing else would clean up);
  * the whole read path — middleware choke point, list filter, single GET —
    follows a membership row.

Membership rows are written with a direct SQLite INSERT because the
`/api/workspaces/:id/members` endpoints are deliberately NOT part of this
change (they were scoped as a follow-up in the plan). The point of these tests
is the READ path and the transaction wiring, both of which are fully exercised
once a row exists.

Never uses port 8081 and never touches a real dev server — see harness.py.
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

# --------------------------------------------------------------------------
# Wire helpers (kept local rather than imported so this file reads standalone,
# the same way workspace_isolation_test.py does it)
# --------------------------------------------------------------------------


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


def _create_admin(bin_path: Path, home: Path, email: str, password: str, *, force: bool = False) -> None:
    env = dict(os.environ)
    env["HOME"] = str(home)
    args = [str(bin_path), "create-admin", "--email", email, "--password", password]
    if force:
        args.append("--force")
    r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=30)
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _login(port: int, email: str, password: str) -> str:
    status, headers, body = _raw("POST", port, "/api/auth/login", body={"email": email, "password": password})
    assert status == 200, body[:500]
    set_cookie = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
    assert "pabrik_session=" in set_cookie
    return set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()


def _create_workspace(port: int, name: str, cookie: str) -> str:
    status, _, body = _raw("POST", port, "/api/workspaces", body={"name": name}, cookie=cookie)
    assert status == 201, body[:500]
    return json.loads(body.decode())["id"]


def _list_workspace_ids(port: int, cookie: str) -> list[str]:
    status, _, body = _raw("GET", port, "/api/workspaces?is_include_items=false", cookie=cookie)
    assert status == 200, body[:500]
    return [w["id"] for w in json.loads(body.decode())["workspaces"]]


def _two_users(bin_path: Path):
    """Auth mode, two admins, ONE database."""
    h = FunctionalHarness.boot(bin_path, extra_args=("--auth",))
    _create_admin(bin_path, h.temp_dir, "a@example.com", "supersecret123")
    _create_admin(bin_path, h.temp_dir, "b@example.com", "supersecret123", force=True)
    return h, _login(h.port, "a@example.com", "supersecret123"), _login(h.port, "b@example.com", "supersecret123")


# --------------------------------------------------------------------------
# DB helpers — the membership row is the unit of sharing, so assert on it
# --------------------------------------------------------------------------


def _db_path(h: FunctionalHarness) -> Path:
    return Path(h.temp_dir) / ".config" / "pabrik" / "agent.db"


def _db_connect(h: FunctionalHarness, *, read_only: bool) -> sqlite3.Connection:
    p = _db_path(h)
    assert p.exists(), f"database not found at {p}"
    if read_only:
        conn = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=5)
    else:
        # The server holds the same file; a short busy timeout turns a lock
        # collision into a retryable error rather than an instant failure.
        conn = sqlite3.connect(p, timeout=10)
    conn.execute("PRAGMA busy_timeout = 10000")
    return conn


def _user_id(h: FunctionalHarness, email: str) -> str:
    conn = _db_connect(h, read_only=True)
    try:
        row = conn.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        assert row is not None, f"no user row for {email}"
        return str(row[0])
    finally:
        conn.close()


def _members_of(h: FunctionalHarness, workspace_id: str) -> list[tuple[str, str]]:
    conn = _db_connect(h, read_only=True)
    try:
        rows = conn.execute(
            "SELECT user_id, role FROM workspace_members WHERE workspace_id = ? ORDER BY user_id",
            (workspace_id,),
        ).fetchall()
        return [(str(u), str(r)) for u, r in rows]
    finally:
        conn.close()


def _add_member(h: FunctionalHarness, workspace_id: str, user_id: str, role: str = "viewer") -> None:
    conn = _db_connect(h, read_only=False)
    try:
        conn.execute(
            "INSERT OR IGNORE INTO workspace_members (workspace_id, user_id, role) VALUES (?, ?, ?)",
            (workspace_id, user_id, role),
        )
        conn.commit()
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------


def test_create_writes_a_membership_row_for_the_real_user(default_pabrik_bin: Path):
    """The create tx must commit the membership row too, or nobody sees it.

    This is the single most load-bearing assertion in the file: the whole
    read path is now membership-driven, so a workspace with no membership row
    is invisible to EVERYONE including its creator. A unit test of the SQL
    cannot catch a handler that only inserts the workspace row.
    """
    h, tok_a, _ = _two_users(default_pabrik_bin)
    try:
        ws = _create_workspace(h.port, "A private", f"pabrik_session={tok_a}")
        uid_a = _user_id(h, "a@example.com")

        members = _members_of(h, ws)
        assert members == [(uid_a, "owner")], f"expected exactly one owner membership, got {members}"

        # And the wire agrees: the creator still sees it.
        assert ws in _list_workspace_ids(h.port, f"pabrik_session={tok_a}")
    finally:
        h.teardown()


def test_auth_off_create_stores_the_sentinel_membership(default_pabrik_bin: Path):
    """Auth off -> owner resolves to the sentinel, and the row must land anyway.

    This is where `normaliseOwnerId` earns its keep: `SqliteBackend.exec`
    binds an empty slice as SQL NULL and `workspace_members.user_id` is NOT
    NULL, so without normalisation the auth-off create would fail outright
    with a constraint violation instead of writing the shared marker.
    """
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        ws = _create_workspace(h.port, "No-auth workspace", "")
        assert ws in _list_workspace_ids(h.port, "")

        members = _members_of(h, ws)
        assert members == [("user_system", "owner")], (
            f"auth-off create must store the shared sentinel membership, got {members}"
        )
    finally:
        h.teardown()


def test_shared_workspace_becomes_visible_to_the_second_user(default_pabrik_bin: Path):
    """The feature: one membership row is the entire difference.

    A's workspace is private, so B gets a 404 and never sees it in the list.
    Add one membership row and B sees it in BOTH the list and the direct GET,
    across every path that consults visibility.
    """
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    try:
        ws = _create_workspace(h.port, "A shares this", f"pabrik_session={tok_a}")
        uid_b = _user_id(h, "b@example.com")

        # Before: private.
        assert ws not in _list_workspace_ids(h.port, f"pabrik_session={tok_b}")
        status, _, _ = _raw("GET", h.port, f"/api/workspaces/{ws}", cookie=f"pabrik_session={tok_b}")
        assert status == 404, f"expected 404 before sharing, got {status}"

        _add_member(h, ws, uid_b, role="editor")

        # After: visible, on every read path.
        assert ws in _list_workspace_ids(h.port, f"pabrik_session={tok_b}")
        status, _, body = _raw("GET", h.port, f"/api/workspaces/{ws}", cookie=f"pabrik_session={tok_b}")
        assert status == 200, f"expected 200 after sharing, got {status}: {body[:300]}"
        assert json.loads(body.decode())["name"] == "A shares this"

        # The child routes are gated by the middleware choke point, so they
        # must open up too — otherwise sharing half-works.
        status, _, body = _raw("GET", h.port, f"/api/workspaces/{ws}/items", cookie=f"pabrik_session={tok_b}")
        assert status == 200, f"a member must reach the workspace's items, got {status}: {body[:300]}"

        # And the owner is unaffected by B being added.
        assert ws in _list_workspace_ids(h.port, f"pabrik_session={tok_a}")
    finally:
        h.teardown()


def test_removing_a_membership_revokes_access(default_pabrik_bin: Path):
    """Sharing is not a one-way door."""
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    try:
        ws = _create_workspace(h.port, "Temporary share", f"pabrik_session={tok_a}")
        uid_b = _user_id(h, "b@example.com")

        _add_member(h, ws, uid_b, role="viewer")
        assert ws in _list_workspace_ids(h.port, f"pabrik_session={tok_b}")

        conn = _db_connect(h, read_only=False)
        try:
            conn.execute(
                "DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?", (ws, uid_b)
            )
            conn.commit()
        finally:
            conn.close()

        assert ws not in _list_workspace_ids(h.port, f"pabrik_session={tok_b}")
        status, _, _ = _raw("GET", h.port, f"/api/workspaces/{ws}", cookie=f"pabrik_session={tok_b}")
        assert status == 404, f"expected 404 after revocation, got {status}"

        # The workspace itself is untouched — nothing was left behind on the
        # workspaces row that would keep re-granting access.
        assert ws in _list_workspace_ids(h.port, f"pabrik_session={tok_a}")
    finally:
        h.teardown()


def test_the_sentinel_membership_keeps_a_legacy_workspace_visible_to_everyone(default_pabrik_bin: Path):
    """The upgrade regression: an operator must not lose their sidebar.

    A workspace created before `--auth` was switched on carries no real owner.
    Migration 100's backfill turns that into a `user_system` membership, and
    the clause treats that row as "shared". If the backfill or the clause ever
    stops doing that, every pre-auth workspace silently disappears from every
    authenticated user's list — the single worst outcome of this migration.
    This test reproduces the backfilled state and asserts the wire result.
    """
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    try:
        ws = _create_workspace(h.port, "Pre-auth legacy", f"pabrik_session={tok_a}")
        uid_a = _user_id(h, "a@example.com")

        # Rewrite A's membership to exactly what the backfill emits for a
        # user_system-owned workspace: one sentinel row, owner role.
        conn = _db_connect(h, read_only=False)
        try:
            conn.execute("DELETE FROM workspace_members WHERE workspace_id = ?", (ws,))
            conn.execute(
                "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES (?, ?, ?)",
                (ws, "user_system", "owner"),
            )
            conn.commit()
        finally:
            conn.close()
        assert _members_of(h, ws) == [("user_system", "owner")], "fixture did not reach backfilled state"

        # A real, unrelated user now sees it.
        assert ws in _list_workspace_ids(h.port, f"pabrik_session={tok_b}")
        status, _, _ = _raw("GET", h.port, f"/api/workspaces/{ws}", cookie=f"pabrik_session={tok_b}")
        assert status == 200, f"a backfilled workspace must be readable by any user, got {status}"

        # The original owner keeps access too.
        assert ws in _list_workspace_ids(h.port, f"pabrik_session={tok_a}")
        assert uid_a  # keeps the variable meaningful; see _user_id above
    finally:
        h.teardown()


def test_delete_removes_the_membership_rows(default_pabrik_bin: Path):
    """No orphans: `PRAGMA foreign_keys` is OFF, so delete must clean up.

    Nothing in SQLite will drop the member rows for us, so if this regresses
    the table grows without bound and — worse — a re-created workspace that
    reused the id would inherit stale members.
    """
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    try:
        ws = _create_workspace(h.port, "Doomed", f"pabrik_session={tok_a}")
        uid_b = _user_id(h, "b@example.com")
        _add_member(h, ws, uid_b, role="viewer")
        assert len(_members_of(h, ws)) == 2

        status, _, _ = _raw("DELETE", h.port, f"/api/workspaces/{ws}", cookie=f"pabrik_session={tok_a}")
        assert status == 200, f"owner must be able to delete, got {status}"

        assert _members_of(h, ws) == [], f"member rows survived the delete: {_members_of(h, ws)}"
    finally:
        h.teardown()


def test_migration_100_actually_runs_on_a_real_boot(default_pabrik_bin: Path):
    """Prove Migration 100 is WIRED, not merely callable.

    The migration.zig unit tests call `Migration100AddWorkspaceMembers.up`
    directly, so they would all pass even if the struct were never registered
    in `allMigrations` — which on a real boot means no table, and every single
    workspace query failing with "no such table: workspace_members". Only a
    real boot proves the chain ran it.
    """
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        conn = _db_connect(h, read_only=True)
        try:
            ddl = conn.execute(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'workspace_members'"
            ).fetchone()
            assert ddl is not None, "workspace_members does not exist after a real boot"
            assert "PRIMARY KEY (workspace_id, user_id)" in str(ddl[0])

            idx = conn.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_workspace_members_user'"
            ).fetchone()
            assert int(idx[0]) == 1, "the user_id direction index is missing"

            # And recorded in the ledger, not merely applied — this is the
            # table the migration runner uses to skip work on the next boot.
            row = conn.execute(
                "SELECT name FROM schema_migrations WHERE version = 100"
            ).fetchone()
            assert row is not None, "migration 100 is not recorded in schema_migrations"
            assert str(row[0]) == "add_workspace_members", f"unexpected ledger name: {row[0]!r}"
        finally:
            conn.close()
    finally:
        h.teardown()
