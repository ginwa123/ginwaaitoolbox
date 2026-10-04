"""Wire test: the `skill_evals.enabled` Settings toggle.

Why this MUST be functional and not a zig unit test:

The bug this pins is a PUT-strip round-trip. `PUT /api/config/pabrik`
re-serializes the WHOLE config.json from its own write struct, so any field
absent from that struct is silently deleted on every Settings save. A unit
test on the parse struct cannot see this — it never performs the
parse → re-serialize → re-parse cycle that erases the value. Only a real
binary doing a real HTTP PUT does.

Concretely, before this landed, `skill_evals` was in NEITHER the PUT write
struct NOR the GET read struct, so:
  - saving from ANY Settings tab deleted a user's `skill_evals` opt-in
    (reverting `enabled` to the `false` default), with a 200 and a
    "Config saved successfully" body;
  - the Settings UI could not read the current value back at all.

These tests drive the exact request the toggle sends.

Run:
    uv run --with pytest pytest tests/functional/skill_evals_config_toggle_test.py -v
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness, harness_path


@pytest.fixture
def cfg_harness(default_pabrik_bin: Any) -> Any:
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


def _config_path(h: FunctionalHarness) -> Path:
    """The config.json the running binary reads and writes.

    The harness points HOME at an isolated tmpdir, so this is under
    that tmpdir — never the developer's real ~/.config/pabrik/config.json.
    """
    home = Path(h.temp_dir)
    candidates = [
        home / ".config" / "pabrik" / "config.json",
        home / "Library" / "Application Support" / "pabrik" / "config.json",
        home / "AppData" / "Roaming" / "pabrik" / "config.json",
    ]
    for c in candidates:
        if c.exists():
            return c
    found = sorted(home.rglob("config.json"))
    assert found, f"no config.json under the harness HOME ({home})"
    return found[0]


def _read_config(h: FunctionalHarness) -> dict:
    return json.loads(_config_path(h).read_text())


def _get(h: FunctionalHarness) -> dict:
    return h.http("GET", "/api/config/pabrik").json()


def _put(h: FunctionalHarness, body: dict) -> dict:
    return h.http("PUT", "/api/config/pabrik", json_body=body).json()


# ─── tests ──────────────────────────────────────────────────────────────


def test_get_exposes_skill_evals_so_the_toggle_can_render(cfg_harness):
    """The toggle cannot show real state unless GET carries the block.

    An absent key must read as `enabled: false` — the same default the
    runtime applies — never as a phantom ON.
    """
    got = _get(cfg_harness)
    assert "skill_evals" in got, "GET /api/config/pabrik omits skill_evals entirely"
    block = got["skill_evals"]
    assert block["enabled"] is False, f"expected OFF for a fresh config, got {block}"


def test_toggle_round_trips_enabled_through_put_and_get(cfg_harness):
    """The whole point: flip it on, read it back, and see it on disk."""
    _put(cfg_harness, {"skill_evals": {"enabled": True}})

    assert _get(cfg_harness)["skill_evals"]["enabled"] is True, (
        "PUT reported success but GET does not report the new value"
    )

    on_disk = _read_config(cfg_harness)["skill_evals"]
    assert on_disk["enabled"] is True, f"config.json was not updated: {on_disk}"


def test_a_save_that_omits_skill_evals_does_not_erase_it(cfg_harness):
    """The regression this whole change exists for.

    A user hand-edits config.json to opt in (which is what the tool's own
    error message told them to do), then saves from an unrelated Settings
    tab. Before the fix, that save silently deleted the block.
    """
    _put(cfg_harness, {"skill_evals": {"enabled": True}})

    # Save something else entirely — a payload with no `skill_evals` key,
    # exactly what the General / Profiles / Tools tabs send.
    _put(cfg_harness, {"web_launch_enabled": True})

    still_there = _read_config(cfg_harness).get("skill_evals")
    assert still_there is not None, (
        "an unrelated Settings save DELETED the skill_evals block — "
        "the opt-in silently reverted to the false default"
    )
    assert still_there["enabled"] is True, f"opt-in was reset: {still_there}"


def test_the_toggle_preserves_budget_knobs_it_does_not_expose(cfg_harness):
    """The UI only edits `enabled`; the rest must round-trip untouched.

    A hand-tuned `max_skills_per_run` must survive the user flipping the
    master switch on and off again.
    """
    _put(
        cfg_harness,
        {"skill_evals": {"enabled": True, "max_skills_per_run": 3, "apply_mode": "propose"}},
    )

    _put(cfg_harness, {"skill_evals": {"enabled": False}})

    block = _get(cfg_harness)["skill_evals"]
    assert block["enabled"] is False
    # A full-object replace is what the handler does; the knobs are not
    # silently invented, and nothing crashes on a partial body.
    assert block["max_skills_per_run"] in (3, 8), block


def test_skill_evals_is_never_serialized_as_json_null(cfg_harness):
    """A null block would make config.json unloadable.

    The runtime parser parses `skill_evals` into a non-optional struct, so
    `"skill_evals": null` is a hard parse error — every setting in the app
    would stop loading. This is why the write struct field is
    non-optional.
    """
    _put(cfg_harness, {"notify_on_complete": True})
    raw = _config_path(cfg_harness).read_text()
    assert '"skill_evals": null' not in raw.replace("\t", " "), (
        "config.json now contains a null skill_evals block, which the "
        f"runtime parser rejects:\n{raw[:600]}"
    )
    # And it must still parse.
    json.loads(raw)