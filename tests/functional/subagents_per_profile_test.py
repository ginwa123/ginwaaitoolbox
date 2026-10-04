"""Subagents are per-profile only (plan 2026-09-04-subagents-per-profile).

Wire contract over HTTP (harness boots a fresh pabrik per test):

  - GET  /api/config/pabrik returns top-level `sub_agents: null` always;
    each profile carries its own `sub_agents` inside `profiles`.
  - PUT granular profile update WITHOUT `sub_agents` preserves the
    profile's existing on-disk list (no clobber regression).
  - PUT granular profile update WITH `sub_agents` replaces the
    profile's list wholesale.
  - PUT strips the deprecated on-disk top-level `sub_agents` key
    after migrating its entries into profiles missing their own list.
"""

from __future__ import annotations

import json

from harness import FunctionalHarness
from pabrik_config_test import config_harness  # noqa: F401  (shared fixture)


SA = {
    "name": "reviewer",
    "model": "gpt-4o",
    "base_url": "https://api.openai.com/v1",
    "thinking": "true",
    "temperature": "0.3",
    "url_style": "openai",
    "api_key": "reviewer-key",
    "system_prompt": "You are a strict code reviewer.",
}


def _profiles(h) -> dict:
    r = h.http("GET", "/api/config/pabrik", expect=200).json()
    assert r.get("sub_agents") is None, (
        f"top-level sub_agents must be null on the wire, got: {r.get('sub_agents')!r}"
    )
    return r.get("profiles") or {}


def test_per_profile_subagents_round_trip_via_object_map(
    config_harness: FunctionalHarness,
) -> None:
    """PUT object-map shape with a profile carrying `sub_agents` → GET
    shows the list under that profile and null at the top level."""
    config_harness.http(
        "PUT",
        "/api/config/pabrik",
        json_body={
            "profiles": {
                "stub": {
                    "model": "stub-model",
                    "base_url": "http://127.0.0.1:1",
                    "api_key": "stub-key-not-real",
                    "url_style": "openai",
                    "sub_agents": [SA],
                },
            },
        },
        expect=200,
    )
    profiles = _profiles(config_harness)
    assert profiles["stub"].get("sub_agents") == [SA]


def test_granular_update_without_subagents_preserves_list(
    config_harness: FunctionalHarness,
) -> None:
    """Granular `update` that omits `sub_agents` must NOT wipe the
    profile's existing list (clobber regression)."""
    config_harness.http(
        "PUT",
        "/api/config/pabrik",
        json_body={
            "profiles": {
                "stub": {
                    "model": "stub-model",
                    "base_url": "http://127.0.0.1:1",
                    "api_key": "stub-key-not-real",
                    "url_style": "openai",
                    "sub_agents": [SA],
                },
            },
        },
        expect=200,
    )
    # Granular update touches only the model; sub_agents omitted.
    config_harness.http(
        "PUT",
        "/api/config/pabrik",
        json_body={
            "profiles": [
                {
                    "name": "stub",
                    "action": "update",
                    "model": "stub-model-v2",
                    "base_url": "http://127.0.0.1:1",
                    "thinking": "auto",
                    "temperature": "auto",
                    "url_style": "openai",
                    "api_key": "stub-key-not-real",
                },
            ],
        },
        expect=200,
    )
    profiles = _profiles(config_harness)
    assert profiles["stub"].get("model") == "stub-model-v2"
    assert profiles["stub"].get("sub_agents") == [SA], (
        "granular update without sub_agents wiped the profile's list"
    )


def test_granular_update_with_subagents_replaces_list(
    config_harness: FunctionalHarness,
) -> None:
    """Granular `update` WITH `sub_agents` replaces the profile's list."""
    config_harness.http(
        "PUT",
        "/api/config/pabrik",
        json_body={
            "profiles": {
                "stub": {
                    "model": "stub-model",
                    "base_url": "http://127.0.0.1:1",
                    "api_key": "stub-key-not-real",
                    "url_style": "openai",
                    "sub_agents": [SA],
                },
            },
        },
        expect=200,
    )
    sa2 = dict(SA, name="helper", system_prompt="You help.")
    config_harness.http(
        "PUT",
        "/api/config/pabrik",
        json_body={
            "profiles": [
                {
                    "name": "stub",
                    "action": "update",
                    "model": "stub-model",
                    "base_url": "http://127.0.0.1:1",
                    "thinking": "auto",
                    "temperature": "auto",
                    "url_style": "openai",
                    "api_key": "stub-key-not-real",
                    "sub_agents": [sa2],
                },
            ],
        },
        expect=200,
    )
    profiles = _profiles(config_harness)
    assert profiles["stub"].get("sub_agents") == [sa2]


def _candidate_config_paths(h):
    """Every config.json location the server might read on this box.

    The harness pre-installs the stub profile at ALL of these paths
    (see `harness.py::_write_stub_llm_profile`), but the server's
    `getDefaultConfigDir` is platform-specific (Linux → `.config`,
    macOS → `Library/Application Support`, Windows → `AppData`).
    A test that edits/asserts exactly ONE path breaks whenever its
    guess disagrees with the server (the macOS CI failure this
    replaces: the file the test read still had `selected_profile_model`
    + the legacy list, proving the server wrote elsewhere).
    Seed/assert across all candidates instead of guessing one.
    """
    return [
        h.temp_dir / ".config" / "pabrik" / "config.json",
        h.temp_dir / "Library" / "Application Support" / "pabrik" / "config.json",
        h.temp_dir / "AppData" / "Roaming" / "pabrik" / "config.json",
    ]


def test_put_strips_deprecated_top_level_key_from_disk(
    config_harness: FunctionalHarness,
) -> None:
    """A PUT save migrates a legacy on-disk top-level `sub_agents`
    array into profiles missing their own list, then strips the key."""
    # Seed the legacy shape into EVERY candidate path so the migration
    # triggers no matter which path the server reads on this platform.
    # Fresh-harness stubs carry no per-profile `sub_agents`, so popping
    # is a no-op that documents the legacy precondition.
    seeded = 0
    for cfg_path in _candidate_config_paths(config_harness):
        if not cfg_path.exists():
            continue
        try:
            disk = json.loads(cfg_path.read_text())
        except Exception:
            continue
        if not isinstance(disk.get("profiles_models"), dict):
            continue
        disk["sub_agents"] = [SA]
        for prof in disk["profiles_models"].values():
            if isinstance(prof, dict):
                prof.pop("sub_agents", None)
        cfg_path.write_text(json.dumps(disk))
        seeded += 1
    assert seeded > 0, "harness stub config missing at every candidate path"

    config_harness.http("PUT", "/api/config/pabrik", json_body={}, expect=200)

    # Wire contract first (platform-independent): the stub profile must
    # show the migrated list and the top level must read null. If this
    # passes but no disk path shows migration, the server wrote outside
    # the isolated HOME — the disk loop below reports exactly that.
    profiles = _profiles(config_harness)
    assert profiles.get("stub", {}).get("sub_agents") == [SA], (
        f"stub profile missing migrated sub_agents via GET: {profiles.get('stub')!r}"
    )

    # Disk contract: whichever candidate path(s) the server actually
    # wrote show the migrated stub AND a stripped top-level key (Zig
    # Stringify emits `"sub_agents": null` for the stripped key rather
    # than omitting it — assert null, not absent). Paths the server
    # never touched retain the seeded legacy shape and are skipped.
    migrated_paths = []
    for cfg_path in _candidate_config_paths(config_harness):
        if not cfg_path.exists():
            continue
        try:
            disk_after = json.loads(cfg_path.read_text())
        except Exception:
            continue
        stub = (disk_after.get("profiles_models") or {}).get("stub") or {}
        if [s.get("name") for s in (stub.get("sub_agents") or [])] != ["reviewer"]:
            continue
        migrated_paths.append(cfg_path)
        # Zig Stringify emits `"sub_agents": null` for the stripped key
        # (null optional) rather than omitting it — assert null, not absent.
        assert disk_after.get("sub_agents") is None, (
            f"deprecated top-level key must be stripped to null on {cfg_path}, "
            f"got: {disk_after.get('sub_agents')!r}"
        )
    assert migrated_paths, (
        "PUT migrated via GET but no candidate disk path shows the migrated "
        "stub — server wrote outside the isolated HOME?"
    )
