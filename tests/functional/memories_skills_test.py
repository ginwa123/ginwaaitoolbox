"""Functional tests for memories + skills.

Memories are full CRUD via HTTP (POST/GET/PUT/DELETE) and stay
file-system-managed: they are .md files under
`~/.config/pabrik/memories/`.

Skills are NOT file-system-managed any more. They are rows in the
workspace-scoped `skills` table (Migration 101), reachable at
`/api/workspaces/:workspace_id/skills[/:skill_name]`; the two
`~/.config/pabrik/skills/` and `<cwd>/.pabrik/skills/` tiers and the
`path` / `is_global` / `deleted_from` fields that described them are
gone. Creation is an agent tool (`add_skill`), so this file seeds rows
into the harness's isolated database directly. Plan:
docs/plans/2026-10-04-skills-sqlite-table.md.

Plan: docs/superpowers/plans/2026-07-26-functional-tests-with-real-data.md (Chunk 6)
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "ms-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _list_memories(harness: FunctionalHarness) -> list[dict[str, Any]]:
    r = harness.http("GET", "/api/memories", expect=200)
    return r.json()["memories"]


def _list_skills(harness: FunctionalHarness, workspace_id: str) -> list[dict[str, Any]]:
    """GET /api/workspaces/:workspace_id/skills returns {skills:[...]}.

    One flat array of {name, description}. The old payload was two arrays
    (`global_skills` + `local_skills`) plus a `cwd`, which is the
    two-directory precedence this change removed.
    """
    r = harness.http("GET", f"/api/workspaces/{workspace_id}/skills", expect=200)
    return r.json()["skills"]


def _seed_skill_row(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str,
    description: str = "Seeded by the functional test.",
    content: str = "---\nname: %s\ndescription: %s\n---\n\nbody\n",
) -> None:
    """Insert one `skills` row straight into the harness's database.

    There is no HTTP create route for skills — `add_skill` is an agent
    tool — so a test that needs a row to read writes one. Written the way
    `skills_store.upsertSkill` writes it, `COALESCE(NULLIF(?, ''), '')`
    included: `SqliteBackend.exec` binds an empty slice as SQL NULL, which
    would violate the NOT NULL constraint on `description`.
    """
    db = Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"
    assert db.exists(), f"database not found at {db}"
    con = sqlite3.connect(db)
    try:
        con.execute(
            "INSERT INTO skills "
            "(id, workspace_id, name, description, content, created_at, updated_at) "
            "VALUES (?, ?, ?, COALESCE(NULLIF(?, ''), ''), "
            "COALESCE(NULLIF(?, ''), ''), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
            (f"sk_seed_{workspace_id}_{name}", workspace_id, name, description, content),
        )
        con.commit()
    finally:
        con.close()


def _get_memory_disk_path(harness: FunctionalHarness, name: str) -> Path:
    """Return the absolute path where a memory file lives on disk.

    Memories live in $XDG_CONFIG_HOME/pabrik/memories/<name> or
    $HOME/.config/pabrik/memories/<name> (Windows: %APPDATA%/pabrik).
    The harness isolates all three, but the file is at the XDG/.config
    location on Windows (where XDG_CONFIG_HOME is now isolated to
    temp_dir/.config). Use that path for assertions; fallback to
    APPDATA if not found (covers old harness without XDG isolation).
    """
    # Check XDG/.config first (current Windows isolation), then APPDATA.
    config_base = harness.temp_dir / ".config" / "pabrik" / "memories" / name
    if config_base.exists():
        return config_base
    appdata_base = harness.temp_dir / "AppData" / "Roaming" / "pabrik" / "memories" / name
    if appdata_base.exists():
        return appdata_base
    # Default for new writes: use the XDG/.config location (matches
    # harness's isolated XDG_CONFIG_HOME on Windows and HOME/.config on Linux).
    return config_base


# ─── Test 1: create + list a global memory ─────────────────────────────


def test_create_global_memory_writes_to_disk(
    harness: FunctionalHarness,
) -> None:
    """POST /api/memories creates a .md file at $HOME/.config/pabrik/memories/<name>."""
    body = harness.http(
        "POST",
        "/api/memories",
        json_body={"name": "test-mem.md", "content": "# Hello\n\nMemory body."},
        expect=201,
    ).json()
    assert "memory" in body
    mem = body["memory"]
    assert mem["name"] == "test-mem.md"

    # File on disk.
    mem_path = _get_memory_disk_path(harness, "test-mem.md")
    assert mem_path.exists(), f"memory file not written to {mem_path}"
    assert mem_path.read_text(encoding="utf-8") == "# Hello\n\nMemory body."

    # Listed via the API.
    listed = _list_memories(harness)
    assert any(m["name"] == "test-mem.md" for m in listed), (
        f"created memory not in list response: {listed!r}"
    )


# ─── Test 2: list 3 memories ────────────────────────────────────────────


def test_list_memories_returns_created(
    harness: FunctionalHarness,
) -> None:
    """Create 3 memories; list shows all 3."""
    names = {"alpha.md", "beta.md", "gamma.md"}
    for name in names:
        harness.http(
            "POST",
            "/api/memories",
            json_body={"name": name, "content": f"# {name}\nbody"},
            expect=201,
        )
    listed = _list_memories(harness)
    listed_names = {m["name"] for m in listed}
    assert names.issubset(listed_names), (
        f"expected {names} in list, got {listed_names}"
    )


# ─── Test 3: update memory overwrites the file ─────────────────────────


def test_update_memory_overwrites_file(
    harness: FunctionalHarness,
) -> None:
    """PUT /api/memories/:name with new content overwrites the file."""
    # Create first.
    harness.http(
        "POST",
        "/api/memories",
        json_body={"name": "update-me.md", "content": "original"},
        expect=201,
    )
    mem_path = _get_memory_disk_path(harness, "update-me.md")
    assert mem_path.read_text(encoding="utf-8") == "original"

    # Update.
    new_content = "# Updated\n\nNew body with unicode: こんにちは"
    r = harness.http(
        "PUT",
        "/api/memories/update-me.md",
        json_body={"content": new_content},
        expect=200,
    )
    assert r.json().get("success", True) is True

    # File content matches.
    assert mem_path.read_text(encoding="utf-8") == new_content


# ─── Test 4: delete memory removes the file ────────────────────────────


def test_delete_memory_removes_file(
    harness: FunctionalHarness,
) -> None:
    """DELETE /api/memories/:name removes the .md file."""
    harness.http(
        "POST",
        "/api/memories",
        json_body={"name": "doomed.md", "content": "goodbye"},
        expect=201,
    )
    mem_path = _get_memory_disk_path(harness, "doomed.md")
    assert mem_path.exists()

    r = harness.http(
        "DELETE",
        "/api/memories/doomed.md",
        expect=200,
    )
    assert r.json().get("success", True) is True
    assert not mem_path.exists(), (
        f"memory file not removed after delete: {mem_path}"
    )


# ─── Test 5: local memory under a cwd ─────────────────────────────────


def test_create_local_memory_under_cwd(
    harness: FunctionalHarness, item_workspace_path: Path
) -> None:
    """POST /api/local-memories with cwd creates the file under that cwd."""
    cwd = item_workspace_path
    body = harness.http(
        "POST",
        "/api/local-memories",
        json_body={
            "name": "local-mem.md",
            "content": "# local\nscoped to cwd",
            "cwd": str(cwd),
        },
        expect=201,
    ).json()
    assert "memory" in body

    # File on disk under the requested cwd.
    mem_path = cwd / ".pabrik" / "memories" / "local-mem.md"
    assert mem_path.exists(), f"local memory not at {mem_path}"
    assert mem_path.read_text(encoding="utf-8") == "# local\nscoped to cwd"


# ─── Test 6: skill listing — a seeded row lists under its workspace ────


def test_skill_list_is_workspace_scoped(
    harness: FunctionalHarness,
) -> None:
    """A skill is a row in the workspace's `skills` table.

    It used to be a `SKILL.MD` file under `~/.config/pabrik/skills/`, which
    the API re-walked on every request and merged with a project-local
    copy. Writing a file to disk no longer makes a skill appear — the
    directory is an input to the importer, not a source of truth.
    """
    ws = _create_workspace(harness, "ms-skills")
    assert _list_skills(harness, ws) == []

    _seed_skill_row(harness, ws, "my-skill", "Does a thing.")

    listed = _list_skills(harness, ws)
    assert [s["name"] for s in listed] == ["my-skill"], (
        f"seeded skill not in list response: {listed!r}"
    )
    assert listed[0] == {"name": "my-skill", "description": "Does a thing."}


def test_skill_list_does_not_leak_across_workspaces(
    harness: FunctionalHarness,
) -> None:
    """The workspace_id in the URL is the isolation boundary.

    A skill file used to be visible from every workspace that happened to
    share a machine; a row is not. This is the assertion that would fail
    first if a query ever dropped `workspace_id` from its WHERE clause.
    """
    ws_a = _create_workspace(harness, "ms-skills-a")
    ws_b = _create_workspace(harness, "ms-skills-b")
    _seed_skill_row(harness, ws_a, "only-in-a", "A's skill.")

    assert [s["name"] for s in _list_skills(harness, ws_a)] == ["only-in-a"]
    assert _list_skills(harness, ws_b) == [], (
        "workspace B must not see workspace A's skill"
    )


# ─── Test 7: skill detail + delete ─────────────────────────────────────


def test_skill_detail_and_delete(
    harness: FunctionalHarness,
) -> None:
    """GET the body, DELETE the row — both under the workspace.

    The delete takes the name as a PATH SEGMENT now, not as `?name=…&is_global=…&cwd=…`.
    Those three query parameters were the directory decision, and a body
    that exists in one place cannot be told apart from one that exists in
    another by query string alone.
    """
    ws = _create_workspace(harness, "ms-skills-delete")
    content = "---\nname: to-delete\ndescription: Will be deleted.\n---\n\n# To Delete\n\nBye.\n"
    _seed_skill_row(harness, ws, "to-delete", "Will be deleted.", content)

    detail = harness.http(
        "GET", f"/api/workspaces/{ws}/skills/to-delete", expect=200
    ).json()
    assert "skill" in detail, f"unexpected detail shape: {detail!r}"
    skill = detail["skill"]
    assert skill is not None, f"skill should exist, got: {detail!r}"
    assert skill.get("name") == "to-delete"
    assert skill.get("description") == "Will be deleted."
    # Byte-exact: `skill_eval` identities are sha256(body), so a body that
    # came back trimmed would stale every cached verdict silently.
    assert skill["content"] == content
    assert skill["content"].startswith("---")
    assert skill["asset_count"] == 0
    # `path` and `is_global` described a directory; there is no directory.
    assert "path" not in skill
    assert "is_global" not in skill
    assert detail["error_message"] == ""

    deleted = harness.http(
        "DELETE", f"/api/workspaces/{ws}/skills/to-delete", expect=200
    ).json()
    assert deleted == {"success": True, "skill_name": "to-delete", "error_message": ""}, (
        f"unexpected delete payload: {deleted!r}"
    )
    assert _list_skills(harness, ws) == []

    # A second delete is a miss, not a silent success.
    missing = harness.http(
        "DELETE", f"/api/workspaces/{ws}/skills/to-delete", expect=404
    ).json()
    assert missing["success"] is False
    assert missing["error_message"]


# ─── Test 8: memory and skill namespaces don't collide ─────────────────


def test_memory_and_skill_namespaces_dont_collide(
    harness: FunctionalHarness,
) -> None:
    """A memory named 'foo.md' and a skill named 'foo' are independent rows.

    The memory is a file under `~/.config/pabrik/memories/`; the skill is a
    row in the `skills` table. Same name, two stores — and deleting one
    must not touch the other.
    """
    ws = _create_workspace(harness, "ms-ns")

    harness.http(
        "POST",
        "/api/memories",
        json_body={"name": "ns-foo.md", "content": "# memory foo"},
        expect=201,
    )
    _seed_skill_row(harness, ws, "ns-foo", "namespace test skill.")

    mems = _list_memories(harness)
    mem_names = {m["name"] for m in mems}
    skill_names = {s["name"] for s in _list_skills(harness, ws)}

    assert "ns-foo.md" in mem_names
    assert "ns-foo" in skill_names

    # Delete one, the other survives.
    harness.http("DELETE", "/api/memories/ns-foo.md", expect=200)
    assert not _get_memory_disk_path(harness, "ns-foo.md").exists()
    assert "ns-foo" in {s["name"] for s in _list_skills(harness, ws)}, (
        "memory delete must not touch the skill row"
    )
