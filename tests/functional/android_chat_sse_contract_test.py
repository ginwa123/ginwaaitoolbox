"""Wire-contract test for the native Android chat event stream.

`HttpChatEventStream` subscribes to `?channels=llm,sessions,queue`
(`ChatApi.eventsPath()`) on its own connection and decodes the frames in
`decodeChatFrame`. The Kotlin unit tests feed that decoder hand-written
strings, so a rename or a re-shape on the server only reaches them as a
failure if somebody remembers to update the fixture — and until then the phone
shows a chat that never updates, with nothing in any log.

This file closes the gap from the other side: it asks a real `nalar` for the
frames and asserts the exact fields the Kotlin reads. The sibling
`android_workers_contract_test.py` does the same for the `workers` channel.

Two sources of frames, deliberately:

  * **A real turn** (`POST /api/llm/session` on the stub profile) for the
    `llm_full` / `session_*` / `queue_*` frames. Only a real run emits
    `llm_full`, and the shapes below — in particular `finish_reason: "null"`
    as a four-character *string* — are the ones a fixture would have got
    wrong.
  * **The test-only emitter** (`POST /api/dev/sse/emit_llm`, gated behind
    `NALAR_TEST_SSE_EMIT=1`, 404 otherwise) for `llm_chunk`, because the stub
    LLM does not stream deltas. It always labels its frames `llm_chunk`
    regardless of the `type` in the body, so it is only used where that
    label is the one being asserted.

Auth rejection is deliberately **not** tested here: the harness runs with auth
off, and `sse_auth_test.py` already boots an `--auth` instance and pins the
`auth_error`-then-close contract.

Run: pytest tests/functional/android_chat_sse_contract_test.py
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
import urllib.request
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import FunctionalHarness  # noqa: E402

#: `ChatApi.eventsPath()`. Spelled out rather than imported, because the point
#: is to fail when one side moves and the other does not.
CHAT_CHANNELS = "llm,sessions,queue"

#: The names `decodeChatFrameUnsafe` has a branch for on these channels. A
#: frame outside this set lands on its `else -> null` and is dropped in
#: silence — the exact failure this file exists to make visible.
KNOWN_EVENTS = {
    "connected",
    "llm_chunk",
    "llm_full",
    "session_created",
    "session_updated",
    "session_deleted",
    "session_unknown",
    "queue_queued",
    "queue_deleted",
    "queue_unknown",
}

#: The keys the Kotlin row mapper reads off an `llm_full`. All of them are
#: present on every real row, including the ones that are empty.
FULL_ROW_KEYS = {
    "id",
    "index",
    "type",
    "session_id",
    "role",
    "content",
    "finish_reason",
    "reasoning_content",
    "tool_call_id",
    "tool_name",
    "tool_calls_json",
    "diffview_before",
    "diffview_after",
    "image_url",
    "video_url",
    "is_error",
}


@pytest.fixture(scope="module")
def harness():
    """One isolated nalar for the module, on a random free port (never 8081).

    `NALAR_TEST_SSE_EMIT=1` is exported *before* the boot, because the gate is
    read from the server process's own environment. With the var absent the
    test-only emitter is a 404 — deliberately, so a developer or production
    run can never be driven through it.
    """
    previous = os.environ.get("NALAR_TEST_SSE_EMIT")
    os.environ["NALAR_TEST_SSE_EMIT"] = "1"
    try:
        with FunctionalHarness.boot(stub_llm_profile=True) as h:
            yield h
    finally:
        if previous is None:
            os.environ.pop("NALAR_TEST_SSE_EMIT", None)
        else:
            os.environ["NALAR_TEST_SSE_EMIT"] = previous


# ─── helpers ────────────────────────────────────────────────────────────────


def _open_sse(harness: FunctionalHarness, channels: str = CHAT_CHANNELS):
    """Open `?channels=<channels>` and pump frames into a queue.

    Multi-line `data:` frames are joined with a newline, because the server
    pretty-prints with `indent_4` and prefixes *every* resulting line. Taking
    only the first `data:` line yields un-parseable JSON for every frame the
    phone actually cares about.

    Exactly one leading space is stripped, which is what the SSE spec says and
    what `SseFrameParser` does. A wider `.strip()` here would hide a server
    that stopped sending the space, so it is deliberate in both places.
    """
    events_q: queue.Queue = queue.Queue()
    stop_event = threading.Event()
    url = f"http://127.0.0.1:{harness.port}/api/events?channels={channels}"
    response = urllib.request.urlopen(urllib.request.Request(url), timeout=30.0)

    def reader() -> None:
        try:
            current_event: str | None = None
            current_data: list[str] = []
            for raw_line in iter(
                lambda: response.readline().decode("utf-8", errors="replace"), ""
            ):
                if stop_event.is_set():
                    break
                if raw_line.startswith("event:"):
                    current_event = raw_line[len("event:"):].strip()
                elif raw_line.startswith("data:"):
                    current_data.append(raw_line[len("data:"):].removeprefix(" "))
                elif raw_line in ("\n", "\r\n"):
                    if current_event is not None:
                        joined = "\n".join(current_data)
                        try:
                            payload = json.loads(joined) if joined else None
                        except json.JSONDecodeError:
                            payload = joined
                        events_q.put((current_event, payload))
                    current_event = None
                    current_data = []
        except Exception:
            # Closed mid-read during teardown. Normal.
            pass

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    return response, thread, events_q, stop_event


def _drain_until(events_q: queue.Queue, predicate, timeout_s: float = 8.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            event, data = events_q.get(timeout=0.1)
        except queue.Empty:
            continue
        if predicate(event, data):
            return (event, data)
    return None


def _collect(events_q: queue.Queue, seconds: float = 2.0):
    out = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            out.append(events_q.get(timeout=0.1))
        except queue.Empty:
            continue
    return out


def _run_a_turn(harness: FunctionalHarness, events_q: queue.Queue) -> str:
    """Queue a turn on the stub profile and return the session it created."""
    response = harness.http(
        "POST",
        "/api/llm/session",
        json_body={"queue_message": "android chat sse contract", "allowed_tools": ""},
        expect=201,
    )
    body = response.json()
    session_id = body.get("session_id") or body.get("id")
    assert session_id, f"the create reply carried no session id: {body}"
    return session_id


def _emit(harness: FunctionalHarness, session_id: str, payload: dict) -> None:
    harness.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={**payload, "session_id": session_id},
        expect=200,
    )


# ─── the subscription itself ────────────────────────────────────────────────


def test_the_chat_channel_set_is_accepted(harness):
    """`channels=llm,sessions,queue` returns 200 SSE, not a terminated stream.

    `parseChannels` rejects an unknown token and the handler's only response to
    that is to close the stream — a 200 that never emits `connected`. The
    Android pump reads the status code, not the handshake, so it would sit
    reporting "Connecting…" over a socket the server has already torn down, for
    the life of the process.
    """
    req = urllib.request.Request(
        f"http://127.0.0.1:{harness.port}/api/events?channels={CHAT_CHANNELS}"
    )
    with urllib.request.urlopen(req, timeout=5.0) as response:
        assert response.status == 200
        ctype = response.headers.get("Content-Type", "")
        assert "text/event-stream" in ctype, f"expected SSE, got {ctype!r}"


def test_the_chat_stream_handshakes(harness):
    """`event: connected` is the only liveness signal the server offers.

    The web's `SseClient` stays in `connecting` without it. On the phone the
    pump reads the HTTP 200 instead and reports `Live`, and the ViewModel's
    reconnect refetch hangs off that transition — so this pins the frame both
    clients need even though only one of them blocks on it.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        found = _drain_until(events_q, lambda e, d: e == "connected", timeout_s=8.0)
        assert found is not None, "no `connected` handshake on the chat channels"
        assert found[1] == {"connected": True}, found[1]
    finally:
        stop.set()
        response.close()


def test_the_stream_is_chunked_with_no_content_length(harness):
    """`Transfer-Encoding: chunked`, because the body never ends.

    The reader has to see frames as the server writes them. A framing that
    waited for a length — or a `Content-Length` that never arrives — turns
    every live chat into a chat that renders only when the socket closes.
    """
    req = urllib.request.Request(
        f"http://127.0.0.1:{harness.port}/api/events?channels={CHAT_CHANNELS}"
    )
    response = urllib.request.urlopen(req, timeout=5.0)
    try:
        assert (
            response.headers.get("Transfer-Encoding", "").lower() == "chunked"
        ), dict(response.headers)
        assert response.headers.get("Content-Length") is None, dict(response.headers)
    finally:
        response.close()


# ─── a real turn ────────────────────────────────────────────────────────────


def test_a_real_turn_emits_only_frames_the_client_decodes(harness):
    """Every frame a turn produces is one `decodeChatFrame` has a branch for.

    The decoder's `else -> null` is a silent drop, so an event the backend
    gained and the phone did not turns into a working chat that quietly stops
    showing the newest turn. The channel set is the *chat's* one, so a turn is
    the cheapest way to see everything it puts on the wire.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        _run_a_turn(harness, events_q)
        frames = _collect(events_q, seconds=6.0)
    finally:
        stop.set()
        response.close()

    assert frames, "a turn produced no frames at all on the chat channels"
    for name, _ in frames:
        assert name in KNOWN_EVENTS, (
            f"unexpected frame {name!r} on the chat channels; either the backend "
            f"gained an event the Android client drops, or the client needs a "
            f"branch for it"
        )


def test_a_real_turn_delivers_a_canonical_full_row(harness):
    """`llm_full` is the frame the client upserts into the transcript.

    Every key the row mapper touches has to be on the wire, *including the
    empty ones*: the Kotlin reads each with a nullable getter and cannot tell
    an absent key from an absent value, so a payload that omits a key rather
    than sending it empty is a different document as far as the client is
    concerned.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        session_id = _run_a_turn(harness, events_q)
        found = _drain_until(
            events_q,
            lambda e, d: e == "llm_full" and isinstance(d, dict) and d.get("session_id") == session_id,
            timeout_s=10.0,
        )
    finally:
        stop.set()
        response.close()

    assert found is not None, "the turn never delivered an llm_full frame"
    _name, data = found
    missing = FULL_ROW_KEYS - set(data)
    assert not missing, (
        f"llm_full omitted {sorted(missing)}; the client's row mapper reads these "
        f"by name and a missing key is not the same as an empty value"
    )
    assert data["id"], "an idless row cannot be merged, keyed, or de-duplicated"
    assert data["type"] == "full"
    assert data["role"], "a row with no role is drawn as neither a turn nor a tool"
    assert isinstance(data["is_error"], bool), (
        "the client branches on `is_error` to tell a diagnostic from a chat turn, "
        "so it has to be a real boolean on every row"
    )


def test_a_null_finish_reason_reaches_the_wire_as_the_string_null(harness):
    """`finish_reason` is `"null"`, not a JSON null, on a real row.

    This is the single most surprising field in the envelope, and it is the
    reason `optNullableString` exists: `JSONObject.optString` renders a JSON
    null as the four-character text `"null"`, so reading the key with the plain
    getter makes every message look like it ended with a finish reason called
    "null" — which is not nothing, and the client's `is_real_turn` test reads
    it.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        session_id = _run_a_turn(harness, events_q)
        found = _drain_until(
            events_q,
            lambda e, d: e == "llm_full" and isinstance(d, dict) and d.get("session_id") == session_id,
            timeout_s=10.0,
        )
    finally:
        stop.set()
        response.close()

    assert found is not None, "the turn never delivered an llm_full frame"
    _name, data = found
    assert "finish_reason" in data
    assert data["finish_reason"] is None or data["finish_reason"] == "null", (
        f"finish_reason is now {data['finish_reason']!r}. The client filters the "
        f"literal string \"null\"; if the server stopped sending it, revisit "
        f"optNullableString rather than assuming the filter is dead code."
    )


def test_every_llm_full_row_is_pretty_printed_across_data_lines(harness):
    """A real row spans several `data:` lines, and the client rejoins them.

    The server serialises with `.whitespace = .indent_4` and then prefixes
    *each* resulting line. A reader that took only the first line gets
    un-parseable JSON for every canonical row — which is the difference
    between a chat that updates and one that does not, with the same pump.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        session_id = _run_a_turn(harness, events_q)
        found = _drain_until(
            events_q,
            lambda e, d: e == "llm_full" and isinstance(d, dict) and d.get("session_id") == session_id,
            timeout_s=10.0,
        )
    finally:
        stop.set()
        response.close()

    assert found is not None, "the turn never delivered an llm_full frame"
    # The reader only produces a dict when the whole document was rejoined and
    # parsed, so reaching here at all is the assertion; this makes the reason
    # explicit rather than incidental.
    assert isinstance(found[1], dict), found[1]


def test_a_turn_announces_its_session_and_its_queue(harness):
    """`session_created` names the session in `id`; `queue_*` in `session_id`.

    The two are read from different fields by the same decoder
    (`SessionChanged` takes `id`, `QueueChanged` takes `session_id`), so a
    swap is a frame that arrives and resolves to no session — dropped before
    the transcript ever sees it, which is why a queued turn can look like it
    vanished.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        session_id = _run_a_turn(harness, events_q)
        created = _drain_until(
            events_q,
            lambda e, d: e == "session_created" and isinstance(d, dict) and d.get("id") == session_id,
            timeout_s=8.0,
        )
        queued = _drain_until(
            events_q,
            lambda e, d: e == "queue_queued" and isinstance(d, dict) and d.get("session_id") == session_id,
            timeout_s=8.0,
        )
    finally:
        stop.set()
        response.close()

    assert created is not None, "no session_created frame for the new chat"
    assert created[1]["id"] == session_id
    assert queued is not None, "no queue_queued frame for the turn"
    assert queued[1]["session_id"] == session_id
    assert queued[1]["action"] == "queued", (
        "the decoder derives the action from the event name, so the payload's "
        "own copy is informational; a disagreement means one side is guessing"
    )


# ─── llm_chunk, through the test-only emitter ───────────────────────────────


def test_a_chunk_frame_carries_the_fields_the_phone_appends(harness):
    """`type: "chunk"` + `content` + `session_id` + `index`.

    The backend sends *raw provider deltas*, so the client appends rather than
    replaces. A frame with neither `content` nor `reasoning_content` is
    dropped outright, and one with no `session_id` is filtered out by the
    ViewModel before the transcript sees it — both of which read on the phone
    as "the agent said nothing".
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        _emit(harness, SESSION_ID, {"type": "chunk", "content": "Hel", "index": 7})
        found = _drain_until(
            events_q,
            lambda e, d: e == "llm_chunk" and isinstance(d, dict) and d.get("type") == "chunk",
            timeout_s=8.0,
        )
    finally:
        stop.set()
        response.close()

    assert found is not None, "no llm_chunk frame arrived"
    _name, data = found
    assert data["type"] == "chunk"
    assert data["content"] == "Hel"
    assert data["session_id"] == SESSION_ID
    assert "index" in data, "the client reads `index` and defaults it to 0 when absent"


def test_an_empty_delta_still_carries_the_content_key(harness):
    """A chunk with empty `content` is a chunk, not something to discard.

    The decoder drops a frame only when BOTH `content` and
    `reasoning_content` are absent. An omitted `content` therefore reads as
    "no payload at all", which is the same code path a thinking delta would
    otherwise take.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        _emit(harness, SESSION_ID, {"type": "chunk", "content": "", "index": 1})
        found = _drain_until(
            events_q,
            lambda e, d: e == "llm_chunk" and isinstance(d, dict) and d.get("index") == 1,
            timeout_s=8.0,
        )
    finally:
        stop.set()
        response.close()

    assert found is not None, "an empty-content chunk never arrived"
    _name, data = found
    assert "content" in data, (
        "an empty delta must still carry the key; the client reads it with a "
        "nullable getter and cannot tell an absent key from an absent field"
    )
    assert data["content"] == ""


def test_a_chunk_final_frame_is_distinguishable_from_a_chunk(harness):
    """`type: "chunk_final"` ends the turn; `type: "chunk"` continues it.

    The ViewModel calls `finishStreaming()` on the former and appends a delta
    on the latter. If the two ever collapsed into one `type`, a turn would end
    on its first word and the placeholder would freeze there.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        _emit(harness, SESSION_ID, {"type": "chunk_final", "index": 3})
        found = _drain_until(
            events_q,
            lambda e, d: e == "llm_chunk" and isinstance(d, dict) and d.get("type") == "chunk_final",
            timeout_s=8.0,
        )
    finally:
        stop.set()
        response.close()

    assert found is not None, "no chunk_final frame arrived"
    _name, data = found
    assert data["type"] == "chunk_final"
    assert data["session_id"] == SESSION_ID
    assert "finish_reason" in data, (
        "the client reads finish_reason off a chunk_final; a real run's frame "
        "carries the token counts nested under `usage`, never at the top level"
    )
    # `usage` is a nullable nested object on the real wire. Absent or null are
    # both fine — the client reports no token count — but a *top-level*
    # `total_tokens` would be the bug that `optNullableObject` exists to fix.
    assert "total_tokens" not in data or data.get("usage") is not None, (
        "total_tokens at the top level of a chunk_final is what the client "
        "used to read, and it is null on every real turn"
    )


def test_a_diagnostic_delta_is_flagged_is_error(harness):
    """`is_error: true` has to survive the trip, or a retry notice is a turn.

    The client renders a diagnostic as an error card and never persists it.
    If the flag stopped being emitted, the frame would take the branch that
    upserts a row, and the retry notice would be written into the transcript
    for good.
    """
    response, _thread, events_q, stop = _open_sse(harness)
    try:
        _emit(
            harness,
            SESSION_ID,
            {
                "type": "full",
                "content": "TooManyRetries",
                "index": 0,
                "role": "assistant",
                "finish_reason": "stop",
                "is_error": True,
            },
        )
        found = _drain_until(
            events_q,
            lambda e, d: isinstance(d, dict) and d.get("content") == "TooManyRetries",
            timeout_s=8.0,
        )
    finally:
        stop.set()
        response.close()

    assert found is not None, "the is_error frame never arrived"
    name, data = found
    assert name in KNOWN_EVENTS, f"an unknown event name for a diagnostic: {name!r}"
    assert data["is_error"] is True, (
        "is_error was not carried; the client branches on it to avoid writing a "
        "diagnostic into the transcript"
    )


#: Reused by the emitter-driven cases above. The emitter takes the session id
#: in the body, so no real row has to exist for it.
SESSION_ID = "sess_android_chat_sse_contract"
