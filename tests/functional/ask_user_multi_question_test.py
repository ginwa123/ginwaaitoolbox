"""Reproduction for the MULTI-`ask_user` bugs.

`ask_user_test.py` seeds exactly ONE question per session, so the whole
"the model asked two questions in one assistant turn" shape has never been
exercised. The tool's own prompt tells the model to *"Call it ALONE"* and to
*"Ask ONE question"*, but a prompt is a request, not an invariant: models emit
parallel `ask_user` calls routinely (a single question with `options` is one
call, but "which environment AND which region" is two), and the backend has no
guard.

Two independent defects live behind that shape:

  1. `workflow.zig` breaks the turn at the `.tool_calls` arm only AFTER
     `handle_tool` has executed the WHOLE batch, and `workflow.zig:933` aborts
     any run started while a question is still pending. So answering the first
     of two questions starts a run that dies before the LLM is ever called.
  2. `ask_user_pending.resumeSession` refuses to start when a worker row
     exists. The doomed run from (1) owns that slot for the length of its own
     startup, so the SECOND answer can be recorded with `resumed:false` — and
     once the doomed run exits there is nothing left to deliver it.

Both are invisible with one question, which is why the existing suite is green.

Wire fidelity matters here: both questions must hang off ONE assistant row with
BOTH tool_call_ids in its `tool_calls_json`, because that is what the provider
returned and what `handle_tool` Phase 2 persists. Seeding two assistant rows
would model a shape the backend can never produce.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

from harness import FunctionalHarness

# The one-question seeders are reused verbatim so the two files cannot drift.
from ask_user_test import (
    _connect,
    _create_session,
    _pending_envelope,
    _tool_envelope,
)


def _seed_two_questions_in_one_assistant_turn(
    harness: FunctionalHarness,
    session_id: str,
) -> tuple[tuple[str, str], tuple[str, str]]:
    """What `handle_tool` writes when ONE assistant message carries TWO
    `ask_user` tool calls.

    Returns ((q1_id, q1_row_id), (q2_id, q2_row_id)).
    """
    now_ns = int(time.time() * 1_000_000_000)
    tool_calls = [
        {"id": "call_1", "type": "function",
         "function": {"name": "ask_user", "arguments": "{}"}},
        {"id": "call_2", "type": "function",
         "function": {"name": "ask_user", "arguments": "{}"}},
    ]

    conn = _connect(harness)
    try:
        # ONE assistant row, TWO tool_call ids — the real shape.
        conn.execute(
            """
            INSERT INTO llm_history (id, session_id, model, response_content, role,
                finish_reason, tool_calls_json, tool_call_id, created_at_nano,
                is_feed_to_llm, agent, loop_index, temperature, is_thinking,
                is_input, is_output)
            VALUES ('asst_multi', ?, 'test-model', '', 'assistant', 'tool_calls', ?,
                NULL, ?, 1, 'Agent', 0, 0.2, 0, 0, 1)
            """,
            (session_id, json.dumps(tool_calls), now_ns),
        )

        rows = []
        for idx, (call_id, qid, question) in enumerate(
            (
                ("call_1", "q_1", "Which environment should I deploy to?"),
                ("call_2", "q_2", "Which region should I deploy to?"),
            )
        ):
            row_id = f"row_{qid}"
            conn.execute(
                """
                INSERT INTO llm_history (id, session_id, model, response_content,
                    role, finish_reason, tool_calls_json, tool_call_id, tool_name,
                    created_at_nano, is_feed_to_llm, agent, loop_index, temperature,
                    is_thinking, is_input, is_output)
                VALUES (?, ?, 'test-model', ?, 'tool', 'tool', '', ?, 'ask_user', ?,
                    1, 'Agent', 0, 0.2, 0, 0, 1)
                """,
                (
                    row_id,
                    session_id,
                    _tool_envelope(qid, question, tool_call_id=call_id),
                    call_id,
                    now_ns + idx + 1,
                ),
            )
            conn.execute(
                """
                INSERT INTO session_pending_question
                    (id, session_id, tool_call_id, llm_history_id, question,
                     multi_select, status, answer, created_at, resolved_at)
                VALUES (?, ?, ?, ?, ?, 0, 'pending', NULL, ?, NULL)
                """,
                (qid, session_id, call_id, row_id, question, now_ns),
            )
            rows.append((qid, row_id))

        conn.commit()
    finally:
        conn.close()

    return rows[0], rows[1]


def _pending_ids(harness: FunctionalHarness, session_id: str) -> list[str]:
    conn = _connect(harness)
    try:
        return [
            r["id"]
            for r in conn.execute(
                "SELECT id FROM session_pending_question "
                "WHERE session_id = ? AND status = 'pending' ORDER BY created_at ASC",
                (session_id,),
            ).fetchall()
        ]
    finally:
        conn.close()


def _question_status(harness: FunctionalHarness, question_id: str) -> str:
    conn = _connect(harness)
    try:
        row = conn.execute(
            "SELECT status FROM session_pending_question WHERE id = ?", (question_id,)
        ).fetchone()
    finally:
        conn.close()
    return "" if row is None else row["status"]


def _tool_row_content(harness: FunctionalHarness, row_id: str) -> str:
    conn = _connect(harness)
    try:
        row = conn.execute(
            "SELECT response_content FROM llm_history WHERE id = ?", (row_id,)
        ).fetchone()
    finally:
        conn.close()
    return "" if row is None else (row["response_content"] or "")


def _llm_row_count(harness: FunctionalHarness, session_id: str) -> int:
    """How many transcript rows exist. An LLM call ADDS at least one row
    (the assistant row it streams back), so a flat count across the resume
    window proves the run never reached the provider."""
    conn = _connect(harness)
    try:
        return int(
            conn.execute(
                "SELECT COUNT(*) FROM llm_history WHERE session_id = ?", (session_id,)
            ).fetchone()[0]
        )
    finally:
        conn.close()


def _worker_exists(harness: FunctionalHarness, session_id: str) -> bool:
    conn = _connect(harness)
    try:
        return conn.execute(
            "SELECT 1 FROM worker WHERE id = ?", (session_id,)
        ).fetchone() is not None
    finally:
        conn.close()


def _wait_until(predicate, timeout: float = 8.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def _insert_worker_row(harness: FunctionalHarness, session_id: str) -> None:
    """Simulate 'a run is already in flight' by putting the row `resumeSession`
    probes for. This is the exact state the doomed first resume leaves behind."""
    conn = _connect(harness)
    try:
        conn.execute(
            "INSERT OR REPLACE INTO worker (id, session_id, working_directory, "
            "last_activity_nano) VALUES (?, ?, '/tmp', ?)",
            (session_id, session_id, int(time.time() * 1_000_000_000)),
        )
        conn.commit()
    finally:
        conn.close()


def _delete_worker_row(harness: FunctionalHarness, session_id: str) -> None:
    conn = _connect(harness)
    try:
        conn.execute("DELETE FROM worker WHERE id = ?", (session_id,))
        conn.commit()
    finally:
        conn.close()


def _queued_message_count(harness: FunctionalHarness, session_id: str) -> int:
    """A refused resume must at least leave a queued message behind — that is
    the one escape hatch that would eventually deliver the answer. It does not.
    """
    conn = _connect(harness)
    try:
        return int(
            conn.execute(
                "SELECT COUNT(*) FROM session_queue_messages WHERE session_id = ?",
                (session_id,),
            ).fetchone()[0]
        )
    finally:
        conn.close()


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_two_pending_questions_are_seeded_and_independent(harness: FunctionalHarness) -> None:
    """Control: the two-question shape is seedable and both rows are live.

    Without this the other tests could pass for the wrong reason (e.g. the
    second question silently deduplicated onto the first).
    """
    session_id = _create_session(harness)
    (q1, row1), (q2, row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    assert row1 != row2
    assert _pending_ids(harness, session_id) == [q1, q2]
    assert '"status":"pending"' in _tool_row_content(harness, row1)
    assert '"status":"pending"' in _tool_row_content(harness, row2)
    # Each card carries its OWN question_id, so the UI keys two distinct cards.
    assert f'"question_id":"{q1}"' in _tool_row_content(harness, row1)
    assert f'"question_id":"{q2}"' in _tool_row_content(harness, row2)


def test_answering_the_first_of_two_records_the_answer_but_delivers_nothing(
    harness: FunctionalHarness,
) -> None:
    """BUG 1 — the answer to question 1 never reaches the model.

    `workflow.zig:933` aborts ANY run started while a question is still
    pending, so the resume that `POST /answer` starts dies before the LLM is
    called. The row rewrite still happened, so the transcript looks right and
    the HTTP response says `resumed: true` — but no provider call was made, and
    question 2 is still open, so the answer is inert until the human answers
    question 2 as well.
    """
    session_id = _create_session(harness)
    (q1, row1), (q2, _row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    before = _llm_row_count(harness, session_id)

    r = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": q1, "answer": "staging"},
        expect=200,
    )
    body = r.json()
    # The endpoint reports success and a resume.
    assert body["status"] == "answered", body
    assert body["resumed"] is True, body

    # …and the row WAS rewritten, so nothing in the response is a lie.
    assert '"status":"answered"' in _tool_row_content(harness, row1)

    # But the model was never asked. Give the run its full startup window, then
    # assert the transcript did not grow by even one row.
    _wait_until(lambda: _worker_exists(harness, session_id), timeout=5.0)
    time.sleep(2.0)
    assert _llm_row_count(harness, session_id) == before, (
        "the resume reached the LLM — update this test, the guard moved"
    )

    # And the session is still blocked on question 2.
    assert _question_status(harness, q2) == "pending"


def test_a_second_answer_while_a_run_is_in_flight_is_recorded_and_never_delivered(
    harness: FunctionalHarness,
) -> None:
    """BUG 2 — the stall.

    `ask_user_pending.resumeSession` returns false when a worker row exists.
    The doomed run from BUG 1 owns that row for the length of its own startup,
    so a human who answers question 2 during that window gets HTTP 200 with
    `resumed:false`, their answer is committed to `llm_history`… and nothing
    will ever hand it to the model.

    The worker row is seeded rather than raced for: the doomed run's own
    startup is a race, but the STATE it leaves behind is deterministic, and
    that state is what the bug actually depends on.
    """
    session_id = _create_session(harness)
    (q1, _row1), (q2, row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    before = _llm_row_count(harness, session_id)
    _insert_worker_row(harness, session_id)

    r = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": q2, "answer": "eu-west-1"},
        expect=200,
    )
    body = r.json()

    # Committed, and the model WOULD see it if it ever ran.
    assert body["status"] == "answered", body
    assert '"status":"answered"' in _tool_row_content(harness, row2)
    assert '"answer":"eu-west-1"' in _tool_row_content(harness, row2)
    assert _question_status(harness, q2) == "answered"

    # …but no run was started for it.
    assert body["resumed"] is False, body

    # When the in-flight run finally exits, NOTHING is left to deliver the
    # answer: no worker, no queued message, no new transcript row. And
    # question 1 is still open, so the `workflow.zig:933` guard would abort
    # any future run too — the answered row for question 2 is unreachable.
    _delete_worker_row(harness, session_id)
    time.sleep(1.5)
    assert not _worker_exists(harness, session_id), "a run was left behind"
    assert _queued_message_count(harness, session_id) == 0, (
        "the refused resume left no queued message to deliver the answer"
    )
    assert _llm_row_count(harness, session_id) == before
    assert _pending_ids(harness, session_id) == [q1], (
        "question 2 is answered and its row rewritten, but question 1 is still "
        "pending — so every future run aborts at the guard and the answered row "
        "is never read by the model"
    )


def test_no_endpoint_tells_the_frontend_how_many_questions_are_open(
    harness: FunctionalHarness,
) -> None:
    """BUG 3 — the UI cannot coordinate sibling cards.

    There is no `GET .../question(s)` route (the module docstring calls the
    table the frontend's source of truth, but nothing serves it), so a card
    cannot ask 'is another question open?' before POSTing. That is why the
    keyboard fan-out in `AskUser.vue` has nothing to arbitrate with: both
    cards fire their own POST with no shared knowledge.
    """
    session_id = _create_session(harness)
    _seed_two_questions_in_one_assistant_turn(harness, session_id)

    for path in (
        f"/api/llm/session/{session_id}/question",
        f"/api/llm/session/{session_id}/questions",
        f"/api/llm/session/{session_id}/pending_question",
    ):
        r = harness.http("GET", path, expect=(200, 404, 405))
        assert r.status in (404, 405), f"{path} unexpectedly answered {r.status}"