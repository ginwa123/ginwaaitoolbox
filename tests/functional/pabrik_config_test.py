"""Functional tests for pabrik config (Tier 1.7).

Exercises the pabrik config HTTP surface:

  - GET  /api/config/pabrik                  (returns stub profile on disk)
  - PUT  /api/config/pabrik                  (round-trip + missing-fields 400)
  - DELETE /api/config/pabrik/profiles/:name (removes from list + 404 unknown
                                            + doesn't touch other profiles)

The harness boots pabrik with `stub_llm_profile=True` which pre-installs
a `stub` profile at `<temp_dir>/.config/pabrik/config.json` (see
`harness.py:_write_stub_llm_profile`). That stub profile is what
GET/PUT/DELETE operate on.

Each test boots a fresh pabrik (function-scoped fixture).
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


# ─── Custom harness fixture ───────────────────────────────────────────────


@pytest.fixture
def config_harness(default_pabrik_bin) -> FunctionalHarness:
    """Boot pabrik with `stub_llm_profile=True` so the harness
    pre-installs a `stub` profile (see `harness.py::_write_stub_llm_profile`).

    Platform-aware config directory: the harness writes the stub
    config to `<HOME>/.config/pabrik/` (Linux convention), but
    pabrik's `getDefaultConfigDir` is platform-specific:
      - macOS   → `<HOME>/Library/Application Support/pabrik/`
      - Linux   → `<XDG_CONFIG_HOME or HOME/.config>/pabrik/`
      - Windows → `<APPDATA>/pabrik/`

    On macOS the harness-written file is at the wrong path, so
    GET returns `profiles: null`. We copy the file to the macOS
    path before boot so pabrik can find it.
    """
    import os
    import platform
    import shutil

    h = FunctionalHarness.boot(
        default_pabrik_bin,
        stub_llm_profile=True,
    )

    # macOS: copy the Linux-style stub config to the macOS path so
    # pabrik can find it at boot (and so PUT/GET round-trip the
    # same file we DELETE later).
    if platform.system() == "Darwin":
        linux_cfg = h.temp_dir / ".config" / "pabrik" / "config.json"
        mac_cfg = h.temp_dir / "Library" / "Application Support" / "pabrik" / "config.json"
        if linux_cfg.exists():
            mac_cfg.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(linux_cfg, mac_cfg)

    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


# ─── Test 1: GET /api/config/pabrik returns the stub profile ─────────────


def test_get_pabrik_config_returns_stub_profile(
    config_harness: FunctionalHarness,
) -> None:
    """GET /api/config/pabrik → 200 with `profiles_models` map that
    contains the harness-installed `stub` profile.
    """
    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = r.get("profiles") or {}
    assert "stub" in profiles, (
        f"harness-installed 'stub' profile missing from response: {list(profiles.keys())}"
    )
    stub = profiles["stub"]
    assert stub.get("model") == "stub-model"
    assert stub.get("base_url") == "http://127.0.0.1:1"


# ─── Test 2: PUT /api/config/pabrik round-trips a new profile ─────────────


def test_put_pabrik_config_round_trips_a_new_profile(
    config_harness: FunctionalHarness,
) -> None:
    """PUT a fresh `profiles_models` object → GET returns the new
    profile. Existing fields (stub) are replaced wholesale by the
    on-disk PUT body (PUT is a full replace).
    """
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "new-profile": {
                "model": "new-model",
                "base_url": "https://new.example.com",
                "api_key": "new-key",
                "url_style": "openai",
            },
        },
        "active_profile": "new-profile",
    }
    config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=200,
    )

    # GET returns the new profile.
    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = r.get("profiles") or {}
    assert "new-profile" in profiles, (
        f"PUT'd profile missing from GET: {list(profiles.keys())}"
    )
    assert profiles["new-profile"].get("model") == "new-model"
    assert r.get("active_profile") == "new-profile"


# ─── Test 3: PUT /api/config/pabrik rejects invalid JSON body ────────────


def test_put_pabrik_config_rejects_invalid_json(
    config_harness: FunctionalHarness,
) -> None:
    """PUT with `{not json}` → 400 'Invalid JSON input'."""
    import urllib.request

    # Send a malformed body via raw bytes (the helper requires JSON).
    req = urllib.request.Request(
        f"http://127.0.0.1:{config_harness.port}/api/config/pabrik",
        data=b"{not json}",
        method="PUT",
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=5.0)
        pytest.fail("expected 400 for malformed JSON body")
    except urllib.error.HTTPError as e:
        assert e.code == 400, f"expected 400, got {e.code}"
        body = e.read().decode("utf-8", errors="replace")
        assert "Invalid JSON" in body, (
            f"400 should mention 'Invalid JSON', got: {body!r}"
        )


# ─── Test 4: PUT /api/config/pabrik with empty body still succeeds ────────


def test_put_pabrik_config_empty_body_preserves_existing(
    config_harness: FunctionalHarness,
) -> None:
    """PUT `{}` → 200; an empty body has all fields defaulted, which
    means the existing on-disk config is read first and the empty
    PUT's defaulted fields (api_endpoint='', model='', etc.) are
    applied as 'no change' (the apply block only updates when len > 0).
    The `stub` profile (installed by the harness) survives.
    """
    config_harness.http("PUT", "/api/config/pabrik", json_body={}, expect=200)

    # The stub profile is still present (PUT {} doesn't wipe it).
    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = r.get("profiles") or {}
    assert "stub" in profiles, (
        f"stub profile missing after PUT {{}}: {list(profiles.keys())}"
    )


# ─── Test 5: DELETE /api/config/pabrik/profiles/stub removes it ──────────


def test_delete_profile_removes_it_from_list(
    config_harness: FunctionalHarness,
) -> None:
    """DELETE /api/config/pabrik/profiles/stub → 200; GET no longer
    contains the `stub` profile.

    The 200 response body is `{success, profile_name,
    active_profile_was_cleared, error_message?}` per
    `pabrik_config_profile_delete.zig`.
    """
    r = config_harness.http(
        "DELETE",
        "/api/config/pabrik/profiles/stub",
        expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("profile_name") == "stub"

    # GET confirms the profile is gone.
    after = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = after.get("profiles") or {}
    assert "stub" not in profiles, (
        f"deleted profile 'stub' still in profiles: {list(profiles.keys())}"
    )


# ─── Test 6: DELETE profile returns 404 for unknown name ────────────────


def test_delete_profile_404_for_unknown_name(
    config_harness: FunctionalHarness,
) -> None:
    """DELETE /api/config/pabrik/profiles/no-such-profile → 404.

    The handler returns `{success: false, profile_name, error_message}`
    with HTTP 404 when the profile is not found.
    """
    r = config_harness.http(
        "DELETE",
        "/api/config/pabrik/profiles/no-such-profile",
        expect=404,
    ).json()
    assert r.get("success") is False
    assert r.get("profile_name") == "no-such-profile"
    assert r.get("error_message") is not None, (
        f"404 should include an error_message, got: {r!r}"
    )


# ─── Test 7: DELETE one profile doesn't touch the others ───────────────


def test_delete_one_profile_does_not_touch_others(
    config_harness: FunctionalHarness,
) -> None:
    """PUT {profiles: {A: {...}, B: {...}}}, DELETE A → B survives.

    Tests that DELETE is scoped to a single name and the rest of
    the profiles_models map is preserved.
    """
    # Set up two profiles via PUT.
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "k",
        "model": "m",
        "url_style": "openai",
        "profiles": {
            "A": {
                "model": "model-a",
                "base_url": "https://a.example.com",
                "api_key": "k-a",
                "url_style": "openai",
            },
            "B": {
                "model": "model-b",
                "base_url": "https://b.example.com",
                "api_key": "k-b",
                "url_style": "openai",
            },
        },
        "active_profile": "B",
    }
    config_harness.http("PUT", "/api/config/pabrik", json_body=put_body, expect=200)

    # DELETE only A.
    r = config_harness.http(
        "DELETE", "/api/config/pabrik/profiles/A", expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("profile_name") == "A"
    assert r.get("active_profile_was_cleared") is False, (
        f"active_profile is B (not A), so was_active should be False; "
        f"got {r!r}"
    )

    # GET confirms: A gone, B survives.
    after = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = after.get("profiles") or {}
    assert "A" not in profiles, f"A should be deleted, got {list(profiles.keys())}"
    assert "B" in profiles, f"B should survive, got {list(profiles.keys())}"
    assert profiles["B"].get("model") == "model-b"


# ─── Test 8: DELETE active_profile clears the active_profile field ─────


def test_delete_active_profile_clears_active_profile_field(
    config_harness: FunctionalHarness,
) -> None:
    """PUT {active_profile: 'target'}, DELETE /profiles/target →
    `active_profile_was_cleared: true` and the field is null on GET.
    """
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "k",
        "model": "m",
        "url_style": "openai",
        "profiles": {
            "target": {
                "model": "target-model",
                "base_url": "https://target.example.com",
                "api_key": "k-t",
                "url_style": "openai",
            },
        },
        "active_profile": "target",
    }
    config_harness.http("PUT", "/api/config/pabrik", json_body=put_body, expect=200)

    # DELETE the active profile.
    r = config_harness.http(
        "DELETE", "/api/config/pabrik/profiles/target", expect=200,
    ).json()
    assert r.get("success") is True
    assert r.get("active_profile_was_cleared") is True, (
        f"active profile was deleted; should be True, got {r!r}"
    )

    # GET confirms: active_profile is null.
    after = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    assert after.get("active_profile") is None, (
        f"active_profile should be null after deleting it, got {after.get('active_profile')!r}"
    )