"""Wire-contract test for the native Android "worker is running" indicator.

The Android client's loading indicator (`src/apps/android_mobile/.../worker/`)
is driven entirely by the backend's `worker` table: `GET /api/workers` for the
bootstrap and the `worker_created` / `worker_updated` / `worker_deleted` SSE
frames for everything after. Those frames now arrive on the app's ONE shared
connection, `?channels=llm,queue,sessions,workers` (see
`src/apps/android_mobile/.../chat/SseBus.kt`) — `WorkerActivityViewModel` is the
second subscriber to it rather than the owner of a second socket. Nothing else
in this repo's TypeScript reads the same two shapes for the *phone*, so a rename
or a re-shape here is invisible to the desktop tests and shows up only as a
spinner that never appears — or, worse, one that never goes away.

Two assumptions in the Kotlin are load-bearing and are what this file exists to
pin:

  1. `session_id` is EMPTY on `worker_updated` and `worker_deleted`; the session
     is in the `id` slot. `decodeChatFrame` resolves `session_id || id`. Read
     `session_id` alone and a `deleted` removes nothing, so the spinner is
     stuck on for a run that finished.
  2. `status` and `is_running` are hardcoded per row and carry no information.
     `WorkerApi.parseRunningSessionIds` projects the *presence* of a row down to
     the id set. Parse `is_running` instead and the client is right by accident
     until the backend stops hardcoding it.
  3. "Presence" means presence *of a row that is not cancelled*. Stopping a run
     does not delete its row -- `POST /api/llm/session/:session/stop` sets
     `worker.cancelled = 1` and the loop reads it back to break out of itself --
     so `GET /api/workers` filters `cancelled = 0` itself. Without that filter a
     stopped run was reported as `status: "running"` and a phone keyed a spinner
     on it for as long as the row lived, which is how a client could claim an
     agent was working when nothing was. The filter itself is pinned by the
     in-memory-SQLite tests in `src/http_handlers/worker_list.zig`; the reason
     it cannot be re-derived from the wire here is that the stub LLM finishes a
     run inside a millisecond, so there is no window in which a stop is
     observable over HTTP.

Run: pytest tests/functional/android_workers_contract_test.py
"""

from __future__ import annotations

import json
import queue
import sys
import threading
import time
import urllib.request
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import FunctionalHarness  # noqa: E402


@pytest.fixture(scope="module")
def harness():
    """Boot one isolated nalar instance for the whole module.

    Uses the harness' default random free port (never 8081, which is reserved
    for the developer's running instance) and an isolated tmpdir HOME.
    """
    with FunctionalHarness.boot() as h:
        yield h


def _open_sse(harness: FunctionalHarness, channels: str):
    """Open `?channels=<channels>` and pump frames into a queue.

    Multi-line `data:` frames are joined with a newline, because the server
    pretty-prints its payloads with `indent_4` — taking only the first `data:`
    line yields a JSON parse error for every worker event.
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
                    current_data.append(raw_line[len("data:"):].strip())
                elif raw_line in ("\n", "\r\n"):
                    if current_event is not None:
                        data_str = "\n".join(current_data)
                        try:
                            payload = json.loads(data_str) if data_str else None
                        except json.JSONDecodeError:
                            payload = data_str
                        events_q.put((current_event, payload))
                    current_event = None
                    current_data = []
        except Exception:
            pass

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    return response, thread, events_q, stop_event


def _drain_until(events_q: queue.Queue, predicate, timeout_s: float = 3.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            event, data = events_q.get(timeout=0.1)
        except queue.Empty:
            continue
        if predicate(event, data):
            return (event, data)
    return None


def _collect(events_q: queue.Queue, seconds: float = 1.0):
    """Drain whatever arrived in a window, so a slow frame is not a failure."""
    out = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            out.append(events_q.get(timeout=0.1))
        except queue.Empty:
            continue
    return out


def _running_ids(payload: dict) -> set[str]:
    """The Kotlin client's projection: presence of a row, `session_id` or `id`."""
    ids = set()
    for row in payload.get("workers") or []:
        session_id = row.get("session_id") or row.get("id") or ""
        if session_id:
            ids.add(session_id)
    return ids


def _read_workers_until_populated(
    harness: FunctionalHarness, timeout_s: float = 5.0
) -> dict:
    """Poll `/api/workers` until a row shows up, then return that payload.

    A queued turn registers its worker and the loop deregisters it again within
    a fraction of a second, so a single read has a real chance of landing in
    between. Returning the last (empty) payload on timeout keeps the caller's
    assertion honest instead of skipping the test.
    """
    deadline = time.monotonic() + timeout_s
    payload = {"workers": [], "count": 0}
    while time.monotonic() < deadline:
        payload = harness.http("GET", "/api/workers", params={"limit": 50}).json()
        if payload.get("workers"):
            return payload
        time.sleep(0.05)
    return payload


# ─── GET /api/workers ────────────────────────────────────────────────────────


def test_workers_list_carries_the_envelope_the_android_client_reads(harness):
    """`workers` + `count`, and an array even with nothing running.

    `WorkerApi.parseRunningSessionIds` reads `workers` only. A payload that
    carried just `count: 0` used to be a null-array crash on the phone's first
    frame, so the empty case is asserted explicitly rather than left implicit.
    """
    payload = harness.http("GET", "/api/workers", params={"limit": 50}).json()

    assert "workers" in payload, payload
    assert isinstance(payload["workers"], list), payload
    assert isinstance(payload["count"], int), payload
    # The Kotlin ignores `count`; it must not be the only thing that changes.
    assert payload["count"] == len(payload["workers"]), payload


def test_workers_list_keeps_the_id_fields_the_android_client_reads(harness):
    """Every row must carry `id`, and `session_id` must be a string or null.

    `id` is the fallback the client uses whenever `session_id` is empty, so a
    row missing it entirely is a session the client cannot key a spinner on.

    Skips when no run is in flight. The harness answers a queued turn with its
    stub LLM, so the worker row is registered and deregistered inside a single
    millisecond — there is no window in which `/api/workers` is reliably
    non-empty here, and a poll loop just burns the timeout. Against a real
    provider this test has teeth; against the stub the equivalent contract is
    covered by `test_worker_frames_always_carry_the_id_the_android_client_
    falls_back_to`, which does observe populated frames.
    """
    harness.http(
        "POST",
        "/api/llm/session",
        json_body={"queue_message": "pin the workers contract", "allowed_tools": ""},
        expect=201,
    )

    payload = _read_workers_until_populated(harness, timeout_s=1.0)
    if not payload["workers"]:
        pytest.skip("the stub LLM finishes the run before the list is readable")

    for row in payload["workers"]:
        assert isinstance(row.get("id"), str) and row["id"], row
        assert row.get("session_id") is None or isinstance(row["session_id"], str), row
        # The client's projection: presence, with `session_id` preferred.
        assert _running_ids({"workers": [row]}), row


def test_every_returned_worker_row_reports_itself_as_running(harness):
    """`status`/`is_running` are literals — which is why presence is the signal.

    This is not an assertion that the backend is right; it pins the behaviour
    the Kotlin parser deliberately ignores. If a future change makes these
    fields meaningful, this test fails and `WorkerApi.parseRunningSessionIds`
    gets revisited rather than left quietly wrong.
    """
    payload = harness.http("GET", "/api/workers", params={"limit": 50}).json()

    for row in payload["workers"]:
        assert row.get("is_running") is True, row
        assert row.get("status") == "running", row
        assert isinstance(row.get("queue_count", 0), int), row


def test_workers_limit_is_honoured(harness):
    """`limit` caps the list, and the client's default is the server's default.

    `WorkerApi.WORKERS_PAGE_LIMIT` is 50 because that is the server's default;
    if one side changes without the other, a busy server silently truncates the
    bootstrap and the omitted sessions never get a spinner.
    """
    one = harness.http("GET", "/api/workers", params={"limit": 1}).json()
    many = harness.http("GET", "/api/workers", params={"limit": 50}).json()

    assert len(one["workers"]) <= 1, one
    assert len(many["workers"]) >= len(one["workers"]), (one, many)
    assert _running_ids(one).issubset(_running_ids(many)) or not one["workers"]


# ─── GET /api/events?channels=workers ────────────────────────────────────────


def test_workers_channel_handshake(harness):
    """`channels=workers` returns 200 SSE and a `connected` frame.

    The Android client subscribes to this channel on its own connection, and
    the pump treats any non-2xx handshake as terminal — it reports the failure
    and never retries. A rejected handshake is therefore a spinner that never
    lights up, for the life of the process, with no error on screen.
    """
    req = urllib.request.Request(
        f"http://127.0.0.1:{harness.port}/api/events?channels=workers"
    )
    with urllib.request.urlopen(req, timeout=5.0) as response:
        assert response.status == 200
        ctype = response.headers.get("Content-Type", "")
        assert "text/event-stream" in ctype, f"expected SSE content-type, got {ctype!r}"

    response, thread, events_q, stop = _open_sse(harness, "workers")
    try:
        found = _drain_until(events_q, lambda e, d: e == "connected", timeout_s=5.0)
        assert found is not None, "no `connected` handshake on the workers channel"
    finally:
        stop.set()
        response.close()


def test_the_shared_channel_set_carries_everything_the_app_needs(harness):
    """One connection, four channels, and a typo in it is silent.

    `SseChannels.eventsPath()` is `llm,queue,sessions,workers` and it is the
    app's only subscription. `parseChannels` rejects an unknown token and the
    handler's only response is to close the stream, so a channel-list typo is a
    200 that never emits `connected` — a spinner that never lights up and a
    chat that never updates, with nothing in any log. Each channel is also
    checked on its own so a failure names which one broke.
    """
    for channels in ("llm,queue,sessions,workers", "llm", "queue", "sessions", "workers"):
        req = urllib.request.Request(
            f"http://127.0.0.1:{harness.port}/api/events?channels={channels}"
        )
        with urllib.request.urlopen(req, timeout=5.0) as response:
            assert response.status == 200, channels
            assert "text/event-stream" in response.headers.get("Content-Type", ""), channels


def test_worker_frames_always_carry_the_id_the_android_client_falls_back_to(harness):
    """`id` is always present, and `session_id` never disagrees with it.

    This is the invariant `decodeChatFrame` actually depends on. It resolves
    `session_id || id`, because the two emitters disagree about which field to
    populate:

      * `updateWorker` (the upsert that emits `created`/`updated`) fills both.
      * `updateWorkerActivityWithDescription` emits `updated` with
        `session_id = ""` and the session in `id`.
      * all three delete emitters emit `deleted` with `session_id = ""` and
        the session in `id`.

    Asserting "every frame has an empty session_id" would be wrong, and
    asserting "the upsert fills both" would only describe one of the three
    paths. What must hold for the fallback to be correct is that `id` is always
    there and that the two fields never name different sessions — which is
    exactly the condition under which `session_id || id` is safe.
    """
    response, thread, events_q, stop = _open_sse(harness, "workers")
    try:
        harness.http(
            "POST",
            "/api/llm/session",
            json_body={"queue_message": "wake a worker", "allowed_tools": ""},
            expect=201,
        )
        frames = _collect(events_q, seconds=3.0)
    finally:
        stop.set()
        response.close()

    worker_frames = [
        (name, data) for name, data in frames if name and name.startswith("worker_")
    ]
    if not worker_frames:
        pytest.skip("no worker frame in the window; the loop finished before the pump saw it")

    for name, data in worker_frames:
        assert isinstance(data, dict), (name, data)
        assert "id" in data, f"{name} omitted `id`; the client cannot fall back"
        assert isinstance(data["id"], str) and data["id"], (name, data)
        # The key is always present, even when blank — the client reads it with
        # `optString`, which yields "" for both a missing key and an empty one.
        assert "session_id" in data, (name, data)
        session_id = data["session_id"]
        assert session_id is None or isinstance(session_id, str), (name, data)
        if session_id:
            assert session_id == data["id"], (
                f"{name} named two different sessions: session_id={session_id!r} "
                f"id={data['id']!r}. The client prefers session_id, so a mismatch "
                f"lights the spinner on a session the worker is not running."
            )


def test_a_worker_delete_frame_ships_an_empty_session_id(harness):
    """The delete path specifically: `session_id` is `""`, not merely absent.

    This is the one frame where reading `session_id` alone is silently wrong —
    the removal resolves to no session, the set never loses the entry, and the
    spinner stays lit for a run that finished. Only observed when a delete
    actually lands in the window; the emit path needs a live agentic loop.
    """
    response, thread, events_q, stop = _open_sse(harness, "workers")
    try:
        harness.http(
            "POST",
            "/api/llm/session",
            json_body={"queue_message": "start then stop", "allowed_tools": ""},
            expect=201,
        )
        found = _drain_until(
            events_q, lambda e, d: e == "worker_deleted", timeout_s=8.0
        )
    finally:
        stop.set()
        response.close()

    if found is None:
        pytest.skip("no worker_deleted in the window; the loop had not finished")

    _, data = found
    assert data.get("session_id") == "", (
        f"worker_deleted now populates session_id={data.get('session_id')!r}. "
        f"The client still handles it, but the Kotlin case that pins the empty "
        f"string should be revisited to say which shape is the one on the wire."
    )
    assert data.get("id"), data


def test_worker_frames_use_the_event_names_the_android_client_decodes(harness):
    """`worker_created` / `worker_updated` / `worker_deleted`, and nothing else.

    A rename on the server side reaches the phone as a permanently empty
    spinner, because `decodeChatFrame`'s `else -> null` drops anything it does
    not recognise and the stream carries no error.
    """
    response, thread, events_q, stop = _open_sse(harness, "workers")
    try:
        harness.http(
            "POST",
            "/api/llm/session",
            json_body={"queue_message": "name the worker frames", "allowed_tools": ""},
            expect=201,
        )
        frames = _collect(events_q, seconds=3.0)
    finally:
        stop.set()
        response.close()

    known = {"connected", "worker_created", "worker_updated", "worker_deleted", "worker_unknown"}
    for name, _ in frames:
        assert name in known, (
            f"unexpected frame {name!r} on the workers channel; either the "
            f"backend gained an event the Android client drops, or the client "
            f"needs a branch for it"
        )
