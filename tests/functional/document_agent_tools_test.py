"""Functional coverage for the `delete_document` / `search_documents` agent tools.

Neither tool is reachable over HTTP on its own — agent tools are dispatched
by the LLM loop, and there is no endpoint that invokes one by name. So what
this file pins down is everything AROUND the dispatch that a unit test on
the executor cannot see:

  * REGISTRY — `GET /api/agent-tools/registry` must list both tools. That
    endpoint reads `tools_equipped.UNIFIED_TOOL_REGISTRY()`, the same table
    the runtime dispatcher reads, so a missing entry here means the model
    can never call the tool AND the Settings → Tools checklist has no tick
    for it. Two surfaces, one assertion.
  * SEEDED — a freshly created agent item must be seeded with
    `search_documents` and must NOT be seeded with `delete_document`. The
    allowlist rows are written once at creation and never backfilled, so a
    fresh item is the only place the asymmetry is observable, and
    `default_tools.py` is the transcription that has to stay in sync.
  * THE SURROUNDING API still works — documents created through
    `/api/workspaces/:ws/documents` are what `search_documents` reads, and
    deleting one through the HTTP DELETE is the same row `delete_document`
    removes. If this regresses, the search tool is searching nothing.

The tool LOGIC (regex/literal/matching, paging, excerpts, the LIKE
prefilter, cross-workspace refusal) is covered by the Zig tests in
`src/agentic_loop/documents_search.zig` and
`src/agentic_loop/tools_exec_document.zig`, which drive the real executors
against in-memory SQLite. This file covers the wire.

Plan: docs/superpowers/plans/ — task "add another tools name
delete_document and search_documents".
"""

from __future__ import annotations

from default_tools import DEFAULT_AGENT_TOOLS
from harness import FunctionalHarness

DELETE_DOCUMENT = "delete_document"
SEARCH_DOCUMENTS = "search_documents"


def _create_workspace(harness: FunctionalHarness, name: str) -> str:
    return harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _create_agent(harness: FunctionalHarness, ws_id: str, name: str) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/agent",
        json_body={"name": name, "path": "/tmp/doc-tools-agent"},
        expect=201,
    )
    return r.json()["item"]["id"]


def _add_document(harness: FunctionalHarness, ws_id: str, title: str, content: str) -> str:
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/documents",
        json_body={"title": title, "content": content, "format": "markdown"},
        expect=201,
    )
    return r.json()["document"]["id"]


# ─── Registry: the tools exist and are dispatchable ──────────────────────


def test_registry_lists_both_new_document_tools(harness: FunctionalHarness) -> None:
    tools = harness.http("GET", "/api/agent-tools/registry", expect=200).json()["tools"]
    names = {t["name"] for t in tools}

    # Both must be registered. A registry entry is what makes a tool
    # dispatchable AND what puts a checkbox in Settings → Tools — if
    # either is missing the user has no way to reach the tool at all.
    assert SEARCH_DOCUMENTS in names, f"{SEARCH_DOCUMENTS} missing from registry"
    assert DELETE_DOCUMENT in names, f"{DELETE_DOCUMENT} missing from registry"

    by_name = {t["name"]: t for t in tools}

    # A non-empty description is the floor: the registry feeds the
    # `search_tool` catalog too, and an entry with no description is a row
    # the model cannot choose on.
    for name in (SEARCH_DOCUMENTS, DELETE_DOCUMENT):
        assert (by_name[name].get("description") or "").strip(), (
            f"{name} has an empty description — nothing for the model to read"
        )

    # `search_documents` is only useful if the model knows what to DO with a
    # row: the description has to name the tools that consume the id. This
    # is the wire copy of the row the Zig tests read off the schema.
    search_desc = by_name[SEARCH_DOCUMENTS]["description"]
    assert "document_id" in search_desc, (
        f"{SEARCH_DOCUMENTS} must tell the model what a row carries; got {search_desc!r}"
    )
    assert "edit_document" in search_desc, (
        f"{SEARCH_DOCUMENTS} must point at the tool that consumes its id; got {search_desc!r}"
    )

    # `delete_document` must state that it is irreversible AND point at
    # `edit_document` as the reversible alternative — otherwise the model
    # reaches for delete whenever the user says "fix this note".
    delete_desc = by_name[DELETE_DOCUMENT]["description"]
    assert "IRREVERSIBLE" in delete_desc, (
        f"{DELETE_DOCUMENT} must lead with the irreversibility; got {delete_desc!r}"
    )
    assert "edit_document" in delete_desc, (
        f"{DELETE_DOCUMENT} must name the reversible alternative; got {delete_desc!r}"
    )

    # `delete_document` takes exactly one argument. A second knob on an
    # irreversible call is a knob the model can fill in wrongly, and the
    # registry description is where a "just one more option" would first
    # show up.
    assert "force" not in delete_desc.lower(), (
        f"{DELETE_DOCUMENT} grew a confirmation knob; got {delete_desc!r}"
    )


# ─── Seeding: read-only default-on, irreversible default-off ────────────


def test_fresh_agent_is_seeded_with_search_documents_but_not_delete(harness: FunctionalHarness) -> None:
    ws_id = _create_workspace(harness, "doc-tools-ws")
    agent_id = _create_agent(harness, ws_id, "doc-tools-agent")

    tools = harness.http("GET", f"/api/agents/{agent_id}/tools", expect=200).json()["tools"]

    assert SEARCH_DOCUMENTS in tools, (
        f"{SEARCH_DOCUMENTS} should be seeded like add/edit_document; got {tools!r}"
    )
    assert DELETE_DOCUMENT not in tools, (
        f"{DELETE_DOCUMENT} irreversibly deletes the user's documents and must NOT be "
        f"seeded into every new agent; got {tools!r}"
    )
    # The whole seeded set still matches the shared transcription, so this
    # test doubles as the "you forgot default_tools.py" alarm.
    assert tools == DEFAULT_AGENT_TOOLS, (
        f"seeded tool set drifted from default_tools.DEFAULT_AGENT_TOOLS: {tools!r}"
    )


def test_delete_document_can_be_enabled_explicitly(harness: FunctionalHarness) -> None:
    """Registered is not the same as seeded — the user can still tick it.

    `POST /api/agents/:id/tools` validates `tool_name` against
    `UNIFIED_TOOL_REGISTRY` and 400s on anything unknown. So a 201 here is
    two assertions at once: the tool is in the registry, and the opt-in
    persists. The one thing that would be a real regression is
    `delete_document` being unreachable — a user who WANTS the agent to
    clean up notes must be able to ask for it.

    This is also why not seeding it is a choice rather than an omission:
    the same wire that refuses an unknown name accepts this one.
    """
    ws_id = _create_workspace(harness, "doc-tools-optin-ws")
    agent_id = _create_agent(harness, ws_id, "optin-agent")

    before = harness.http("GET", f"/api/agents/{agent_id}/tools", expect=200).json()["tools"]
    assert DELETE_DOCUMENT not in before, "the fresh agent should not start with it"

    # 201, not 400 — a 400 would mean the name is not in the registry.
    harness.http(
        "POST",
        f"/api/agents/{agent_id}/tools",
        json_body={"tool_name": DELETE_DOCUMENT},
        expect=201,
    )

    after = harness.http("GET", f"/api/agents/{agent_id}/tools", expect=200).json()["tools"]
    assert DELETE_DOCUMENT in after, f"opt-in did not persist; got {after!r}"
    # And nothing else moved.
    assert sorted(after) == sorted(DEFAULT_AGENT_TOOLS + [DELETE_DOCUMENT]), (
        f"enabling one tool changed the rest of the set; got {after!r}"
    )

    # Ticking it off again is a clean DELETE, not a 500.
    harness.http(
        "DELETE",
        f"/api/agents/{agent_id}/tools/{DELETE_DOCUMENT}",
        expect=200,
    )
    final = harness.http("GET", f"/api/agents/{agent_id}/tools", expect=200).json()["tools"]
    assert final == DEFAULT_AGENT_TOOLS, f"opt-out drifted the set; got {final!r}"


def test_an_unknown_tool_name_is_still_rejected(harness: FunctionalHarness) -> None:
    """The registry validation is real, not a rubber stamp.

    Without this, "POST returned 201" in the test above would prove
    nothing — an endpoint that accepts any string would pass it too.
    """
    ws_id = _create_workspace(harness, "doc-tools-unknown-ws")
    agent_id = _create_agent(harness, ws_id, "unknown-agent")

    harness.http(
        "POST",
        f"/api/agents/{agent_id}/tools",
        json_body={"tool_name": "definitely_not_a_tool_1790"},
        expect=400,
    )


# ─── The documents the search tool reads ────────────────────────────────


def test_documents_crud_round_trip_the_search_tool_reads(harness: FunctionalHarness) -> None:
    """`search_documents` reads the `documents` table; prove it is populated.

    A tool whose backing rows the REST surface cannot create would be a
    tool that can only ever find documents some other code path made — and
    nothing in the build would say so.
    """
    ws_id = _create_workspace(harness, "doc-tools-crud-ws")

    doc_id = _add_document(harness, ws_id, "Release plan v2", "# Release plan\n\n- ship 095\n")
    assert doc_id.startswith("doc_"), f"unexpected document id shape: {doc_id!r}"

    listed = harness.http("GET", f"/api/workspaces/{ws_id}/documents", expect=200).json()["documents"]
    assert [d["id"] for d in listed] == [doc_id]
    assert listed[0]["title"] == "Release plan v2"

    fetched = harness.http("GET", f"/api/workspaces/{ws_id}/documents/{doc_id}", expect=200).json()["document"]
    assert fetched["content"] == "# Release plan\n\n- ship 095\n"

    # A second document with the same title in a DIFFERENT workspace must
    # not appear in the first workspace's list — the same `workspace_id`
    # guard `search_documents` relies on, exercised over the wire.
    other_ws = _create_workspace(harness, "doc-tools-crud-other")
    _add_document(harness, other_ws, "Release plan v2", "not yours")
    mine = harness.http("GET", f"/api/workspaces/{ws_id}/documents", expect=200).json()["documents"]
    assert [d["id"] for d in mine] == [doc_id], "another workspace's document leaked into the list"

    harness.http("DELETE", f"/api/workspaces/{ws_id}/documents/{doc_id}", expect=200)
    after = harness.http("GET", f"/api/workspaces/{ws_id}/documents", expect=200).json()["documents"]
    assert after == [], f"delete left the row behind: {after!r}"

    # A deleted document is gone for the tools too — 404, not a 200 with
    # an empty body, so `delete_document`'s "already gone" case and this
    # one agree.
    harness.http(
        "GET",
        f"/api/workspaces/{ws_id}/documents/{doc_id}",
        expect=(404,),
    )


def test_documents_body_empty_round_trips_as_empty_string(harness: FunctionalHarness) -> None:
    """`search_documents` has to match an empty body without erroring.

    `SqliteBackend.exec` binds a zero-length slice as SQL NULL, so an
    empty body is the one input that has historically broken writes. A
    document with an empty body must land as "" — a NULL would make the
    search engine read a null haystack, and the unit tests do not catch
    it because they insert through the same store the tool does.
    """
    ws_id = _create_workspace(harness, "doc-tools-empty-ws")
    doc_id = _add_document(harness, ws_id, "Heading only", "")

    fetched = harness.http("GET", f"/api/workspaces/{ws_id}/documents/{doc_id}", expect=200).json()["document"]
    assert fetched["content"] == "", f"empty body did not round-trip as \"\": {fetched['content']!r}"