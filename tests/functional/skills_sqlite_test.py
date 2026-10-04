r"""Functional tests for the workspace-scoped skills HTTP surface.

The wire shapes are pinned in `docs/plans/2026-10-04-skills-sqlite-table.md`:

| Route | Response |
|---|---|
| `GET /api/workspaces/:workspace_id/skills` | `{"skills": [{"name", "description"}]}` |
| `GET /api/workspaces/:workspace_id/skills/:skill_name` | `{"skill": {name, description, content, asset_count} \| null, "error_message": ""}` |
| `DELETE /api/workspaces/:workspace_id/skills/:skill_name` | `{"success", "skill_name", "error_message": ""}` |

These are WIRE round-trips on purpose. The Zig useCase tests cover the
same behaviour against an in-memory database, but they cannot see a route
that `matchRoute` swallows: `matchRoute` walks routes in registration
order and returns on the first hit, so a `:skill_name` route registered
before the collection route answers the collection request with the wrong
handler, or a stale `/api/skills` route keeps answering after the move and
every assertion here passes against the old contract instead of the new
one. That failure is invisible from unit tests.

There is no HTTP write route for skills — creation is an agent tool
(`add_skill`) — so rows are seeded straight into the same on-disk database
the harness isolated, following the read-only-handle precedent in
`default_workspace_provisioning_test.py`. The isolation assertions are the
point: a skill seeded in one workspace must be invisible, undeletable and
unconfirmable from another.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from harness import FunctionalHarness

BODY = "---\nname: pdf\ndescription: Work with PDFs.\n---\n\nRun `scripts/convert.py`.\n"


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str) -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _db_path(harness: FunctionalHarness) -> Path:
    p = Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"
    assert p.exists(), f"database not found at {p}"
    return p


def _connect(harness: FunctionalHarness) -> sqlite3.Connection:
    return sqlite3.connect(_db_path(harness))


def _seed_skill(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str,
    description: str = "Work with PDFs.",
    content: str = BODY,
) -> None:
    """Insert one `skills` row directly.

    Written the way `skills_store.upsertSkill` writes it, including the
    `COALESCE(NULLIF(?, ''), '')` guard: `SqliteBackend.exec` binds an
    empty slice as SQL NULL, which would violate the NOT NULL constraint
    on `description`. Seeding the raw value would make this test fail for a
    reason that has nothing to do with the routes.
    """
    con = _connect(harness)
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


def _seed_asset(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str,
    rel_path: str,
    content: str,
) -> None:
    con = _connect(harness)
    try:
        row = con.execute(
            "SELECT id FROM skills WHERE workspace_id = ? AND name = ?",
            (workspace_id, name),
        ).fetchone()
        assert row is not None, f"no skills row for {workspace_id}/{name}"
        con.execute(
            "INSERT INTO skill_assets (id, skill_id, rel_path, content, created_at) "
            "VALUES (?, ?, ?, COALESCE(NULLIF(?, ''), ''), CURRENT_TIMESTAMP)",
            (f"sa_seed_{workspace_id}_{name}_{rel_path}", row[0], rel_path, content),
        )
        con.commit()
    finally:
        con.close()


def _row_count(harness: FunctionalHarness, table: str) -> int:
    con = _connect(harness)
    try:
        return int(con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
    finally:
        con.close()


# ─── The route table ───────────────────────────────────────────────────────


def test_skills_are_reachable_only_under_a_workspace(harness: FunctionalHarness) -> None:
    """The three routes moved; the directory-tier collection route is gone.

    `/api/skills` answered by merging `~/.config/pabrik/skills/` with
    `<cwd>/.pabrik/skills/` and had no workspace id to scope either to. It
    must 404 now, not answer with a legacy shape — a client pinned to the
    old shape would otherwise keep working and never learn the move
    happened.
    """
    ws = _create_workspace(harness, "skills-routes")

    listed = harness.http("GET", f"/api/workspaces/{ws}/skills", expect=200).json()
    assert set(listed) == {"skills"}, f"unexpected list shape: {listed!r}"
    assert listed["skills"] == [], f"a fresh workspace should hold no skills: {listed!r}"

    # The old collection route and the old detail route are both gone.
    harness.http("GET", "/api/skills", expect=404)
    harness.http("GET", "/api/skills/pdf", expect=404)
    harness.http("DELETE", "/api/skills", params={"name": "pdf"}, expect=404)

    # The sibling eval prefix is untouched by the move — it is a sibling ON
    # PURPOSE, because a literal nested under the `:skill_name` route would
    # be captured as the param.
    harness.http("GET", "/api/skill-evals/summary", expect=200)


def test_list_returns_name_and_description_only(harness: FunctionalHarness) -> None:
    """`{skills:[{name, description}]}` — no body, no path, no is_global.

    `is_global` described which of two directories a body was read from.
    With one workspace-scoped table there is no such question, and a field
    that is always `false` (or always `true`) is worse than an absent one:
    a client would keep branching on it.
    """
    ws = _create_workspace(harness, "skills-list")
    _seed_skill(harness, ws, "pdf", "Work with PDFs.")
    _seed_skill(harness, ws, "zig-trap", "The `std.mem.trimRight` trap.", "body")

    body = harness.http("GET", f"/api/workspaces/{ws}/skills", expect=200).json()
    rows = {s["name"]: s for s in body["skills"]}

    assert set(rows) == {"pdf", "zig-trap"}, f"unexpected skills: {body!r}"
    assert rows["pdf"] == {"name": "pdf", "description": "Work with PDFs."}
    # The list row carries no body: a workspace can hold dozens of skills
    # and the sidebar only renders a picker.
    assert "content" not in rows["pdf"]
    assert "path" not in rows["pdf"]
    assert "is_global" not in rows["pdf"]


def test_detail_returns_the_body_and_the_companion_count(
    harness: FunctionalHarness,
) -> None:
    """`{skill:{name, description, content, asset_count}, error_message:""}`.

    `content` is asserted BYTE-EXACT, frontmatter included: `skill_eval`
    identities are `sha256(body)`, so a handler that trimmed, re-encoded or
    stripped the `---` block would stale every cached verdict for the skill
    with no other symptom.
    """
    ws = _create_workspace(harness, "skills-detail")
    _seed_skill(harness, ws, "pdf")
    _seed_asset(harness, ws, "pdf", "scripts/convert.py", "print('hi')")

    detail = harness.http("GET", f"/api/workspaces/{ws}/skills/pdf", expect=200).json()

    assert detail["error_message"] == ""
    skill = detail["skill"]
    assert skill is not None, f"skill should exist, got: {detail!r}"
    assert skill["name"] == "pdf"
    assert skill["description"] == "Work with PDFs."
    assert skill["content"] == BODY, "body must round-trip byte-exact"
    assert skill["content"].startswith("---"), "the frontmatter is part of the body"
    assert skill["asset_count"] == 1
    # No `path`: the body no longer lives at a pathname, and a client that
    # reconstructs one is the path-shaped contract this change removes.
    assert "path" not in skill
    assert "is_global" not in skill


def test_detail_of_a_foreign_workspace_is_404_and_lists_what_does_exist(
    harness: FunctionalHarness,
) -> None:
    """A foreign name is NOT 403.

    A 403 would confirm the name exists, which is exactly what the
    workspace scoping exists to hide. The payload instead carries
    `available_skills` — the REQUESTING workspace's names, never the other
    workspace's — so a caller that got the name wrong is told what does
    exist instead of only that it does not.
    """
    ws_a = _create_workspace(harness, "skills-scope-a")
    ws_b = _create_workspace(harness, "skills-scope-b")
    _seed_skill(harness, ws_a, "pdf")
    _seed_skill(harness, ws_a, "zig-trap", "A trap.")
    _seed_skill(harness, ws_b, "secret-skill", "B's own skill.")

    detail = harness.http("GET", f"/api/workspaces/{ws_b}/skills/pdf", expect=404).json()

    assert detail["skill"] is None
    assert detail["error_message"], "a miss must say why"
    assert sorted(detail["available_skills"]) == ["secret-skill"], (
        f"ws_b must only be told about its OWN skills, got: {detail!r}"
    )


def test_delete_removes_the_row_and_its_companions(harness: FunctionalHarness) -> None:
    """`{success, skill_name, error_message}` with no `deleted_from`.

    `deleted_from` named the directory the body was removed from. There is
    no directory of record any more, and the importer never deletes from
    disk — so the row goes and the `SKILL.MD` stays, which is the
    deliberate consequence of a non-destructive migration.
    """
    ws = _create_workspace(harness, "skills-delete")
    _seed_skill(harness, ws, "pdf")
    _seed_asset(harness, ws, "pdf", "scripts/convert.py", "print('hi')")

    deleted = harness.http("DELETE", f"/api/workspaces/{ws}/skills/pdf", expect=200).json()
    assert deleted == {"success": True, "skill_name": "pdf", "error_message": ""}, (
        f"unexpected delete payload: {deleted!r}"
    )

    assert _row_count(harness, "skill_assets") == 0, (
        "PRAGMA foreign_keys is off project-wide, so the declared CASCADE "
        "does nothing — orphaned companion rows would collide with a "
        "re-import on UNIQUE (skill_id, rel_path)"
    )

    # Second delete is a miss, not a silent success.
    again = harness.http("DELETE", f"/api/workspaces/{ws}/skills/pdf", expect=404).json()
    assert again["success"] is False
    assert again["skill_name"] == "pdf"
    assert again["error_message"]


def test_delete_from_a_foreign_workspace_deletes_nothing(
    harness: FunctionalHarness,
) -> None:
    """404, and the other workspace's row survives."""
    ws_a = _create_workspace(harness, "skills-del-a")
    ws_b = _create_workspace(harness, "skills-del-b")
    _seed_skill(harness, ws_a, "pdf")
    before = _row_count(harness, "skills")

    body = harness.http("DELETE", f"/api/workspaces/{ws_b}/skills/pdf", expect=404).json()

    assert body["success"] is False
    assert body["error_message"] == "skill not found", (
        "a foreign name must get the same message as one that does not exist"
    )
    assert _row_count(harness, "skills") == before


def test_a_skill_created_by_a_tool_is_visible_to_the_next_read(
    harness: FunctionalHarness,
) -> None:
    """The list reflects writes made by the agent tools, not a cached walk.

    The old handlers re-read the directory on every request, so a
    filesystem change showed up immediately. The table has to keep that
    promise for `add_skill`, or the sidebar and the model disagree about
    which skills exist.
    """
    ws = _create_workspace(harness, "skills-add")
    assert harness.http("GET", f"/api/workspaces/{ws}/skills", expect=200).json()["skills"] == []

    _seed_skill(harness, ws, "added-by-tool", "Written after the first read.")

    listed = harness.http("GET", f"/api/workspaces/{ws}/skills", expect=200).json()
    assert [s["name"] for s in listed["skills"]] == ["added-by-tool"]


def test_detail_of_an_unknown_name_is_a_clean_404(harness: FunctionalHarness) -> None:
    """A miss is a 404 that says what the workspace DOES hold.

    The payload shape matters as much as the status: the caller is holding
    a name it cannot use, and `available_skills` is the only way it learns
    the right one. (Path traversal in a name is refused by
    `skills_store.isValidSkillName` and asserted in Zig's own tests; a URL
    client normalises `..` segments away before they reach the server, so
    it is not something this layer can even be asked about.)
    """
    ws = _create_workspace(harness, "skills-unknown")
    detail = harness.http("GET", f"/api/workspaces/{ws}/skills/does-not-exist", expect=404).json()

    assert detail["skill"] is None
    assert detail["error_message"] == "skill not found"
    assert detail["available_skills"] == []


def test_list_response_is_a_plain_array_of_objects(harness: FunctionalHarness) -> None:
    """Guard against a `count`/tiered envelope creeping back in.

    The old payload was `{global_skills, local_skills, cwd}` — two arrays
    because there were two directories. One table means one array, and a
    client that has to branch on which array to read is the precedence bug
    this change removes.
    """
    ws = _create_workspace(harness, "skills-shape")
    _seed_skill(harness, ws, "pdf")

    body: dict[str, Any] = harness.http("GET", f"/api/workspaces/{ws}/skills", expect=200).json()
    assert list(body.keys()) == ["skills"]
    assert isinstance(body["skills"], list)
    assert isinstance(body["skills"][0], dict)