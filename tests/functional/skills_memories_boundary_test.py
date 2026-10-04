"""Functional tests for the skills/memories filesystem boundary (plan 2026-09-25, W2.6).

Boots a REAL pabrik binary via the harness (never a live dev server, never
port 8081). Two authenticated admins share ONE server process and ONE OS
account, so this is the wire-level proof of what W2.6 can and cannot scope.

WHY THIS FILE ASSERTS A BOUNDARY RATHER THAN ISOLATION
------------------------------------------------------
`/api/skills*` and `/api/memories*` are **filesystem-scoped**, not DB rows:

  * global skills/memories live in `~/.config/pabrik/skills|memories/` — one
    directory per OS account, shared by every browser user on the machine;
  * local skills/memories live in `{cwd}/.pabrik/skills|memories/` — and
    `cwd` is caller-supplied.

There is no `user_id` column to filter on, so "scope them per user" would
mean inventing a per-user filesystem root — which is the **deferred D9
boundary** (per-user OS uid/chroot or a workspace-root allowlist), not a
row-level predicate. The plan explicitly defers that decision.

A fake fix here would be worse than none: it would make the system *look*
isolated while the same bytes stay readable by path. So this file pins the
boundary as a documented, tested fact:

  * GLOBAL-SHARED  — B's `GET /api/skills` / `/api/memories` sees the same
                     global entries as A's (the shared OS-account directory).
  * LOCAL-CWD      — the local list follows the caller-supplied `?cwd=`, so
                     B can point at A's workspace directory and read its
                     `.pabrik/` files. This is the D9 boundary, asserted so a
                     future change that closes it must update this test.
  * AUTH-OFF       — without `--auth` the same endpoints still work.

Both users are created with `create-admin`, so the assertions here are also
the admin-vs-admin assertions: `admin` grants NO cross-user visibility.
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
    assert "pabrik_session=" in set_cookie
    return set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()


def _two_users(bin_path: Path):
    h = _boot_auth(bin_path)
    _create_admin(bin_path, h.temp_dir, "a@example.com", "supersecret123")
    _create_admin(bin_path, h.temp_dir, "b@example.com", "supersecret123", force=True)
    tok_a = _login(h.port, "a@example.com", "supersecret123")
    tok_b = _login(h.port, "b@example.com", "supersecret123")
    return h, tok_a, tok_b


def _write_local_memory(cwd: Path, name: str, body: str) -> None:
    d = cwd / ".pabrik" / "memories"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{name}.md").write_text(body, encoding="utf-8")


def test_global_skills_and_memories_are_shared_across_users(default_pabrik_bin: Path):
    """The global dir is one per OS account — both users see the same entries.

    This is the D9 boundary, not a bug in the row-level isolation: there is
    no `user_id` on a file. Asserted so the boundary is visible and a future
    per-user filesystem root must update this test.
    """
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    try:
        # A creates a global memory via the API.
        status, _, body = _raw(
            "POST", h.port, "/api/memories",
            body={"name": "shared-note.md", "content": "# shared\n\nbody"},
            cookie=f"pabrik_session={tok_a}",
        )
        assert status in (200, 201), body[:500]

        # B sees it in the global list — same OS-account directory.
        status, _, b_body = _raw("GET", h.port, "/api/memories", cookie=f"pabrik_session={tok_b}")
        assert status == 200, b_body[:300]
        assert "shared-note" in b_body.decode(), (
            "global memories are one directory per OS account; B must see A's "
            "entry (D9 boundary). If this now fails, the boundary was closed — "
            "update this test and the plan's D9 section."
        )

        # Same for skills: both users get a 200 with the same global set.
        for who, tok in (("A", tok_a), ("B", tok_b)):
            status, _, s_body = _raw("GET", h.port, "/api/skills", cookie=f"pabrik_session={tok}")
            assert status == 200, f"{who} skills list: {s_body[:300]}"
    finally:
        h.teardown()


def test_local_memories_follow_the_caller_supplied_cwd(default_pabrik_bin: Path, tmp_path: Path):
    """`?cwd=` is caller-supplied, so B can read A's workspace `.pabrik/` files.

    This is the D9 filesystem boundary in its sharpest form: the local
    memories endpoint is a path-scoped file read, and the path comes from the
    request. Asserted (not "fixed") because closing it means a per-user
    filesystem root or a workspace-root allowlist — a separate decision.
    """
    h, tok_a, tok_b = _two_users(default_pabrik_bin)
    try:
        a_dir = tmp_path / "a-workspace"
        a_dir.mkdir()
        _write_local_memory(a_dir, "a-secret", "# A's local memory\n\nprivate-ish")

        # A reads its own local memories.
        status, _, a_body = _raw(
            "GET", h.port, f"/api/local-memories?cwd={a_dir}",
            cookie=f"pabrik_session={tok_a}",
        )
        assert status == 200, a_body[:300]
        assert "a-secret" in a_body.decode()

        # B points at A's directory and reads the same file — the boundary.
        status, _, b_body = _raw(
            "GET", h.port, f"/api/local-memories?cwd={a_dir}",
            cookie=f"pabrik_session={tok_b}",
        )
        assert status == 200, b_body[:300]
        assert "a-secret" in b_body.decode(), (
            "local memories are path-scoped and `cwd` is caller-supplied; B "
            "reading A's directory is the D9 boundary. If this now fails, the "
            "boundary was closed — update this test and the plan's D9 section."
        )
    finally:
        h.teardown()


def test_skills_and_memories_auth_off_is_unchanged(default_pabrik_bin: Path):
    """Regression: without `--auth` both endpoints still work."""
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        status, _, body = _raw("GET", h.port, "/api/skills")
        assert status == 200, body[:300]
        status, _, body = _raw("GET", h.port, "/api/memories")
        assert status == 200, body[:300]
        # `/api/local-memories` needs a cwd (query or server cwd); pass one.
        status, _, body = _raw("GET", h.port, f"/api/local-memories?cwd={h.temp_dir}")
        assert status == 200, body[:300]
    finally:
        h.teardown()
