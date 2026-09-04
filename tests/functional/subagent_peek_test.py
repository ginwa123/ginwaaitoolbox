"""Functional wire tests for sub-agent peek fetches.

Task: task_1788551671819_5 (sub-agent peek always empty).

The bug: clicking the eye icon always showed `No messages yet.`, even
after the sub-agent finished. Root causes fixed on branch
`worktree/fix-subagent-peek-realtime`:

  P0 backend: child sid embedded the raw agent name
       (`subagent_{ns}_backend implementer`) — raw spaces break the HTTP
       request line, `/` breaks router segment matching even when
       encoded (http_parser decodes %2F before matchPathWithParams
       splits). Fixed by slugifying at spawn (spaces->'_', rest dropped).
  P0 frontend: peek fetched with the raw sid (no encodeURIComponent).
       Fixed in useSubAgentPeek + api.getChatHistory.

These tests replay the wire round-trip against a real binary (no LLM
needed — the populated-sub-agent path is covered by zig unit tests for
slugify + vitest for encode/refetch):

  1. unknown subagent-style sid → 200 `{ messages: [] }` (peek renders
     the empty state gracefully, never a 404 crash).
  2. percent-encoded sid (`%5F` for `_`) resolves to the same session
     (http_parser decodes the path before router matching — the decode
     half of the P0 transport fix).
  3. `%2F` (encoded slash) does NOT match a session route (decodes to
     `/` before segment split → no match → 404). This pins WHY the
     backend must slugify slashes away at spawn: no encoding can carry
     a `/` through this router.
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


def _create_session(harness: FunctionalHarness) -> str:
    r = harness.http("POST", "/api/llm/session", json_body={"name": "peek-probe"}, expect=201)
    return r.json()["id"]


def test_peek_unknown_subagent_sid_returns_empty_200(harness: FunctionalHarness):
    """The eye panel fetches `GET .../messages` for the child sid. A sid
    with no rows (wrong id, pre-first-row live open) must be 200 empty,
    not an error — the panel shows `No messages yet.` + live SSE."""
    body = harness.http(
        "GET", "/api/llm/session/subagent_1_never_existed/messages?limit=100", expect=200
    ).json()
    assert body["messages"] == [], f"got: {body!r}"


def test_peek_percent_encoded_sid_decodes_to_same_session(harness: FunctionalHarness):
    """`%5F` (`_`) in the path must decode before router matching, so the
    frontend's new `encodeURIComponent(sid)` fetch hits the same rows as
    the raw fetch. Session ids contain `_`, giving us a decode probe
    without needing a space in the id."""
    session_id = _create_session(harness)
    assert "_" in session_id, f"expected '_' in generated id, got: {session_id!r}"

    plain = harness.http(
        "GET", f"/api/llm/session/{session_id}/messages?limit=10", expect=200
    ).json()
    encoded_id = session_id.replace("_", "%5F")
    assert encoded_id != session_id
    decoded = harness.http(
        "GET", f"/api/llm/session/{encoded_id}/messages?limit=10", expect=200
    ).json()
    assert decoded["messages"] == plain["messages"]
    assert decoded.get("has_more", False) == plain.get("has_more", False)


def test_peek_encoded_slash_does_not_match_session_route(harness: FunctionalHarness):
    """`%2F` decodes to `/` BEFORE the router splits on `/`, so the path
    gains a segment and matches no route → 404. This is the invariant
    that forces slugify-at-spawn (P0): a sid containing `/` can never be
    fetched, however the frontend encodes it."""
    session_id = _create_session(harness)
    bad_id = session_id.replace("_", "%2F", 1)
    assert bad_id != session_id
    harness.http("GET", f"/api/llm/session/{bad_id}/messages?limit=10", expect=404)
