"""Functional wire tests for workspace-scoped secrets (Migration 101).

Plan: docs/superpowers/plans/2026-10-02-workspace-secrets.md — `### Task 7`.

Why these tests exist rather than more Zig unit tests
====================================================
`src/http_handlers/secrets_*.zig` ships a full set of inline `useCase` tests,
and every one of them passes. None of them can see the three failure modes
this feature is actually exposed to:

  1. **Route-order shadowing.** `matchRoute` walks routes in REGISTRATION
     ORDER and returns on the first hit. `main.zig` registers the two
     literal `/secrets` routes before the two `/secrets/:secret_id` routes;
     reverse that and every create lands on the PATCH handler with
     `secret_id` unset. The static byte-offset test in `secrets_list.zig`
     pins the order in `main.zig` AS TEXT — it cannot see a router that
     changed its matching strategy, and it sees no wire at all.

  2. **The empty-slice-binds-as-NULL collapse.** `SqliteBackend.exec` binds
     a zero-length slice as SQL NULL, and `workspace_secrets.value` is
     `NOT NULL`. `createSecret` guards `value.len == 0` before the INSERT so
     the answer is a 400; without that guard the same request is a 500
     "DB error". The unit test calls `useCase` with `value: ""` and gets
     `error.ValueRequired` from the guard it is testing — it can never
     distinguish "the guard fired" from "the guard is unreachable".

  3. **Response-shape drift.** `SecretResponse` has no `value` field, which
     is the whole design (a browser that wrote a credential must not be able
     to read it back). Adding one field to a struct is invisible to every
     `useCase` test in the file. Only the raw bytes on the wire can catch it,
     and only a check on the RAW TEXT catches a stray `"value":` that a
     parsed-JSON key check would walk past.

Template: `agent_knowledge_edit_test.py` (the PR #291 shape — the same three
failure modes, same reason they shipped past green unit tests).

Covered
=======
  * CRUD round-trip, with the plaintext value absent from every body.
  * The write-only guarantee across the whole cycle (the headline).
  * Cross-workspace isolation: B cannot see, rotate or delete A's row, and
    the refusal is 404 — never 403, which would confirm the id exists.
  * `value: ""` is a 400, not a 500 NULL-constraint violation.
  * Duplicate name: 409 in one workspace, 201 in another.
  * Name grammar `[A-Za-z0-9_-]{1,64}`, including both boundaries.
  * Missing `name` / missing `value` on POST.
  * A `name` in a PATCH body is a CLAIM about which row is addressed, not a
    rename.
  * `{{SECRETS:UNKNOWN}}` through the real agentic loop, via a stub LLM that
    serves the tool call: the tool result is an error envelope naming
    `UNKNOWN`, and the target file is never created.

Run:
    NALAR_BIN=<worktree>/zig-out/bin/nalar \
      python -m pytest tests/functional/workspace_secrets_test.py -v

NEVER curl a live server for any of this. `FunctionalHarness` boots a fresh
binary against an isolated tmpdir HOME and tears both down. Port 8081 is
the always-running dev server; `harness.RESERVED_PORTS` skips it.
"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from harness import FunctionalHarness, Response, harness_path

# ─── Canaries ──────────────────────────────────────────────────────────────
#
# Distinctive, JSON-safe (no quoting artefacts), and different from every
# secret NAME used below — a name is not a secret and is echoed by the 409
# conflict message, so reusing one would make a leak indistinguishable from
# a legitimate disclosure.
FIRST_VALUE = "sk_live_CANARY_4f1c9a_Zx7Q_DO_NOT_LEAK"
SECOND_VALUE = "sk_live_CANARY_be02d8_Mm4R_ROTATED_DO_NOT_LEAK"

# What a wire body would look like if the write-only guarantee regressed.
VALUE_KEY_NEEDLES = ('"value"', '"value":', 'value":')


# ─── Helpers ───────────────────────────────────────────────────────────────


def _text(response: Response) -> str:
    """The raw response body as text.

    Every "this must not be in the response" assertion in this module reads
    THIS, not `response.json()`. A parsed-JSON check can only see keys it
    thinks to look for; a raw-text check sees a stray field, a duplicated
    key, and prose that mentions the value in a diagnostic string.
    """
    return response.body.decode("utf-8", errors="replace")


def _assert_value_absent(response: Response, *needles: str) -> None:
    """Fail if any needle appears anywhere in the raw response body."""
    text = _text(response)
    for needle in needles:
        assert needle not in text, (
            f"PLAINTEXT LEAK: {needle!r} appears in the body of the "
            f"{response.status} response.\n--- raw body ---\n{text}"
        )


def _assert_no_value_key(response: Response) -> None:
    """Fail if the response body carries a JSON key named `value` at all."""
    text = _text(response)
    for needle in VALUE_KEY_NEEDLES:
        assert needle not in text, (
            f"RESPONSE-SHAPE LEAK: {needle!r} appears in the body of the "
            f"{response.status} response — SecretResponse must carry "
            f"id/name/created_at/updated_at and nothing else.\n"
            f"--- raw body ---\n{text}"
        )


def _create_workspace(harness: FunctionalHarness, name: str) -> str:
    r = harness.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _secrets_url(workspace_id: str) -> str:
    return f"/api/workspaces/{workspace_id}/secrets"


def _secret_url(workspace_id: str, secret_id: str) -> str:
    return f"/api/workspaces/{workspace_id}/secrets/{secret_id}"


def _create_secret(
    harness: FunctionalHarness,
    workspace_id: str,
    name: str,
    value: str,
    *,
    expect: int = 201,
) -> Response:
    return harness.http(
        "POST",
        _secrets_url(workspace_id),
        json_body={"name": name, "value": value},
        expect=expect,
    )


def _list_secrets(harness: FunctionalHarness, workspace_id: str, expect: int = 200) -> Response:
    return harness.http("GET", _secrets_url(workspace_id), expect=expect)


def _patch_secret(
    harness: FunctionalHarness,
    workspace_id: str,
    secret_id: str,
    body: dict[str, Any],
    expect: int = 200,
) -> Response:
    return harness.http(
        "PATCH", _secret_url(workspace_id, secret_id), json_body=body, expect=expect
    )


def _delete_secret(
    harness: FunctionalHarness,
    workspace_id: str,
    secret_id: str,
    expect: int = 200,
) -> Response:
    return harness.http("DELETE", _secret_url(workspace_id, secret_id), expect=expect)


def _one_named(harness: FunctionalHarness, workspace_id: str, name: str) -> dict[str, Any]:
    """The single list row called `name` — the only way to read a row back."""
    body = _list_secrets(harness, workspace_id).json()
    matches = [s for s in body["secrets"] if s["name"] == name]
    assert len(matches) == 1, (
        f"expected exactly one row named {name!r} in {body['secrets']!r}"
    )
    return matches[0]


def _assert_wire_shape(secret: dict[str, Any]) -> None:
    """`SecretResponse` is exactly {id, name, created_at, updated_at}."""
    assert set(secret.keys()) == {"id", "name", "created_at", "updated_at"}, (
        f"unexpected SecretResponse keys: {sorted(secret.keys())!r}"
    )
    assert secret["id"], "id must be non-empty"
    assert secret["name"], "name must be non-empty"
    assert secret["created_at"], "created_at must be non-empty"
    assert secret["updated_at"], "updated_at must be non-empty"


# ─── 1. Full CRUD round-trip ───────────────────────────────────────────────


def test_full_crud_round_trip(harness: FunctionalHarness) -> None:
    """Create → list → rotate → read back → delete → empty.

    The "read back" step is worth a note. There is NO
    `GET /api/workspaces/:id/secrets/:secret_id` route — the route table has
    four verbs and a single-secret read is not one of them (main.zig
    registers GET on the collection only). So the round-trip's read-back is
    two assertions: the by-id GET is a 404 (which is what makes
    write-only STRUCTURAL rather than a property of one struct definition),
    and the row is still present and unchanged in the collection read.
    """
    ws = _create_workspace(harness, "secrets-crud-ws")

    # ── CREATE ──
    created = _create_secret(harness, ws, "GITHUB_TOKEN", FIRST_VALUE)
    assert created.status == 201
    secret = created.json()["secret"]
    _assert_wire_shape(secret)
    assert secret["name"] == "GITHUB_TOKEN"
    _assert_value_absent(created, FIRST_VALUE)
    _assert_no_value_key(created)
    secret_id = secret["id"]

    # ── LIST ──
    listed = _list_secrets(harness, ws)
    assert listed.json()["count"] == 1
    row = _one_named(harness, ws, "GITHUB_TOKEN")
    _assert_wire_shape(row)
    assert row["id"] == secret_id
    _assert_value_absent(listed, FIRST_VALUE)
    _assert_no_value_key(listed)

    # No single-secret read endpoint exists — 404, and nothing in the body
    # that would stand in for one.
    by_id = harness.http("GET", _secret_url(ws, secret_id), expect=404)
    _assert_value_absent(by_id, FIRST_VALUE)

    # ── ROTATE (PATCH the value) ──
    rotated = _patch_secret(harness, ws, secret_id, {"value": SECOND_VALUE})
    assert rotated.status == 200
    rotated_secret = rotated.json()["secret"]
    _assert_wire_shape(rotated_secret)
    assert rotated_secret["id"] == secret_id
    assert rotated_secret["name"] == "GITHUB_TOKEN", "a rotation must not rename"
    _assert_value_absent(rotated, FIRST_VALUE, SECOND_VALUE)
    _assert_no_value_key(rotated)

    # The row is still the same row after the rotation.
    after = _one_named(harness, ws, "GITHUB_TOKEN")
    assert after["id"] == secret_id
    _assert_no_value_key(_list_secrets(harness, ws))

    # ── DELETE ──
    deleted = _delete_secret(harness, ws, secret_id)
    assert deleted.json() == {"id": secret_id, "success": True}, (
        f"DELETE answer should be {{id, success}}, got {deleted.json()!r}"
    )
    _assert_no_value_key(deleted)

    # ── GONE ──
    empty = _list_secrets(harness, ws)
    assert empty.json()["count"] == 0
    assert empty.json()["secrets"] == []
    _assert_no_value_key(empty)


# ─── 2. The write-only guarantee, end to end (headline) ────────────────────


def test_plaintext_never_appears_in_any_response_across_the_cycle(
    harness: FunctionalHarness,
) -> None:
    """The headline: not one response body in a full lifecycle carries a value.

    A per-test check is not enough. The leak this guards against is
    asymmetric — the read path is the one that would grow a field, and it
    only does so if every read is allowed to be checked separately. This
    test sweeps the CREATE / LIST / ROTATE / ERROR / DELETE cycle and holds
    EVERY response against BOTH values at once, so a leak introduced by any
    one verb fails here.

    Not vacuous: the same `FIRST_VALUE` canary is proven STORED and
    SUBSTITUTABLE by the positive control turn in
    `test_unknown_placeholder_names_the_missing_key_and_dispatches_nothing`,
    which reads it back off disk. So "the value never came back" is a fact
    about the response shapes, not about a value that was silently dropped
    on write.
    """
    ws = _create_workspace(harness, "secrets-writeonly-ws")
    canaries = (FIRST_VALUE, SECOND_VALUE)

    responses: list[Response] = []

    # Happy path.
    created = _create_secret(harness, ws, "STRIPE_KEY", FIRST_VALUE)
    responses.append(created)
    secret_id = created.json()["secret"]["id"]

    responses.append(_list_secrets(harness, ws))
    responses.append(_patch_secret(harness, ws, secret_id, {"value": SECOND_VALUE}))
    responses.append(_list_secrets(harness, ws))

    # A PATCH that rotates nothing (`{}`) — the "keep the stored value" path
    # must not be the one that reads it back to return it.
    responses.append(_patch_secret(harness, ws, secret_id, {}))

    # Every refusal path. Each of these echoes the NAME (which is not a
    # secret) and must echo nothing else.
    responses.append(_create_secret(harness, ws, "STRIPE_KEY", FIRST_VALUE, expect=409))
    responses.append(_create_secret(harness, ws, "", FIRST_VALUE, expect=400))
    responses.append(_create_secret(harness, ws, "has space", FIRST_VALUE, expect=400))
    responses.append(_patch_secret(harness, ws, secret_id, {"value": ""}, expect=400))
    responses.append(
        _patch_secret(harness, ws, secret_id, {"name": "STRIPE_KEY", "value": ""}, expect=400)
    )
    responses.append(_patch_secret(harness, ws, secret_id, {"name": "RENAMED"}, expect=404))

    # Cross-workspace refusals.
    other = _create_workspace(harness, "secrets-writeonly-other-ws")
    responses.append(_list_secrets(harness, other))
    responses.append(_patch_secret(harness, other, secret_id, {"value": FIRST_VALUE}, expect=404))
    responses.append(_delete_secret(harness, other, secret_id, expect=404))

    # Teardown.
    responses.append(_delete_secret(harness, ws, secret_id))
    responses.append(_list_secrets(harness, ws))

    assert len(responses) >= 14, f"the sweep shrank: only {len(responses)} responses"
    for response in responses:
        _assert_value_absent(response, *canaries)

    # The 2xx subset must also carry no `value` KEY at all — a length hint
    # or a masked preview would not contain the plaintext but is still the
    # leak this design refuses. The 4xx bodies are exempt because their
    # prose legitimately contains the word ("value is required").
    for response in responses:
        if 200 <= response.status < 300:
            _assert_no_value_key(response)

    # Sanity: the sweep actually exercised both a rotation and a refusal,
    # so it cannot pass for the wrong reason (e.g. a filter that dropped
    # everything).
    statuses = [r.status for r in responses]
    assert 201 in statuses and 200 in statuses and 409 in statuses and 404 in statuses
    assert FIRST_VALUE != SECOND_VALUE


# ─── 3. Cross-workspace isolation ──────────────────────────────────────────


def test_cross_workspace_isolation_is_404_never_403(harness: FunctionalHarness) -> None:
    """Workspace B must not be able to read, rotate or delete A's row.

    The status is the assertion. A 403 ("forbidden") would CONFIRM the id
    exists, which is precisely the one bit workspace scoping exists to
    withhold: it turns the endpoint into an oracle that enumerates another
    tenant's row ids. So every refusal here must be indistinguishable from
    the answer for an id that never existed — checked by comparing the two
    bodies at the end.
    """
    ws_a = _create_workspace(harness, "secrets-iso-a")
    ws_b = _create_workspace(harness, "secrets-iso-b")

    created = _create_secret(harness, ws_a, "OPENAI_KEY", FIRST_VALUE)
    foreign_id = created.json()["secret"]["id"]

    # ── B lists nothing ──
    b_list = _list_secrets(harness, ws_b)
    assert b_list.json()["count"] == 0, f"B must see no secrets: {b_list.json()!r}"
    assert b_list.json()["secrets"] == []

    # A really does have one — a false negative here would make every other
    # assertion in this test vacuously true.
    assert _list_secrets(harness, ws_a).json()["count"] == 1

    # ── B cannot GET A's row by id (no such route; 404 either way) ──
    b_get = harness.http("GET", _secret_url(ws_b, foreign_id), expect=404)
    _assert_value_absent(b_get, FIRST_VALUE)

    # ── B cannot rotate it ──
    b_patch = _patch_secret(harness, ws_b, foreign_id, {"value": SECOND_VALUE}, expect=404)
    assert b_patch.status != 403, "403 would confirm the id exists"
    _assert_value_absent(b_patch, FIRST_VALUE, SECOND_VALUE)

    # ── B cannot delete it ──
    b_delete = _delete_secret(harness, ws_b, foreign_id, expect=404)
    assert b_delete.status != 403, "403 would confirm the id exists"
    _assert_value_absent(b_delete, FIRST_VALUE)

    # ── A's row survived every attempt, and is still A's ──
    still_there = _one_named(harness, ws_a, "OPENAI_KEY")
    assert still_there["id"] == foreign_id
    assert _list_secrets(harness, ws_b).json()["count"] == 0
    assert _list_secrets(harness, ws_a).json()["count"] == 1

    # Proof by continuation rather than by absence: A can still rotate its
    # own row, which a B-side delete would have made impossible.
    a_rotated = _patch_secret(harness, ws_a, foreign_id, {"value": SECOND_VALUE})
    assert a_rotated.status == 200
    _assert_no_value_key(a_rotated)

    # ── No oracle: a foreign id and a fabricated one answer identically ──
    real_not_found = _patch_secret(harness, ws_b, "sec_definitely_not_real", {"value": "x"}, expect=404)
    made_up_not_found = _patch_secret(harness, ws_b, foreign_id, {"value": "x"}, expect=404)
    assert real_not_found.json() == made_up_not_found.json(), (
        "a foreign id and a fabricated id answer differently, so this "
        f"endpoint can be used to probe another workspace's row ids.\n"
        f"fabricated: {real_not_found.json()!r}\n"
        f"foreign:    {made_up_not_found.json()!r}"
    )

    # Same for DELETE.
    real_del = _delete_secret(harness, ws_b, "sec_definitely_not_real", expect=404)
    made_up_del = _delete_secret(harness, ws_b, foreign_id, expect=404)
    assert real_del.json() == made_up_del.json(), (
        f"fabricated: {real_del.json()!r}\nforeign:    {made_up_del.json()!r}"
    )


# ─── 4. Empty value is a 400, not a 500 ───────────────────────────────────


def test_empty_value_is_400_not_a_500_null_constraint_violation(
    harness: FunctionalHarness,
) -> None:
    """`value: ""` must be refused at the edge.

    This is the SqliteBackend empty-slice trap in its purest form. `exec`
    binds a zero-length slice as SQL NULL, and `value TEXT NOT NULL` rejects
    it — so the unguarded path answers 500 "DB error" for what is really a
    blank form field. The operator sees a server fault and files a bug; the
    fix is to type something. A 400 with a name for the field is the whole
    difference.
    """
    ws = _create_workspace(harness, "secrets-empty-value-ws")

    blank = _create_secret(harness, ws, "BLANK_VALUE", "", expect=400)
    assert blank.status == 400
    assert blank.json().get("error") == "value is required", (
        f"the 400 should name the offending field, got {blank.json()!r}"
    )

    # Nothing was written on the way to the error — a 400 that half-applied
    # would leave a credential that authenticates nothing.
    assert _list_secrets(harness, ws).json()["count"] == 0

    # The rotation path has the same trap and the same answer.
    created = _create_secret(harness, ws, "ROTATING", FIRST_VALUE)
    sid = created.json()["secret"]["id"]
    rotate_blank = _patch_secret(harness, ws, sid, {"value": ""}, expect=400)
    assert rotate_blank.status == 400
    assert rotate_blank.json().get("error") == "value is required"

    # ...and the row is still usable afterwards.
    assert _patch_secret(harness, ws, sid, {"value": SECOND_VALUE}).status == 200
    assert _list_secrets(harness, ws).json()["count"] == 1


# ─── 5. Duplicate name ─────────────────────────────────────────────────────


def test_duplicate_name_is_409_in_one_workspace_201_in_another(
    harness: FunctionalHarness,
) -> None:
    """Names are unique per WORKSPACE, not per database.

    Two workspaces are two tenants; each keeps its own GITHUB_TOKEN. A
    database-wide unique index would make the second tenant's key name a
    function of the first tenant's choices.
    """
    ws_a = _create_workspace(harness, "secrets-dup-a")
    ws_b = _create_workspace(harness, "secrets-dup-b")

    first = _create_secret(harness, ws_a, "GITHUB_TOKEN", FIRST_VALUE)
    assert first.status == 201

    dup = _create_secret(harness, ws_a, "GITHUB_TOKEN", SECOND_VALUE, expect=409)
    assert dup.status == 409
    # The conflict names the KEY so the UI can say which row to change. The
    # key is not a secret — it is what the model types into a placeholder.
    assert dup.json().get("error", "").find("GITHUB_TOKEN") != -1, (
        f"the 409 should name the conflicting key, got {dup.json()!r}"
    )
    _assert_value_absent(dup, FIRST_VALUE, SECOND_VALUE)

    # The loser must not have half-applied: one row, and it is still A's.
    assert _list_secrets(harness, ws_a).json()["count"] == 1
    assert _one_named(harness, ws_a, "GITHUB_TOKEN")["id"] == first.json()["secret"]["id"]

    # Same name, different workspace: a clean 201.
    second = _create_secret(harness, ws_b, "GITHUB_TOKEN", SECOND_VALUE)
    assert second.status == 201
    assert second.json()["secret"]["id"] != first.json()["secret"]["id"]
    assert _list_secrets(harness, ws_b).json()["count"] == 1

    # Names are trimmed before the uniqueness check, so surrounding
    # whitespace cannot smuggle in a second row under a different spelling.
    padded = _create_secret(harness, ws_a, "  GITHUB_TOKEN  ", SECOND_VALUE, expect=409)
    assert padded.status == 409
    assert _list_secrets(harness, ws_a).json()["count"] == 1


# ─── 6. Invalid name ───────────────────────────────────────────────────────


def test_name_outside_the_placeholder_grammar_is_400(harness: FunctionalHarness) -> None:
    """Names are restricted to `[A-Za-z0-9_-]{1,64}`.

    The name is what a model types into a `{{SECRETS:NAME}}` placeholder, so
    a name the grammar cannot express is rejected at the edge rather than
    stored and then rendered as literal, unresolvable placeholder text.
    """
    ws = _create_workspace(harness, "secrets-name-grammar-ws")

    # Each of these is a name the placeholder lexer cannot spell. The
    # boundary pair (64 accepted / 65 refused) is the one a `<=`/`>=` typo
    # in the validator would silently break.
    for bad in (
        "has space",
        "has.dot",
        "brace{",
        "slash/one",
        "col:on",
        "emoji🐍",
        "a" * 65,
        "A" * 64 + "-",
    ):
        rejected = _create_secret(harness, ws, bad, FIRST_VALUE, expect=400)
        assert rejected.json().get("error") == "name must match [A-Za-z0-9_-]{1,64}", (
            f"unexpected message for name {bad!r}: {rejected.json()!r}"
        )

    assert _list_secrets(harness, ws).json()["count"] == 0, (
        "a rejected name must not have been stored"
    )

    # Boundaries that ARE legal, so the assertions above are not passing
    # because everything is rejected.
    for good in ("A", "a" * 64, "GITHUB_TOKEN", "token-with_underscores-and-dashes123"):
        created = _create_secret(harness, ws, good, FIRST_VALUE)
        assert created.json()["secret"]["name"] == good


# ─── 7. Missing ids / missing fields ───────────────────────────────────────


def test_missing_name_and_missing_value_are_both_400(harness: FunctionalHarness) -> None:
    """A blank submission is a 400 that names the field, on both fields."""
    ws = _create_workspace(harness, "secrets-missing-fields-ws")

    empty_body = harness.http("POST", _secrets_url(ws), json_body={}, expect=400)
    assert empty_body.json().get("error") == "name is required", (
        f"got {empty_body.json()!r}"
    )

    # Whitespace-only is blank, not a legal one-character name.
    for blank in ("", "   ", "\t\n"):
        rejected = _create_secret(harness, ws, blank, FIRST_VALUE, expect=400)
        assert rejected.json().get("error") == "name is required"

    # The mirror image: a name with no value.
    no_value = harness.http(
        "POST", _secrets_url(ws), json_body={"name": "ONLY_A_NAME"}, expect=400
    )
    assert no_value.json().get("error") == "value is required", (
        f"got {no_value.json()!r}"
    )

    # And a value with no name.
    no_name = harness.http(
        "POST", _secrets_url(ws), json_body={"value": FIRST_VALUE}, expect=400
    )
    assert no_name.json().get("error") == "name is required"

    # Unparseable JSON is also a 400 rather than a 500.
    harness.http(
        "POST",
        _secrets_url(ws),
        json_body=["not", "an", "object"],
        expect=400,
    )

    assert _list_secrets(harness, ws).json()["count"] == 0, (
        "no refused request may have written a row"
    )
    _assert_value_absent(empty_body, FIRST_VALUE)
    _assert_value_absent(no_name, FIRST_VALUE)


# ─── 7b. A PATCH `name` is a claim, not a rename ───────────────────────────


def test_patch_name_is_a_claim_not_a_rename(harness: FunctionalHarness) -> None:
    """The name is immutable, and a mismatched claim is indistinguishable
    from a row that is not there.

    A rename would silently break every prompt, skill and saved tool call
    that references `{{SECRETS:OLD_NAME}}`, and no rename is undoable from
    the UI. So the `name` field of a PATCH body asserts WHICH row is being
    addressed; when it does not match, the answer is 404 — the same answer a
    wrong-workspace id gets, so a rename probe leaks nothing either.
    """
    ws = _create_workspace(harness, "secrets-immutable-name-ws")
    created = _create_secret(harness, ws, "ORIGINAL_NAME", FIRST_VALUE)
    sid = created.json()["secret"]["id"]

    # The matching claim plus a new value: a rotation.
    ok = _patch_secret(harness, ws, sid, {"name": "ORIGINAL_NAME", "value": SECOND_VALUE})
    assert ok.status == 200
    assert ok.json()["secret"]["name"] == "ORIGINAL_NAME"
    _assert_no_value_key(ok)

    # A non-matching claim: refused, and the stored value is untouched
    # (proved by the row still rotating cleanly afterwards).
    rename = _patch_secret(
        harness, ws, sid, {"name": "RENAMED", "value": FIRST_VALUE}, expect=404
    )
    assert rename.json().get("error") == "secret not found", f"got {rename.json()!r}"
    assert _one_named(harness, ws, "ORIGINAL_NAME")["id"] == sid
    assert _list_secrets(harness, ws).json()["count"] == 1

    # A rename attempt that also carries an invalid name is refused on the
    # NAME (400), before the row is even read — so it cannot be used to
    # probe which ids exist.
    invalid = _patch_secret(harness, ws, sid, {"name": "has space"}, expect=400)
    assert invalid.json().get("error") == "name must match [A-Za-z0-9_-]{1,64}"

    # A body with neither field returns the row untouched, and does not
    # advance `updated_at` (no write happened).
    before = _one_named(harness, ws, "ORIGINAL_NAME")["updated_at"]
    noop = _patch_secret(harness, ws, sid, {})
    assert noop.status == 200
    assert noop.json()["secret"]["id"] == sid
    assert _one_named(harness, ws, "ORIGINAL_NAME")["updated_at"] == before

    # An empty PATCH body (no JSON at all) is a 400, not a crash.
    harness.http("PATCH", _secret_url(ws, sid), json_body=None, expect=400)


# ─── 8. Placeholder error, through the real agentic loop ───────────────────
#
# `handle_tool.zig` already unit-tests the substitution seam by calling
# `dispatchTool` in-process. That cannot show what the MODEL sees: the
# envelope after persistence, after redaction, in a real worker thread, in a
# real process. Only a stub LLM upstream serving the tool call over the
# actual wire does that — the shape proven by
# `agent_list_directory_relative_path_test.py`, reused here.
#
# The test runs TWO turns against the same workspace:
#
#   A. `{{SECRETS:UNKNOWN}}` — the required case. Error envelope naming
#      `UNKNOWN`, and the target file does not exist afterwards.
#   B. `{{SECRETS:PRESENT_KEY}}` — a positive CONTROL. Same machinery, same
#      session shape, a name the workspace really has. It must SUCCEED and
#      write the file.
#
# B is what makes A mean something. `SecretResolver` fails closed: a session
# that resolves to no workspace answers null for every name, so turn A would
# produce the identical envelope whether or not workspace resolution works
# at all. Turn B succeeds only when `workspace_scope.resolveWorkspaceId`
# really found this workspace and really loaded this row — so A's failure is
# pinned to the unknown NAME, not to a resolver that refuses everything.

#: Legal per the `[A-Za-z0-9_-]` grammar, so the ONLY reason the first turn
#: fails is that this workspace has no secret by that name.
UNKNOWN_NAME = "UNKNOWN"
#: A secret this workspace really has — the control.
PRESENT_NAME = "PRESENT_KEY"

UNKNOWN_CALL_ID = "call_secrets_unknown_1"
PRESENT_CALL_ID = "call_secrets_present_1"
NEVER_WRITTEN_FILENAME = "never-created-because-the-placeholder-did-not-resolve.txt"
CONTROL_FILENAME = "control-written-from-a-placeholder-that-did-resolve.txt"


def _tool_call_sse(call_id: str, tool_name: str, arguments: str) -> bytes:
    """One OpenAI-style SSE stream carrying a single tool_call."""
    first = {
        "id": f"chatcmpl-stub-{call_id}",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [
            {
                "index": 0,
                "delta": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": call_id,
                            "type": "function",
                            "function": {"name": tool_name, "arguments": arguments},
                        }
                    ],
                },
                "finish_reason": None,
            }
        ],
    }
    final = {
        "id": f"chatcmpl-stub-{call_id}",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
    }
    return (
        "".join(f"data: {json.dumps(chunk)}\n\n" for chunk in (first, final))
        + "data: [DONE]\n\n"
    ).encode()


def _text_sse(text: str) -> bytes:
    """OpenAI-style SSE carrying a plain assistant message (turn terminator)."""
    first = {
        "id": "chatcmpl-stub-text",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [
            {
                "index": 0,
                "delta": {"role": "assistant", "content": text},
                "finish_reason": None,
            }
        ],
    }
    final = {
        "id": "chatcmpl-stub-text",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    return (
        "".join(f"data: {json.dumps(chunk)}\n\n" for chunk in (first, final))
        + "data: [DONE]\n\n"
    ).encode()


class _StubState:
    """Serves a fixed queue of tool calls, one per agentic turn.

    A request is a FOLLOW-UP turn (and gets a plain stop reply) as soon as it
    carries the id of a call already served — that is how the loop is told
    to finish instead of looping. Anything else that carries a `tools` array
    consumes the next queued call. The session auto-naming request carries
    no `tools` array, so it never consumes one.
    """

    def __init__(self, pending: list[tuple[str, str, str]]) -> None:
        self.lock = threading.Lock()
        self.requests: list[bytes] = []
        self.pending = list(pending)
        self.served: list[str] = []

    def note(self, body: bytes) -> tuple[str, str, str] | None:
        with self.lock:
            self.requests.append(body)
            for call_id in self.served:
                if call_id.encode() in body:
                    return None  # follow-up turn: the tool result is in hand
            if self.pending and b'"tools"' in body:
                call = self.pending.pop(0)
                self.served.append(call[0])
                return call
            return None


class _StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args: Any) -> None:  # silence stderr noise
        pass

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        state: _StubState = self.server.state  # type: ignore[attr-defined]
        call = state.note(body)
        if call is None:
            raw = _text_sse("stopping")
        else:
            call_id, tool_name, arguments = call
            raw = _tool_call_sse(call_id, tool_name, arguments)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def _start_stub(pending: list[tuple[str, str, str]]) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    server.state = _StubState(pending)  # type: ignore[attr-defined]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def _wait_for_tool_row(
    harness: FunctionalHarness, session_id: str, timeout_s: float = 60.0
) -> dict[str, Any] | None:
    """Poll until a `write_file` row for this session carries content.

    `handle_tool` writes a PLACEHOLDER row (empty content) before dispatch,
    so a row merely EXISTING is not proof the tool ran — the content has to
    arrive. A dead worker never fills it, so fail fast instead of burning
    the whole timeout on a crashed process.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        r = harness.http(
            "GET",
            f"/api/llm/session/{session_id}/messages",
            params={"sort_by": "created_at", "direction": "asc", "limit": 100},
            expect=200,
        )
        for message in r.json().get("messages", []):
            if message.get("tool_name") != "write_file":
                continue
            if (message.get("content") or "").strip():
                return message
        if not harness.health():
            return None
        time.sleep(0.5)
    return None


def _run_turn(
    harness: FunctionalHarness, ws_path: Path, tag: str, prompt: str
) -> dict[str, Any] | None:
    """Start one real agentic turn with `write_file` as the only tool."""
    session_id = f"sess_secrets_{tag}_{int(time.time() * 1000)}"
    harness.http(
        "POST",
        "/api/llm/session",
        json_body={
            "session_id": session_id,
            "queue_message": prompt,
            "cwd_session": str(ws_path),
            "allowed_tools": "write_file",
            "image_urls": "",
            "selected_profile_model": "secrets-stub",
            "is_auto_retry_until_stop": "",
        },
        expect=(200, 201, 500),
    )
    return _wait_for_tool_row(harness, session_id)


def test_unknown_placeholder_names_the_missing_key_and_dispatches_nothing(
    default_nalar_bin: Path,
) -> None:
    """`{{SECRETS:UNKNOWN}}` produces a tool error naming `UNKNOWN`, and the
    tool never runs.

    Driven over a real wire: a stub LLM upstream serves the exact tool call
    byte-for-byte, through a real agentic loop, in a real process. The
    in-process unit tests in `handle_tool.zig` cannot see the envelope as
    the MODEL sees it — persisted, redacted, and streamed.

    Runs a positive control alongside the required case; see the section
    header above for why A without B proves nothing.
    """
    harness = FunctionalHarness.boot(default_nalar_bin, stub_llm_profile=True)
    server: ThreadingHTTPServer | None = None
    try:
        # ── A workspace whose item path IS the session cwd, so
        #    `workspace_scope.resolveWorkspaceId` resolves it by path.
        ws = _create_workspace(harness, "secrets-placeholder-ws")
        ws_path = Path(harness_path(harness, "secrets-placeholder-ws"))
        ws_path.mkdir(parents=True, exist_ok=True)
        agent = harness.http(
            "POST",
            f"/api/workspaces/{ws}/items/agent",
            json_body={"name": "placeholder-agent", "path": str(ws_path)},
            expect=201,
        )
        assert agent.json()["item"]["id"]

        # One real secret so the workspace is not empty, and so the control
        # turn has something to resolve.
        present = _create_secret(harness, ws, PRESENT_NAME, FIRST_VALUE)
        assert present.status == 201
        present_id = present.json()["secret"]["id"]

        # Both target files live under the harness tempdir, so the teardown
        # already owns them and the assertions are about paths that exist in
        # this test's own world.
        never_written = ws_path / NEVER_WRITTEN_FILENAME
        control_written = ws_path / CONTROL_FILENAME
        assert not never_written.exists()

        server = _start_stub(
            [
                (
                    UNKNOWN_CALL_ID,
                    "write_file",
                    json.dumps(
                        {
                            "path": str(never_written),
                            "content": "{{SECRETS:%s}}" % UNKNOWN_NAME,
                            "create_with_dir": False,
                        }
                    ),
                ),
                (
                    PRESENT_CALL_ID,
                    "write_file",
                    json.dumps(
                        {
                            "path": str(control_written),
                            "content": "{{SECRETS:%s}}" % PRESENT_NAME,
                            "create_with_dir": False,
                        }
                    ),
                ),
            ]
        )
        stub_port = server.server_address[1]
        stub_url = f"http://127.0.0.1:{stub_port}/v1/chat/completions"
        harness.http(
            "PUT",
            "/api/config/nalar",
            json_body={
                "api_endpoint": stub_url,
                "api_key": "sk-stub-test",
                "model": "stub-model",
                "url_style": "openai",
                "profiles": {
                    "secrets-stub": {
                        "model": "stub-model",
                        "base_url": stub_url,
                        "api_key": "sk-stub-test",
                        "url_style": "openai",
                    },
                },
                "active_profile": "secrets-stub",
            },
            expect=200,
        )

        # ── Turn A: the required case. ──
        unknown_row = _run_turn(
            harness, ws_path, "unknown", "write the file using the placeholder"
        )
        # ── Turn B: the control. ──
        present_row = _run_turn(
            harness, ws_path, "present", "write the file using the other placeholder"
        )

        log_tail = harness.tail_log(4000)

        # The worker must have survived both turns.
        assert harness.health(), (
            f"nalar died during the turn.\n--- log tail ---\n{log_tail[-4000:]}"
        )

        state: _StubState = server.state  # type: ignore[attr-defined, union-attr]
        with state.lock:
            served = list(state.served)
        # Guard against a vacuous pass: if the stub never served the calls,
        # nothing was exercised at all.
        assert UNKNOWN_CALL_ID in served, (
            f"the stub never served the unknown-placeholder call.\n"
            f"--- log tail ---\n{log_tail[-4000:]}"
        )
        assert PRESENT_CALL_ID in served, (
            f"the stub never served the control call.\n"
            f"--- log tail ---\n{log_tail[-4000:]}"
        )
        assert unknown_row is not None, (
            f"no write_file tool result row appeared for the unknown "
            f"placeholder.\n--- log tail ---\n{log_tail[-4000:]}"
        )
        assert present_row is not None, (
            f"no write_file tool result row appeared for the control "
            f"placeholder.\n--- log tail ---\n{log_tail[-4000:]}"
        )

        # ── Control first: the resolver really works over this wire. ──
        control = json.loads(present_row["content"])
        assert control["tool"] == "write_file", control
        assert control["success"] is True, (
            f"a resolvable placeholder must dispatch and succeed: {control}"
        )
        assert control_written.exists(), (
            "the control turn did not write its file, so the harness path "
            "never reaches the executor and the unknown-name assertion "
            "below proves nothing"
        )
        # The executor got the REAL value (property A) — the point of the
        # whole feature, and the half a redaction-only test cannot see.
        assert control_written.read_text() == FIRST_VALUE, (
            f"the executor should have received the real value, got "
            f"{control_written.read_text()!r}"
        )
        # ...while the tool result the model reads back carries the
        # PLACEHOLDER, never the value (property B).
        assert FIRST_VALUE not in present_row["content"], (
            "the resolved value leaked into the persisted tool result: "
            f"{present_row['content']!r}"
        )

        # ── The required case. ──
        envelope = json.loads(unknown_row["content"])
        assert envelope["tool"] == "write_file", envelope
        assert envelope["success"] is False, (
            f"an unresolvable placeholder must not report success: {envelope}"
        )
        assert envelope["data"] is None, f"a refused call carries no data: {envelope}"
        error = envelope["error"]
        assert UNKNOWN_NAME in error, (
            "the envelope must name the missing key so the agent knows what "
            f"to ask the user for: {error!r}"
        )
        assert "Nothing was run" in error, (
            f"the envelope must say the call did not execute: {error!r}"
        )

        # The PLACEHOLDER, not a value, is what the agent sees back.
        assert "{{SECRETS:%s}}" % UNKNOWN_NAME in unknown_row["content"], (
            f"`parameters` must echo the unsubstituted arguments: {envelope}"
        )
        assert FIRST_VALUE not in unknown_row["content"], (
            "the unrelated workspace secret leaked into a tool result: "
            f"{unknown_row['content']!r}"
        )

        # ── Dispatched nothing: the file the call targeted does not exist. ──
        assert not never_written.exists(), (
            "the tool RAN despite the unresolvable placeholder — "
            f"{never_written} exists with content {never_written.read_text()!r}"
        )

        # ── The workspace's real secret is untouched by the failed turn. ──
        assert _one_named(harness, ws, PRESENT_NAME)["id"] == present_id
        assert _list_secrets(harness, ws).json()["count"] == 1
        _assert_value_absent(_list_secrets(harness, ws), FIRST_VALUE)
    finally:
        try:
            harness.teardown()
        except Exception:
            pass
        if server is not None:
            server.shutdown()