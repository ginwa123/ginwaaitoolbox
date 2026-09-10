"""Workspace-level routines (Migration 084) wire contract.

Exercises the new workspace-routine endpoints against a REAL nalar
binary + REAL SQLite, replaying the EXACT JSON bodies the frontend
RoutineView will send — plus deletion proofs that the old per-task
surface is gone.

  Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md
  Task: task_1789032258828_0

Covers:
  * CREATE      — happy path (201 {item, routine} + next_run_at set),
                  bad cron → 400, empty name/path → 400,
                  no schedule → manual-only (next_run_at '').
  * GET bundle  — 200 shape; agent-type item → 400 ItemNotRoutine;
                  unknown item → 404.
  * PATCH       — instruction-only keeps schedule; schedule change
                  recomputes next_run_at; schedule '' → NULL;
                  enabled=false → NULL; bad cron → 400.
  * DELETION    — GET /api/routines → 404; POST .../tasks/:id/run → 404;
                  POST tasks {task_type:'routine'} → 400
                  RoutineTasksRemoved; PUT tasks with routine fields →
                  200 plain update (fields ignored, still standard).
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "ws-routines") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_routine(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str = "nightly",
    **kwargs,
) -> dict:
    body = {"name": name, "path": "/tmp/routine-test", **kwargs}
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/routine",
        json_body=body,
        expect=201,
    )
    return r.json()


def _create_agent(harness: FunctionalHarness, workspace_id: str) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": "agent", "path": "/tmp/routine-test"},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_folder(harness: FunctionalHarness, workspace_id: str) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items",
        json_body={"name": "folder", "item_type": "folder", "path": "/tmp/routine-test"},
        expect=201,
    )
    return r.json()["id"]


# ─── CREATE ────────────────────────────────────────────────────────────────


def test_create_routine_happy_path(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    body = _create_routine(
        harness, ws_id, instruction="do things", schedule="0 9 * * *"
    )
    assert body["item"]["item_type"] == "routine", body
    assert body["routine"]["id"] == body["item"]["id"], body
    assert body["routine"]["instruction"] == "do things", body
    assert body["routine"]["schedule"] == "0 9 * * *", body
    assert body["routine"]["next_run_at"] != "", body


def test_create_routine_bad_cron_returns_400(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/routine",
        json_body={"name": "bad", "path": "/tmp/routine-test", "schedule": "not a cron"},
        expect=400,
    )
    assert "cron" in r.json().get("error", "").lower(), r.json()


def test_create_routine_empty_name_or_path_returns_400(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/routine",
        json_body={"name": "   ", "path": "/tmp/routine-test"},
        expect=400,
    )
    harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/routine",
        json_body={"name": "x", "path": ""},
        expect=400,
    )


def test_create_routine_without_schedule_is_manual_only(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    body = _create_routine(harness, ws_id, "manual", instruction="run me by hand")
    assert body["routine"]["schedule"] == "", body
    assert body["routine"]["next_run_at"] == "", body


# ─── GET ───────────────────────────────────────────────────────────────────


def test_get_bundle_returns_routine(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, instruction="hi", schedule="*/5 * * * *")
    item_id = created["item"]["id"]

    r = harness.http(
        "GET", f"/api/workspaces/{ws_id}/items/{item_id}/routine", expect=200
    )
    routine = r.json()["routine"]
    assert routine["instruction"] == "hi", routine
    assert routine["schedule"] == "*/5 * * * *", routine
    assert routine["enabled"] is True, routine


def test_get_on_agent_item_returns_400(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    agent_id = _create_agent(harness, ws_id)

    r = harness.http(
        "GET", f"/api/workspaces/{ws_id}/items/{agent_id}/routine", expect=400
    )
    assert "not a routine" in r.json().get("error", "").lower(), r.json()


def test_get_missing_item_returns_404(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    harness.http(
        "GET", f"/api/workspaces/{ws_id}/items/does-not-exist/routine", expect=404
    )


# ─── PATCH ─────────────────────────────────────────────────────────────────


def test_patch_instruction_keeps_schedule(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, schedule="0 9 * * *")
    item_id = created["item"]["id"]

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{item_id}/routine",
        json_body={"instruction": "do other things"},
        expect=200,
    )
    routine = r.json()["routine"]
    assert routine["instruction"] == "do other things", routine
    assert routine["schedule"] == "0 9 * * *", routine
    assert routine["next_run_at"] != "", routine


def test_patch_schedule_recomputes_next_run_at(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, schedule="0 9 * * *")
    item_id = created["item"]["id"]

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{item_id}/routine",
        json_body={"schedule": "*/5 * * * *"},
        expect=200,
    )
    routine = r.json()["routine"]
    assert routine["schedule"] == "*/5 * * * *", routine
    assert routine["next_run_at"] != "", routine


def test_patch_clear_schedule_nulls_next_run_at(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, schedule="0 9 * * *")
    item_id = created["item"]["id"]

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{item_id}/routine",
        json_body={"schedule": ""},
        expect=200,
    )
    routine = r.json()["routine"]
    assert routine["schedule"] == "", routine
    assert routine["next_run_at"] == "", routine


def test_patch_disable_nulls_next_run_at(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, schedule="0 9 * * *")
    item_id = created["item"]["id"]

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{item_id}/routine",
        json_body={"enabled": False},
        expect=200,
    )
    routine = r.json()["routine"]
    assert routine["enabled"] is False, routine
    assert routine["next_run_at"] == "", routine


def test_patch_bad_cron_returns_400(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id)
    item_id = created["item"]["id"]

    r = harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{item_id}/routine",
        json_body={"schedule": "bogus"},
        expect=400,
    )
    assert "cron" in r.json().get("error", "").lower(), r.json()


# ─── RUN ───────────────────────────────────────────────────────────────────


def test_run_fires_routine(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, instruction="go", schedule="0 0 * * *")
    item_id = created["item"]["id"]

    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{item_id}/routines/{item_id}/run",
        json_body={},
        expect=200,
    ).json()
    assert r.get("success") is True, r
    assert r.get("session_id") == item_id, r
    assert r.get("status") == "firing", r


def test_run_disabled_routine_returns_409(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, schedule="0 0 * * *")
    item_id = created["item"]["id"]

    harness.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{item_id}/routine",
        json_body={"enabled": False},
        expect=200,
    )
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{item_id}/routines/{item_id}/run",
        json_body={},
        expect=409,
    )
    assert "disabled" in r.json().get("error", "").lower(), r.json()


def test_run_unknown_routine_returns_404(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id)
    item_id = created["item"]["id"]

    harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{item_id}/routines/does-not-exist/run",
        json_body={},
        expect=404,
    )


def test_run_routine_under_wrong_item_returns_404(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    first = _create_routine(harness, ws_id, "first")
    second = _create_routine(harness, ws_id, "second")

    harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{second['item']['id']}/routines/{first['item']['id']}/run",
        json_body={},
        expect=404,
    )


# ─── CASCADE ─────────────────────────────────────────────────────────────────


def test_delete_item_cascades_routine(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id)
    item_id = created["item"]["id"]

    harness.http(
        "DELETE", f"/api/workspaces/{ws_id}/items/{item_id}", expect=200
    )
    # Item gone → routine bundle 404s (FK cascade wiped the row).
    harness.http(
        "GET", f"/api/workspaces/{ws_id}/items/{item_id}/routine", expect=404
    )


def test_manual_only_routine_never_auto_fires(harness: FunctionalHarness) -> None:
    """A schedule-less routine has NULL next_run_at so the scheduler's
    due-scan (`next_run_at <= now`) can never match it — only the
    manual run endpoint fires it."""
    ws_id = _create_workspace(harness)
    created = _create_routine(harness, ws_id, "manual")
    item_id = created["item"]["id"]

    r = harness.http(
        "GET", f"/api/workspaces/{ws_id}/items/{item_id}/routine", expect=200
    )
    assert r.json()["routine"]["next_run_at"] == ""

    # ...but manual run still works.
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{item_id}/routines/{item_id}/run",
        json_body={},
        expect=200,
    ).json()
    assert r.get("success") is True


# ─── DELETION PROOFS ───────────────────────────────────────────────────────


def test_old_global_routines_list_is_gone(harness: FunctionalHarness) -> None:
    harness.http("GET", "/api/routines", expect=404)


def test_old_per_task_run_endpoint_is_gone(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    folder_id = _create_folder(harness, ws_id)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{folder_id}/tasks",
        json_body={"name": "plain task"},
        expect=201,
    )
    task_id = r.json()["id"]
    harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{folder_id}/tasks/{task_id}/run",
        expect=404,
    )


def test_create_task_with_routine_type_is_rejected(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness)
    folder_id = _create_folder(harness, ws_id)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{folder_id}/tasks",
        json_body={
            "name": "sneaky routine",
            "task_type": "routine",
            "schedule": "* * * * *",
            "initial_prompt": "x",
        },
        expect=400,
    )
    assert "routine" in r.json().get("error", "").lower(), r.json()


def test_put_task_with_routine_fields_is_plain_update(harness: FunctionalHarness) -> None:
    """Old clients sending schedule/initial_prompt get a 200 plain task
    update (unknown fields ignored) — the task stays standard."""
    ws_id = _create_workspace(harness)
    folder_id = _create_folder(harness, ws_id)
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{folder_id}/tasks",
        json_body={"name": "plain task"},
        expect=201,
    )
    task_id = r.json()["id"]

    harness.http(
        "PUT",
        f"/api/workspaces/{ws_id}/items/{folder_id}/tasks/{task_id}",
        json_body={
            "schedule": "*/5 * * * *",
            "initial_prompt": "stale client",
            "enabled": True,
        },
        expect=200,
    )

    r = harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{folder_id}/tasks/{task_id}",
        expect=200,
    )
    task = r.json()["task"]
    assert task["task_type"] == "standard", task
    assert "routine" not in task, task
