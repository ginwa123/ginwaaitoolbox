"""Functional regression: a failed auto-name call must not strand the
session as "New Chat" forever.

Reported symptom (task_1790347400820_4): with the `space bunny free`
(OpenAI-style, `url_style: "openai"`) profile, sessions sat in the
sidebar as "New Chat" forever even though the main turn streamed fine.
The live daemon log for those runs contained:

    ERROR [SESSION NAME] Failed to call LLM for session name

Root cause in `src/agentic_loop/workflow.zig`: the name generator ran
exactly once, gated on `loop_counter == 1`. When that single name call
failed (transient 429, a provider that rejects the extra request, a
transport blip) nothing ever retried it, so the placeholder name was
permanent for the life of the session. The catch block also logged a
constant with no error name, so the failure was invisible.

The fix gates the attempt on "the session still has a placeholder name"
instead of on the loop counter, which makes the call both idempotent
and retryable.

What this test proves at the wire
---------------------------------
Both a real pabrik process and the real HTTP/worker path are exercised:

  1. Turn 1 — the stub upstream answers the NAME request with HTTP 503
     (the provider rejects the extra name call) and answers the main
     agent turn normally. The session must stay "New Chat" (nothing was
     named) but the main turn must still complete.
  2. Turn 2 — a second user message on the same session triggers
     another worker run. The name request now succeeds. The session MUST
     be renamed, and the linked task row must follow the cascade.

Pre-fix, step 2 leaves the session as "New Chat" and the assertion
fails. Port selection is the harness's (random 40000..60000), never
8081.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from harness import FunctionalHarness

SESSION_ID = "sess_auto_name_retry_1"
GENERATED_NAME = "wire-verified-auto-name"


def _text_sse(text: str) -> bytes:
    """OpenAI-style SSE stream carrying a plain assistant message."""
    first = {
        "id": "chatcmpl-stub-text",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [
            {
                "index": 0,
                "delta": {"role": "assistant", "content": text},
                "finish_reason": None,
            }
        ],
    }
    final = {
        "id": "chatcmpl-stub-text",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    body = "".join(f"data: {json.dumps(c)}\n\n" for c in (first, final))
    return (body + "data: [DONE]\n\n").encode()


def _tool_call_sse(call_id: str) -> bytes:
    """One tool-call round-trip.

    The workflow services the tool result and loops back for another
    LLM request, so a stub that always answers this way drives one
    `while (true)` iteration per call.
    """
    arguments = json.dumps({"path": "AGENTS.md", "limit": 1})
    first = {
        "id": "chatcmpl-stub-tool",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [
            {
                "index": 0,
                "delta": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": call_id,
                            "type": "function",
                            "function": {"name": "read_file", "arguments": arguments},
                        }
                    ],
                },
                "finish_reason": None,
            }
        ],
    }
    final = {
        "id": "chatcmpl-stub-tool",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
    }
    body = "".join(f"data: {json.dumps(c)}\n\n" for c in (first, final))
    return (body + "data: [DONE]\n\n").encode()


def _error_json(code: str, message: str) -> bytes:
    return json.dumps({"error": {"message": message, "type": code}}).encode()


class _StubState:
    """Fails the FIRST session-name request with HTTP 503.

    The name request is identified the same way the existing
    `agent_list_directory_relative_path_test.py` stub identifies a
    turn: the name call carries NO `tools` array, while the main agent
    turn always does.
    """

    def __init__(
        self,
        tool_rounds: int = 0,
        name_always_fails: bool = False,
    ) -> None:
        self.lock = threading.Lock()
        self.name_calls: list[bytes] = []
        self.agent_calls = 0
        self.name_failures_served = 0
        # How many tool-call rounds the main turn should drive before it
        # answers with a plain stop.
        self.tool_rounds = tool_rounds
        # When true the name request ALWAYS 503s, so the number of name
        # calls equals the number of loop iterations that reached the gate.
        self.name_always_fails = name_always_fails

    def classify(self, body: bytes) -> str:
        with self.lock:
            if b"SessionNameGenerator" in body or (
                b'"tools"' not in body and b"SessionName" in body
            ):
                self.name_calls.append(body)
                return "name"
            self.agent_calls += 1
            return "agent"

    def name_call_count(self) -> int:
        with self.lock:
            return len(self.name_calls)

    def agent_call_count(self) -> int:
        with self.lock:
            return self.agent_calls


class _StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args: Any) -> None:  # silence stderr noise
        pass

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        state: _StubState = self.server.state  # type: ignore[attr-defined]
        kind = state.classify(body)

        if kind == "name":
            with state.lock:
                first_name_call = state.name_failures_served == 0
                # name_always_fails must 503 EVERY name request, not just
                # the first — otherwise the second call would succeed,
                # close the placeholder gate, and hide the very
                # amplification this test is built to detect.
                reject = first_name_call or state.name_always_fails
                if reject:
                    state.name_failures_served += 1
            if reject:
                # The provider rejects the extra name request on turn 1.
                raw = _error_json("rate_limit_error", "name call rejected")
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
            else:
                raw = _text_sse(GENERATED_NAME)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        with state.lock:
            round_index = state.agent_calls
            tool_rounds = state.tool_rounds
        if tool_rounds and round_index <= tool_rounds:
            raw = _tool_call_sse(f"call_round_{round_index}")
        else:
            raw = _text_sse("done")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def _start_stub(
    tool_rounds: int = 0,
    name_always_fails: bool = False,
) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    server.state = _StubState(  # type: ignore[attr-defined]
        tool_rounds=tool_rounds,
        name_always_fails=name_always_fails,
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def _read_names(harness: FunctionalHarness) -> tuple[str | None, str | None]:
    """Return (sessions.name, workspace_item_tasks.name) for the session."""
    db_path = harness.temp_dir / ".config" / "pabrik" / "agent.db"
    conn = sqlite3.connect(str(db_path))
    try:
        row = conn.execute(
            "SELECT s.name, t.name FROM sessions s "
            "LEFT JOIN workspace_item_tasks t ON t.id = s.id "
            "WHERE s.id = ?",
            (SESSION_ID,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None, None
    return row[0], row[1]


def _wait_until(predicate, timeout_s: float) -> bool:
    """Poll `predicate` until it is true or `timeout_s` elapses."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.1)
    return bool(predicate())


def _wait_for_name(
    harness: FunctionalHarness,
    predicate,
    timeout_s: float = 60.0,
) -> tuple[str | None, str | None]:
    deadline = time.monotonic() + timeout_s
    last: tuple[str | None, str | None] = (None, None)
    while time.monotonic() < deadline:
        last = _read_names(harness)
        if predicate(last):
            return last
        if not harness.health():
            return last
        time.sleep(0.25)
    return last


# Alias kept for readability at the call sites that first wait on the
# worker having touched the DB at all.
_wait_until_name = _wait_for_name


def _send_turn(
    harness: FunctionalHarness,
    message: str,
    profile: str,
    allowed_tools: str = "",
) -> None:
    harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": SESSION_ID,
            "queue_message": message,
            "cwd_session": str(harness.temp_dir),
            "allowed_tools": allowed_tools,
            "image_urls": "",
            "selected_profile_model": profile,
            "is_auto_retry_until_stop": "",
        },
        expect=(200, 201, 500),
    )


def test_failed_auto_name_call_is_retried_on_the_next_turn(
    default_pabrik_bin: Any,
) -> None:
    """Turn 1's name call is rejected; turn 2 must still name the session."""
    server = _start_stub()
    harness = FunctionalHarness.boot(default_pabrik_bin, stub_llm_profile=True)
    try:
        stub_url = f"http://127.0.0.1:{server.server_address[1]}/v1/chat/completions"
        profile = "autoname-stub"
        harness.http(
            "PUT",
            "/api/config/pabrik",
            json_body={
                "api_endpoint": stub_url,
                "api_key": "sk-stub-test",
                "model": "stub-model",
                "url_style": "openai",
                "profiles": {
                    profile: {
                        "model": "stub-model",
                        "base_url": stub_url,
                        "api_key": "sk-stub-test",
                        "url_style": "openai",
                    },
                },
                "active_profile": profile,
            },
            expect=200,
        )

        # ── Turn 1: the name call fails (HTTP 503), the main turn runs.
        _send_turn(harness, "please fix the login bug on mobile", profile)

        state: _StubState = server.state  # type: ignore[attr-defined]
        # Wait until turn 1 has actually reached the stub's NAME endpoint.
        # The worker runs asynchronously off the POST, so polling the name
        # counter (not just the DB row) is what proves the scenario was
        # exercised rather than raced past.
        assert _wait_until(lambda: state.name_call_count() >= 1, 60.0), (
            "turn 1 never attempted a session-name call — this run proved "
            f"nothing. log tail:\n{harness.tail_log(3000)}"
        )
        # The main turn must complete even though the name call failed,
        # and the rejected name call must leave the placeholder in place.
        first = _wait_until_name(
            harness, lambda n: n[0] is not None, 60.0
        )
        assert first[0] in ("New Chat", "New Session"), (
            f"turn 1's name call was rejected with 503, so the session must "
            f"still be a placeholder; got {first!r}\n"
            f"--- log tail ---\n{harness.tail_log(3000)}"
        )
        # Exactly one attempt in turn 1 (the attempt is bounded per run).
        assert state.name_call_count() == 1, (
            f"expected exactly 1 name attempt in turn 1, got "
            f"{state.name_call_count()}"
        )

        # ── Turn 2: the same session, a new user message. The name call
        #    now succeeds, and the placeholder gate must let it through.
        _send_turn(harness, "any update on that?", profile)

        final = _wait_for_name(
            harness,
            lambda n: n[0] == GENERATED_NAME,
            timeout_s=60.0,
        )
        assert final[0] == GENERATED_NAME, (
            "the session is STILL a placeholder after the second turn: the "
            "failed auto-name call was never retried (the pre-fix bug).\n"
            f"names={final!r}\n--- log tail ---\n{harness.tail_log(6000)}"
        )
        # The rename cascades to the linked task row ONLY when one exists
        # (a plain chat session created via POST /api/llm/session has no
        # workspace_item_tasks row, and `updateTaskName` correctly
        # returns early for it). When a task row is present it must
        # follow, so the task list and the chat list never disagree.
        if final[1] is not None:
            assert final[1] == GENERATED_NAME, (
                f"sessions.name was renamed but the task row was not: {final!r}"
            )

        with state.lock:
            assert len(state.name_calls) >= 2, (
                "expected a second session-name call on turn 2; "
                f"saw {len(state.name_calls)}"
            )
    finally:
        try:
            harness.teardown()
        except Exception:
            pass
        server.shutdown()


def test_existing_name_is_never_overwritten_by_the_generator(
    default_pabrik_bin: Any,
) -> None:
    """A session that already has a real name must keep it.

    The new gate is "is the name still a placeholder?", so once a name
    exists — generated or typed by the user — the generator must stop.
    Without this the retry fix would rename every existing chat on the
    next turn.
    """
    server = _start_stub()
    harness = FunctionalHarness.boot(default_pabrik_bin, stub_llm_profile=True)
    try:
        stub_url = f"http://127.0.0.1:{server.server_address[1]}/v1/chat/completions"
        profile = "autoname-stub"
        harness.http(
            "PUT",
            "/api/config/pabrik",
            json_body={
                "api_endpoint": stub_url,
                "api_key": "sk-stub-test",
                "model": "stub-model",
                "url_style": "openai",
                "profiles": {
                    profile: {
                        "model": "stub-model",
                        "base_url": stub_url,
                        "api_key": "sk-stub-test",
                        "url_style": "openai",
                    },
                },
                "active_profile": profile,
            },
            expect=200,
        )

        _send_turn(harness, "first message", profile)
        _wait_for_name(harness, lambda n: n[0] == GENERATED_NAME, timeout_s=60.0)

        # The user renames the chat by hand (the frontend's rename call).
        harness.http(
            "PUT",
            f"/api/llm/session/{SESSION_ID}",
            json_body={"name": "my hand-picked title"},
            expect=(200, 204),
        )
        renamed, _ = _read_names(harness)
        assert renamed == "my hand-picked title", (
            f"hand rename did not land: {renamed!r}\n"
            f"--- log tail ---\n{harness.tail_log(3000)}"
        )

        state2: _StubState = server.state  # type: ignore[attr-defined]
        with state2.lock:
            name_calls_before = len(state2.name_calls)
            agent_calls_before = state2.agent_calls

        # A further turn must NOT call the generator again. Wait for the
        # turn-2 worker to demonstrably reach the stub BEFORE asserting —
        # a bare sleep would let the assertion pass simply because the
        # worker had not run yet, which is exactly the regression this
        # test exists to catch.
        _send_turn(harness, "second message", profile)
        assert _wait_until(
            lambda: state2.agent_call_count() > agent_calls_before, 60.0
        ), "turn 2's main turn never reached the stub"
        # Give a wrongly-running name call a beat to land after the turn.
        _wait_until(lambda: state2.name_call_count() > name_calls_before, 2.0)

        after, _ = _read_names(harness)
        assert after == "my hand-picked title", (
            f"the auto-name generator overwrote an existing name: {after!r}"
        )
        assert state2.name_call_count() == name_calls_before, (
            "the generator ran again for an already-named session: "
            f"{name_calls_before} -> {state2.name_call_count()}"
        )
    finally:
        try:
            harness.teardown()
        except Exception:
            pass
        server.shutdown()


def test_name_call_is_not_repeated_per_tool_call_iteration(
    default_pabrik_bin: Any,
) -> None:
    """A failing name call must cost ONE LLM round-trip per turn, not one
    per tool-call iteration.

    The workflow's loop is `while (true)` with no iteration cap: one user
    message can drive many iterations, one per tool round-trip. A gate
    evaluated per ITERATION would add a blocking name call (5-minute read
    timeout) to every one of them whenever the provider keeps failing the
    name request — turning a rare single failure into a systematic cost
    multiplier. The attempt is therefore bounded to once per worker run;
    the retry this fix wants is ACROSS turns.

    The stub makes the main turn take three tool-call iterations and fails
    the name call every time, so the iteration count is directly
    observable as the number of name calls.
    """
    server = _start_stub(tool_rounds=3, name_always_fails=True)
    harness = FunctionalHarness.boot(default_pabrik_bin, stub_llm_profile=True)
    try:
        stub_url = f'http://127.0.0.1:{server.server_address[1]}/v1/chat/completions'
        profile = "autoname-stub"
        harness.http(
            "PUT",
            "/api/config/pabrik",
            json_body={
                "api_endpoint": stub_url,
                "api_key": "sk-stub-test",
                "model": "stub-model",
                "url_style": "openai",
                "profiles": {
                    profile: {
                        "model": "stub-model",
                        "base_url": stub_url,
                        "api_key": "sk-stub-test",
                        "url_style": "openai",
                    },
                },
                "active_profile": profile,
            },
            expect=200,
        )

        _send_turn(
            harness,
            "run three tool rounds please",
            profile,
            allowed_tools="read_file",
        )

        state: _StubState = server.state  # type: ignore[attr-defined]
        # Wait until the turn has driven every scripted tool round.
        assert _wait_until(
            lambda: state.agent_call_count() >= 4, 90.0
        ), (
            f"the turn never reached the scripted tool rounds "
            f"(agent calls={state.agent_call_count()}).\n"
            f"--- log tail ---\n{harness.tail_log(4000)}"
        )

        assert state.name_call_count() == 1, (
            "the auto-name call ran "
            f"{state.name_call_count()} times for ONE turn of "
            f"{state.agent_call_count()} LLM requests — the per-iteration "
            "bound is missing, so a persistently failing name provider "
            "costs one extra blocking LLM call per tool-call iteration."
        )
    finally:
        try:
            harness.teardown()
        except Exception:
            pass
        server.shutdown()
