"""Functional wire tests for the `ask_user` agent tool (Migration 088).

Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md

The design makes this feature testable WITHOUT an LLM. `ask_user` does not
block: it records a question, returns immediately, and the agentic loop
BREAKS. The human's answer rewrites that tool call's `llm_history` row in
place and starts a new run. So a test only has to:

  1. seed the two rows the backend would have written (assistant tool_calls
     row + the tool-result row) plus the pending question row;
  2. POST the exact body `AskUser.vue` sends;
  3. assert the row rewrite AND the resume.

That last one is why this file exists: the row rewrite is the model's view of
the answer, and `resumed:true` proves a new run was started. Neither is
observable from Zig unit tests.

Covers:
  * happy path — answer recorded, tool row rewritten in place, run resumed;
  * idempotency — a second POST is a 200, not a 4xx, and resumes once;
  * validation — empty answer 400, unknown question 404, wrong session 403;
  * skip — settles as `skipped` and still resumes;
  * abandoned — a message sent instead of an answer settles the question and
    rewrites the row, so the model never reads `pending`;
  * the route resolves to its own handler (the route-order trap).
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

from harness import FunctionalHarness

# ─── DB helpers (direct sqlite3 into the isolated HOME's agent.db) ──────────


def _db_path(harness: FunctionalHarness) -> Path:
    return Path(harness.temp_dir) / ".config" / "nalar" / "agent.db"


def _connect(harness: FunctionalHarness) -> sqlite3.Connection:
    conn = sqlite3.connect(str(_db_path(harness)), timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


_SESSION_SEQ = 0


def _create_session(harness: FunctionalHarness, name: str = "ask-user-probe") -> str:
    """Spin up a session ROW without starting a run.

    Deliberately `PUT /api/llm/session/:id` (which auto-creates via
    `ensureSessionExists`) and NOT `POST /api/llm/session`: the POST variant
    starts an agent run, and the run's DB transaction then hides this test's
    externally-seeded rows from the app (the row would look missing and the
    endpoint would 404). Same reasoning as
    `session_human_touched_at_test._create_session_via_update`.
    """
    global _SESSION_SEQ
    _SESSION_SEQ += 1
    session_id = f"sess_askuser_{int(time.time())}_{_SESSION_SEQ}"
    harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": name},
        expect=200,
    )
    return session_id


def _pending_envelope(question_id: str, question: str) -> str:
    """The inner `<data>` payload `execAskUser` produces while pending."""
    return (
        "<ask_user>"
        "<status>pending</status>"
        f"<question_id>{question_id}</question_id>"
        "<header>Deploy target</header>"
        f"<question>{question}</question>"
        "<allow_free_text>true</allow_free_text>"
        "<multi_select>false</multi_select>"
        "<recommended>staging</recommended>"
        "<options><option>staging</option><option>production</option></options>"
        "<instruction>The human has been asked and this turn is ending.</instruction>"
        "</ask_user>"
    )


def _tool_envelope(question_id: str, question: str, tool_call_id: str = "call_abc") -> str:
    args = json.dumps(
        {
            "header": "Deploy target",
            "question": question,
            "options": ["staging", "production"],
            "recommended": "staging",
        },
        separators=(",", ":"),
    )
    return (
        "<tool><name>ask_user</name>"
        f"<parameters><header>Deploy target</header><question>{question}</question>"
        "<options><item>staging</item><item>production</item></options>"
        "<recommended>staging</recommended></parameters>"
        "<success>true</success>"
        f"<data>{_pending_envelope(question_id, question)}</data></tool>"
    )


def _seed_question(
    harness: FunctionalHarness,
    session_id: str,
    question_id: str = "q_test_1",
    tool_call_id: str = "call_abc",
    question: str = "Which environment should I deploy to?",
) -> tuple[str, str]:
    """Insert what handle_tool Phase 1/3 + execAskUser would have written.

    Returns (question_id, tool_result_row_id).
    """
    tool_row_id = f"row_{question_id}"
    assistant_row_id = f"asst_{question_id}"
    now_ns = int(time.time() * 1_000_000_000)

    conn = _connect(harness)
    try:
        # The assistant row that made the call (tool_calls_json is what makes
        # the chain a valid assistant(tool_calls) + tool(result) pair).
        conn.execute(
            """
            INSERT INTO llm_history (id, session_id, model, response_content, role,
                finish_reason, tool_calls_json, tool_call_id, created_at_nano,
                is_feed_to_llm, agent, loop_index, temperature, is_thinking,
                is_input, is_output)
            VALUES (?, ?, 'test-model', '', 'assistant', 'tool_calls', ?, NULL, ?,
                1, 'Agent', 0, 0.2, 0, 0, 1)
            """,
            (
                assistant_row_id,
                session_id,
                json.dumps([{"id": tool_call_id, "type": "function",
                             "function": {"name": "ask_user", "arguments": "{}"}}]),
                now_ns,
            ),
        )
        # The tool-result placeholder, rewritten in place by the endpoint.
        conn.execute(
            """
            INSERT INTO llm_history (id, session_id, model, response_content, role,
                finish_reason, tool_calls_json, tool_call_id, tool_name,
                created_at_nano, is_feed_to_llm, agent, loop_index, temperature,
                is_thinking, is_input, is_output)
            VALUES (?, ?, 'test-model', ?, 'tool', 'tool', '', ?, 'ask_user', ?,
                1, 'Agent', 0, 0.2, 0, 0, 1)
            """,
            (tool_row_id, session_id, _tool_envelope(question_id, question), tool_call_id, now_ns + 1),
        )
        # The pending question (Migration 088).
        conn.execute(
            """
            INSERT INTO session_pending_question
                (id, session_id, tool_call_id, llm_history_id, question,
                 multi_select, status, answer, created_at, resolved_at)
            VALUES (?, ?, ?, ?, ?, 0, 'pending', NULL, ?, NULL)
            """,
            (question_id, session_id, tool_call_id, tool_row_id, question, now_ns),
        )
        conn.commit()
    finally:
        conn.close()

    return question_id, tool_row_id


def _question(harness: FunctionalHarness, question_id: str) -> sqlite3.Row | None:
    conn = _connect(harness)
    try:
        return conn.execute(
            "SELECT * FROM session_pending_question WHERE id = ?", (question_id,)
        ).fetchone()
    finally:
        conn.close()


def _tool_row_content(harness: FunctionalHarness, row_id: str) -> str:
    conn = _connect(harness)
    try:
        row = conn.execute(
            "SELECT response_content FROM llm_history WHERE id = ?", (row_id,)
        ).fetchone()
        return "" if row is None else (row["response_content"] or "")
    finally:
        conn.close()


def _worker_exists(harness: FunctionalHarness, session_id: str) -> bool:
    conn = _connect(harness)
    try:
        row = conn.execute("SELECT 1 FROM worker WHERE id = ?", (session_id,)).fetchone()
        return row is not None
    finally:
        conn.close()


def _wait_for_worker(harness: FunctionalHarness, session_id: str, timeout: float = 8.0) -> bool:
    """The resume runs in a concurrent task, so the worker row lands just after
    the HTTP response. Poll briefly instead of asserting immediately."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _worker_exists(harness, session_id):
            return True
        time.sleep(0.05)
    return False


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_answer_rewrites_the_tool_row_and_resumes_the_run(harness: FunctionalHarness) -> None:
    """Happy path: the model's view of the answer + a new run."""
    session_id = _create_session(harness)
    question_id, row_id = _seed_question(harness, session_id)

    r = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": question_id, "answer": "staging"},
        expect=200,
    )
    body = r.json()
    assert body["status"] == "answered", body
    assert body["resumed"] is True, body

    # 1. the question row resolved
    row = _question(harness, question_id)
    assert row is not None and row["status"] == "answered", dict(row) if row else None
    assert row["answer"] == "staging"

    # 2. the tool-result ROW was rewritten in place — same row id, which is
    #    what the model reads on the next run.
    content = _tool_row_content(harness, row_id)
    assert "<status>answered</status>" in content, content
    assert "<answer>staging</answer>" in content, content
    assert "<status>pending</status>" not in content, content

    # 3. a run was started.
    assert _wait_for_worker(harness, session_id), "no worker row after answering"


def test_double_answer_is_idempotent_and_resumes_once(harness: FunctionalHarness) -> None:
    """A double-click (or a retry after a lost 200) must never 4xx."""
    session_id = _create_session(harness)
    question_id, row_id = _seed_question(harness, session_id)

    first = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": question_id, "answer": "production"},
        expect=200,
    )
    assert first.json()["status"] == "answered"

    second = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": question_id, "answer": "production"},
        expect=200,
    )
    assert second.json()["status"] == "answered", second.json()
    # No second run was started for an already-resolved question.
    assert second.json()["resumed"] is False, second.json()

    # The stored answer is unchanged by the replay.
    assert "<answer>production</answer>" in _tool_row_content(harness, row_id)
    # The question row stores the RAW value, not the envelope.
    assert _question_answer(harness, question_id) == "production"


def _question_answer(harness: FunctionalHarness, question_id: str) -> str:
    row = _question(harness, question_id)
    return "" if row is None else (row["answer"] or "")


def test_empty_answer_is_rejected_on_the_wire(harness: FunctionalHarness) -> None:
    """An empty answer would bind as SQL NULL downstream — it must 400."""
    session_id = _create_session(harness)
    question_id, row_id = _seed_question(harness, session_id)

    for bad in ("", "   "):
        r = harness.http(
            "POST",
            f"/api/llm/session/{session_id}/answer",
            json_body={"question_id": question_id, "answer": bad},
            expect=(400,),
        )
        assert r.status == 400, (bad, r.status, r.body)

    # The question is untouched, so a retry is safe.
    row = _question(harness, question_id)
    assert row is not None and row["status"] == "pending"
    assert "<status>pending</status>" in _tool_row_content(harness, row_id)


def test_unknown_question_is_404_and_other_session_is_403(harness: FunctionalHarness) -> None:
    """Never let session A answer session B's question."""
    owner = _create_session(harness, "ask-user-owner")
    other = _create_session(harness, "ask-user-other")
    question_id, _ = _seed_question(harness, owner)

    missing = harness.http(
        "POST",
        f"/api/llm/session/{owner}/answer",
        json_body={"question_id": "q_does_not_exist", "answer": "staging"},
        expect=(404,),
    )
    assert missing.status == 404, missing.status

    stolen = harness.http(
        "POST",
        f"/api/llm/session/{other}/answer",
        json_body={"question_id": question_id, "answer": "staging"},
        expect=(403,),
    )
    assert stolen.status == 403, stolen.status

    # Still pending for its rightful owner.
    row = _question(harness, question_id)
    assert row is not None and row["status"] == "pending"


def test_body_requires_a_question_key(harness: FunctionalHarness) -> None:
    session_id = _create_session(harness)
    _seed_question(harness, session_id)

    r = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"answer": "staging"},
        expect=(400,),
    )
    assert r.status == 400, r.status


def test_tool_call_id_is_accepted_as_the_fallback_key(harness: FunctionalHarness) -> None:
    """The card always has the tool_call_id, so it must work as a key."""
    session_id = _create_session(harness)
    _, row_id = _seed_question(harness, session_id, tool_call_id="call_fallback")

    r = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"tool_call_id": "call_fallback", "answer": "staging"},
        expect=200,
    )
    assert r.json()["status"] == "answered", r.json()
    assert "<answer>staging</answer>" in _tool_row_content(harness, row_id)


def test_skip_settles_the_question_and_still_resumes(harness: FunctionalHarness) -> None:
    """Skip is not Stop: the run must continue, and the model is told not to
    guess instead of being handed an answer."""
    session_id = _create_session(harness)
    question_id, row_id = _seed_question(harness, session_id)

    r = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": question_id, "skip": True},
        expect=200,
    )
    assert r.json()["status"] == "skipped", r.json()

    content = _tool_row_content(harness, row_id)
    assert "<status>skipped</status>" in content, content
    assert "Do not guess" in content, content
    assert _wait_for_worker(harness, session_id), "skip did not resume the run"


def test_a_new_message_instead_of_an_answer_settles_it_as_abandoned(
    harness: FunctionalHarness,
) -> None:
    """The user is never dead-ended: sending a message settles the question and
    the model is told the human moved on (it must not read `pending`)."""
    session_id = _create_session(harness)
    question_id, row_id = _seed_question(harness, session_id)

    # `POST /api/llm/session` creates-or-sends, so it answers 201 here.
    harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "queue_message": "never mind, use production",
            "cwd_session": "/tmp",
        },
        expect=(200, 201),
    )

    row = _question(harness, question_id)
    assert row is not None and row["status"] == "abandoned", dict(row) if row else None

    content = _tool_row_content(harness, row_id)
    assert "<status>abandoned</status>" in content, content
    # The whole point: the model never sees the pending envelope.
    assert "<status>pending</status>" not in content, content

    # And any later answer for it is refused rather than re-resumed.
    late = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": question_id, "answer": "staging"},
        expect=200,
    )
    assert late.json()["status"] == "abandoned", late.json()
    assert late.json()["resumed"] is False, late.json()


def test_answer_route_is_not_shadowed_by_sibling_routes(harness: FunctionalHarness) -> None:
    """Route-order regression guard: `/answer` must resolve to its OWN handler.

    `matchRoute` walks routes in registration order, so a sibling `:param`
    route registered earlier could capture this path (the /knowledge/reorder
    class of bug). The distinctive JSON keys prove which handler ran.
    """
    session_id = _create_session(harness)

    # Wrong method on the right path → 404/405, never a sibling handler's 200
    # with sibling keys.
    r = harness.http("GET", f"/api/llm/session/{session_id}/answer", expect=(404, 405))
    assert r.status >= 400, (r.status, r.body)

    # The real handler answers with its own keys.
    question_id, _ = _seed_question(harness, session_id)
    ok = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": question_id, "answer": "staging"},
        expect=200,
    )
    body = ok.json()
    assert "resumed" in body and "status" in body, body
    # A session-scoped sibling (e.g. /stop) returns `success`, not these.
    assert body.get("success") is True, body
