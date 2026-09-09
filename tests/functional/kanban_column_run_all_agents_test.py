"""Functional tests for the bulk `run_all_agents` column endpoint.

Plan: docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md
(Task 5 regression).

Wire under test:
  POST /api/workspaces/:ws/items/:item/kanban/columns/:col/run_all_agents
    -> 200 {"success":true,"column_id":...,"started":[...],"skipped":[...],"failed":[...]}
    -> 404 {"error":"column not found"} for unknown columns.

The tests replay the exact frontend flow against a real binary
(fresh binary, isolated tmpdir HOME, harness auto-picks a port != 8081):

  1. seed workspace -> kanban item -> first column with 3 tasks.
  2. start_agent on task-1 first (-> 200 triggered, so task-1 owns a worker).
  3. POST run_all_agents -> 200 with a started/skipped split covering task-1
     (task-1 lands in `skipped` while its worker is in-flight; if the worker
     already drained it may land in `started` again — either way it must be
     covered by the union of the three lists).
  4. re-POST run_all_agents -> still 200 (safe / idempotent envelope).
  5. unknown column -> 404.
  6. GET .../tasks/:task_id single route still works (route-order guard:
     the new POST literal was registered in the columns family, never under
     /tasks/:task_id, so neither the single GET nor the list GET is shadowed).
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "run-all-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "sprint-run-all") -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    body = r.json()
    return body["item"]["id"]


def _list_columns(harness: FunctionalHarness, workspace_id: str, kanban_id: str) -> list[dict[str, Any]]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/columns",
        expect=200,
    )
    return r.json()["columns"]


def _create_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    name: str,
    column_id: str,
) -> dict[str, Any]:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks",
        json_body={"name": name, "column_id": column_id},
        expect=201,
    )
    return r.json()


def _seed_column_with_three_tasks(
    harness: FunctionalHarness,
) -> tuple[str, str, str, list[str]]:
    """Seed workspace -> kanban -> first column with 3 tasks.

    Returns (workspace_id, kanban_id, column_id, [task1, task2, task3]).
    """
    ws_id = _create_workspace(harness)
    kanban_id = _create_kanban(harness, ws_id)
    cols = _list_columns(harness, ws_id, kanban_id)
    assert len(cols) >= 1, f"expected seeded columns, got {cols!r}"
    col_id = cols[0]["id"]
    ids: list[str] = []
    for i in range(3):
        task = _create_task(harness, ws_id, kanban_id, f"bulk-task-{i}", col_id)
        assert task["id"].startswith("task_"), f"unexpected task shape: {task!r}"
        ids.append(task["id"])
    assert len(set(ids)) == 3, f"expected 3 distinct tasks, got {ids!r}"
    return ws_id, kanban_id, col_id, ids


def _start_agent(
    harness: FunctionalHarness, workspace_id: str, kanban_id: str, task_id: str, expect: int = 200
) -> Any:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks/{task_id}/start_agent",
        json_body={},
        expect=expect,
    )
    return r.json()


def _run_all_agents(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    column_id: str,
    expect: int = 200,
) -> Any:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/columns/{column_id}/run_all_agents",
        json_body={},
        expect=expect,
    )
    return r.json()


# ─── Test 1: start_agent on task-1 first ────────────────────────────────────


def test_start_agent_on_task1_first(harness: FunctionalHarness):
    """Precondition for the bulk split: task-1 starts cleanly (-> 200)."""
    ws_id, kanban_id, _col_id, ids = _seed_column_with_three_tasks(harness)
    body = _start_agent(harness, ws_id, kanban_id, ids[0], expect=200)
    assert body.get("success") is True
    assert body.get("session_id") == ids[0]
    assert body.get("status") == "triggered"


# ─── Test 2: bulk run covers all three with a started/skipped split ─────────


def test_run_all_agents_started_skipped_split(harness: FunctionalHarness):
    """POST run_all_agents -> 200 with started/skipped/failed covering all 3.

    task-1 already owns a worker (started above), so it must land in
    `skipped` while the worker is in-flight. If the worker already drained,
    task-1 may land in `started` again — either way the union of the three
    lists must equal exactly the 3 seeded ids.
    """
    ws_id, kanban_id, col_id, ids = _seed_column_with_three_tasks(harness)
    _start_agent(harness, ws_id, kanban_id, ids[0], expect=200)

    body = _run_all_agents(harness, ws_id, kanban_id, col_id, expect=200)
    assert body.get("success") is True, f"got: {body!r}"
    assert body.get("column_id") == col_id, f"got: {body!r}"
    for key in ("started", "skipped", "failed"):
        assert isinstance(body.get(key), list), f"expected list for {key!r}, got: {body!r}"

    union = set(body["started"]) | set(body["skipped"]) | set(body["failed"])
    assert union == set(ids), f"bulk must cover all 3 tasks, got: {body!r}"
    # task-1 is covered by the started/skipped split (never silently dropped
    # into `failed` alone without the other two being accounted for — the
    # union check above is the hard gate; this pins the split explicitly).
    assert ids[0] in body["skipped"] or ids[0] in body["started"], (
        f"task-1 {ids[0]!r} must be in skipped (worker in-flight) or started "
        f"(worker drained), got: {body!r}"
    )
    # The two idle tasks should have been started (at least one of them —
    # the other may be skipped if the first bulk call raced a worker write).
    assert len(body["started"]) >= 1, f"expected >=1 started, got: {body!r}"


# ─── Test 3: re-POST is safe ────────────────────────────────────────────────


def test_run_all_agents_repost_safe(harness: FunctionalHarness):
    """Second POST -> still 200 with the same 3-id coverage (no 409/500)."""
    ws_id, kanban_id, col_id, ids = _seed_column_with_three_tasks(harness)
    _start_agent(harness, ws_id, kanban_id, ids[0], expect=200)

    first = _run_all_agents(harness, ws_id, kanban_id, col_id, expect=200)
    assert first.get("success") is True

    second = _run_all_agents(harness, ws_id, kanban_id, col_id, expect=200)
    assert second.get("success") is True, f"got: {second!r}"
    assert second.get("column_id") == col_id
    union = set(second["started"]) | set(second["skipped"]) | set(second["failed"])
    assert union == set(ids), f"re-POST must still cover all 3, got: {second!r}"


# ─── Test 4: unknown column -> 404 ──────────────────────────────────────────


def test_run_all_agents_unknown_column_404(harness: FunctionalHarness):
    """POST run_all_agents on a bogus column -> 404 `column not found`."""
    ws_id, kanban_id, _col_id, _ids = _seed_column_with_three_tasks(harness)
    body = _run_all_agents(harness, ws_id, kanban_id, "col_does_not_exist", expect=404)
    assert "column not found" in body.get("error", "").lower(), f"got: {body!r}"


# ─── Test 5: single-task GET unshadowed ─────────────────────────────────────


def test_single_task_get_unshadowed(harness: FunctionalHarness):
    """GET .../tasks/:task_id still returns the single task (not the list).

    Guards the route-order rule: the new POST
    .../kanban/columns/:column_id/run_all_agents lives in the columns family
    (main.zig, after columns DELETE), never under /tasks/:task_id, so the
    single-task GET + the list GET must both keep working.
    """
    ws_id, kanban_id, _col_id, ids = _seed_column_with_three_tasks(harness)

    single = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{ids[0]}",
        expect=200,
    ).json()
    assert isinstance(single.get("task"), dict), f"expected task envelope, got: {single!r}"
    assert single["task"]["id"] == ids[0]

    listed = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks",
        params={"limit": 100},
        expect=200,
    ).json()
    tasks = listed.get("tasks", listed if isinstance(listed, list) else [])
    found = {t["id"] for t in tasks if isinstance(t, dict) and "id" in t}
    assert set(ids) <= found, f"list must contain all 3 seeded tasks, got {found!r}"
