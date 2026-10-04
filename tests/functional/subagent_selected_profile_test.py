"""Subagent selected_profile_model forwarding (task_1789672620943_1).

Regression: subagent child rows persisted NULL profile because
runSubAgent never forwarded the parent's selection to RunParamsNew,
so every LLM call fell back to top-level defaults instead of the
parent profile (e.g. union alpha).

Wire contract over HTTP (harness boots a fresh pabrik per test):

  - PUT /api/llm/session/:id {selected_profile_model} persists it
    (same updateSessionSelectedProfileModel the workflow fix uses).
  - GET /api/llm/session/:id/messages?limit=1 echoes it back
    (same re_read path the per-iteration loop uses to resolve the
    model for every LLM call).

A real spawn_sub_agent round-trip needs a live LLM and is covered
by the Zig static-contract test in tools_exec_spawn_sub_agent.zig
("spawn forwards selected_profile_model to subagent child").
"""

from __future__ import annotations

import time

from harness import FunctionalHarness


def _get_profile_via_messages(
    harness: FunctionalHarness, session_id: str
) -> str | None:
    for _ in range(30):
        body = harness.http(
            "GET",
            f"/api/llm/session/{session_id}/messages",
            params={"limit": 1},
            expect=200,
        ).json()
        got = body.get("selected_profile_model")
        if got is not None:
            return got
        time.sleep(0.1)
    return None


def test_subagent_profile_persists_and_rereads(harness: FunctionalHarness) -> None:
    """PUT profile -> GET messages echoes it (DB not NULL, re-read works)."""
    session_id = "sess_subagent_profile_fwd_001"

    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"selected_profile_model": "union alpha"},
        expect=200,
    ).json()
    assert r["selected_profile_model"] == "union alpha"

    got = _get_profile_via_messages(harness, session_id)
    assert got == "union alpha", (
        f"profile lost on re-read (would be ''/NULL for subagent rows); got {got!r}"
    )


def test_empty_profile_explicitly_clears_via_put(harness: FunctionalHarness) -> None:
    """PUT with explicit empty profile clears it (HTTP always writes).

    Documents the distinction: the HTTP endpoint clears on empty
    (user explicitly picking "Default" in settings), while the
    workflow spawn path only writes when non-empty so a child retry
    with empty params can't NULL out the row.
    """
    session_id = "sess_subagent_profile_fwd_002"

    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"selected_profile_model": "union alpha"},
        expect=200,
    )
    # Explicit empty = clear by design (session_update.zig always writes).
    r2 = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"selected_profile_model": ""},
        expect=200,
    ).json()
    assert r2["selected_profile_model"] == ""

    got = _get_profile_via_messages(harness, session_id)
    # With zero llm_history rows the messages endpoint yields null
    # (no JOINed row); both None and '' mean "no profile".
    assert got in (None, ""), f"expected cleared profile, got {got!r}"
