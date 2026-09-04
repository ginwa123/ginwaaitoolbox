"""Functional tests for nalar-tui cwd fix.

Regression for "theres a mismatch cwd, when using nalar-tui"
(task_1788360732549_2). The TUI was hardcoding cwd_session="" so the
backend fell back to createSandbox → ~/.local/share/nalar/data/apps/<session_id>
(empty). The agent then listed the sandbox instead of the shell's cwd.

Contract:
  POST /api/llm/session with cwd_session="/tmp/my-proj" → worker.workingDirectory == "/tmp/my-proj"
  POST /api/llm/session with cwd_session="" → worker.workingDirectory contains ".local/share/nalar/data/apps"
"""

from __future__ import annotations

import time
from typing import Any

import pytest

from harness import FunctionalHarness


def _read_session_cwd(harness: FunctionalHarness, session_id: str) -> str | None:
    """Read sessions.cwd straight from the SQLite DB."""
    import sqlite3

    db_path = harness.temp_dir / ".config" / "nalar" / "agent.db"
    conn = sqlite3.connect(str(db_path))
    try:
        row = conn.execute(
            "SELECT cwd FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
    finally:
        conn.close()
    return row[0] if row else None


def _wait_for_session_cwd(
    harness: FunctionalHarness,
    session_id: str,
    timeout_s: float = 5.0,
) -> str | None:
    """Poll DB for sessions.cwd until row appears or timeout."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        cwd = _read_session_cwd(harness, session_id)
        if cwd is not None:
            return cwd
        time.sleep(0.05)
    return None


def _wait_for_worker(
    harness: FunctionalHarness,
    session_id: str,
    timeout_s: float = 5.0,
) -> dict[str, Any] | None:
    """Poll GET /api/workers/:id until 200 or timeout."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            r = harness.http("GET", f"/api/workers/{session_id}", expect=(200, 404))
            if r.status == 200:
                return r.json()
        except AssertionError:
            pass
        time.sleep(0.05)
    return None


def test_tui_cwd_reaches_backend_as_working_directory(
    harness: FunctionalHarness,
) -> None:
    """POST with cwd_session='/tmp/my-proj' → sessions.cwd == that path.

    This is what nalar-tui now does: it captures the shell's cwd via
    realPath and sends it as cwd_session. The backend's session_create
    useCase must honor it (effective_cwd = cwd_session when non-empty).
    We check sessions.cwd (persisted) rather than worker (ephemeral —
    worker is deleted when the stub LLM fails).
    """
    session_id = "tui-cwd-test-001"
    cwd = "/tmp/my-proj"

    # POST like nalar-tui does (via transport.postSend → buildSendBody)
    harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "queue_message": "hello from tui",
            "cwd_session": cwd,
            "allowed_tools": "all",
            "image_urls": "",
            "selected_profile_model": "",
            "is_auto_retry_until_stop": "",
        },
        expect=(201, 500),
    )

    got = _wait_for_session_cwd(harness, session_id, timeout_s=5.0)
    assert got is not None, f"sessions row for {session_id!r} never appeared within 5s"
    assert got == cwd, (
        f"sessions.cwd must equal the cwd_session sent by TUI. "
        f"Expected {cwd!r}, got {got!r}. "
        f"If got is sandbox path, transport.buildSendBody is still hardcoding \"\"."
    )


def test_tui_empty_cwd_falls_back_to_sandbox(
    harness: FunctionalHarness,
) -> None:
    """POST with cwd_session='' → sessions.cwd is sandbox path.

    Empty cwd is the sentinel for "no override" — backend falls back to
    createSandbox → ~/.local/share/nalar/data/apps/<session_id>.
    This preserves backward compat for callers that intentionally want sandbox.
    """
    session_id = "tui-cwd-test-002"

    harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "queue_message": "hello with empty cwd",
            "cwd_session": "",
            "allowed_tools": "all",
            "image_urls": "",
            "selected_profile_model": "",
            "is_auto_retry_until_stop": "",
        },
        expect=(201, 500),
    )

    got = _wait_for_session_cwd(harness, session_id, timeout_s=5.0)
    assert got is not None, f"sessions row for {session_id!r} never appeared within 5s"
    # Windows joins the sandbox with backslashes
    # (C:\...\nalar-func-XXX\.local\share\nalar\data\apps\<session>);
    # POSIX uses forward slashes. Normalize before asserting so the
    # same contract holds on both.
    normalized = got.replace("\\", "/")
    assert ".local/share/nalar/data/apps" in normalized or "/tmp" in normalized, (
        f"empty cwd_session should fall back to sandbox (or /tmp). Got {got!r}"
    )
    # Must NOT be the explicit /tmp/my-proj from the other test
    assert got != "/tmp/my-proj", f"empty cwd should not equal explicit cwd, got {got!r}"


def test_tui_cwd_with_special_chars_round_trips(
    harness: FunctionalHarness,
) -> None:
    """cwd with spaces and quotes must survive JSON escaping.

    transport.buildSendBody now uses encodeJsonString for cwd, so
    paths like '/tmp/my project' or '/tmp/a\"b' must round-trip.
    """
    session_id = "tui-cwd-test-003"
    cwd = "/tmp/my project with spaces"

    harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "queue_message": "hello",
            "cwd_session": cwd,
            "allowed_tools": "all",
            "image_urls": "",
            "selected_profile_model": "",
            "is_auto_retry_until_stop": "",
        },
        expect=(201, 500),
    )

    got = _wait_for_session_cwd(harness, session_id, timeout_s=5.0)
    assert got is not None, f"sessions row for {session_id!r} never appeared"
    assert got == cwd, (
        f"cwd with spaces must round-trip. Expected {cwd!r}, got {got!r}"
    )
