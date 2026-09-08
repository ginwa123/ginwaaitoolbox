"""Functional wire test: REST `skills` + SSE `session_skills` agree after skill equip.

Plan Task 5: docs/superpowers/plans/2026-09-08-live-session-skills-sse.md

Flow:
  1. PUT /api/llm/session/:id creates the session row (no LLM needed).
  2. Seed one session_skills row, then REST GET messages asserts
     body["skills"][0]["skill_name"].
  3. Open SSE /api/events?channels=llm, POST one agent turn, drain until
     llm_full with matching session_id, assert
     data["session_skills"][0]["skill_name"].
  4. Explicit key-name contract: REST key is `skills`, SSE key is
     `session_skills` (locks the mismatch so future renames fail loudly).

Seed method: direct sqlite3 INSERT into session_skills (NOT the real
get_skill/add_skill tool path — that path needs a live LLM plus skill .md
files on disk; the contract under test here is DB -> REST/SSE
serialization, and the inserted row is byte-identical to what
handle_tool.zig SaveSkill writes: INSERT OR REPLACE INTO session_skills
(session_id, skill_name, content, loaded_at_nano) with
strftime('%s','now')).
"""

from __future__ import annotations

import json
import queue
import sqlite3
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any, Iterator

import pytest

from harness import FunctionalHarness

SKILL_NAME = "live-wire-skill"
SKILL_CONTENT = "live wire content"
SESSION_ID = "sess_skills_live_001"


@pytest.fixture
def skills_harness(default_nalar_bin: Path) -> Iterator[FunctionalHarness]:
    """Fresh nalar booted with the stub LLM profile.

    The stub points at a dead port so the LLM call fails fast, but the
    session row + worker turn still run: the queue-message insert emits
    llm_full (workflow.zig uses is_emit_sse=true) carrying session_skills.
    """
    h = FunctionalHarness.boot(default_nalar_bin, stub_llm_profile=True)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


def _open_sse(harness: FunctionalHarness, channels: str = "llm"):
    """Open SSE in a background thread; returns (response, thread, queue, stop)."""
    events_q: queue.Queue = queue.Queue()
    stop_event = threading.Event()
    url = f"http://127.0.0.1:{harness.port}/api/events?channels={channels}"
    response = urllib.request.urlopen(urllib.request.Request(url), timeout=30.0)

    def reader() -> None:
        try:
            current_event: str | None = None
            current_data: list[str] = []
            for raw_line in iter(lambda: response.readline().decode("utf-8", errors="replace"), ""):
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
                            data_obj = json.loads(data_str) if data_str else None
                        except json.JSONDecodeError:
                            data_obj = data_str
                        events_q.put((current_event, data_obj))
                    current_event = None
                    current_data = []
        except (OSError, ValueError, AttributeError):
            pass

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    return response, thread, events_q, stop_event


def _drain_until(events_q: queue.Queue, predicate, timeout_s: float = 60.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            event, data = events_q.get(timeout=0.5)
        except queue.Empty:
            continue
        if predicate(event, data):
            return (event, data)
    return None


def _seed_session_skill(harness: FunctionalHarness) -> None:
    """Direct DB insert mirroring llm_history.saveSkill's SQL."""
    db_path = harness.temp_dir / ".config" / "nalar" / "agent.db"
    assert db_path.exists(), f"agent.db missing at {db_path}"
    conn = sqlite3.connect(str(db_path))
    try:
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute(
            "INSERT OR REPLACE INTO session_skills"
            " (session_id, skill_name, content, loaded_at_nano)"
            " VALUES (?, ?, ?, strftime('%s', 'now'))",
            (SESSION_ID, SKILL_NAME, SKILL_CONTENT),
        )
        conn.commit()
    finally:
        conn.close()


def test_rest_and_sse_skills_agree(skills_harness: FunctionalHarness) -> None:
    h = skills_harness

    # 1. Create session row without running the agent.
    h.http("PUT", f"/api/llm/session/{SESSION_ID}", json_body={"name": "skills-live"}, expect=200)

    # 2. Seed one skill row (direct insert — see module docstring).
    _seed_session_skill(h)

    # 3. REST: top-level `skills` carries the seeded skill.
    body = h.http("GET", f"/api/llm/session/{SESSION_ID}/messages?limit=10", expect=200).json()
    assert "skills" in body, f"REST must use key 'skills'; got keys {sorted(body.keys())!r}"
    assert "session_skills" not in body, (
        f"REST must NOT use SSE key 'session_skills' at top level; got keys {sorted(body.keys())!r}"
    )
    assert isinstance(body["skills"], list) and len(body["skills"]) == 1, (
        f"expected exactly 1 REST skill, got {body.get('skills')!r}"
    )
    assert body["skills"][0]["skill_name"] == SKILL_NAME, (
        f"REST skill_name mismatch: {body['skills'][0]!r}"
    )

    # 4. SSE: open llm channel, trigger one turn, drain for fresh llm_full.
    response, thread, events_q, stop_event = _open_sse(h, "llm")
    try:
        h.http(
            "POST",
            "/api/llm/session",
            json_body={
                "session_id": SESSION_ID,
                "session_name": "skills-live",
                "queue_message": "ping",
            },
            expect=(200, 201, 500),
        )
        found = _drain_until(
            events_q,
            lambda ev, data: ev == "llm_full"
            and isinstance(data, dict)
            and data.get("session_id") == SESSION_ID
            and isinstance(data.get("session_skills"), list)
            and len(data["session_skills"]) > 0,
            timeout_s=60.0,
        )
    finally:
        stop_event.set()
        try:
            response.close()
        except Exception:
            pass
    assert found is not None, "no llm_full with non-empty session_skills arrived within 60s"
    _, data = found
    assert isinstance(data, dict)
    assert "session_skills" in data, f"SSE must use key 'session_skills'; got keys {sorted(data.keys())!r}"
    assert "skills" not in data, (
        f"SSE must NOT use REST key 'skills'; got keys {sorted(data.keys())!r}"
    )
    names = [s.get("skill_name") for s in data["session_skills"]]
    assert SKILL_NAME in names, f"SSE session_skills missing {SKILL_NAME!r}; got {names!r}"

    # 5. Cross-wire agreement: REST and SSE carry the same skill set.
    rest_names = {s.get("skill_name") for s in body["skills"]}
    assert rest_names == {SKILL_NAME}, f"REST skill set mismatch: {rest_names!r}"
    assert set(names) == rest_names, (
        f"REST/SSE skill sets disagree: REST={sorted(rest_names)!r} SSE={sorted(set(names))!r}"
    )
