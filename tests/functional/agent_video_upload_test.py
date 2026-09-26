"""Functional tests for full video upload to LLM (Migration 090).

Exercises the video_urls wire contract against a REAL nalar binary +
REAL SQLite, replaying the EXACT JSON bodies the frontend sends:

  * TASK CREATE — POST kanban/tasks with video_urls → 201, task echoes
    video_urls, row persists.
  * TASK UPDATE — PUT tasks/:id with video_urls → 200; invalid mime →
    400; image mime in video_urls → 400 (wrong column).
  * CHAT SEND — POST /api/llm/session with video_urls → 201; the
    session messages read-back carries video_url.
  * SIZE CAP — oversize video_urls payload → 413 (not 500).
  * EMPTY-STRING TRAP — video_urls:"" binds as SQL '' literal (not
    NULL) → 200, no NOT NULL violation.

Small base64 stubs stand in for real video bytes — the backend never
decodes media, it only validates the data:video/<mime>;base64 prefix,
the allowlist, and the byte cap.
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


@pytest.fixture
def llm_harness(default_nalar_bin: Any) -> Any:
    """Harness with stub LLM profile so the async worker drains the queue
    (user row lands in llm_history BEFORE the LLM call fires)."""
    h = FunctionalHarness.boot(default_nalar_bin, stub_llm_profile=True)
    try:
        yield h
    finally:
        h.teardown()

MP4 = "data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDE="
WEBM = "data:video/webm;base64,GkXfo59ChoEBQveBAULygQRC84E"
MOV = "data:video/quicktime;base64,AAAAIGZ0eXBxdCA="


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "video-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": "board", "path": "/tmp/video-test"},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    body: dict[str, Any],
    expect: int = 201,
) -> dict[str, Any]:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=expect,
    )
    return r.json()


def _update_task(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    task_id: str,
    body: dict[str, Any],
    expect: int = 200,
) -> Any:
    r = harness.http(
        "PUT",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks/{task_id}",
        json_body=body,
        expect=expect,
    )
    return r.json()


def _get_task(
    harness: FunctionalHarness, workspace_id: str, kanban_id: str, task_id: str
) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks/{task_id}",
        expect=200,
    )
    return r.json()["task"]


def _get_task_media(
    harness: FunctionalHarness, workspace_id: str, kanban_id: str, task_id: str
) -> dict[str, Any]:
    """The lazy media payload (media-flags change).

    Task create/get responses deliberately carry only the
    `is_have_image` / `is_have_video` flags so board fetches stay small;
    the full `||`-delimited strings live behind this route
    (`src/http_handlers/tasks_media.zig`, registered at main.zig:790).
    """
    r = harness.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks/{task_id}/media",
        expect=200,
    )
    return r.json()


# ─── Task create with video_urls ───────────────────────────────────────────


def test_create_task_with_mp4_echoes_video_urls(harness: FunctionalHarness):
    """Create with a video → the flag is set and `/media` round-trips it."""
    ws = _create_workspace(harness)
    kb = _create_kanban(harness, ws)
    resp = _create_task(
        harness, ws, kb, {"mode": "create", "name": "clip", "video_urls": MP4}
    )
    task = resp["task"]
    # The create response carries the flag, not the payload — asserting
    # `task["video_urls"]` here is what broke when the media-flags change
    # moved the full string to the lazy /media route.
    assert task["is_have_video"] is True, resp
    assert "video_urls" not in task, (
        f"create response should stay flag-only, got: {sorted(task)}"
    )
    media = _get_task_media(harness, ws, kb, task["id"])
    assert media["video_urls"] == MP4, media
    # GET-by-id keeps the same flag-only contract.
    row = _get_task(harness, ws, kb, task["id"])
    assert row["is_have_video"] is True, row
    assert "video_urls" not in row, (
        f"task GET should stay flag-only, got: {sorted(row)}"
    )


def test_create_task_with_multiple_video_mimes(harness: FunctionalHarness):
    """Three data URLs join with `||` and survive the round-trip intact."""
    ws = _create_workspace(harness)
    kb = _create_kanban(harness, ws)
    joined = "||".join([MP4, WEBM, MOV])
    resp = _create_task(
        harness, ws, kb, {"mode": "create", "name": "clips", "video_urls": joined}
    )
    assert resp["task"]["is_have_video"] is True, resp
    media = _get_task_media(harness, ws, kb, resp["task"]["id"])
    assert media["video_urls"] == joined, media


def test_create_task_rejects_image_mime_in_video_urls(harness: FunctionalHarness):
    ws = _create_workspace(harness)
    kb = _create_kanban(harness, ws)
    _create_task(
        harness,
        ws,
        kb,
        {"mode": "create", "name": "wrong-col", "video_urls": "data:image/png;base64,iVBORw0="},
        expect=400,
    )


def test_create_task_rejects_disallowed_video_mime(harness: FunctionalHarness):
    ws = _create_workspace(harness)
    kb = _create_kanban(harness, ws)
    _create_task(
        harness,
        ws,
        kb,
        {"mode": "create", "name": "ogg", "video_urls": "data:video/ogg;base64,T2dnUw=="},
        expect=400,
    )


# ─── Task PATCH with video_urls ────────────────────────────────────────────


def test_update_task_sets_and_clears_video_urls(harness: FunctionalHarness):
    """PUT sets the payload, PUT "" clears it, and the flag tracks both."""
    ws = _create_workspace(harness)
    kb = _create_kanban(harness, ws)
    resp = _create_task(harness, ws, kb, {"mode": "create", "name": "patchme"})
    tid = resp["task"]["id"]
    assert _get_task_media(harness, ws, kb, tid)["video_urls"] == ""
    assert _get_task(harness, ws, kb, tid)["is_have_video"] is False

    _update_task(harness, ws, kb, tid, {"video_urls": MP4})
    assert _get_task_media(harness, ws, kb, tid)["video_urls"] == MP4
    assert _get_task(harness, ws, kb, tid)["is_have_video"] is True

    # Empty string clears (SQL '' literal — must NOT 500 on NOT NULL).
    _update_task(harness, ws, kb, tid, {"video_urls": ""})
    assert _get_task_media(harness, ws, kb, tid)["video_urls"] == ""
    assert _get_task(harness, ws, kb, tid)["is_have_video"] is False


def test_update_task_rejects_http_url_in_video_urls(harness: FunctionalHarness):
    ws = _create_workspace(harness)
    kb = _create_kanban(harness, ws)
    resp = _create_task(harness, ws, kb, {"mode": "create", "name": "patchbad"})
    _update_task(
        harness, ws, kb, resp["task"]["id"], {"video_urls": "http://example.com/x.mp4"},
        expect=400,
    )


# ─── Chat send with video_urls ─────────────────────────────────────────────


def _user_messages_with_video(
    harness: FunctionalHarness, session_id: str, timeout_s: float = 15.0
) -> list[str]:
    """Poll session messages until a user row appears (async worker drain)."""
    import time

    deadline = time.time() + timeout_s
    while True:
        r = harness.http(
            "GET",
            f"/api/llm/session/{session_id}/messages",
            params={"sort_by": "created_at", "direction": "asc", "limit": 100},
            expect=200,
        )
        msgs = r.json()["messages"]
        users = [m for m in msgs if m.get("role") == "user"]
        if users or time.time() > deadline:
            return [m.get("video_url", "") for m in users]
        time.sleep(0.3)


def test_create_session_with_video_urls_attaches_them_to_user_message(
    harness: FunctionalHarness,
):
    """Synchronous path: mode=create_session writes the user row inline."""
    ws = _create_workspace(harness)
    kb = _create_kanban(harness, ws)
    resp = _create_task(
        harness,
        ws,
        kb,
        {
            "mode": "create_session",
            "name": "Bug with clip",
            "description": "See the attached clip",
            "video_urls": MP4,
        },
    )
    sid = resp["task"]["id"]
    videos = _user_messages_with_video(harness, sid)
    assert any(MP4 in v for v in videos), f"no user message carries the mp4: {videos!r}"


def test_chat_send_with_video_urls_persists_to_session_messages(
    llm_harness: FunctionalHarness,
):
    ws = _create_workspace(llm_harness)
    kb = _create_kanban(llm_harness, ws)
    resp = _create_task(
        llm_harness,
        ws,
        kb,
        {
            "mode": "create_and_run",
            "name": "watch this",
            "description": "see attached",
            "queue_message": "watch this",
            "video_urls": MP4,
        },
    )
    sid = resp["session"]["id"]
    videos = _user_messages_with_video(llm_harness, sid)
    assert any(MP4 in v for v in videos), f"no user message carries the mp4: {videos!r}"


def test_chat_send_direct_with_video_urls(llm_harness: FunctionalHarness):
    r = llm_harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "queue_message": "look",
            "video_urls": MP4,
        },
        expect=201,
    )
    sid = r.json()["id"]
    videos = _user_messages_with_video(llm_harness, sid)
    assert any(MP4 in v for v in videos), f"no user message carries the mp4: {videos!r}"


def test_chat_send_with_2mb_video_body_is_accepted(llm_harness: FunctionalHarness):
    """Regression: session_create rejected bodies > 1 MB with 413.

    A real 1.8 MB mp4 base64-encodes to ~2.4 MB of JSON. The handler
    gate is now 35 MB (25 MB video cap + base64 inflation); the
    25 MB video_urls_validation cap stays the user-facing limit.
    """
    big_payload = "A" * (2 * 1024 * 1024)
    r = llm_harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "queue_message": "big clip",
            "video_urls": f"data:video/mp4;base64,{big_payload}",
        },
        expect=201,
    )
    sid = r.json()["id"]
    videos = _user_messages_with_video(llm_harness, sid)
    assert any("data:video/mp4;base64," in v for v in videos), (
        f"no user message carries the video: {[v[:40] for v in videos]!r}"
    )
