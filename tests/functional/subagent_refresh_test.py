"""Functional wire tests for GET /api/subagent/progress/:tool_call_id.

Task: task_1788505292766_1 (spawn-subagent-refresh-persist).

The bug: progress events are SSE-ephemeral, so a page refresh mid-run
wipes ChatView's subAgentProgressMap with no replay — the card
collapses to "0 sub-agents" (Task 0 shows "starting…" instead, but the
running/done breakdown is still lost).

The fix: the backend mirrors every progress event into an in-memory
snapshot registry (subagent_progress.zig); this endpoint serves
`{ tool_call_id, progress[] }` so loadChatHistory can rehydrate
placeholder cards. These tests replay the wire round-trip against a
real binary:

  1. unknown tool_call_id → 200 `{ tool_call_id, progress: [] }`
     (must NOT 404 — the frontend treats empty as "keep fallback").
  2. sibling routes still work (route-order shadowing guard).
  3. response shape carries the snapshot row keys.

NOTE: a populated snapshot (mid-run rows) needs live sub-agent
threads, which need a real LLM — not available in this harness. The
populated path is covered by zig unit tests (upsert/get round-trip in
subagent_progress.zig) + vitest (applySnapshotRows in
subagentProgress.spec.ts). These wire tests lock the route, the
empty-shape contract, and the no-shadowing invariant.
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


# ─── Test 1: unknown tool_call_id → 200 empty progress ────────────────────


def test_subagent_progress_unknown_id_returns_empty(harness: FunctionalHarness):
    """A tool_call_id with no live batch must return its id and an empty
    progress array — this is what ChatView sees for completed batches
    (snapshot cleared) and after a server restart (map wiped)."""
    body = harness.http("GET", "/api/subagent/progress/tc_never_existed", expect=200).json()
    assert body["tool_call_id"] == "tc_never_existed", f"got: {body!r}"
    assert body["progress"] == [], f"got: {body!r}"


# ─── Test 2: sibling routes unshadowed (route-order guard) ───────────────


def test_subagent_progress_route_does_not_shadow_siblings(harness: FunctionalHarness):
    """`/api/subagent/progress/:tool_call_id` is a fresh prefix, but pin
    the invariant anyway: the pre-existing session routes must still
    resolve after registering it."""
    r = harness.http("POST", "/api/llm/session", json_body={"name": "subagent-sib"}, expect=201)
    session_id = r.json()["id"]

    messages = harness.http(
        "GET", f"/api/llm/session/{session_id}/messages?limit=10", expect=200
    ).json()
    assert "messages" in messages

    stream = harness.http("GET", f"/api/llm/session/{session_id}/stream", expect=200).json()
    assert set(stream.keys()) >= {"active", "content"}

    # And the new route itself still works.
    snap = harness.http("GET", "/api/subagent/progress/tc_sibling_probe", expect=200).json()
    assert snap["tool_call_id"] == "tc_sibling_probe"
    assert snap["progress"] == []


# ─── Test 3: snapshot row shape ──────────────────────────────────────────


def test_subagent_progress_row_shape_keys(harness: FunctionalHarness):
    """The response must carry the keys the frontend rehydrator reads.
    With no live batch the array is empty, so assert the top-level
    shape here; per-row keys are locked by the zig getSnapshot tests +
    the applySnapshotRows vitest contract."""
    body = harness.http("GET", "/api/subagent/progress/tc_shape_probe", expect=200).json()
    assert set(body.keys()) >= {"tool_call_id", "progress"}
    assert isinstance(body["progress"], list)
