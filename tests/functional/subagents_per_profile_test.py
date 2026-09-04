"""Subagents are per-profile only (plan 2026-09-04-subagents-per-profile).

Wire contract over HTTP (harness boots a fresh nalar per test):

  - GET  /api/config/nalar returns top-level `sub_agents: null` always;
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

import pytest

from harness import FunctionalHarness
from nalar_config_test import config_harness  # noqa: F401  (shared fixture)


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
    r = h.http("GET", "/api/config/nalar", expect=200).json()
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
        "/api/config/nalar",
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
        "/api/config/nalar",
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
        "/api/config/nalar",
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
        "/api/config/nalar",
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
        "/api/config/nalar",
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


def test_put_strips_deprecated_top_level_key_from_disk(
    config_harness: FunctionalHarness,
) -> None:
    """A PUT save migrates a legacy on-disk top-level `sub_agents`
    array into profiles missing their own list, then strips the key."""
    cfg_path = (
        config_harness.temp_dir / ".config" / "nalar" / "config.json"
    )
    if not cfg_path.exists():
        pytest.skip("stub config not at Linux path (non-Linux platform?)")
    disk = json.loads(cfg_path.read_text())
    disk["sub_agents"] = [SA]
    # Ensure the stub profile has NO sub_agents key (legacy shape).
    disk["profiles_models"]["stub"].pop("sub_agents", None)
    cfg_path.write_text(json.dumps(disk))

    config_harness.http("PUT", "/api/config/nalar", json_body={}, expect=200)

    disk_after = json.loads(cfg_path.read_text())
    # Zig Stringify emits `"sub_agents": null` for the stripped key
    # (null optional) rather than omitting it — assert null, not absent.
    assert disk_after.get("sub_agents") is None, (
        f"deprecated top-level key must be stripped to null, got: {disk_after.get('sub_agents')!r}"
    )
    migrated = disk_after["profiles_models"]["stub"].get("sub_agents") or []
    assert [s["name"] for s in migrated] == ["reviewer"]
