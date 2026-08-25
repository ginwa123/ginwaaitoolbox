"""Functional tests: ``sessions.name`` MUST equal ``workspace_item_tasks.name`` after create.

Regression for the user-reported bug "task name and session name should
same" (task_1787671636395_1). The user opened a kanban board, created
a card with a real title ("settings like on notifi when error not
showup in frontend  also retry ms"), then opened a chatview / sidebar
list and saw the linked session row's ``name`` column holding the
literal task_id (e.g. ``task_1787671269086_0``) instead of the title.

The contract this file pins:

    For every API path that creates a kanban task + linked session,
    the very next ``SELECT sessions.name FROM sessions WHERE id = task_id``
    must return the user-typed task title — never the task_id, never
    ``"New Session"``, never an empty string.

If a future refactor diverges one path from this contract, the
matching test fails. The 2026-08-13 PR #225 fixed three paths but
left gaps in the legacy ``mode='create'``-without-unattended lazy
session-init path; this suite catches both the original regression
and any new gap.

Plan: docs/superpowers/plans/2026-09-02-kanban-task-session-name-bind.md
Task: task_1787671636395_1
"""

from __future__ import annotations

import sqlite3
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create_workspace(harness: FunctionalHarness, name: str = "kanban-namebind-ws") -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(harness: FunctionalHarness, workspace_id: str, name: str = "sprint-namebind") -> str:
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
    description: str = "test description",
    mode: str = "create_session",
    is_auto_retry_until_stop: str | None = None,
    queue_message: str | None = None,
) -> dict[str, Any]:
    """POST /workspaces/:ws/items/:kanban/kanban/tasks with the given mode.

    Mirrors the frontend's `addKanbanTask(mode, payload)` call. The
    `mode` argument matches the three wire values the handler accepts:

      - ``create``         — legacy (no session INSERT; bare-row insert
                             only when ``is_auto_retry_until_stop`` is
                             supplied).
      - ``create_session`` — plain "Create task" button. Inserts a full
                             sessions row (no worker kick-off).
      - ``create_and_run`` — "Create task & run agent" button. Inserts
                             a full sessions row AND starts the worker
                             (requires a non-empty ``queue_message``).

    Returns the parsed response body (``{ task, session? }``).
    """
    body: dict[str, Any] = {
        "mode": mode,
        "name": name,
        "description": description,
    }
    if is_auto_retry_until_stop is not None:
        body["is_auto_retry_until_stop"] = is_auto_retry_until_stop
    if queue_message is not None:
        body["queue_message"] = queue_message
    elif mode == "create_and_run":
        # The handler 400s on empty queue_message for create_and_run
        # (see kanban_tasks_create.zig:127-135). Mirror the frontend's
        # wire shape — frontend concatenates name + "\n\n" + description.
        body["queue_message"] = f"{name}\n\n{description}"
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _create_task_via_generic_endpoint(
    harness: FunctionalHarness,
    workspace_id: str,
    kanban_id: str,
    *,
    name: str,
    description: str = "test description",
    is_auto_retry_until_stop: str | None = None,
) -> dict[str, Any]:
    """POST /workspaces/:ws/items/:item/tasks (the generic endpoint,
    NOT the kanban-scoped one). task_type='standard' is the default.

    This endpoint also creates a kanban task when the parent item is
    a kanban (task_create.zig::useCase auto-assigns to the first
    column at MAX(kanban_position)+1).
    """
    body: dict[str, Any] = {
        "name": name,
        "description": description,
        "task_type": "standard",
    }
    if is_auto_retry_until_stop is not None:
        # TaskCreateRequest's is_auto_retry_until_stop is `?[]const u8`
        # — the handler inserts a bare sessions row (no profile column)
        # when the field is set. This is the unattended-mode flag.
        body["is_auto_retry_until_stop"] = is_auto_retry_until_stop
    r = harness.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks",
        json_body=body,
        expect=201,
    )
    return r.json()


def _read_session_name(harness: FunctionalHarness, session_id: str) -> str | None:
    """Read ``sessions.name`` straight from the SQLite DB.

    Returns ``None`` when no row matches (the session hasn't been
    INSERTed yet — happens for the ``mode='create'``-without-unattended
    lazy path until the user types their first chat message).
    """
    db_path = harness.temp_dir / ".config" / "nalar" / "agent.db"
    conn = sqlite3.connect(str(db_path))
    try:
        row = conn.execute(
            "SELECT name FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
    finally:
        conn.close()
    return row[0] if row else None


def _read_session_name_after(
    harness: FunctionalHarness,
    session_id: str,
    *,
    timeout_s: float = 5.0,
    poll_interval_s: float = 0.05,
) -> str | None:
    """Poll the DB for a sessions row matching ``session_id`` until one
    appears OR ``timeout_s`` elapses.

    Required for the lazy-init path (test 7). The chain is:

        POST /api/llm/session → useCase → di.emit_run_agent (synchronous)
            → insert_worker (scheduled on the Io group, NOT synchronous)
            → returns HTTP response
        (HTTP response arrives BEFORE insert_worker runs)

    So a naïve `_read_session_name` immediately after the POST can
    return ``None`` because the async `insert_worker` task that owns
    the actual `INSERT OR IGNORE INTO sessions` hasn't been scheduled
    yet. Locally the gap is microseconds (passes 5/5); on a slower
    CI runner with different IO scheduling, the gap can stretch past
    the test's read deadline. Polling bridges that without making the
    test's semantics looser (we still verify the row eventually lands
    with the right name — just on a small time budget).

    Returns the row's ``name`` column when present, or ``None`` on
    timeout.
    """
    import time

    deadline = time.monotonic() + timeout_s
    while True:
        got = _read_session_name(harness, session_id)
        if got is not None:
            return got
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_interval_s)


# ─── Test 1: mode='create_session' ─────────────────────────────────────────


def test_create_session_binds_session_name_to_task_name(
    llm_harness: FunctionalHarness,
) -> None:
    """The plain "Create task" button (`mode='create_session'`) must
    insert a sessions row whose ``name`` column equals the user-typed
    task title.

    Pre-fix the binding was missing — sessions.name held ``task_id`` as
    a placeholder. Post-fix (kanban_tasks_create.zig step-5) the bind
    is explicit: ``standard_result.name`` (the task name) for the
    ``(id, name, status, cwd, ...)`` tuple.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    task_title = "Investigate settings notification bug"

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name=task_title,
        mode="create_session",
    )
    task_id = resp["task"]["id"]
    assert resp["session"]["id"] == task_id, (
        f"task.id == session.id contract: task={task_id!r}, session="
        f"{resp['session']['id']!r}"
    )
    assert resp["session"]["status"] == "idle", (
        f"create_session must return status='idle' (no agent), "
        f"got {resp['session']['status']!r}"
    )

    got = _read_session_name(llm_harness, task_id)
    assert got == task_title, (
        f"sessions.name must equal the user-typed task title after "
        f"create_session. Expected {task_title!r}, got {got!r}. If "
        f"the value is the task_id (e.g. 'task_<timestamp>'), the "
        f"INSERT OR IGNORE in kanban_tasks_create.zig step-5 is "
        f"binding the wrong column."
    )


# ─── Test 2: mode='create_and_run' ─────────────────────────────────────────


def test_create_and_run_binds_session_name_to_task_name(
    llm_harness: FunctionalHarness,
) -> None:
    """`mode='create_and_run'` (the "Create task & run agent" button)
    must bind ``sessions.name = task.name`` — same contract as
    create_session, because both paths share kanban_tasks_create.zig's
    step-5 full INSERT.

    The worker may not actually finish (we use the stub-llm-profile
    harness so the LLM call fails silently), but the sessions row
    must be written with the correct name BEFORE the worker starts.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    task_title = "Run agent to investigate X"

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name=task_title,
        mode="create_and_run",
    )
    task_id = resp["task"]["id"]
    assert resp["session"]["status"] == "send", (
        f"create_and_run must return status='send' (worker queued), "
        f"got {resp['session']['status']!r}"
    )

    got = _read_session_name(llm_harness, task_id)
    assert got == task_title, (
        f"sessions.name must equal the user-typed task title after "
        f"create_and_run. Expected {task_title!r}, got {got!r}."
    )


# ─── Test 3: legacy mode='create' WITH unattended flag ──────────────────────


def test_create_legacy_with_unattended_binds_session_name_to_task_name(
    llm_harness: FunctionalHarness,
) -> None:
    """Legacy ``mode='create'`` is preserved for backward compat. When
    the dialog's Unattended toggle is ON, the handler forwards
    ``is_auto_retry_until_stop='1'`` into task_create.zig::useCase,
    which inserts a bare sessions row (no profile column) with
    ``name = task.name``.

    Pinning this contract guards against a regression that drops the
    ``if (is_create_only) parsed.is_auto_retry_until_stop else null``
    ternary at kanban_tasks_create.zig:178 (which is itself a
    defense against a different bug — see task_1787494153778_2).
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    task_title = "Legacy unattended task"

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name=task_title,
        mode="create",
        is_auto_retry_until_stop="1",
    )
    task_id = resp["task"]["id"]
    # Legacy mode returns session=null (the handler doesn't add a
    # session envelope for mode='create').
    assert resp.get("session") is None, (
        f"legacy mode='create' should NOT add a session envelope "
        f"(the row is written by task_create.useCase instead), "
        f"got {resp.get('session')!r}"
    )

    got = _read_session_name(llm_harness, task_id)
    assert got == task_title, (
        f"sessions.name must equal the user-typed task title for "
        f"legacy mode='create' WITH unattended flag. Expected "
        f"{task_title!r}, got {got!r}. If the bind is missing, "
        f"sessions.name holds task_id as a placeholder."
    )


# ─── Test 4: legacy mode='create' WITHOUT unattended flag ───────────────────


def test_create_legacy_without_unattended_creates_no_session_row(
    llm_harness: FunctionalHarness,
) -> None:
    """Legacy ``mode='create'`` with NO unattended flag should leave
    the sessions table untouched. The session row is created LAZILY
    when the user opens the chat and types the first message (via
    POST /api/llm/session, see test 7 below).

    Pinning the "no row yet" state here is important — if a future
    refactor starts inserting unconditionally, the session would be
    created with the wrong name before the user ever opens the chat
    (and the lazy-init path in test 7 would no-op on the PK conflict).
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    task_title = "Title-only legacy task"

    resp = _create_task_via_kanban_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name=task_title,
        mode="create",
        # No is_auto_retry_until_stop — handler forwards null into
        # useCase, so useCase skips its bare sessions INSERT.
        is_auto_retry_until_stop=None,
    )
    task_id = resp["task"]["id"]

    got = _read_session_name(llm_harness, task_id)
    assert got is None, (
        f"legacy mode='create' WITHOUT unattended flag must NOT "
        f"insert a sessions row (it's created lazily by POST "
        f"/api/llm/session). Got sessions.name={got!r} — the row "
        f"exists too early."
    )


# ─── Test 5: generic endpoint WITH unattended flag ──────────────────────────


def test_standard_task_via_generic_endpoint_with_unattended_binds_name(
    llm_harness: FunctionalHarness,
) -> None:
    """The generic POST /workspaces/:ws/items/:item/tasks endpoint
    (NOT the kanban-scoped one) also creates a kanban task when the
    parent is a kanban. With ``is_auto_retry_until_stop='1'`` set,
    task_create.zig::useCase inserts a bare sessions row with
    ``name = task.name`` (task_create.zig:649-650).

    This is the same code path as test 3, exercised via the
    non-kanban-scoped endpoint. Both must bind correctly.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    task_title = "Generic endpoint unattended task"

    resp = _create_task_via_generic_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name=task_title,
        is_auto_retry_until_stop="1",
    )
    task_id = resp["id"]

    got = _read_session_name(llm_harness, task_id)
    assert got == task_title, (
        f"sessions.name must equal the user-typed task title after "
        f"generic /tasks endpoint create WITH unattended. Expected "
        f"{task_title!r}, got {got!r}."
    )


# ─── Test 6: generic endpoint WITHOUT unattended flag ───────────────────────


def test_standard_task_via_generic_endpoint_without_unattended_creates_no_row(
    llm_harness: FunctionalHarness,
) -> None:
    """Generic POST /tasks endpoint WITHOUT unattended flag must leave
    the sessions table untouched (useCase skips its bare INSERT). Same
    rationale as test 4 — the row is created lazily by the chat
    first-message flow (test 7).
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    task_title = "Generic endpoint lazy task"

    resp = _create_task_via_generic_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name=task_title,
        # No is_auto_retry_until_stop.
    )
    task_id = resp["id"]

    got = _read_session_name(llm_harness, task_id)
    assert got is None, (
        f"generic /tasks endpoint WITHOUT unattended must NOT insert "
        f"a sessions row (it's lazy-init by chat flow). Got "
        f"sessions.name={got!r}."
    )


# ─── Test 7: the LAZY-INIT gap — chat first-message must bind the title ────


def test_chat_first_message_after_lazy_create_binds_session_name_to_task_name(
    llm_harness: FunctionalHarness,
) -> None:
    """REGRESSION PIN: when a kanban task is created WITHOUT an
    explicit session INSERT (the legacy mode='create' without
    unattended, OR the generic /tasks endpoint without unattended,
    OR the LLM agent tool create_kanban_task when unattended+profile
    are both unset), the session row is created LAZILY by the
    chatview's first-message POST /api/llm/session call.

    The backend's session_create.zig::useCase receives
    ``parsed.session_name`` (empty when the frontend doesn't send it)
    and falls back to the literal default ``"New Session"`` — that's
    the bug. The expected behaviour: when the resolved session_id
    matches an existing ``workspace_item_tasks`` row, the handler
    should resolve the session name from the task's title so the
    sidebar ChatsList shows the user-typed title, not "New Session".

    Pre-fix the sidebar would show "New Session" for every kanban
    task whose chat the user opened without first creating a session.
    Post-fix (this test pins it) the bind is correct on first POST.
    """
    ws_id = _create_workspace(llm_harness)
    kanban_id = _create_kanban(llm_harness, ws_id)
    task_title = "Lazy-init kanban task"

    # 1. Create the task WITHOUT any session-init fields.
    resp = _create_task_via_generic_endpoint(
        llm_harness,
        ws_id,
        kanban_id,
        name=task_title,
        # No unattended flag — useCase skips the bare sessions INSERT.
    )
    task_id = resp["id"]

    # 2. Sanity: the sessions row doesn't exist yet.
    assert _read_session_name(llm_harness, task_id) is None, (
        "sanity: setup should leave sessions table empty for this task"
    )

    # 3. Send the first chat message — the frontend's ChatView does
    # this via api.sendChatMessage, which POSTs to /api/llm/session
    # with: session_id, queue_message, cwd_session, image_urls,
    # selected_profile_model, is_auto_retry_until_stop. NO session_name
    # field. The backend's session_create.zig::useCase receives an
    # empty session_name and (pre-fix) defaults to "New Session",
    # losing the bind to the task title.
    # The endpoint may 201 on success OR 500 when the stub LLM profile
    # fails to reach a real API. Tolerate both — the worker may fail
    # silently because the harness has no real LLM key, but the wire
    # round-trip still triggers the relevant code path. Critically,
    # the session INSERT happens in the *async* `insert_worker` task
    # scheduled by `di.emit_run_agent`'s Io group; the HTTP response
    # returns BEFORE that task runs. We poll for the row to appear
    # in test step 4 below.
    r = llm_harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": task_id,
            "queue_message": "Hello agent, please help with this task",
            "cwd_session": "",
            "image_urls": "",
            "selected_profile_model": "",
            "is_auto_retry_until_stop": "",
        },
        expect=(201, 500),
    )

    # 4. Poll for the sessions row to appear. The async insert_worker
    # scheduled by di.emit_run_agent may run microseconds (local dev,
    # fast CPU) or hundreds of milliseconds (CI runner, busy host)
    # after the HTTP response returns. A single read with no poll
    # intermittently returned `None` on the CI runner (the original
    # failure CI run 32868582221) — see the `_read_session_name_after`
    # docstring for the full timing rationale.
    got = _read_session_name_after(llm_harness, task_id, timeout_s=5.0)
    assert got is not None, (
        f"chat first-message POST must trigger lazy session-row init "
        f"for task_id={task_id!r}. Got no row within 5s — "
        f"insert_worker's INSERT OR IGNORE was skipped (session_create.zig "
        f"may not have called emit_run_agent) or the async Io group "
        f"task is taking >5s to schedule."
    )
    assert got == task_title, (
        f"sessions.name must equal the user-typed task title after "
        f"chat first-message lazy-init. Expected {task_title!r}, "
        f"got {got!r}.\n"
        f"  - If got is {task_id!r}: session_create.zig is binding "
        f"name=session_id by accident (very wrong).\n"
        f"  - If got is 'New Session': session_create.zig's "
        f"parsed.session_name='' fallback is winning. The fix: when "
        f"session_id matches an existing workspace_item_tasks row, "
        f"look up the task's name and use THAT as the session name."
    )


# ─── llm_harness fixture (boots nalar with stub-llm-profile) ────────────────


@pytest.fixture
def llm_harness(default_nalar_bin: Any) -> Any:
    """A harness booted with the LLM stub profile so create_and_run's
    workflow doesn't try to call a real LLM. The wire works; the LLM
    call fails silently — we don't care about LLM outcomes here, only
    that the sessions row is written with the correct name BEFORE the
    worker starts (or fails).
    """
    h = FunctionalHarness.boot(
        default_nalar_bin,
        stub_llm_profile=True,
    )
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass
