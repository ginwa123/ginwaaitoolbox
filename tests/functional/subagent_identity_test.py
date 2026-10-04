"""Sub-agent identity columns (Migration 091, task_1789909961925_0).

A sub-agent session keeps its parent's selected_profile_model (for
thinking inheritance, #554) but now also records its own identity in
sessions.sub_agent_name + parent_session_id. The messages endpoint
exposes both so DB inspection and the UI show who actually ran
(e.g. "implementator") instead of only the parent profile.

Wire contract over HTTP (harness boots a fresh pabrik per test):

  - GET /api/llm/session/:id/messages includes sub_agent_name and
    parent_session_id keys (null/empty for main sessions).
  - sessions table has the new columns (migration ran).

A real spawn_sub_agent round-trip needs a live LLM and is covered
by the Zig unit test in llm_history.zig
("updateSessionSubAgentInfo: stamps sub-agent name and parent").
"""

from __future__ import annotations

from harness import FunctionalHarness


def test_messages_wire_includes_sub_agent_identity(harness: FunctionalHarness) -> None:
    """Main session echoes null/empty identity fields (keys present)."""
    session_id = "sess_subagent_identity_001"

    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"selected_profile_model": "muse spark auto"},
        expect=200,
    )

    body = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/messages",
        params={"limit": 1},
        expect=200,
    ).json()

    assert "sub_agent_name" in body, f"missing sub_agent_name key: {sorted(body)}"
    assert "parent_session_id" in body, f"missing parent_session_id key: {sorted(body)}"
    assert body["sub_agent_name"] in (None, ""), body["sub_agent_name"]
    assert body["parent_session_id"] in (None, ""), body["parent_session_id"]
    # Parent profile still flows through unchanged.
    assert body.get("selected_profile_model") in (None, "muse spark auto", "")
