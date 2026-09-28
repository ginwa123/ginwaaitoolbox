"""Workspace-scoped session list + session-detail workspace_id (wire).

Background
----------
`GET /api/llm/session` gained an optional `workspace_id` query param:
when present, the list is scoped to that workspace's sessions
(task-linked ∪ cwd-matched, resolved server-side by
`workspace_scope.workspaceSessionIds`) and `total` must carry the SAME
filter so pagination stays truthful. Semantics locked here over the
real wire:

  * present + matching  -> only that workspace's sessions, total = N
  * present + unknown   -> sessions: [], total: 0 (fail closed)
  * present + EMPTY     -> sessions: [], total: 0 (fail closed —
                           never `IN ()`, never a global leak)
  * absent              -> all sessions (global back-compat guard)

`GET /api/llm/session/:session_id` (a NEW endpoint from the same plan)
returns the session detail incl. `workspace_id` — the owning workspace
id, or null for a session outside every workspace.

Also guards `items_count` on `GET /api/workspaces` (populated for
EVERY workspace regardless of `is_include_items`).

Zig-side coverage lives in `src/http_handlers/session_list.zig`,
`session_get.zig`, `workspaces_list.zig`, and
`src/agentic_loop/llm_history.zig` (count-query contract).

Run:
    NALAR_BIN=<worktree>/zig-out/bin/nalarcore-linux-x86_64 \
      python3 -m pytest tests/functional/session_list_workspace_test.py -v
"""

from __future__ import annotations

import time
import uuid
from typing import Any

from harness import FunctionalHarness


# ─── Helpers (mirror agent_workspace_history_test.py) ──────────────────────


def _create_workspace(harness: FunctionalHarness, name: str) -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(
    harness: FunctionalHarness, workspace_id: str, name: str, path: str
) -> str:
    """Kanban item WITH a `path` — the path is what the cwd-matching
    scope resolver prefix-matches plain-chat cwds against."""
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name, "path": path},
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
) -> str:
    """POST mode='create_session' — session.id == task.id (the exact
    task→session→workspace join the scope resolver reads)."""
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body={"mode": "create_session", "name": name, "description": description},
        expect=201,
    )
    return r.json()["task"]["id"]


def _create_plain_session(harness: FunctionalHarness, name: str, cwd: str) -> str:
    """Plain chat via POST /api/llm/session. `cwd_session` is the
    body field session_create.zig reads for the working directory.

    An explicit `session_id` is passed because the server-side
    default generator (helpers.random.generateSessionId) derives its
    hex from (pid, second) — two plain sessions created within the
    same second collide, and the second INSERT OR IGNORE silently
    reuses the first row. Unique ids sidestep that pre-existing
    generator weakness (reported separately).

    The sessions row is INSERTed by the async emit_run_agent task, so
    wait for it to exist (via the detail endpoint) before asserting
    on the list."""
    session_id = f"sess_test_{uuid.uuid4().hex[:24]}"
    r = harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "session_name": name,
            "cwd_session": cwd,
        },
        expect=201,
    )
    assert r.json()["id"] == session_id, f"create echoed {r.json()!r}"
    _wait_for_session(harness, session_id)
    return session_id


def _wait_for_session(
    harness: FunctionalHarness, session_id: str, timeout_s: float = 5.0
) -> dict[str, Any]:
    """Poll GET /api/llm/session/:id until the row exists (200).
    Also exercises the detail route on every seed: 404 while the
    async insert is still in flight, 200 once landed."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        r = harness.http(
            "GET", f"/api/llm/session/{session_id}", expect=(200, 404)
        )
        if r.status == 200:
            body = r.json()
            assert body.get("session_id") == session_id, f"detail echoed {body!r}"
            return body
        time.sleep(0.05)
    raise AssertionError(
        f"session {session_id} did not appear within {timeout_s}s"
    )


def _list_sessions(
    harness: FunctionalHarness, params: dict[str, Any] | None = None
) -> dict[str, Any]:
    r = harness.http("GET", "/api/llm/session", params=params, expect=200)
    body = r.json()
    assert isinstance(body.get("sessions"), list), f"bad list shape: {body!r}"
    assert isinstance(body.get("total"), int), f"missing total: {body!r}"
    return body


def _session_ids(body: dict[str, Any]) -> set[str]:
    return {s["session_id"] for s in body["sessions"]}


def _seed(harness: FunctionalHarness) -> dict[str, str]:
    """Two workspaces with disjoint sessions:

    A: task_a1 + task_a2 (task-linked) + plain_a (cwd /proj/a/sub
      under A's item path /proj/a)      -> 3 sessions
    B: task_b1 (task-linked)             -> 1 session
    """
    ws_a = _create_workspace(harness, "scoped-ws-a")
    kanban_a = _create_kanban(harness, ws_a, "sprint-a", "/proj/a")
    task_a1 = _create_task(
        harness, ws_a, kanban_a,
        name="Alpha one", description="alpha workspace first task",
    )
    task_a2 = _create_task(
        harness, ws_a, kanban_a,
        name="Alpha two", description="alpha workspace second task",
    )
    plain_a = _create_plain_session(harness, "plain-under-a", "/proj/a/sub")

    ws_b = _create_workspace(harness, "scoped-ws-b")
    kanban_b = _create_kanban(harness, ws_b, "sprint-b", "/proj/b")
    task_b1 = _create_task(
        harness, ws_b, kanban_b,
        name="Beta one", description="beta workspace only task",
    )

    return {
        "ws_a": ws_a,
        "ws_b": ws_b,
        "task_a1": task_a1,
        "task_a2": task_a2,
        "plain_a": plain_a,
        "task_b1": task_b1,
    }


# ─── Tests: GET /api/llm/session?workspace_id=... ──────────────────────────


def test_workspace_a_scope_includes_tasks_and_cwd_chat_excludes_b(
    harness: FunctionalHarness,
) -> None:
    """Leak test: workspace_id=A returns A's 2 task sessions + the
    cwd-matched plain chat, never B's id, and total == 3 (the count
    query must carry the same filter — total must NOT stay global)."""
    seed = _seed(harness)

    body = _list_sessions(harness, {"workspace_id": seed["ws_a"], "limit": 50})
    ids = _session_ids(body)
    assert ids == {seed["task_a1"], seed["task_a2"], seed["plain_a"]}, (
        f"workspace A scope wrong: {sorted(ids)!r}"
    )
    assert seed["task_b1"] not in ids, "workspace B's session leaked into A"
    assert body["total"] == 3, f"total must match the scope, got {body['total']}"


def test_workspace_b_scope_returns_only_b(harness: FunctionalHarness) -> None:
    seed = _seed(harness)

    body = _list_sessions(harness, {"workspace_id": seed["ws_b"], "limit": 50})
    ids = _session_ids(body)
    assert ids == {seed["task_b1"]}, f"workspace B scope wrong: {sorted(ids)!r}"
    assert body["total"] == 1, f"total must be 1, got {body['total']}"


def test_unknown_workspace_id_fails_closed(harness: FunctionalHarness) -> None:
    seed = _seed(harness)

    body = _list_sessions(harness, {"workspace_id": "nope", "limit": 50})
    assert body["sessions"] == [], f"unknown scope must be empty, got {body!r}"
    assert body["total"] == 0, f"unknown scope total must be 0, got {body['total']}"
    assert seed["task_a1"] not in _session_ids(body)


def test_empty_workspace_id_fails_closed(harness: FunctionalHarness) -> None:
    """`workspace_id=` (present but empty) must NOT behave like the
    param being absent — fail closed instead of leaking the global
    list (guards the `IN ()` / empty-bind bug classes)."""
    _seed(harness)

    body = _list_sessions(harness, {"workspace_id": "", "limit": 50})
    assert body["sessions"] == [], f"empty scope must be empty, got {body!r}"
    assert body["total"] == 0, f"empty scope total must be 0, got {body['total']}"


def test_absent_workspace_id_returns_all_sessions(harness: FunctionalHarness) -> None:
    """Global back-compat: without the param the list is unscoped."""
    seed = _seed(harness)

    body = _list_sessions(harness, {"limit": 50})
    ids = _session_ids(body)
    expected = {seed["task_a1"], seed["task_a2"], seed["plain_a"], seed["task_b1"]}
    assert ids == expected, f"global list wrong: {sorted(ids)!r}"
    assert body["total"] == 4, f"global total must be 4, got {body['total']}"


# ─── Tests: GET /api/llm/session/:session_id → workspace_id ────────────────


def test_session_detail_returns_owning_workspace_id(
    harness: FunctionalHarness,
) -> None:
    """Detail workspace_id: task-linked session → A, cwd-matched
    plain chat → A, session outside every workspace → null."""
    seed = _seed(harness)
    outside = _create_plain_session(harness, "outside-chat", "/elsewhere")

    r = harness.http(
        "GET", f"/api/llm/session/{seed['task_a1']}", expect=200
    ).json()
    assert r["session_id"] == seed["task_a1"]
    assert r["workspace_id"] == seed["ws_a"], (
        f"task session must resolve to A, got {r.get('workspace_id')!r}"
    )

    r = harness.http(
        "GET", f"/api/llm/session/{seed['plain_a']}", expect=200
    ).json()
    assert r["workspace_id"] == seed["ws_a"], (
        f"cwd-matched plain chat must resolve to A, got {r.get('workspace_id')!r}"
    )

    r = harness.http(
        "GET", f"/api/llm/session/{outside}", expect=200
    ).json()
    assert r.get("session_id") == outside, f"detail echoed wrong session: {r!r}"
    assert r["workspace_id"] is None, (
        f"session outside every workspace must be null, got body {r!r}"
    )


# ─── Test: GET /api/workspaces → items_count ───────────────────────────────


def test_workspaces_list_carries_items_count(harness: FunctionalHarness) -> None:
    """Every workspace row carries `items_count` (its workspace_items
    row count), whether or not is_include_items fetches the rows.

    Note the +1 everywhere: Migration 094 gives every workspace a DEFAULT
    project (an `agent` item rooted at $HOME), created eagerly by
    `POST /api/workspaces` and healed on read. So "a workspace with nothing
    in it" is no longer a reachable state — it has the default and nothing
    else. The numbers are named so the intent survives the next migration
    that adds another system-owned row.
    """
    seed = _seed(harness)
    empty_ws = _create_workspace(harness, "no-items-ws")

    # One seeded kanban per workspace, plus the default.
    EXPECTED = 2
    # The "no items" workspace has only the default.
    EXPECTED_EMPTY = 1

    r = harness.http("GET", "/api/workspaces", expect=200).json()
    by_id = {w["id"]: w for w in r["workspaces"]}
    assert by_id[seed["ws_a"]]["items_count"] == EXPECTED, by_id[seed["ws_a"]]
    assert by_id[seed["ws_b"]]["items_count"] == EXPECTED, by_id[seed["ws_b"]]
    assert by_id[empty_ws]["items_count"] == EXPECTED_EMPTY, by_id[empty_ws]

    # Cross-check against the authoritative list rather than trusting the
    # badge: the count and the rows must agree, and there must be exactly
    # one default among them.
    for ws_id, expected in (
        (seed["ws_a"], EXPECTED),
        (seed["ws_b"], EXPECTED),
        (empty_ws, EXPECTED_EMPTY),
    ):
        listed = harness.http("GET", f"/api/workspaces/{ws_id}/items", expect=200).json()
        assert listed["count"] == expected, f"{ws_id}: {listed!r}"
        defaults = [i for i in listed["items"] if i.get("is_default") == 1]
        assert len(defaults) == 1, f"{ws_id}: {listed!r}"
        assert defaults[0]["item_type"] == "agent", f"{ws_id}: {listed!r}"

    # Same badge with the items skipped (lazy-load path).
    r2 = harness.http(
        "GET",
        "/api/workspaces",
        params={"is_include_items": "false"},
        expect=200,
    ).json()
    by_id2 = {w["id"]: w for w in r2["workspaces"]}
    assert by_id2[seed["ws_a"]]["items_count"] == EXPECTED, by_id2[seed["ws_a"]]
    assert by_id2[empty_ws]["items_count"] == EXPECTED_EMPTY, by_id2[empty_ws]
    assert all(w["items"] == [] for w in r2["workspaces"]), (
        "is_include_items=false must return empty items arrays"
    )
