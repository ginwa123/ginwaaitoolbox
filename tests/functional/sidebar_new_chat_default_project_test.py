"""Functional tests for the per-workspace default project and the New Chat flow.

Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md
Task: task_1790528102260_4

The invariant under test is:

    Every workspace has a default project. If we look for one and don't find
    it, we create it before doing anything else.

The default is a ``workspace_items`` row of ``item_type='agent'`` whose
``path`` is the server user's home directory, and it is where the "New Chat"
action in the desktop sidebar and the Android drawer creates its chat.

Why a functional test and not a unit test
-----------------------------------------
Because the whole feature is defined by *where the home directory lands*.
``harness.py`` boots the binary with ``HOME`` pointed at an isolated tmpdir,
which is the only way to assert two things that no unit test can reach:

  * the default project's ``path`` really is that HOME, and
  * a chat created inside it really resolves its cwd to that HOME and NOT to
    a ``/tmp`` sandbox — which is the silent failure mode, because
    ``session_create.zig`` falls back to ``createSandbox`` whenever the path
    chain comes up empty, and the agent would then run somewhere the user
    never asked for.

The second test that cannot be a unit test is the orphan guard: the items
list *writes*, so an unknown workspace id must create nothing. See
``test_reading_an_unknown_workspace_creates_nothing``.
"""

from __future__ import annotations

from harness import FunctionalHarness


def _create_workspace(harness: FunctionalHarness, name: str = "default-ws") -> str:
    return harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _items(harness: FunctionalHarness, ws_id: str) -> list[dict]:
    return harness.http("GET", f"/api/workspaces/{ws_id}/items", expect=200).json()["items"]


def _defaults(harness: FunctionalHarness, ws_id: str) -> list[dict]:
    return [item for item in _items(harness, ws_id) if item.get("is_default") == 1]


# ---------------------------------------------------------------------------
# The invariant
# ---------------------------------------------------------------------------


def test_a_new_workspace_already_has_a_default_project(harness: FunctionalHarness) -> None:
    """POST /api/workspaces creates the default eagerly.

    Not required for the invariant (the list read would heal it) but it is what
    makes the Projects section show the default on first paint instead of only
    after a refetch.
    """
    ws_id = _create_workspace(harness)

    defaults = _defaults(harness, ws_id)
    assert len(defaults) == 1, f"a new workspace must have exactly one default, got {defaults!r}"

    default = defaults[0]
    assert default["item_type"] == "agent", (
        f"the default must be agent mode, got {default['item_type']!r}"
    )
    assert default["path"] == str(harness.temp_dir), (
        f"the default's root must be the server user's home, got {default['path']!r} "
        f"(expected the harness HOME {harness.temp_dir!r})"
    )


def test_the_default_project_endpoint_is_idempotent(harness: FunctionalHarness) -> None:
    """The invariant, asserted over the wire: a miss creates, a hit returns.

    Two calls must yield one row and the same id. The endpoint is the
    cold-start fallback both clients use, so a non-idempotent one would
    duplicate the project every time an app that was open during the upgrade
    clicked New Chat.
    """
    ws_id = _create_workspace(harness)

    first = harness.http("POST", f"/api/workspaces/{ws_id}/default-project", expect=200)
    second = harness.http("POST", f"/api/workspaces/{ws_id}/default-project", expect=200)

    first_id = first.json()["item"]["id"]
    second_id = second.json()["item"]["id"]
    assert first_id == second_id, f"a second call must return the same project: {first_id} != {second_id}"
    assert first.json()["created"] is False, "the default already existed, so created must be false"
    assert second.json()["created"] is False

    defaults = _defaults(harness, ws_id)
    assert len(defaults) == 1, f"still exactly one default after two calls, got {defaults!r}"


def test_reading_the_items_list_heals_a_workspace_with_no_default(
    harness: FunctionalHarness,
) -> None:
    """D12: the LIST read creates the default when the lookup misses.

    This is the enforcement point — both clients already call this endpoint, so
    neither needs a "does the default exist?" branch. A workspace whose default
    was deleted (or which predates Migration 094) must come back with one.
    """
    ws_id = _create_workspace(harness)

    # Delete every item, which removes the default too. The workspace itself
    # stays, so this is exactly the "miss" the invariant has to heal.
    #
    # Note there is deliberately NO read between the deletes and the assertion
    # below: a list read is itself the healing act, so checking the
    # "precondition" with a read would repair the workspace and then assert
    # that the workspace was already healthy. The deletes ARE the miss.
    for item in _items(harness, ws_id):
        harness.http("DELETE", f"/api/workspaces/{ws_id}/items/{item['id']}", expect=200)

    # The plain read — no special endpoint, no query flag — brings it back.
    items = _items(harness, ws_id)
    defaults = [item for item in items if item.get("is_default") == 1]
    assert len(defaults) == 1, f"the list read must heal the workspace, got {items!r}"
    assert defaults[0]["path"] == str(harness.temp_dir), (
        f"the healed default must still be rooted at HOME, got {defaults[0]['path']!r}"
    )


def test_reading_an_unknown_workspace_creates_nothing(harness: FunctionalHarness) -> None:
    """The orphan guard — the one way a write-on-read goes wrong.

    ``useCaseList`` does NOT 404 for an unknown workspace; it returns ``[]``.
    So there was no existence check to lean on, and an ungated ensure would
    create a ``workspace_items`` row for a workspace that never existed — an
    orphan that nothing ever displays and nothing ever cleans up.
    """
    before = harness.http("GET", "/api/workspaces", expect=200).json()
    ghost = "ws_does_not_exist"

    # 200 + [] is preserved on purpose: making this a 404 would be a
    # wire-contract change no caller asked for.
    assert harness.http("GET", f"/api/workspaces/{ghost}/items", expect=200).json()["items"] == []

    # The default-project endpoint, by contrast, IS explicit, so it 404s.
    harness.http("POST", f"/api/workspaces/{ghost}/default-project", expect=404)

    after = harness.http("GET", "/api/workspaces", expect=200).json()
    assert after == before, (
        "reading an unknown workspace must not invent a workspace; "
        f"before={before!r} after={after!r}"
    )


def test_every_item_reports_is_default_so_clients_can_find_it(harness: FunctionalHarness) -> None:
    """Both clients' fast path is a local find over this response.

    The field has to be on EVERY row, not just the default's, or a client
    cannot distinguish "ordinary project" from "a default it has not seen".
    """
    ws_id = _create_workspace(harness)
    harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/agent",
        json_body={"name": "helper", "path": "/tmp/helper"},
        expect=201,
    )

    items = _items(harness, ws_id)
    assert len(items) >= 2, f"expected the default plus the helper, got {items!r}"
    for item in items:
        assert "is_default" in item, f"every item must carry is_default, got {item!r}"
        assert item["is_default"] in (0, 1), f"is_default must be 0 or 1, got {item!r}"
    assert sum(item["is_default"] for item in items) == 1, "exactly one default per workspace"


# ---------------------------------------------------------------------------
# The point of the whole thing: the chat runs in $HOME
# ---------------------------------------------------------------------------


def test_a_chat_in_the_default_project_resolves_its_cwd_to_home(
    harness: FunctionalHarness,
) -> None:
    """A New Chat inside the default project runs with $HOME as its cwd.

    This is the assertion the feature exists for. The fallback chain in
    ``session_create.zig`` is ``task.cwd → workspace_items.path →
    createSandbox(...)``, so a default project stored with an empty or wrong
    ``path`` does not error — it silently puts the agent in a temp sandbox. Only
    a harness with a controlled HOME can tell those apart.
    """
    ws_id = _create_workspace(harness)
    default = _defaults(harness, ws_id)[0]

    # Exactly what the clients send for a New Chat: a name, a type, and no cwd.
    task = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{default['id']}/tasks",
        json_body={"name": "New Chat", "task_type": "standard"},
        expect=201,
    ).json()
    assert task["workspace_item_id"] == default["id"]

    # The session create, with cwd_session deliberately empty so the server has
    # to resolve it from the project's path. Its response body carries only
    # {id, name, status} — no cwd — so the resolved value is read back from the
    # session list, which is where the chat UI reads it too.
    harness.http(
        "POST",
        "/api/llm/session",
        json_body={"session_id": task["id"], "session_name": "New Chat", "cwd_session": ""},
        expect=201,
    )

    # The list keys rows by `session_id` (SessionInfoJson), not `id`.
    sessions = harness.http("GET", "/api/llm/session", expect=200).json()["sessions"]
    mine = next(s for s in sessions if s["session_id"] == task["id"])
    cwd = mine.get("cwd") or ""
    assert cwd == str(harness.temp_dir), (
        f"the chat must run in the server user's home, got {cwd!r} "
        f"(expected {harness.temp_dir!r})"
    )
    # Stated explicitly because it is the failure that looks like success: a
    # sandbox path is a perfectly valid absolute path, so nothing above would
    # complain. `createSandbox` builds
    # <dataDir>/apps/<sanitized session id>, so THAT shape is the marker —
    # not "/tmp", which the harness's own HOME legitimately sits under.
    sandbox_suffix = f".local/share/nalar/data/apps/{task['id']}"
    assert not cwd.endswith(sandbox_suffix), (
        f"the agent fell back to a per-session sandbox instead of HOME: {cwd!r}"
    )


def test_a_corrupted_default_name_is_repaired_over_the_wire(
    harness: FunctionalHarness,
) -> None:
    """A default project whose name was corrupted by the old build heals itself.

    The allocator bug wrote 0xAA poison bytes into the name, which the sidebar
    rendered as ``[ 170, 170, … ]``. Fixing the bug stops new damage, but the
    rows are already in the user's database — so the read path rewrites any name
    that is empty, not valid UTF-8, or full of control characters.

    Corrupting the row directly through SQLite is the only way to reproduce the
    pre-fix state: a clean binary will never write a bad name again.
    """
    import sqlite3
    from pathlib import Path

    ws_id = _create_workspace(harness)
    default = _defaults(harness, ws_id)[0]

    db = list(Path(harness.temp_dir).rglob("agent.db"))
    assert db, "expected an agent.db under the harness HOME"
    con = sqlite3.connect(str(db[0]))
    try:
        con.execute(
            "UPDATE workspace_items SET name = ? WHERE id = ?",
            (b"\xaa" * 8, default["id"]),
        )
        con.commit()

        # A plain list read — the same call the sidebar makes — repairs it.
        items = _items(harness, ws_id)
        healed = next(i for i in items if i["id"] == default["id"])
        assert healed["name"] == "Project Default", (
            f"the corrupted name should have been repaired, got {healed['name']!r}"
        )

        # And the repair is persisted, so it does not churn on every read.
        stored = con.execute(
            "SELECT name FROM workspace_items WHERE id = ?", (default["id"],)
        ).fetchone()[0]
        assert stored == "Project Default", f"the row was not rewritten: {stored!r}"

        # A real name is left alone — the repair must never clobber a rename.
        con.execute(
            "UPDATE workspace_items SET name = 'Renamed by hand' WHERE id = ?",
            (default["id"],),
        )
        con.commit()
        again = next(i for i in _items(harness, ws_id) if i["id"] == default["id"])
        assert again["name"] == "Renamed by hand", (
            f"a user rename must survive the repair, got {again['name']!r}"
        )
    finally:
        con.close()
