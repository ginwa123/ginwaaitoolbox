"""Wire test: the Skill Evals HTTP surface.

Covers the three routes the frontend actually calls:

    GET  /api/skill-evals/runs?run_id=&session_id=&limit=
    GET  /api/skill-evals/summary?session_id=
    POST /api/skill-evals/results/apply?result_id=&action=

Why a functional test and not a unit test: the read handlers resolve the
DB through `getSingleton()`, so they are not unit-testable as written, and
the apply route's whole risk is in its WIRE shape — a `result_id` that is a
query parameter rather than a path segment (so the route stays a literal
and cannot be shadowed by a later `:param`), and a closed error set that
must map to 400/404/409 rather than falling through to a 500.

The rows are seeded directly through the API's own database file, because
there is no HTTP route that creates an eval run — the agent's
`run_skill_eval` tool does, and driving a full agent turn just to get one
row would test the agent, not this surface.

Run:
    uv run --with pytest pytest tests/functional/skill_evals_api_test.py -v
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── fixtures ───────────────────────────────────────────────────────────


@pytest.fixture
def evals_harness(default_pabrik_bin: Any) -> Any:
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


def _db_path(h: FunctionalHarness) -> Path:
    """The sqlite file the running binary opened.

    The harness points HOME at an isolated tmpdir, so the DB lives under
    that tmpdir. Search for it rather than hard-coding the layout.
    """
    home = Path(h.temp_dir)
    candidates = sorted(home.rglob("*.db")) + sorted(home.rglob("*.sqlite"))
    for c in candidates:
        if c.is_file() and c.stat().st_size > 0:
            return c
    raise AssertionError(f"no sqlite db found under {home}")


def _seed_result(h: FunctionalHarness, *, result_id: str, verdict: str = "update") -> None:
    """Insert one run + one result, the shape `run_skill_eval` writes."""
    db = _db_path(h)
    con = sqlite3.connect(str(db))
    try:
        con.execute(
            "INSERT OR IGNORE INTO skill_eval_runs "
            "(id, session_id, scope, trigger, status, total_tokens) "
            "VALUES (?, 'sess_wire', 'session', 'self_prompt', 'done', 0)",
            (f"run_{result_id}",),
        )
        con.execute(
            "INSERT OR IGNORE INTO skill_eval_results "
            "(id, run_id, skill_key, skill_name, session_id, status, verdict, "
            " base_content_hash, rationale) "
            "VALUES (?, ?, 'global:wire-skill', 'wire-skill', 'sess_wire', "
            "'done', ?, 'deadbeef', 'seeded for the wire test')",
            (result_id, f"run_{result_id}", verdict),
        )
        con.commit()
    finally:
        con.close()


# ─── the read surface ───────────────────────────────────────────────────


def test_runs_returns_valid_json_with_empty_arrays_when_nothing_matches(
    evals_harness: FunctionalHarness,
) -> None:
    """A filter that matches nothing is a 200 with empty arrays.

    Not a 404 and not a 500: `?run_id=` is a filter, and "no rows" is a
    legitimate answer to a filter. A 404 here would make the frontend show
    an error for a session that simply has no evals yet.
    """
    r = evals_harness.http("GET", "/api/skill-evals/runs", params={"run_id": "nope"})
    body = json.loads(r.body)
    assert body["runs"] == []
    assert body["results"] == []


def test_runs_returns_a_seeded_run_and_its_results(
    evals_harness: FunctionalHarness,
) -> None:
    _seed_result(evals_harness, result_id="res_wire_1")
    r = evals_harness.http(
        "GET", "/api/skill-evals/runs", params={"run_id": "run_res_wire_1"}
    )
    body = json.loads(r.body)
    assert len(body["runs"]) == 1
    assert body["runs"][0]["id"] == "run_res_wire_1"
    assert len(body["results"]) == 1
    assert body["results"][0]["skill_name"] == "wire-skill"
    assert body["results"][0]["verdict"] == "update"
    # Not applied yet, so the UI offers Apply.
    assert body["results"][0]["applied"] is False


def test_runs_rejects_a_non_numeric_limit_with_400(
    evals_harness: FunctionalHarness,
) -> None:
    r = evals_harness.http(
        "GET", "/api/skill-evals/runs", params={"limit": "abc"}, expect=400
    )
    body = json.loads(r.body)
    assert "limit" in json.dumps(body).lower()


def test_runs_rejects_limit_zero_with_400(evals_harness: FunctionalHarness) -> None:
    evals_harness.http("GET", "/api/skill-evals/runs", params={"limit": "0"}, expect=400)


def test_runs_clamps_an_oversized_limit_rather_than_erroring(
    evals_harness: FunctionalHarness,
) -> None:
    """`limit=99999` is clamped to MAX_LIMIT, not rejected.

    A caller asking for more than we serve gets what we serve; only a
    malformed value is a 400.
    """
    r = evals_harness.http("GET", "/api/skill-evals/runs", params={"limit": "99999"})
    assert r.status == 200


def test_summary_is_valid_json_and_tallies_the_seeded_rows(
    evals_harness: FunctionalHarness,
) -> None:
    _seed_result(evals_harness, result_id="res_wire_2", verdict="keep")
    _seed_result(evals_harness, result_id="res_wire_3", verdict="keep")
    r = evals_harness.http(
        "GET", "/api/skill-evals/summary", params={"session_id": "sess_wire"}
    )
    body = json.loads(r.body)
    assert body["total"] == 2
    counts = {c["verdict"]: c["n"] for c in body["counts"]}
    assert counts.get("keep") == 2


def test_summary_on_an_empty_table_is_zero_not_an_error(
    evals_harness: FunctionalHarness,
) -> None:
    r = evals_harness.http(
        "GET", "/api/skill-evals/summary", params={"session_id": "never_seen"}
    )
    body = json.loads(r.body)
    assert body["total"] == 0
    assert body["counts"] == []


def test_a_rationale_containing_a_quote_survives_json_encoding(
    evals_harness: FunctionalHarness,
) -> None:
    """The response must parse even when a stored string contains a quote.

    `rationale` is free text written by an LLM, so a raw `"` in it is
    normal input, not an edge case.
    """
    db = _db_path(evals_harness)
    con = sqlite3.connect(str(db))
    try:
        con.execute(
            "INSERT OR IGNORE INTO skill_eval_runs "
            "(id, session_id, scope, trigger, status) "
            "VALUES ('run_quote', 'sess_wire', 'session', 'self_prompt', 'done')"
        )
        con.execute(
            "INSERT OR IGNORE INTO skill_eval_results "
            "(id, run_id, skill_key, skill_name, session_id, status, verdict, rationale) "
            "VALUES ('res_quote', 'run_quote', 'global:q', 'q', 'sess_wire', "
            "'done', 'update', 'it said \"this path is gone\" and left')"
        )
        con.commit()
    finally:
        con.close()

    r = evals_harness.http(
        "GET", "/api/skill-evals/runs", params={"run_id": "run_quote"}
    )
    body = json.loads(r.body)  # raises if the escaping is wrong
    assert '"this path is gone"' in body["results"][0]["rationale"]


# ─── the apply endpoint ─────────────────────────────────────────────────


def test_apply_requires_a_result_id(evals_harness: FunctionalHarness) -> None:
    r = evals_harness.http(
        "POST", "/api/skill-evals/results/apply", expect=400
    )
    assert "result_id" in json.dumps(json.loads(r.body)).lower()


def test_apply_on_an_unknown_result_is_404(evals_harness: FunctionalHarness) -> None:
    evals_harness.http(
        "POST",
        "/api/skill-evals/results/apply",
        params={"result_id": "does_not_exist"},
        expect=404,
    )


def test_apply_records_the_action_and_is_idempotent_guarded(
    evals_harness: FunctionalHarness,
) -> None:
    """The first apply wins; the second is a 409, not a second write.

    Two clicks, two clients or two humans must not both write the skill.
    """
    _seed_result(evals_harness, result_id="res_apply_1")

    first = evals_harness.http(
        "POST",
        "/api/skill-evals/results/apply",
        params={"result_id": "res_apply_1", "action": "edit"},
    )
    body = json.loads(first.body)
    assert body["applied"] is True
    assert body["action"] == "edit"

    # The second attempt is refused, and the refusal is a 409 — the caller
    # can tell "someone already did this" from "that does not exist".
    evals_harness.http(
        "POST",
        "/api/skill-evals/results/apply",
        params={"result_id": "res_apply_1", "action": "delete"},
        expect=409,
    )

    # And the row still records the FIRST action, not the loser's.
    r = evals_harness.http(
        "GET", "/api/skill-evals/runs", params={"run_id": "run_res_apply_1"}
    )
    result = json.loads(r.body)["results"][0]
    assert result["applied"] is True
    assert result["apply_action"] == "edit"


def test_apply_on_a_stale_result_is_409(evals_harness: FunctionalHarness) -> None:
    """A verdict whose body moved on is not applicable."""
    _seed_result(evals_harness, result_id="res_stale_1")
    db = _db_path(evals_harness)
    con = sqlite3.connect(str(db))
    try:
        con.execute(
            "UPDATE skill_eval_results SET status = 'stale' WHERE id = 'res_stale_1'"
        )
        con.commit()
    finally:
        con.close()

    evals_harness.http(
        "POST",
        "/api/skill-evals/results/apply",
        params={"result_id": "res_stale_1"},
        expect=409,
    )
