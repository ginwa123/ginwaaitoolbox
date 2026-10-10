r"""Functional tests for the skills WRITE surface: POST (insert) and PATCH (update).

The read/delete surface is covered by ``skills_sqlite_test.zig``. This file
exists because a write route has failure modes a unit test cannot see, and
all three of them are about the WIRE rather than the logic:

1. **Route-order shadowing.** ``matchRoute`` walks routes in registration
   order and returns on the first hit, so a ``:skill_name`` route registered
   BEFORE the collection route answers ``POST /skills`` with the detail
   handler — which reads a body it does not have and 404s. Every assertion
   below would pass against the wrong handler if the order were wrong,
   because the wrong handler also answers *something*.
2. **Empty-slice-as-NULL.** ``SqliteBackend.exec`` binds ``""`` as SQL NULL,
   which ``skills.description NOT NULL`` rejects. A create that sends
   ``description: ""`` — the exact body the UI sends when the user fills
   only the name — must round-trip as ``""``, not 500.
3. **A patch that mentions one field must not blank the other.** The store
   loads the current row first, but only the wire proves the handler
   actually forwards both fields.

So these are real HTTP round-trips against a booted binary, replaying the
EXACT JSON the frontend sends.

WHY PYTHON AND NOT ZIG: ``zig build functional-test:zig`` is not a step any
CI workflow runs — ``ci-functional.yml`` invokes
``zig build functional-test-all``, which is pytest over
``tests/functional/`` and ``tests/functional_ui/``. A ``*_test.zig`` file
registered in ``tests/functional/root.zig`` is therefore reachable only by
a developer who types the step by hand. The Zig twin
(``skills_write_test.zig``) exists and is kept in sync; this file is the
one that actually gates the branch.
"""

from __future__ import annotations

import pytest

# The body asserted BYTE-EXACT after a create and after a patch.
# Frontmatter included: `skill_eval` identities are sha256(body), so a
# handler that trimmed the `---` block would stale every cached verdict.
BODY = "---\nname: pdf\ndescription: Work with PDFs.\n---\n\nRun `scripts/convert.py`.\n"

pytestmark = pytest.mark.functional


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _create_workspace(harness, name: str) -> str:
    """POST /api/workspaces -> the new workspace's id."""
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    ws_id = r.json().get("id")
    assert ws_id, f"workspace create returned no id: {r.body!r}"
    return ws_id


def _create_skill(harness, ws: str, name: str, description: str, content: str, expect: int = 201):
    """POST /api/workspaces/<ws>/skills with the exact body the form sends."""
    return harness.http(
        "POST",
        f"/api/workspaces/{ws}/skills",
        json_body={"name": name, "description": description, "content": content},
        expect=expect,
    )


def _patch_skill(harness, ws: str, name: str, description: str, content: str, expect: int = 200):
    """PATCH with BOTH fields, always — the edit form never sends one alone."""
    return harness.http(
        "PATCH",
        f"/api/workspaces/{ws}/skills/{name}",
        json_body={"description": description, "content": content},
        expect=expect,
    )


def _detail(harness, ws: str, name: str):
    return harness.http("GET", f"/api/workspaces/{ws}/skills/{name}", expect=(404, 200))


def _list(harness, ws: str):
    return harness.http("GET", f"/api/workspaces/{ws}/skills", expect=200)


# --------------------------------------------------------------------------
# create
# --------------------------------------------------------------------------


def test_create_inserts_a_skill_and_returns_the_stored_row(harness):
    """201 + the stored row, and the next read agrees."""
    ws = _create_workspace(harness, "skills-create")

    r = _create_skill(harness, ws, "pdf", "Work with PDFs.", BODY)
    skill = r.json()["skill"]
    assert skill["name"] == "pdf"
    assert skill["description"] == "Work with PDFs."
    # BYTE-EXACT, frontmatter included.
    assert skill["content"] == BODY
    # This route writes the body only; a bundle's companions arrive through
    # the importer. Claiming otherwise would render a "0 bundled files" row.
    assert skill["asset_count"] == 0

    again = _detail(harness, ws, "pdf").json()["skill"]
    assert again["content"] == BODY


def test_create_with_an_empty_description_round_trips_as_empty_not_a_500(harness):
    """The empty-slice-as-NULL trap, on the wire.

    ``SqliteBackend.exec`` binds ``""`` as SQL NULL and
    ``skills.description`` is NOT NULL. The UI sends exactly this body when
    the user fills only the name, so a handler without the guard answers
    500 for a blank form field.
    """
    ws = _create_workspace(harness, "skills-empty-desc")

    r = _create_skill(harness, ws, "half-written", "", BODY)
    skill = r.json()["skill"]
    # `""`, not `null` and not a missing key: a null would render a blank
    # list row indistinguishable from a bug.
    assert skill["description"] == ""
    assert skill["content"] == BODY


def test_create_of_a_duplicate_name_is_409_and_does_not_overwrite(harness):
    """`upsertSkill` is create-or-replace BY DESIGN, so the refusal lives here."""
    ws = _create_workspace(harness, "skills-dupe")
    _create_skill(harness, ws, "pdf", "first", "first body")

    r = _create_skill(harness, ws, "pdf", "second", "second body", expect=409)
    # The message names the skill, so the UI can say which row to change.
    assert r.json()["error"] == "a skill named 'pdf' already exists in this workspace"

    # The duplicate must not have half-applied.
    assert _detail(harness, ws, "pdf").json()["skill"]["content"] == "first body"


def test_create_of_a_name_that_exists_in_another_workspace_succeeds(harness):
    """A foreign name must NOT be a conflict — a 409 would confirm it exists."""
    ws_a = _create_workspace(harness, "skills-scope-a")
    ws_b = _create_workspace(harness, "skills-scope-b")
    _create_skill(harness, ws_a, "pdf", "A's copy", "A's body")

    r = _create_skill(harness, ws_b, "pdf", "B's copy", "B's body")
    assert r.json()["skill"]["content"] == "B's body"

    # And A's copy is untouched.
    assert _detail(harness, ws_a, "pdf").json()["skill"]["content"] == "A's body"


@pytest.mark.parametrize("bad", ["..", "a/b", "has space", ".hidden", "trailing."])
def test_create_of_an_invalid_name_is_400_and_writes_nothing(harness, bad):
    """`name` is joined onto a materialisation directory by `use_skill`."""
    ws = _create_workspace(harness, "skills-bad-name")

    r = _create_skill(harness, ws, bad, "d", "body", expect=400)
    assert r.json()["error"] == (
        "name must be 1-128 characters of letters, digits, dot, dash or underscore"
    )

    assert _list(harness, ws).json()["skills"] == []


def test_create_with_a_blank_name_is_400(harness):
    ws = _create_workspace(harness, "skills-blank-name")
    r = _create_skill(harness, ws, "   ", "d", "body", expect=400)
    assert r.json()["error"] == "name is required"


# --------------------------------------------------------------------------
# update
# --------------------------------------------------------------------------


def test_patch_updates_the_description_and_the_body(harness):
    """The edit form ALWAYS sends both fields, so this also proves the
    handler forwards both: a handler that dropped one would blank it."""
    ws = _create_workspace(harness, "skills-patch")
    _create_skill(harness, ws, "pdf", "old description", "old body")

    r = _patch_skill(harness, ws, "pdf", "new description", "new body")
    skill = r.json()["skill"]
    assert skill["name"] == "pdf"
    assert skill["description"] == "new description"
    assert skill["content"] == "new body"

    # And the next read agrees — the response is not a fabricated echo.
    again = _detail(harness, ws, "pdf").json()["skill"]
    assert again["description"] == "new description"
    assert again["content"] == "new body"


def test_patch_with_an_empty_description_clears_it_rather_than_keeping_it(harness):
    """Why the body fields are `?[]const u8` and not `[]const u8` with a
    default: an omitted field keeps its value, an explicit empty one does not."""
    ws = _create_workspace(harness, "skills-clear-desc")
    _create_skill(harness, ws, "pdf", "a description", "a body")

    skill = _patch_skill(harness, ws, "pdf", "", "a body").json()["skill"]
    assert skill["description"] == ""
    # The body was NOT cleared along with it.
    assert skill["content"] == "a body"


def test_patch_with_no_change_is_409(harness):
    """A 200 here would render a saved-looking pane that saved nothing."""
    ws = _create_workspace(harness, "skills-noop-patch")
    _create_skill(harness, ws, "pdf", "same", "same body")

    r = _patch_skill(harness, ws, "pdf", "same", "same body", expect=409)
    assert r.json()["error"] == "nothing to change — the skill already holds these values"


def test_patch_from_a_foreign_workspace_is_404_and_changes_nothing(harness):
    """A 403 would confirm the name exists, which is the one thing workspace
    scoping exists to withhold."""
    ws_a = _create_workspace(harness, "skills-patch-a")
    ws_b = _create_workspace(harness, "skills-patch-b")
    _create_skill(harness, ws_a, "pdf", "A's copy", "A's body")

    r = _patch_skill(harness, ws_b, "pdf", "stolen", "stolen body", expect=404)
    # The SAME message as a name that does not exist.
    assert r.json()["error"] == "skill not found"

    assert _detail(harness, ws_a, "pdf").json()["skill"]["content"] == "A's body"


def test_patch_of_an_unknown_name_is_404(harness):
    ws = _create_workspace(harness, "skills-patch-unknown")
    r = _patch_skill(harness, ws, "ghost", "d", "body", expect=404)
    assert r.json()["error"] == "skill not found"


def test_patch_that_tries_to_rename_is_404_and_leaves_the_body(harness):
    """The name is the `use_skill({ name })` argument and the `skill_eval`
    identity. A `name` in the body is a CLAIM about which row is being
    addressed, and a claim that does not match gets the same answer as a
    row that is not there."""
    ws = _create_workspace(harness, "skills-rename")
    _create_skill(harness, ws, "pdf", "a description", "the body that must survive")

    # The edit form never sends a `name`, so this body is hand-built: it is
    # what a client that tried to rename would put on the wire.
    harness.http(
        "PATCH",
        f"/api/workspaces/{ws}/skills/pdf",
        json_body={
            "name": "pdf-renamed",
            "description": "a description",
            "content": "never applied",
        },
        expect=404,
    )

    assert _detail(harness, ws, "pdf").json()["skill"]["content"] == "the body that must survive"
    # And the new name was not created alongside it.
    assert _detail(harness, ws, "pdf-renamed").json()["error_message"] == "skill not found"


# --------------------------------------------------------------------------
# the list reflects writes
# --------------------------------------------------------------------------


def test_a_skill_created_over_http_is_visible_to_the_next_list(harness):
    """The old handlers re-read a directory on every request. The table has
    to keep that promise for the HTTP write path too, or the sidebar and
    the model disagree about which skills exist."""
    ws = _create_workspace(harness, "skills-create-then-list")
    assert _list(harness, ws).json()["skills"] == []

    _create_skill(harness, ws, "created-over-http", "Written over the wire.", BODY)

    rows = _list(harness, ws).json()["skills"]
    assert len(rows) == 1
    assert rows[0]["name"] == "created-over-http"
    assert rows[0]["description"] == "Written over the wire."


def test_a_patch_is_visible_to_the_next_list(harness):
    """The description is the list row's second line, so an edit that
    changed it has to show up there or the two halves disagree."""
    ws = _create_workspace(harness, "skills-patch-then-list")
    _create_skill(harness, ws, "pdf", "old description", "body")
    _patch_skill(harness, ws, "pdf", "new description", "body")

    rows = _list(harness, ws).json()["skills"]
    assert len(rows) == 1
    assert rows[0]["description"] == "new description"


# --------------------------------------------------------------------------
# scoping
# --------------------------------------------------------------------------


def test_the_write_routes_are_reachable_only_under_a_workspace(harness):
    """A bare `/api/skills` has no workspace to scope to, which is why it was
    removed. It must keep 404-ing rather than answering with a legacy shape —
    a client pinned to the old shape would otherwise keep working and never
    learn the move happened."""
    ws = _create_workspace(harness, "skills-write-scope")

    harness.http(
        "POST",
        "/api/skills",
        json_body={"name": "pdf", "content": "x"},
        expect=404,
    )
    harness.http(
        "PATCH",
        "/api/skills/pdf",
        json_body={"content": "x"},
        expect=404,
    )

    # The workspace-scoped pair does.
    _create_skill(harness, ws, "scoped", "d", "body")
    _patch_skill(harness, ws, "scoped", "d2", "body2")
