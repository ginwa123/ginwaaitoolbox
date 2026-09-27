"""Functional tests for memories + skills.

Memories are full CRUD via HTTP (POST/GET/PUT/DELETE). Skills are
file-system-managed — the API has GET (list/detail) and DELETE, but
no POST/PUT for skill creation. Skills live as .md files in
`~/.config/nalar/skills/`; the API only reads and deletes them.

Plan: docs/superpowers/plans/2026-07-26-functional-tests-with-real-data.md (Chunk 6)
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "ms-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _list_memories(harness: FunctionalHarness) -> list[dict[str, Any]]:
    r = harness.http("GET", "/api/memories", expect=200)
    return r.json()["memories"]


def _list_skills(harness: FunctionalHarness) -> list[dict[str, Any]]:
    """GET /api/skills returns {global_skills:[...], local_skills:[...], cwd}.

    Returns the merged list (global + local). Each skill has
    {name, description, tags, path}; `path` is provenance and may be "" for a
    skill the agent created.
    """
    r = harness.http("GET", "/api/skills", expect=200)
    body = r.json()
    return body.get("global_skills", []) + body.get("local_skills", [])


def _get_memory_disk_path(harness: FunctionalHarness, name: str) -> Path:
    """Return the absolute path where a memory file lives on disk.

    Memories live in $XDG_CONFIG_HOME/nalar/memories/<name> or
    $HOME/.config/nalar/memories/<name> (Windows: %APPDATA%/nalar).
    The harness isolates all three, but the file is at the XDG/.config
    location on Windows (where XDG_CONFIG_HOME is now isolated to
    temp_dir/.config). Use that path for assertions; fallback to
    APPDATA if not found (covers old harness without XDG isolation).
    """
    # Check XDG/.config first (current Windows isolation), then APPDATA.
    config_base = harness.temp_dir / ".config" / "nalar" / "memories" / name
    if config_base.exists():
        return config_base
    appdata_base = harness.temp_dir / "AppData" / "Roaming" / "nalar" / "memories" / name
    if appdata_base.exists():
        return appdata_base
    # Default for new writes: use the XDG/.config location (matches
    # harness's isolated XDG_CONFIG_HOME on Windows and HOME/.config on Linux).
    return config_base


def _boot_with_skill(
    default_nalar_bin: Path,
    tmp_path: Path,
    name: str,
    description: str,
    tags: str = "",
    is_global: bool = True,
) -> FunctionalHarness:
    """Boot a fresh nalar with a SKILL.MD already on disk.

    Skills are rows now, and the disk sweep is INSERT OR IGNORE at BOOT. A
    file written after the server is already up is therefore invisible until
    the next start — which is exactly why these tests boot their own instance
    instead of using the shared `harness` fixture.
    """
    home = tmp_path / f"nalar-func-seeded-{name}"
    home.mkdir(parents=True, exist_ok=True)
    root = home / ".config" / "nalar" / "skills" if is_global else home / ".nalar" / "skills"
    skill_dir = root / name
    skill_dir.mkdir(parents=True, exist_ok=True)
    tags_line = f"tags: [{tags}]\n" if tags else ""
    (skill_dir / "SKILL.MD").write_text(
        f"---\nname: {name}\ndescription: \"{description}\"\n{tags_line}---\n\n# {name}\n\nBody.\n",
        encoding="utf-8",
    )
    h = FunctionalHarness.boot(default_nalar_bin, seed_home=home)
    try:
        return h
    except Exception:
        raise


def _get_skill_disk_path(harness: FunctionalHarness, name: str) -> Path:
    """Return the absolute path where a skill file lives on disk.

    Skills are stored as `$XDG_CONFIG_HOME/nalar/skills/<name>/SKILL.MD`
    or `$HOME/.config/nalar/skills/<name>/SKILL.MD`
    (Windows: %APPDATA%/nalar/skills). Same fallback as memories.
    """
    config_base = harness.temp_dir / ".config" / "nalar" / "skills" / name / "SKILL.MD"
    if config_base.exists():
        return config_base
    appdata_base = harness.temp_dir / "AppData" / "Roaming" / "nalar" / "skills" / name / "SKILL.MD"
    if appdata_base.exists():
        return appdata_base
    return config_base


# ─── Test 1: create + list a global memory ─────────────────────────────


def test_create_global_memory_writes_to_disk(
    harness: FunctionalHarness,
) -> None:
    """POST /api/memories creates a .md file at $HOME/.config/nalar/memories/<name>."""
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
    mem_path = cwd / ".nalar" / "memories" / "local-mem.md"
    assert mem_path.exists(), f"local memory not at {mem_path}"
    assert mem_path.read_text(encoding="utf-8") == "# local\nscoped to cwd"


# ─── Test 6: skill listing — create skill on disk, list it ────────────


def test_skill_create_on_disk_then_list(
    default_nalar_bin: Path,
    tmp_path: Path,
) -> None:
    """A SKILL.MD on disk becomes a ROW, imported at boot.

    Skills require YAML frontmatter (`---\nname: ...\ndescription: ...\n---`)
    to be discoverable. A bare markdown file with no frontmatter is silently
    skipped, same as before — the importer reuses `list_skills_from_dir_path`.

    The tags assertion is the point of the whole feature: the frontmatter
    `tags:` line used to be parsed by nothing, and now it is a column the
    agent (and the UI) can read.
    """
    h = _boot_with_skill(
        default_nalar_bin, tmp_path, "my-skill", "Does a thing.", tags="workflow,api"
    )
    try:
        listed = h.http("GET", "/api/skills", expect=200).json()
        by_name = {
            s["name"]: s
            for s in listed.get("global_skills", []) + listed.get("local_skills", [])
        }
        assert "my-skill" in by_name, f"created skill not in list: {sorted(by_name)}"
        assert by_name["my-skill"]["description"] == "Does a thing."
        assert by_name["my-skill"]["tags"] == "workflow||api"

        # And it resolves to a single row on the detail endpoint, with the
        # same name usable as the handle (the filesystem path is gone).
        detail = h.http("GET", "/api/skills/my-skill", expect=200).json()["skill"]
        assert detail["is_global"] is True
        assert detail["tags"] == "workflow||api"
        assert "Body." in detail["content"]
    finally:
        h.teardown()


# ─── Test 7: skill detail + delete ─────────────────────────────────────


def test_skill_detail_and_delete(
    default_nalar_bin: Path,
    tmp_path: Path,
) -> None:
    """GET /api/skills/:name returns the row; DELETE removes it and its file.

    The mirror is cleaned on delete, so the `SKILL.MD` folder goes with the
    row — otherwise the next boot's importer would resurrect it.
    """
    home = tmp_path / "nalar-func-seeded-to-delete"
    skill_path = home / ".config" / "nalar" / "skills" / "to-delete" / "SKILL.MD"
    skill_path.parent.mkdir(parents=True, exist_ok=True)
    skill_path.write_text(
        "---\nname: to-delete\ndescription: \"Will be deleted.\"\n---\n\n# To Delete\n\nBye.\n",
        encoding="utf-8",
    )
    h = FunctionalHarness.boot(default_nalar_bin, seed_home=home)
    try:
        detail = h.http("GET", "/api/skills/to-delete", expect=200).json()
        assert "skill" in detail, f"unexpected detail shape: {detail!r}"
        skill = detail["skill"]
        assert skill is not None, f"skill should exist, got: {detail!r}"
        assert skill.get("name") == "to-delete"
        assert "content" in skill
        # `path` is provenance now and is present for an imported row.
        assert "path" in skill
        assert skill.get("is_global") is True

        del_resp = h.http(
            "DELETE",
            "/api/skills",
            params={"name": "to-delete", "is_global": "true"},
            expect=200,
        ).json()
        assert del_resp.get("success") is True
        assert not skill_path.exists(), (
            f"skill file not removed after delete: {skill_path}"
        )
    finally:
        h.teardown()


# ─── Test 8: memory and skill namespaces don't collide ─────────────────


def test_memory_and_skill_namespaces_dont_collide(
    default_nalar_bin: Path,
    tmp_path: Path,
) -> None:
    """A memory named 'ns-foo.md' and a skill named 'ns-foo' are independent.

    The memory is a file under the memories root and is written on POST; the
    skill is a row in `skills` seeded from a SKILL.MD at boot. Deleting one must
    not touch the other's storage.
    """
    home = tmp_path / "nalar-func-seeded-ns"
    skill_path = home / ".config" / "nalar" / "skills" / "ns-foo" / "SKILL.MD"
    skill_path.parent.mkdir(parents=True, exist_ok=True)
    skill_path.write_text(
        "---\nname: ns-foo\ndescription: \"namespace test skill.\"\n---\n\nBody.\n",
        encoding="utf-8",
    )
    h = FunctionalHarness.boot(default_nalar_bin, seed_home=home)
    try:
        h.http(
            "POST",
            "/api/memories",
            json_body={"name": "ns-foo.md", "content": "# memory foo"},
            expect=201,
        )

        mem_names = {m["name"] for m in _list_memories(h)}
        skill_names = {s.get("name", s) for s in _list_skills(h)}

        assert "ns-foo.md" in mem_names
        assert "ns-foo" in skill_names

        # Delete the memory; the skill's row and its mirrored file survive.
        h.http("DELETE", "/api/memories/ns-foo.md", expect=200)
        assert skill_path.exists(), "memory delete must not touch the skill file"
        assert "ns-foo" in {s.get("name", s) for s in _list_skills(h)}
    finally:
        h.teardown()
