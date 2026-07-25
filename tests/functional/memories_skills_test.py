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
    {name, description, path, is_global}.
    """
    r = harness.http("GET", "/api/skills", expect=200)
    body = r.json()
    return body.get("global_skills", []) + body.get("local_skills", [])


def _get_memory_disk_path(harness: FunctionalHarness, name: str) -> Path:
    """Return the absolute path where a memory file lives on disk.

    Memories live in $HOME/.config/nalar/memories/<name> — the
    harness's temp_dir IS the $HOME for the nalar process, so the
    file is at temp_dir/.config/nalar/memories/<name>.
    """
    return harness.temp_dir / ".config" / "nalar" / "memories" / name


def _get_skill_disk_path(harness: FunctionalHarness, name: str) -> Path:
    """Return the absolute path where a skill file lives on disk.

    Skills are stored as `$HOME/.config/nalar/skills/<name>/SKILL.MD`
    (each skill in its own subdirectory; the file is uppercase).
    """
    return harness.temp_dir / ".config" / "nalar" / "skills" / name / "SKILL.MD"


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
    assert mem_path.read_text() == "# Hello\n\nMemory body."

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
    assert mem_path.read_text() == "original"

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
    assert mem_path.read_text() == new_content


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
    assert mem_path.read_text() == "# local\nscoped to cwd"


# ─── Test 6: skill listing — create skill on disk, list it ────────────


def test_skill_create_on_disk_then_list(
    harness: FunctionalHarness,
) -> None:
    """Skills are file-system-managed. Create a .md file directly,
    then list via API.

    Skills require YAML frontmatter (`---\\nname: ...\\ndescription: ...\\n---`)
    to be discoverable by `list_skills_from_dir_path`. A bare markdown
    file with no frontmatter is silently skipped.
    """
    skill_path = _get_skill_disk_path(harness, "my-skill")
    skill_path.parent.mkdir(parents=True, exist_ok=True)
    skill_path.write_text(
        "---\n"
        "name: my-skill\n"
        "description: Does a thing.\n"
        "---\n"
        "\n"
        "# My Skill\n"
        "\n"
        "Body of the skill.\n"
    )

    listed = _list_skills(harness)
    skill_names = {s.get("name", s) for s in listed}
    assert "my-skill" in skill_names, (
        f"created skill not in list: {skill_names}"
    )


# ─── Test 7: skill detail + delete ─────────────────────────────────────


def test_skill_detail_and_delete(
    harness: FunctionalHarness,
) -> None:
    """GET /api/skills/:name returns the file; DELETE removes it."""
    skill_path = _get_skill_disk_path(harness, "to-delete")
    skill_path.parent.mkdir(parents=True, exist_ok=True)
    skill_path.write_text(
        "---\n"
        "name: to-delete\n"
        "description: Will be deleted.\n"
        "---\n"
        "\n"
        "# To Delete\n"
        "\n"
        "Bye.\n"
    )

    # Detail. Response shape: {"skill": {name, description, content, path, is_global},
    # "error_message": null|"..."}.
    detail = harness.http("GET", "/api/skills/to-delete", expect=200).json()
    assert "skill" in detail, f"unexpected detail shape: {detail!r}"
    skill = detail["skill"]
    assert skill is not None, f"skill should exist, got: {detail!r}"
    assert skill.get("name") == "to-delete"
    assert "content" in skill
    assert "path" in skill
    assert skill.get("is_global") is True

    # Delete. The DELETE endpoint takes query params (?name=...&is_global=true).
    del_resp = harness.http(
        "DELETE",
        "/api/skills",
        params={"name": "to-delete", "is_global": "true"},
        expect=200,
    ).json()
    assert del_resp.get("success") is True
    assert not skill_path.exists(), (
        f"skill file not removed after delete: {skill_path}"
    )


# ─── Test 8: memory and skill namespaces don't collide ─────────────────


def test_memory_and_skill_namespaces_dont_collide(
    harness: FunctionalHarness,
) -> None:
    """A memory named 'foo.md' and a skill named 'foo' live in different
    directories and both round-trip through their respective APIs.
    """
    # Create memory foo.md.
    harness.http(
        "POST",
        "/api/memories",
        json_body={"name": "ns-foo.md", "content": "# memory foo"},
        expect=201,
    )
    # Create skill foo (file on disk).
    skill_path = _get_skill_disk_path(harness, "ns-foo")
    skill_path.parent.mkdir(parents=True, exist_ok=True)
    skill_path.write_text(
        "---\n"
        "name: ns-foo\n"
        "description: namespace test skill.\n"
        "---\n"
        "\n"
        "Body.\n"
    )

    # Both are independently queryable.
    mems = _list_memories(harness)
    mem_names = {m["name"] for m in mems}
    skills = _list_skills(harness)
    skill_names = {s.get("name", s) for s in skills}

    assert "ns-foo.md" in mem_names
    assert "ns-foo" in skill_names

    # Delete one doesn't affect the other.
    harness.http("DELETE", "/api/memories/ns-foo.md", expect=200)
    assert not _get_memory_disk_path(harness, "ns-foo.md").exists()
    assert skill_path.exists(), (
        "memory delete must not touch the skill file"
    )
