"""Functional coverage for the cross-project cwd system prompt.

The prompt builder must render every sibling project path from
``workspace_items``. This suite creates 25 siblings (more than the former
cap of 20) and verifies the real ``GET /test/system-prompt/:session_id``
wire response contains every absolute path.

Port 8081 is never used; the functional harness chooses its own free port.
"""

from __future__ import annotations

import sqlite3
import uuid
from pathlib import Path

from harness import FunctionalHarness


SESSION_ID = "task_cross_project_cwd_all"
SIBLING_COUNT = 25


def _db_path(harness: FunctionalHarness) -> Path:
    return Path(harness.temp_dir) / ".config" / "nalar" / "agent.db"


def _seed_bound_session_and_siblings(
    harness: FunctionalHarness,
    workspace_id: str,
    self_item_id: str,
    root: Path,
) -> list[Path]:
    sibling_paths: list[Path] = []
    for index in range(SIBLING_COUNT):
        path = root / f"sibling-{index}"
        path.mkdir(parents=True, exist_ok=True)
        sibling_paths.append(path)

    conn = sqlite3.connect(f"file:{_db_path(harness)}?mode=rw", uri=True, timeout=10)
    try:
        conn.execute(
            "UPDATE sessions SET cwd = ? WHERE id = ?",
            (str(root / "self"), SESSION_ID),
        )
        conn.execute(
            "INSERT INTO workspace_item_tasks "
            "(id, name, workspace_item_id, created_at, updated_at, task_type) "
            "VALUES (?, ?, ?, datetime('now'), datetime('now'), 'standard')",
            (SESSION_ID, "Cross-project test", self_item_id),
        )
        conn.execute(
            "INSERT INTO llm_history (id, session_id, model, response_content) "
            "VALUES (?, ?, ?, ?)",
            (f"msg_{uuid.uuid4().hex[:12]}", SESSION_ID, "gpt-4o", "seed"),
        )
        for index, path in enumerate(sibling_paths):
            conn.execute(
                "INSERT INTO workspace_items "
                "(id, workspace_id, item_type, name, path, position) "
                "VALUES (?, ?, 'chat', ?, ?, ?)",
                (
                    f"item_cross_sibling_{index}",
                    workspace_id,
                    f"Sibling {index}",
                    str(path),
                    index,
                ),
            )
        conn.commit()
    finally:
        conn.close()

    return sibling_paths


def test_system_prompt_contains_every_workspace_item_sibling_path(
    harness: FunctionalHarness,
) -> None:
    workspace = harness.http(
        "POST",
        "/api/workspaces",
        json_body={"name": "cross-project-cwd-all"},
        expect=201,
    ).json()
    workspace_id = workspace["id"]

    self_root = Path(harness.temp_dir) / "cross-project-cwd-self"
    self_root.mkdir(parents=True, exist_ok=True)
    self_item = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": "Self project", "path": str(self_root)},
        expect=201,
    ).json()["item"]

    harness.http(
        "PUT",
        f"/api/llm/session/{SESSION_ID}",
        json_body={"name": "Cross-project cwd prompt test"},
        expect=200,
    )
    sibling_paths = _seed_bound_session_and_siblings(
        harness,
        workspace_id,
        self_item["id"],
        self_root,
    )

    response = harness.http(
        "GET",
        f"/test/system-prompt/{SESSION_ID}",
        expect=200,
    )
    system_prompt = response.json()["system_prompt"]

    assert "## Cross-Project Context" in system_prompt
    assert "Sibling project directories:" in system_prompt
    sibling_section = system_prompt.split("Sibling project directories:", 1)[1]
    for path in sibling_paths:
        assert f"`{path}`" in sibling_section, f"missing sibling cwd: {path}"
    assert f"`{self_root}`" not in sibling_section
