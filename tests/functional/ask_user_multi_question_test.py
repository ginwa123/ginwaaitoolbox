"""Regression tests for the MULTI-`ask_user` stall.

`ask_user_test.py` seeds exactly ONE question per session, so the whole
"the model asked two questions in one assistant turn" shape has never been
exercised. The tool's own prompt tells the model to *"Call it ALONE"* and to
*"Ask ONE question"*, but a prompt is a request, not an invariant: models emit
parallel `ask_user` calls routinely, and the backend had no guard.

## The bug this pins

The answer endpoint resumed the run after EVERY answer. With two questions open:

1. Answering Q1 started a run that hit the `hasPendingQuestion` guard at the top
   of `workflow.zig`'s loop and aborted before the LLM was ever called — so the
   answer sat in the transcript unread while the response claimed
   `resumed: true`.
2. That aborted run held the `worker` row for the length of its own startup, and
   `resumeSession` refuses to start while one exists — so the answer to the
   SECOND question could be committed with `resumed: false` and then never be
   delivered by anything. A permanent stall.

## The fix

Resume only when the LAST question is settled (`questions_remaining == 0`).
The last answer resumes once, and the model reads every answer in the turn
together. See the step-4 comment in `src/http_handlers/ask_user_answer.zig`.

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


def _seed_one_question(
    harness: FunctionalHarness,
    session_id: str,
    qid: str = "q_solo",
    call_id: str = "call_solo",
) -> tuple[str, str]:
    """One question, one assistant row — the N == 1 regression guard."""
    now_ns = int(time.time() * 1_000_000_000)
    conn = _connect(harness)
    try:
        conn.execute(
            """
            INSERT INTO llm_history (id, session_id, model, response_content, role,
                finish_reason, tool_calls_json, tool_call_id, created_at_nano,
                is_feed_to_llm, agent, loop_index, temperature, is_thinking,
                is_input, is_output)
            VALUES ('asst_solo', ?, 'test-model', '', 'assistant', 'tool_calls', ?,
                NULL, ?, 1, 'Agent', 0, 0.2, 0, 0, 1)
            """,
            (
                session_id,
                json.dumps([{"id": call_id, "type": "function",
                             "function": {"name": "ask_user", "arguments": "{}"}}]),
                now_ns,
            ),
        )
        conn.execute(
            """
            INSERT INTO llm_history (id, session_id, model, response_content, role,
                finish_reason, tool_calls_json, tool_call_id, tool_name,
                created_at_nano, is_feed_to_llm, agent, loop_index, temperature,
                is_thinking, is_input, is_output)
            VALUES (?, ?, 'test-model', ?, 'tool', 'tool', '', ?, 'ask_user', ?,
                1, 'Agent', 0, 0.2, 0, 0, 1)
            """,
            (f"row_{qid}", session_id,
             _tool_envelope(qid, "Which environment?", tool_call_id=call_id),
             call_id, now_ns + 1),
        )
        conn.execute(
            """
            INSERT INTO session_pending_question
                (id, session_id, tool_call_id, llm_history_id, question,
                 multi_select, status, answer, created_at, resolved_at)
            VALUES (?, ?, ?, ?, ?, 0, 'pending', NULL, ?, NULL)
            """,
            (qid, session_id, call_id, f"row_{qid}", "Which environment?", now_ns),
        )
        conn.commit()
    finally:
        conn.close()
    return qid, f"row_{qid}"


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
    (the assistant row it streams back), so a flat count across a resume
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


def _queued_message_count(harness: FunctionalHarness, session_id: str) -> int:
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


def _wait_until(predicate, timeout: float = 8.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def _answer(harness: FunctionalHarness, session_id: str, question_id: str, answer: str):
    return harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": question_id, "answer": answer},
        expect=200,
    ).json()


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


def test_answering_the_first_of_two_defers_the_resume(harness: FunctionalHarness) -> None:
    """The regression. Answering Q1 must NOT start a run.

    It used to: the run hit the `hasPendingQuestion` guard at the top of
    `workflow.zig`'s loop and aborted before the LLM was called, so the answer
    was never delivered — while the response still claimed `resumed: true`.
    """
    session_id = _create_session(harness)
    (q1, row1), (q2, _row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    before = _llm_row_count(harness, session_id)

    body = _answer(harness, session_id, q1, "staging")

    assert body["status"] == "answered", body
    # The answer is still committed — deferring the resume must not lose it.
    assert '"status":"answered"' in _tool_row_content(harness, row1)
    assert _question_status(harness, q1) == "answered"

    # …but NO run was started, and the card is told how many are left so the
    # UI can say "1 of 2 answered" instead of showing a dead turn.
    assert body["resumed"] is False, body
    assert body["questions_remaining"] == 1, body

    time.sleep(2.0)
    assert not _worker_exists(harness, session_id), "a doomed run was started"
    assert _llm_row_count(harness, session_id) == before

    # Q2 is untouched and still owed.
    assert _question_status(harness, q2) == "pending"
    assert _pending_ids(harness, session_id) == [q2]


def test_answering_the_last_question_resumes_once_with_both_answers(
    harness: FunctionalHarness,
) -> None:
    """The positive half: the LAST answer resumes, and the model reads both.

    This is what the old code failed to do for the first answer — it now
    happens once, at the end, instead of never.
    """
    session_id = _create_session(harness)
    (q1, row1), (q2, row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    first = _answer(harness, session_id, q1, "staging")
    assert first["resumed"] is False and first["questions_remaining"] == 1, first

    second = _answer(harness, session_id, q2, "eu-west-1")
    assert second["status"] == "answered", second
    assert second["questions_remaining"] == 0, second
    assert second["resumed"] is True, second

    # Both answers are in the transcript the model is about to be given.
    assert '"answer":"staging"' in _tool_row_content(harness, row1)
    assert '"answer":"eu-west-1"' in _tool_row_content(harness, row2)
    assert _pending_ids(harness, session_id) == []

    assert _wait_until(lambda: _worker_exists(harness, session_id), timeout=8.0), (
        "the last answer did not start a run"
    )


def test_the_answer_order_does_not_matter(harness: FunctionalHarness) -> None:
    """Answering Q2 first must defer exactly like answering Q1 first.

    The old stall was reachable from the second POST whichever question it was,
    because the guard is session-scoped, not question-scoped.
    """
    session_id = _create_session(harness)
    (q1, row1), (q2, row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    second_first = _answer(harness, session_id, q2, "eu-west-1")
    assert second_first["resumed"] is False, second_first
    assert second_first["questions_remaining"] == 1, second_first
    time.sleep(1.5)
    assert not _worker_exists(harness, session_id), "a doomed run was started"

    last = _answer(harness, session_id, q1, "staging")
    assert last["resumed"] is True, last
    assert last["questions_remaining"] == 0, last
    assert '"answer":"staging"' in _tool_row_content(harness, row1)
    assert _pending_ids(harness, session_id) == []


def test_a_single_question_still_resumes_immediately(harness: FunctionalHarness) -> None:
    """N == 1 must be untouched — the common path cannot afford a regression.

    `questions_remaining` is the new signal the fix branches on, so an off-by-one
    there would silently stop every ordinary question from resuming.
    """
    session_id = _create_session(harness)
    q1, row1 = _seed_one_question(harness, session_id)

    body = _answer(harness, session_id, q1, "staging")
    assert body["status"] == "answered", body
    assert body["questions_remaining"] == 0, body
    assert body["resumed"] is True, body
    assert '"status":"answered"' in _tool_row_content(harness, row1)
    assert _wait_until(lambda: _worker_exists(harness, session_id), timeout=8.0)


def test_skipping_one_of_two_also_defers_the_resume(harness: FunctionalHarness) -> None:
    """Skip is a resolution like any other, so it must defer identically.

    Otherwise "skip question 1" would start the doomed run that "answer question
    1" no longer does.
    """
    session_id = _create_session(harness)
    (q1, _row1), (q2, row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    skipped = harness.http(
        "POST",
        f"/api/llm/session/{session_id}/answer",
        json_body={"question_id": q1, "skip": True},
        expect=200,
    ).json()
    assert skipped["status"] == "skipped", skipped
    assert skipped["resumed"] is False, skipped
    assert skipped["questions_remaining"] == 1, skipped
    time.sleep(1.5)
    assert not _worker_exists(harness, session_id), "a doomed run was started"

    last = _answer(harness, session_id, q2, "eu-west-1")
    assert last["resumed"] is True, last
    assert _queued_message_count(harness, session_id) == 0


def test_a_deferred_answer_is_never_stranded(harness: FunctionalHarness) -> None:
    """The stall itself: nothing may be left holding an undelivered answer.

    The old failure mode was an answer committed with `resumed:false` and no
    run, queue, or retry left to deliver it. Answering the last question is now
    always what delivers the turn, so the pair must end with zero pending.
    """
    session_id = _create_session(harness)
    (q1, row1), (q2, row2) = _seed_two_questions_in_one_assistant_turn(harness, session_id)

    _answer(harness, session_id, q1, "staging")
    _answer(harness, session_id, q2, "eu-west-1")

    assert _pending_ids(harness, session_id) == []
    assert _queued_message_count(harness, session_id) == 0
    assert '"answer":"staging"' in _tool_row_content(harness, row1)
    assert '"answer":"eu-west-1"' in _tool_row_content(harness, row2)
    assert '"status":"pending"' not in _tool_row_content(harness, row1)
    assert '"status":"pending"' not in _tool_row_content(harness, row2)
    # The model must never be handed a `pending` envelope it could guess at.
    assert _wait_until(lambda: _worker_exists(harness, session_id), timeout=8.0)


def test_no_endpoint_lists_the_remaining_questions(harness: FunctionalHarness) -> None:
    """The frontend has to learn the count from the response, not a list route.

    `AskUser.vue` counts its own pending cards out of the transcript, so this is
    a deliberate non-goal rather than an oversight — pinned so nobody adds a
    second source of truth for "is another question open".
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