"""The question this suite exists to answer, asked before any Kotlin is written.

Every later scenario assumes one thing: that rows written straight into the
harness instance's ``agent.db`` are visible to a client talking to that
instance over HTTP while it runs with auth **off**. That assumption is not
obvious — the sessions/messages queries carry a per-owner visibility clause
(``src/http_handlers/auth_common.zig`` ``ownerVisibilityClause``), and seeded
rows have a NULL ``user_id``.

The clause reads

    (? = 'user_system' OR s.user_id IS NULL OR s.user_id = ''
     OR s.user_id = 'user_system' OR s.user_id = ?)

and the comment above it says the system user sees everything, because with
``--auth`` off there is no identity and the system user *is* the installation.
So the scope is a no-op and a NULL owner is visible. The suite's whole
architecture rests on that, so it gets asserted over the wire here rather than
argued from a comment — a subtle change to that clause would otherwise show up
as ten unexplained instrumented failures on a device, which is the most
expensive possible place to discover it.

The assertions below are deliberately shape-independent (ids and text present in
the payload) plus one shape assertion pinned against the envelope the Kotlin
reads. If the server changes the envelope, this fails here — in a two-second
Python test — instead of on the phone.
"""

from __future__ import annotations

import json

from db_seed import DbSeed
from harness import FunctionalHarness

#: Spelled out, not imported from the Kotlin, because the point of a contract is
#: to fail when one side moves and the other does not. ``FunctionalScenario``
#: holds the same constant for the instrumented side; ``drift_test.py`` asserts
#: the two sets agree.
PROBE_SESSION = "sess_fn_wire_probe"

USER_TEXT = "hi there from the harness"
ASSISTANT_TEXT = "hello! this reply came out of the database"

#: ``ChatApi.MESSAGES_PAGE_LIMIT`` + ``ChatApi.messagesPath``. Mirrored rather
#: than imported: this file exists to notice when that path moves.
MESSAGES_LIMIT = 1000


def _seed_probe_session(seed_db_path, session_id: str) -> tuple[str, str]:
    """Write one user row and one assistant row; return their ids."""
    seed = DbSeed(seed_db_path)
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Wire probe")
        user_id = seed.seed_user_message(conn, session_id, USER_TEXT)
        assistant_id = seed.seed_assistant_message(conn, session_id, ASSISTANT_TEXT)
    return user_id, assistant_id


def test_auth_off_boot_reports_anonymous(android_harness: FunctionalHarness) -> None:
    """A harness-booted nalar must run open, or the app shows a login screen.

    The app maps this exact envelope to ``SessionPhase.Authenticated`` with a
    null ``userId`` (``auth/AuthViewModel.kt`` -> ``AuthResult.AuthDisabled``),
    which is why no scenario here has to sign in. If this ever flips to 401, it
    is the app-side symptom that shows up first — so pin it at the source.
    """
    response = android_harness.http("GET", "/api/auth/me")

    assert response.status == 200, response.body[:400]
    body = response.json()
    assert body["authenticated"] is False
    assert body["auth_enabled"] is False


def test_seeded_rows_are_visible_over_the_apps_own_wire(
    android_harness: FunctionalHarness, seed_db
) -> None:
    """The load-bearing assumption of the whole suite.

    Seeds directly into the harness's ``agent.db`` and reads the rows back over
    the same request the chat screen makes on open
    (``GET /api/llm/session/{id}/messages?limit=1000&sort_by=id&direction=asc``).
    If the owner-scope clause ever stops being a no-op for an anonymous server,
    or the seeded columns stop matching the schema the endpoint reads, this is
    where it surfaces.
    """
    user_id, assistant_id = _seed_probe_session(seed_db, PROBE_SESSION)

    response = android_harness.http(
        "GET",
        f"/api/llm/session/{PROBE_SESSION}/messages",
        params={"limit": MESSAGES_LIMIT, "sort_by": "id", "direction": "asc"},
    )

    assert response.status == 200, response.body[:400]
    raw = response.body.decode("utf-8")

    # Shape-independent: both rows made it through the owner scope, with their
    # text intact. Asserting on the raw body means a renamed envelope key still
    # fails loudly here rather than silently returning an empty list.
    assert user_id in raw, f"seeded user row {user_id} missing from the response"
    assert assistant_id in raw, (
        f"seeded assistant row {assistant_id} missing from the response"
    )
    assert USER_TEXT in raw
    assert ASSISTANT_TEXT in raw

    # Shape: pinned against a measured response, not against a guess. The API is
    # a projection of the table, not a dump of it — the text column arrives as
    # `content` (never `response_content`), the pagination count as `total`, and
    # `created_at_nano` is not emitted at all. That last one is exactly why the
    # phone orders by `id`; see `ChatApi.messagesPath` for its own reasoning.
    body = json.loads(raw)
    assert isinstance(body, dict), type(body)
    assert "messages" in body, sorted(body)
    rows = body["messages"]
    assert isinstance(rows, list), type(rows)

    ids = [row.get("id") for row in rows]
    assert ids == [user_id, assistant_id], (
        "expected exactly the two seeded rows, in insertion order; got "
        f"{ids!r}. An extra row means the harness reused a database; a wrong "
        "order means seeded ids are no longer chronologically ordered, and the "
        "phone sorts by id."
    )
    # The property the phone actually depends on: seeded ids ascend, so
    # `ORDER BY id` is a chronological order for seeded rows too.
    assert ids == sorted(ids), ids

    assert body["total"] == 2
    assert body["has_more"] is False
    assert not body["next_cursor"], body["next_cursor"]

    by_id = {row["id"]: row for row in rows}
    assert by_id[user_id]["role"] == "user"
    assert by_id[assistant_id]["role"] == "assistant"
    assert by_id[user_id]["is_input"] is True
    assert by_id[assistant_id]["is_output"] is True
    assert by_id[user_id]["content"] == USER_TEXT
    assert by_id[assistant_id]["content"] == ASSISTANT_TEXT


def test_recents_needs_a_workspace(android_harness: FunctionalHarness, seed_db) -> None:
    """Reconnaissance for the sidebar scenario, which is deliberately not built.

    The drawer's list is scoped: ``RecentsApi.chatsPath`` always sends a
    ``workspace_id``, and the server fails **closed** on an empty or unknown id.
    A seeded session therefore does not put a row in the drawer on its own.

    This records what the endpoint actually returns for a seeded session with no
    workspace, so the follow-up that adds the sidebar scenario starts from a
    measurement rather than a guess. It asserts only the fail-closed contract,
    which is the part the Kotlin already depends on.
    """
    _seed_probe_session(seed_db, PROBE_SESSION)

    response = android_harness.http(
        "GET",
        "/api/session",
        params={
            "sort_by": "updated_at",
            "direction": "desc",
            "limit": 30,
            "workspace_id": "",
        },
    )

    assert response.status == 200, response.body[:400]
    body = response.json()
    rows = body.get("sessions", body.get("messages", []))
    assert rows == [], (
        "an empty workspace_id must fail closed to an empty list, never leak "
        f"another workspace's sessions; got {len(rows)} rows"
    )
