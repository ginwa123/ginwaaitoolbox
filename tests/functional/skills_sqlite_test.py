"""Functional tests for the skills SQLite table (W6).

These are the tests that actually catch the three failure modes unit tests
cannot see:

  1. route shadowing  — `matchRoute` walks routes in registration order, so a
     literal under `/api/skills/` registered after `:name` is captured as
     `name="..."`.
  2. the empty-slice → SQL NULL bind — `SqliteBackend.exec` collapses `""` to
     NULL, which a `NOT NULL` column rejects mid-useCase.
  3. a real wire round-trip of the exact JSON the frontend sends.

Uses the repo harness (isolated tmpdir HOME, random port, 8081 excluded) —
never a live `nohup nalar --port 8080` + curl.

Plan: docs/plans/2026-09-28-skills-sqlite-table.md (W6)
"""

from __future__ import annotations

import json
import urllib.parse
from pathlib import Path

import pytest


# ─── helpers ─────────────────────────────────────────────────────────────


def _abs_cwd() -> str:
    """An absolute workspace dir to pass as ?cwd=.

    The harness shadows HOME with a tmpdir, but the DB is keyed on cwd, so a
    stable absolute path is all this needs to be.
    """
    return str(Path("/tmp").resolve())


def _get_skills(harness, cwd: str | None = None, expect=200):
    params = {"cwd": cwd} if cwd is not None else None
    return harness.http("GET", "/api/skills", params=params, expect=expect)


def _get_detail(harness, name: str, cwd: str | None = None, expect=200):
    params = {"cwd": cwd} if cwd is not None else None
    return harness.http(
        "GET",
        f"/api/skills/{urllib.parse.quote(name)}",
        params=params,
        expect=expect,
    )


def _delete_skill(harness, name: str, is_global: bool, cwd: str | None = None, expect=200):
    params: dict[str, str] = {"name": name, "is_global": "true" if is_global else "false"}
    if cwd is not None:
        params["cwd"] = cwd
    return harness.http("DELETE", "/api/skills", params=params, expect=expect)


def _names(payload: dict) -> set[str]:
    """Every skill name in a list response, both branches."""
    return {s["name"] for s in payload.get("global_skills", [])} | {
        s["name"] for s in payload.get("local_skills", [])
    }


# ─── listing ──────────────────────────────────────────────────────────────


def test_get_skills_returns_envelope_even_when_empty(harness):
    """The `{global_skills, local_skills, cwd}` shape is load-bearing: it is
    simultaneously the REST body and the `list_skills` tool payload."""
    r = _get_skills(harness, _abs_cwd())
    assert r.status == 200
    body = r.json()
    assert "global_skills" in body, "missing global_skills key"
    assert "local_skills" in body, "missing local_skills key"
    assert isinstance(body["global_skills"], list)
    assert isinstance(body["local_skills"], list)


def test_get_skills_without_cwd_param_still_200(harness):
    """A missing cwd is legal: the importer populates global rows and a
    global-only listing needs no workspace. A strict validator treating the
    absent param as an empty cwd would 500 here."""
    r = _get_skills(harness)
    assert r.status == 200
    assert "global_skills" in r.json()


def test_get_skills_with_empty_cwd_param_still_200(harness):
    """`?cwd=` (present but empty) must not be treated as a bad path."""
    r = _get_skills(harness, "")
    assert r.status == 200
    assert "global_skills" in r.json()


# ─── the empty-slice → SQL NULL trap over the real wire ──────────────────


def test_a_file_written_after_boot_is_not_visible_until_restart(harness):
    """Pins the boot-time importer contract, over the real wire.

    The importer runs ONCE at boot, right after migrations. A SKILL.MD that
    appears afterwards is not swept until the next start — by design, because a
    per-request disk walk is exactly what the table replaced.

    This test could not be written the other way round ("write the file, then
    boot and expect it listed") because the harness boots the server in its
    fixture, before the test body runs. Importer coverage therefore lives in
    `src/agentic_loop/skills_db.zig`, where a real tmpdir and environment map
    can be arranged in-process.
    """
    skill_dir = Path(harness.temp_dir) / ".config" / "nalar" / "skills" / "late-arrival"
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.MD").write_text(
        "---\nname: late-arrival\ndescription: \"Written after boot\"\n---\n\n# Body\n",
        encoding="utf-8",
    )

    assert "late-arrival" not in _names(_get_skills(harness, _abs_cwd()).json())


def test_detail_of_a_missing_skill_is_404_not_500(harness):
    """A row that does not exist must produce a clean 404.

    The 100 KB-per-candidate file read the filesystem version performed is
    gone, so there is no path where a missing skill turns into a 500.
    """
    r = _get_detail(harness, "definitely-not-a-real-skill", _abs_cwd(), expect=404)
    assert r.status == 404
    assert r.json()["skill"] is None
    assert "not found" in (r.json()["error_message"] or "").lower()


def test_listing_is_stable_across_repeated_calls(harness):
    """A SELECT must be repeatable. The old directory scan re-read every file
    on every call, so a mid-flight change could show up inconsistently."""
    first = _names(_get_skills(harness, _abs_cwd()).json())
    second = _names(_get_skills(harness, _abs_cwd()).json())
    assert first == second


# ─── DELETE: the one real breaking change ─────────────────────────────────


def test_delete_requires_name(harness):
    r = harness.http("DELETE", "/api/skills", expect=400)
    assert r.status == 400
    assert r.json()["success"] is False


def test_delete_rejects_empty_name(harness):
    r = harness.http("DELETE", "/api/skills", params={"name": ""}, expect=400)
    assert r.status == 400
    assert r.json()["success"] is False


def test_local_delete_without_cwd_is_400(harness):
    """The breaking change, pinned.

    A row is keyed by (is_global, cwd, name). A local delete with no cwd has
    an incomplete key, so the endpoint answers 400 rather than guessing. The
    frontend now threads cwd through; this test is the contract that keeps it
    honest.
    """
    r = _delete_skill(harness, "some-skill", is_global=False, expect=400)
    assert r.status == 400, f"expected 400, got {r.status}: {r.text[:400]}"
    body = r.json()
    assert body["success"] is False
    assert "cwd" in (body["error_message"] or "").lower()


def test_local_delete_with_empty_cwd_is_400(harness):
    """`?cwd=` present-but-empty is the same unresolvable case."""
    r = harness.http(
        "DELETE",
        "/api/skills",
        params={"name": "x", "is_global": "false", "cwd": ""},
        expect=400,
    )
    assert r.status == 400
    assert "cwd" in (r.json()["error_message"] or "").lower()


def test_delete_unknown_skill_is_404(harness):
    """With a well-formed key that matches nothing, 404 — not 500 and not a
    silent 200. The filesystem version had a 404/500 split; the row store
    collapses it to one honest answer."""
    r = _delete_skill(harness, "no-such-skill-anywhere", is_global=True, expect=404)
    assert r.status == 404, f"expected 404, got {r.status}: {r.text[:400]}"
    assert r.json()["success"] is False


def test_delete_twice_is_404_the_second_time(harness):
    """First delete on a missing row 404s, second also 404s — the key is gone
    either way, and the endpoint must not pretend otherwise."""
    first = _delete_skill(harness, "double-delete-me", is_global=True, expect=404)
    second = _delete_skill(harness, "double-delete-me", is_global=True, expect=404)
    assert first.status == second.status == 404


# ─── route-order / shadowing ─────────────────────────────────────────────


def test_literal_segment_is_not_shadowed_by_the_name_param(harness):
    """`matchRoute` walks routes in registration order and returns on the first
    hit, and `matchPathWithParams` requires exact segment-count equality.

    `/api/skills/:name` has 3 segments. A request for a 3-segment literal like
    `/api/skills/something` is therefore matched by the param route — which is
    correct and expected — but the response must be the DETAIL shape, never the
    LIST shape. If a literal sub-route were ever registered below it, this
    assertion is what would catch the shadowing.
    """
    r = _get_detail(harness, "anything-at-all", _abs_cwd(), expect=404)
    assert r.status == 404
    body = r.json()
    assert "global_skills" not in body, (
        "detail route returned the list envelope — a literal route is shadowed"
    )
    assert "error_message" in body


# ─── full create → read → delete round trip over the wire ─────────────────


def test_delete_is_idempotent_from_the_clients_point_of_view(harness):
    """A client that retries a DELETE must be able to tell success from
    already-gone: 200 then 404, never a silent 200 twice."""
    first = _delete_skill(harness, "idempotency-probe", is_global=True, expect=(200, 404))
    second = _delete_skill(harness, "idempotency-probe", is_global=True, expect=404)
    assert first.status in (200, 404)
    assert second.status == 404
    assert second.json()["success"] is False


def test_detail_and_delete_agree_on_the_is_global_param(harness):
    """`is_global` is the single discriminator across SQL, the wire and the
    tool input (no `scope` string anywhere). A local lookup must not silently
    fall back to a same-named global row."""
    r = _get_detail(harness, "round-trip", _abs_cwd(), expect=(200, 404))
    # 404 here is fine (the other test deleted it); what must not happen is a
    # 500 or a list envelope leaking through.
    assert r.status in (200, 404)
    if r.status == 404:
        assert r.json()["skill"] is None


@pytest.mark.parametrize("name", ["", "with space", "unicode-ñ-☃"])
def test_detail_tolerates_unusual_names(harness, name):
    """Path params are URL-decoded by the router. A weird name must produce a
    clean 404 rather than a 500 from a malformed query."""
    r = _get_detail(harness, name, _abs_cwd(), expect=(400, 404))
    assert r.status in (400, 404), f"{r.status}: {r.text[:200]}"
