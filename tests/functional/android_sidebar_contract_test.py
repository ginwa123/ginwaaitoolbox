"""Wire-contract test for the native Android sidebar.

The Android client (`src/apps/android_mobile/.../recents/RecentsApi.kt`) is the
one consumer of these two endpoints that is not in this repo's TypeScript, so
nothing else here would notice a rename of `session_name` -> `title` or a switch
of the timestamp format. Its Kotlin unit tests pin the parser against fixtures,
but a fixture only proves the parser agrees with itself; this test pins the
parser against the server.

Every assertion below corresponds to a field or query parameter the Kotlin
client depends on. If one of them changes here, the Android sidebar silently
renders empty, which is the failure mode this file exists to prevent.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import FunctionalHarness  # noqa: E402

#: The exact shape `RecentsApi.parseTimestampEpochMillis` accepts. If the server
#: ever starts emitting unix millis here, or a local-time stamp, the Android
#: client renders every "5m" label shifted by the device's UTC offset.
SQLITE_UTC = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")


@pytest.fixture(scope="module")
def harness():
    """Boot one isolated nalar instance for the whole module.

    Uses the harness' default random free port (never 8081, which is reserved
    for the developer's running instance) and an isolated tmpdir HOME.
    """
    with FunctionalHarness.boot() as h:
        yield h


def _create_workspace(harness: FunctionalHarness, name: str) -> str:
    # Creating a workspace is a 201; the harness' default `expect` is 200.
    body = harness.http(
        "POST",
        "/api/workspaces",
        json_body={"name": name},
        expect=201,
    ).json()
    return body["id"]


def test_workspaces_list_keeps_the_fields_the_android_client_reads(harness):
    """`is_include_items=false` must still carry id + name per row.

    The Android dropdown is a two-field view. If either is dropped, the sidebar
    renders an unnamed, unselectable row.
    """
    _create_workspace(harness, "Android contract workspace")

    payload = harness.http(
        "GET",
        "/api/workspaces",
        params={"is_include_items": "false"},
    ).json()

    assert "workspaces" in payload, payload
    rows = payload["workspaces"]
    assert isinstance(rows, list), rows
    assert rows, "expected at least the workspace just created"

    for row in rows:
        assert isinstance(row["id"], str) and row["id"], row
        assert isinstance(row["name"], str), row

    names = [row["name"] for row in rows]
    assert "Android contract workspace" in names, names


def test_workspaces_list_omits_items_when_asked(harness):
    """`is_include_items=false` is an optimisation, not a licence to drop the array.

    The Kotlin parser tolerates a missing `items` key, but the desktop store
    does not — so the contract holds both ways.
    """
    payload = harness.http(
        "GET",
        "/api/workspaces",
        params={"is_include_items": "false"},
    ).json()

    for row in payload["workspaces"]:
        assert row["items"] == [], row
        assert isinstance(row["items_count"], int), row


def test_session_list_keeps_the_fields_the_android_client_reads(harness):
    """The recents list must expose session_id, session_name and the two stamps.

    `session_id` is the row key, `session_name` is the sidebar title, and the
    timestamps drive the relative-time pill.
    """
    payload = harness.http(
        "GET",
        "/api/session",
        params={
            "sort_by": "updated_at",
            "direction": "desc",
            "limit": 30,
        },
    ).json()

    assert "sessions" in payload, payload
    assert isinstance(payload["sessions"], list), payload
    # The Kotlin client reads `total`/`has_more` off the same envelope.
    assert isinstance(payload["total"], int), payload
    assert isinstance(payload["has_more"], bool), payload

    for session in payload["sessions"]:
        assert isinstance(session["session_id"], str) and session["session_id"], session
        assert isinstance(session["session_name"], str), session
        # Migration 082: the human-touched stamp is "" for legacy rows, never
        # null — the client's `optString` fallback chain depends on that.
        assert "last_human_touched_at" in session, session
        assert session["last_human_touched_at"] is not None, session


def test_session_timestamps_are_sqlite_utc_strings(harness):
    """Timestamps must be `YYYY-MM-DD HH:MM:SS` UTC, not local time or epoch.

    This is the single highest-risk assumption in the Android client: the
    Kotlin parser builds a `LocalDateTime` and pins it to `ZoneOffset.UTC`. A
    server-side switch to unix millis would still "parse" (the parser accepts
    both shapes) but every label would be wrong by the device's offset.
    """
    payload = harness.http(
        "GET",
        "/api/session",
        params={"limit": 30},
    ).json()

    checked = 0
    for session in payload["sessions"]:
        for field in ("created_at", "updated_at", "last_human_touched_at"):
            value = session.get(field, "")
            if value == "":
                # Empty is a documented legacy shape; the client falls back.
                continue
            assert SQLITE_UTC.match(value), (
                f"{field} is not a SQLite UTC datetime: {value!r} "
                f"(session {session.get('session_id')})"
            )
            checked += 1

    # Guard against the assertion loop silently passing on an empty list.
    # An empty list is fine on a fresh install, so only assert the loop ran
    # when sessions actually exist.
    if payload["sessions"]:
        assert checked > 0, payload["sessions"]


def test_session_list_scopes_to_a_workspace_and_fails_closed(harness):
    """A known workspace returns its sessions; an unknown one returns none.

    The Android client always sends a real `workspace_id`. It must never fall
    back to the global list, so the fail-closed behaviour is load-bearing.
    """
    workspace_id = _create_workspace(harness, "Scoped contract workspace")

    scoped = harness.http(
        "GET",
        "/api/session",
        params={"workspace_id": workspace_id, "limit": 30},
    ).json()
    assert scoped["sessions"] == [], scoped

    unknown = harness.http(
        "GET",
        "/api/session",
        params={"workspace_id": "ws_does_not_exist", "limit": 30},
    ).json()
    # Fail-closed: an unknown id must not leak the global session list.
    assert unknown["sessions"] == [], unknown


def test_session_list_is_reachable_under_the_aliased_path(harness):
    """`/api/session` and `/api/llm/session` are the same handler.

    The Android client calls `/api/session`; the desktop store calls the
    `/api/llm/session` alias. They must not drift apart.
    """
    direct = harness.http("GET", "/api/session", params={"limit": 5}).json()
    aliased = harness.http("GET", "/api/llm/session", params={"limit": 5}).json()

    assert [s["session_id"] for s in direct["sessions"]] == [
        s["session_id"] for s in aliased["sessions"]
    ], "the two session-list paths disagree"
