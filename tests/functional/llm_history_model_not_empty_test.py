"""`llm_history.model` is never empty — wire-level proof.

Background
----------
A blank `model` landed in `llm_history` for a kanban-created session
(reproduced on live data: `agent.db` row `1791057639139594690`, where
`typeof(model)='text'` and `quote(model)=''`). Two paths could produce it:

  1. **Raw SQL with a `''` literal.** `kanban_tasks_create.zig` (HTTP) and
     `create_kanban_task.zig` (agent tool) both seed a synthetic `role='user'`
     row so the chatview never lands on the "How can I help you?" empty
     state, and both hardcoded `''` for `model`.

  2. **An empty *bind*, which is worse — it loses the row.** The backend binds
     a zero-length slice as SQL NULL; NULL violates `model TEXT NOT NULL`, so
     the INSERT fails outright, and every call site swallows that non-fatally.
     The user's message row is silently gone.

This suite asserts the invariant at the WIRE level, against a real server on
an isolated tmpdir HOME: after a kanban `create_session`, the seeded
`llm_history` row exists AND its `model` is non-empty. Existence matters as
much as non-emptiness — failure mode 2 is a missing row, and a test that only
asserted "no empty model" would pass vacuously on a dropped row.

Why a functional test and not a unit test: the unit tests exercise
`model_guard.resolve` in isolation. This replays the exact HTTP body the
frontend's "Create task" button sends, so it also covers the config cascade
that decides *which* model gets written.

Run:
    PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 \
      python3 -m pytest tests/functional/llm_history_model_not_empty_test.py -v
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from harness import FunctionalHarness

# The sentinel the backend substitutes when no model can be resolved. Mirrors
# `agentic_loop/llm_history_model_guard.zig::UNKNOWN_MODEL` and the literal in
# Migration 101's trigger. A real model id is never this string.
UNKNOWN_MODEL = "unknown"


# ─── Helpers ───────────────────────────────────────────────────────────────


def _db_path(harness: FunctionalHarness) -> Path:
    return Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"


def _history_rows(harness: FunctionalHarness, session_id: str) -> list[sqlite3.Row]:
    conn = sqlite3.connect(str(_db_path(harness)), timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        return list(
            conn.execute(
                "SELECT id, model, typeof(model) AS t, role, response_content "
                "FROM llm_history WHERE session_id = ? ORDER BY created_at_nano",
                (session_id,),
            )
        )
    finally:
        conn.close()


def _create_workspace(harness: FunctionalHarness, name: str = "model-guard-ws") -> str:
    return harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "sprint-guard") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
    description: str,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """POST mode='create_session' — the exact wire the frontend's plain
    "Create task" button sends."""
    body: dict[str, Any] = {"mode": "create_session", "name": name, "description": description}
    if extra:
        body.update(extra)
    return harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=201,
    ).json()


# ─── Tests ─────────────────────────────────────────────────────────────────


def test_kanban_create_session_seeds_a_row_with_a_non_empty_model(
    harness: FunctionalHarness,
):
    """The regression itself: the seeded row must carry a real model.

    The harness's stub profile leaves `active_profile` unset and the config
    carries no top-level `model`, so `resolveEffectiveProfile` cascades all
    the way down to an empty string. That is exactly the condition that used
    to write `''`. The row must still land, with a non-empty model.
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)

    resp = _create_task(harness, ws_id, kanban_id, name="Guarded card", description="check the model")
    task_id = resp["task"]["id"]

    rows = _history_rows(harness, task_id)

    # Existence first. An empty-bind INSERT fails outright against
    # `model TEXT NOT NULL` and the caller swallows it — so the pre-fix
    # symptom for some configs is NO row at all. Asserting only "no empty
    # model" would pass vacuously against a dropped row.
    assert len(rows) == 1, (
        f"expected exactly 1 seeded llm_history row for {task_id}, "
        f"got {len(rows)}: {[dict(r) for r in rows]!r}"
    )

    row = rows[0]
    # `typeof` distinguishes the two failure modes: 'null' = the NULL-collapse
    # drop path, 'text' with a blank value = the `''`-literal path.
    assert row["t"] != "null", f"model is SQL NULL (empty-bind collapse): {dict(row)!r}"
    assert (row["model"] or "").strip(), f"model is blank: {dict(row)!r}"
    # The seeded row is the synthetic user message, and it must still be there.
    assert row["role"] == "user"
    assert row["response_content"] == "Guarded card\n\ncheck the model"


def test_seeded_model_is_either_real_or_the_sentinel(harness: FunctionalHarness):
    """The model must be either a real id or the sentinel — never blank.

    Two paths are acceptable and both are asserted to be *non-empty*:
      - a real model id, when the profile cascade resolves one;
      - `UNKNOWN_MODEL`, when it resolves to nothing.

    What is NOT acceptable is `''`, which is what the two raw-SQL sites used
    to hardcode.
    """
    ws_id = _create_workspace(harness, name="model-guard-ws-2")
    kanban_id = _create_kanban(harness, ws_id, name="sprint-guard-2")

    resp = _create_task(
        harness,
        ws_id,
        kanban_id,
        name="Second card",
        description="also check the model",
        extra={"is_auto_retry_until_stop": "1", "selected_profile_model": "stub"},
    )
    task_id = resp["task"]["id"]

    rows = _history_rows(harness, task_id)
    assert len(rows) == 1, f"expected 1 seeded row, got {[dict(r) for r in rows]!r}"

    model = rows[0]["model"]
    assert model, f"model must never be blank: {dict(rows[0])!r}"
    assert model == UNKNOWN_MODEL or model.strip() != "", (
        f"model must be the sentinel or a real id, got {model!r}"
    )


def test_no_blank_model_anywhere_in_the_database(harness: FunctionalHarness):
    """Database-wide sweep after several task creates.

    Catches a regression that a per-session assertion would miss: a write
    site that still binds an empty model would either drop its row or, after
    Migration 101's trigger is in place, be caught there. Either way the
    sweep must come back clean.
    """
    ws_id = _create_workspace(harness, name="model-guard-ws-3")
    kanban_id = _create_kanban(harness, ws_id, name="sprint-guard-3")

    for i in range(3):
        _create_task(
            harness,
            ws_id,
            kanban_id,
            name=f"Card {i}",
            description=f"body {i}",
        )

    conn = sqlite3.connect(str(_db_path(harness)), timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        blank = list(
            conn.execute(
                "SELECT id, session_id, model FROM llm_history "
                "WHERE model IS NULL OR TRIM(model) = ''"
            )
        )
    finally:
        conn.close()

    assert blank == [], f"llm_history rows with a blank model: {[dict(r) for r in blank]!r}"
