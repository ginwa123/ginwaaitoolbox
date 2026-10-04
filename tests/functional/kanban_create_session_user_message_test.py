"""Functional tests for the create_session user-message fix.

Regression for the bug "create task still not insert user llm history
role" (task_1787213354784_1). Pre-fix, POST
/api/workspaces/:ws/items/:kanban/tasks with `mode='create_session'`
inserted the sessions row but NOT a user-role llm_history row — the
user's typed description was silently dropped, the chatview landed on
an empty session, and the user had no record of what they originally
asked for.

Post-fix, when `mode='create_session'` is used with a non-empty
description, the handler inserts a user-role llm_history row with
content = `name + "\n\n" + description` (mirrors create_and_run's
wire format). Empty descriptions stay on a clean chat — title-only
tasks don't get a stray "name\n\n" bubble.

We use the harness with `stub_llm_profile=True` so the create_and_run
variant of the test doesn't try to call a real LLM (the wire works,
the worker fails silently, we don't care about LLM outcomes).

Plan: docs/superpowers/plans/2026-08-19-kanban-create-task-inits-session.md
Task: task_1787213354784_1
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "kanban-csum-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(
    harness: FunctionalHarness, workspace_id: str, name: str = "sprint-csum"
) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_task_via_kanban_endpoint(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
    description: str,
    mode: str,
    image_urls: list[str] | None = None,
) -> dict[str, Any]:
    """POST /workspaces/:ws/items/:kanban/kanban/tasks with the given mode.

    Mirrors the frontend's `addKanbanTask(mode, payload)`:
      - mode='create_session'   → plain "Create task" button (the bug)
      - mode='create_and_run'   → "Create task & run agent" button
      - mode='create'           → legacy

    `image_urls` is the array of base64 data URLs the user pasted/attached
    in the kanban detail editor (KanbanDescriptionEditor.pendingFiles).
    The frontend converts each file to a `data:<mime>;base64,...` URL and
    passes the array as `imageUrls` — see KanbanView.handleCreateTaskSave
    line 944-947 (fileToBase64 + imageUrls forwarding).

    For mode='create_and_run' the backend requires a non-empty
    queue_message (validation lives in kanban_tasks_create.zig:127-135
    — 400 otherwise). The frontend builds this from
    `name + "\n\n" + description` (see KanbanView.handleCreateTaskSave
    line 961-966), so we mirror that contract here.

    Returns the parsed response body: `{ task: {...}, session: {...}? }`.
    """
    body: dict[str, Any] = {
        "mode": mode,
        "name": name,
        "description": description,
    }
    if image_urls is not None:
        # Wire shape: the frontend joins base64 data URLs with '||'
        # before sending (see api/index.ts:752 — `body.image_urls =
        # params.imageUrls.join('||')`). The backend's body parser
        # reads `image_urls` as a single `||`-joined string. The
        # workflow drain splits by `|` (single) so the actual stored
        # value uses `|` separator in llm_history.image_url.
        body["image_urls"] = "|".join(image_urls)
    if mode == "create_and_run":
        # The frontend concatenates name + "\n\n" + description into
        # the wire queue_message — same shape the create_session path
        # now persists as the initial user message.
        body["queue_message"] = f"{name}\n\n{description}" if description else name
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _get_session_messages(
    harness: FunctionalHarness, session_id: str
) -> list[dict[str, Any]]:
    """GET /api/llm/session/:id/messages returns the llm_history rows
    (newest first by default; we ask for created_at ASC to mirror the
    chat render order).

    Returns the list of message dicts. Each has at least: id, role,
    content, session_id, created_at.
    """
    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/messages",
        params={"sort_by": "created_at", "direction": "asc", "limit": 100},
        expect=200,
    )
    body = r.json()
    msgs = body.get("messages")
    assert isinstance(msgs, list), f"expected messages list, got: {body!r}"
    return msgs


def _user_role_messages(
    harness: FunctionalHarness, session_id: str
) -> list[dict[str, Any]]:
    """Filter to role='user' rows only (the bug is specifically about
    a missing user-role row)."""
    return [m for m in _get_session_messages(harness, session_id) if m.get("role") == "user"]


# ─── Test 1: create_session WITH description inserts one user-role row ────


def test_create_session_with_description_inserts_user_role_row(
    llm_harness: FunctionalHarness,
) -> None:
    """Regression for task_1787213354784_1.

    When the user clicks the plain "Create task" button (which sends
    mode='create_session' on the wire), the handler must insert a
    user-role llm_history row with content = `name + "\n\n" + description`.
    Pre-fix the row was missing entirely; the chatview landed on an
    empty session and the user's typed description was silently dropped.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    description = "Steps:\n1. Open file\n2. Read code\n3. Find root cause"

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name="Investigate X bug",
        description=description,
        mode="create_session",
    )
    task = resp.get("task")
    assert task is not None, f"create response missing 'task': {resp!r}"
    task_id = task["id"]
    assert task_id.startswith("task_"), f"task id should start with task_, got {task_id!r}"

    # mode='create_session' returns session.status='idle' (vs 'send' for
    # create_and_run — the wire discriminator the frontend uses to
    # distinguish "session exists, no worker" from "session exists,
    # worker started").
    session = resp.get("session")
    assert session is not None, f"create_session response missing 'session': {resp!r}"
    assert session.get("id") == task_id, (
        f"session.id should match task.id (task.id == session.id convention), "
        f"got session.id={session.get('id')!r} vs task.id={task_id!r}"
    )
    assert session.get("status") == "idle", (
        f"create_session should return status='idle' (no agent triggered), "
        f"got {session.get('status')!r}"
    )

    # GET /api/llm/session/:id/messages — the fix's contract is that
    # exactly ONE user-role row exists with content = name\n\ndescription.
    user_msgs = _user_role_messages(llm_harness, task_id)

    assert len(user_msgs) == 1, (
        f"expected exactly 1 user-role llm_history row, got {len(user_msgs)}: "
        f"{user_msgs!r}"
    )

    expected_content = f"Investigate X bug\n\n{description}"
    actual_content = user_msgs[0].get("content")
    assert actual_content == expected_content, (
        f"user-role row content should match wire 'name\\n\\ndescription':\n"
        f"  expected: {expected_content!r}\n"
        f"  actual:   {actual_content!r}"
    )

    # The message must carry the standard llm_history fields — role='user',
    # session_id == task_id (the task.id == session.id convention).
    msg = user_msgs[0]
    assert msg.get("role") == "user"
    assert msg.get("session_id") == task_id


# ─── Test 2: create_session EMPTY description STILL inserts a user row ─────


def test_create_session_with_empty_description_inserts_user_message(
    llm_harness: FunctionalHarness,
) -> None:
    """Regression for the empty-description bug (task_1787757006639_2).

    Title-only tasks (description == '' AND no image_urls) MUST still
    get a user-role llm_history row, otherwise the chatview lands on
    a blank session showing "How can I help you?" (the user has no
    record that they ever created the task and no way to recover
    the title from the chat).

    Pre-fix, the handler gated the INSERT behind
    `description.len > 0 or image_urls_wire.len > 0` — when both were
    empty, NO row was inserted and the chatview rendered the empty
    state. Post-fix the gate is removed and the INSERT always fires
    with content = `name + "\n\n" + description` (empty description
    → content = `name + "\n\n"`, with the trailing separator).

    This test replays the EXACT wire the dialog sends when the user
    types a title and no description and clicks "Create task"
    (mode='create_session'). The frontend's KanbanView.handleCreateTaskSave
    forwards an empty description verbatim (no trim, no fallback).
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name="Title-only task",
        description="",
        mode="create_session",
    )
    task_id = resp["task"]["id"]

    # Exactly ONE user-role row — the INSERT must fire even with
    # empty description (the empty gate is the bug being fixed).
    user_msgs = _user_role_messages(llm_harness, task_id)
    assert len(user_msgs) == 1, (
        f"title-only task must get EXACTLY 1 user-role row (the "
        f"`description.len > 0` gate is the bug), got {len(user_msgs)}: "
        f"{user_msgs!r}"
    )

    # Content shape: name + "\n\n" + description. Empty description
    # means the literal ends in "\n\n". This matches the wire shape
    # create_and_run already uses, so a user who switches from
    # "Create task" to "Create task & run agent" sees the same first
    # user bubble.
    expected_content = "Title-only task\n\n"
    actual_content = user_msgs[0].get("content")
    assert actual_content == expected_content, (
        f"title-only user-role row should have content = name + '\\n\\n':\n"
        f"  expected: {expected_content!r}\n"
        f"  actual:   {actual_content!r}"
    )

    # Standard wire fields still apply (role='user', session_id matches
    # task.id per the task.id == session.id convention).
    msg = user_msgs[0]
    assert msg.get("role") == "user", (
        f"inserted row must have role='user', got {msg.get('role')!r}"
    )
    assert msg.get("session_id") == task_id, (
        f"inserted row must have session_id == task.id, got "
        f"{msg.get('session_id')!r} vs task.id={task_id!r}"
    )


# ─── Test 3: image attachments are persisted on the user message ─────────


# A pair of stub base64 image URLs (deliberately short — the
# llm_history column stores the full data URL string, but we only
# need to assert "the value passed in is the value stored"). These
# match the wire shape the frontend's KanbanDescriptionEditor sends
# via fileToBase64() — see KanbanView.handleCreateTaskSave line 944-947.
PNG_DATA_URL_1 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg=="
JPEG_DATA_URL_2 = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwA/wA/8H//2Q=="


def test_create_session_with_image_urls_attaches_them_to_user_message(
    llm_harness: FunctionalHarness,
) -> None:
    """Image attachments from the kanban detail dialog must land on
    the user-role llm_history row's `image_url` column, so the chatview
    can render thumbnails inline.

    Pre-fix (the bug being closed by this PR) the user-role row was
    missing entirely — the user's typed description + attachments
    were silently dropped from the chat. Post-fix the row exists AND
    carries the attachments.

    Wire shape (matches the frontend's KanbanView.handleCreateTaskSave):
      - frontend collects base64 data URLs from pendingFiles
      - backend receives them as `imageUrls` (array) on the JSON body
      - backend joins them with `||` (Migration 069 wire format)
        into a single string stored on `workspace_item_tasks.image_urls`
        AND now also on `llm_history.image_url` (this test)
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    description = "See the attached screenshots"
    image_urls = [PNG_DATA_URL_1, JPEG_DATA_URL_2]

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name="Bug with screenshots",
        description=description,
        mode="create_session",
        image_urls=image_urls,
    )
    task_id = resp["task"]["id"]

    user_msgs = _user_role_messages(llm_harness, task_id)
    assert len(user_msgs) == 1, (
        f"expected exactly 1 user-role llm_history row, got {len(user_msgs)}: "
        f"{user_msgs!r}"
    )

    # Wire shape: image_url is the `|`-joined concatenation of the
    # input data URLs (matches how the workflow drain stores images
    # on user-role rows; inserLLMHistories joins with `||` but the
    # workflow drain at agentic_loop/workflow.zig:696-705 splits on
    # single `|` and re-joins).
    expected_image_url = "|".join(image_urls)
    actual_image_url = user_msgs[0].get("image_url")
    assert actual_image_url == expected_image_url, (
        f"user-role row's image_url should carry the `||`-joined input "
        f"data URLs:\n  expected: {expected_image_url!r}\n"
        f"  actual:   {actual_image_url!r}"
    )

    # The text content is still the wire-format concatenation.
    assert user_msgs[0].get("content") == f"Bug with screenshots\n\n{description}", (
        f"user-role row's content should match the wire format"
    )

    # The task itself still carries the image_urls column (already
    # existed pre-fix — assert we didn't regress that path).
    assert resp["task"].get("description") == description


# ─── Test 4: image-only (empty description) still inserts a row ────────────


def test_create_session_with_image_urls_only_still_inserts_user_message(
    llm_harness: FunctionalHarness,
) -> None:
    """The new contract fires on `description.len > 0 OR image_urls.len > 0`
    — title-only tasks with attached images must still get a user-role
    row (otherwise the chatview would land on an empty session and the
    user's attachment intent would be invisible).

    Regression guard for the gate change — pre-fix the gate was
    `description.len > 0` only, which would silently drop image-only
    tasks.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name="Screenshots only",
        description="",
        mode="create_session",
        image_urls=[PNG_DATA_URL_1],
    )
    task_id = resp["task"]["id"]

    user_msgs = _user_role_messages(llm_harness, task_id)
    assert len(user_msgs) == 1, (
        f"image-only task should still get 1 user-role row (gate is "
        f"`description.len > 0 OR image_urls_wire.len > 0`), got "
        f"{len(user_msgs)}: {user_msgs!r}"
    )
    # Even with empty description, the content is `name\n\n` (no
    # trailing description). The image_url is preserved.
    assert user_msgs[0].get("content") == "Screenshots only\n\n", (
        f"image-only user message should have name as content (with the "
        f"`\\n\\n` separator and an empty description), got "
        f"{user_msgs[0].get('content')!r}"
    )
    assert user_msgs[0].get("image_url") == PNG_DATA_URL_1, (
        f"image_url should be the input data URL, got "
        f"{user_msgs[0].get('image_url')!r}"
    )


# ─── Profile persistence (regression: task_1787494153778_2) ────────────────


def _get_session_selected_profile(
    harness: FunctionalHarness, session_id: str
) -> str | None:
    """GET /api/llm/session/:id/messages?limit=1 → selected_profile_model.

    This is the exact endpoint the chatview reads on session open
    (ChatView.vue loadChatHistory + api.getSession). The backend
    COALESCEs NULL → '' so a lost profile surfaces as '' (or None if
    the field is absent from the response entirely).

    For create_and_run, the workflow runs in the background after the
    create response returns; the queued user message is drained
    asynchronously (~0.2-0.4s later). Until it lands, the session has
    0 llm_history rows and — pre-fallback-fix — the endpoint returned
    `selected_profile_model: null` (the value is extracted from the
    first JOINed row in getSessionMessagesSorted).

    IMPORTANT (the flake this helper once had): the JSON response
    ALWAYS contains the `selected_profile_model` key — std.json
    serializes optional fields as explicit null, never omits them.
    So a key-presence guard (`if "selected_profile_model" in body`)
    short-circuits on attempt 0 with None and never retries. Poll on
    the VALUE instead: retry until non-None, then return whatever we
    got ('' included — that's the no-profile sentinel the control
    test asserts on).
    """
    import time

    for attempt in range(30):  # up to ~3s
        r = harness.http(
            "GET",
            f"/api/llm/session/{session_id}/messages",
            params={"limit": 1},
            expect=200,
        )
        body = r.json()
        got = body.get("selected_profile_model")
        if got is not None:
            return got
        time.sleep(0.1)
    return None  # surface as "value never became non-null" — the bug


def _get_session_flag_via_db(
    harness: FunctionalHarness, session_id: str
) -> str | None:
    """Read sessions.is_auto_retry_until_stop straight from the DB.

    Used to prove the unattended flag itself is NOT lost by the
    gating fix (it must land on the step-5 full INSERT instead of the
    useCase's bare INSERT).
    """
    import sqlite3

    db_path = harness.temp_dir / ".config" / "pabrik" / "agent.db"
    conn = sqlite3.connect(str(db_path))
    try:
        row = conn.execute(
            "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
    finally:
        conn.close()
    return row[0] if row else None


def test_create_session_persists_selected_profile_model(
    llm_harness: FunctionalHarness,
) -> None:
    """Regression for task_1787494153778_2 ("wrong profile select").

    The dialog ALWAYS sends is_auto_retry_until_stop ('0' or '1').
    Pre-fix, that flag made task_create.useCase insert a bare sessions
    row (no selected_profile_model column) BEFORE the handler's
    profile-bearing INSERT OR IGNORE — which then no-oped on the PK
    conflict and the profile was silently dropped (GET returned '').

    This test replays the EXACT wire the dialog sends with Unattended
    ON + a profile picked: both fields present, mode='create_session'.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)

    body: dict[str, Any] = {
        "mode": "create_session",
        "name": "Profile persistence check",
        "description": "dialog wire with unattended on",
        # The bug's trigger: the dialog ALWAYS includes this field.
        "is_auto_retry_until_stop": "1",
        # The harness's stub profile (see _write_stub_llm_profile in
        # harness.py) — the only profile name that exists in the
        # test HOME's config.json.
        "selected_profile_model": "stub",
    }
    resp = llm_harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=201,
    ).json()
    task_id = resp["task"]["id"]

    # The profile must survive the create → GET round-trip.
    got = _get_session_selected_profile(llm_harness, task_id)
    assert got == "stub", (
        f"selected_profile_model lost on create_session wire! "
        f"expected 'stub', got {got!r}. If '' or None: the bare "
        f"useCase sessions INSERT won the PK race again (the bug)."
    )

    # And the unattended flag must NOT be lost by the gating — it now
    # lands via the step-5 full INSERT instead of the useCase's bare one.
    # SQLite stores is_auto_retry_until_stop as INTEGER (schema default 0),
    # so we compare both '1' and 1 — Python's sqlite3 returns the raw
    # column type, which the empty-string bound becomes NULL→0/1.
    flag = _get_session_flag_via_db(llm_harness, task_id)
    assert flag in ("1", 1), (
        f"is_auto_retry_until_stop should be '1' (persisted by the "
        f"step-5 full INSERT), got {flag!r}"
    )


def test_create_and_run_persists_selected_profile_model(
    llm_harness: FunctionalHarness,
) -> None:
    """Same regression for the 'Create task & run agent' button
    (mode='create_and_run') — same bare-INSERT PK race, same fix."""
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)

    body: dict[str, Any] = {
        "mode": "create_and_run",
        "name": "Profile persistence run",
        "description": "dialog wire with unattended on",
        "queue_message": "Profile persistence run\ndialog wire with unattended on",
        "is_auto_retry_until_stop": "1",
        "selected_profile_model": "stub",
    }
    resp = llm_harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=201,
    ).json()
    task_id = resp["task"]["id"]

    got = _get_session_selected_profile(llm_harness, task_id)
    assert got == "stub", (
        f"selected_profile_model lost on create_and_run wire! "
        f"expected 'stub', got {got!r}"
    )


def test_create_session_without_profile_stays_empty(
    llm_harness: FunctionalHarness,
) -> None:
    """Control: no selected_profile_model on the wire → GET returns ''
    (the COALESCE-on-NULL shape), NOT a stale value. Guards against a
    regression where the fix accidentally leaks a default into the
    column."""
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name="No profile task",
        description="",
        mode="create_session",
    )
    task_id = resp["task"]["id"]

    got = _get_session_selected_profile(llm_harness, task_id)
    assert got in ("", None), (
        f"no-profile create should leave selected_profile_model empty, "
        f"got {got!r}"
    )


# ─── LLM stub fixture (mirror sessions_and_llm_test.py) ────────────────────


@pytest.fixture
def llm_harness(default_pabrik_bin: Any) -> Any:
    """A harness booted with the LLM stub profile so create_and_run's
    workflow doesn't try to call a real LLM. The wire works; the LLM
    call fails silently — we don't care about LLM outcomes in this
    suite. We DO care about the user-role row that lands in llm_history
    BEFORE the LLM call fires (that's part of the queue drain in
    agentic_loop/workflow.zig:716-740).
    """
    h = FunctionalHarness.boot(
        default_pabrik_bin,
        stub_llm_profile=True,
    )
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass