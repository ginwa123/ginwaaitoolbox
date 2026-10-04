"""Functional tests for the model-thinking knobs (plan 2026-08-23-model-thinking).

Exercises the pabrik config HTTP surface for the new
`thinking_budget_tokens` and `reasoning_effort` per-profile fields:

  - PUT  /api/config/pabrik with profile-level thinking_budget_tokens
         + reasoning_effort round-trips through GET.
  - PUT  /api/config/pabrik rejects thinking_budget_tokens=0 with 400
         (InvalidThinkingBudgetTokens).
  - PUT  /api/config/pabrik rejects thinking_budget_tokens > 2_000_000
         with 400 (InvalidThinkingBudgetTokens).
  - PUT  /api/config/pabrik rejects garbage reasoning_effort ("super")
         with 400.

The harness boots pabrik with `stub_llm_profile=True` which pre-installs
a `stub` profile at `<temp_dir>/.config/pabrik/config.json`. Each test
boots a fresh pabrik (function-scoped fixture).
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


@pytest.fixture
def config_harness(default_pabrik_bin) -> FunctionalHarness:
    """Boot pabrik with `stub_llm_profile=True` so the harness
    pre-installs a `stub` profile. We mirror the macOS dance from
    `pabrik_config_test.py` to ensure the stub is found on every
    platform."""
    import os
    import platform
    import shutil

    h = FunctionalHarness.boot(
        default_pabrik_bin,
        stub_llm_profile=True,
    )

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


# ─── Test 1: PUT round-trips thinking_budget_tokens + reasoning_effort ──────


def test_profile_thinking_budget_and_effort_round_trip(
    config_harness: FunctionalHarness,
) -> None:
    """PUT a profile with both new knobs → GET returns the same values.

    This is the core "the wire shape works" test for the feature.
    Without it, a frontend save would silently drop the user's
    configuration.
    """
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "alpha": {
                "model": "claude-test",
                "base_url": "https://api.example.com",
                "api_key": "alpha-key",
                "thinking": "on",
                "temperature": "auto",
                "url_style": "anthropic",
                "thinking_budget_tokens": 4096,
                "reasoning_effort": "high",
            }
        },
    }
    config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=200,
    )

    # GET returns the saved profile with both fields.
    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = r.get("profiles") or {}
    assert "alpha" in profiles, (
        f"PUT'd profile missing from GET: {list(profiles.keys())}"
    )
    alpha = profiles["alpha"]
    assert alpha.get("thinking_budget_tokens") == 4096, (
        f"thinking_budget_tokens round-trip failed: "
        f"got {alpha.get('thinking_budget_tokens')!r}"
    )
    assert alpha.get("reasoning_effort") == "high", (
        f"reasoning_effort round-trip failed: "
        f"got {alpha.get('reasoning_effort')!r}"
    )


# ─── Test 2: PUT rejects thinking_budget_tokens=0 ────────────────────────


def test_profile_thinking_budget_zero_rejected(
    config_harness: FunctionalHarness,
) -> None:
    """thinking_budget_tokens=0 violates Anthropic's 1024 floor. Backend
    rejects with HTTP 400 and an error body mentioning the field name."""
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "alpha": {
                "model": "claude-test",
                "base_url": "https://api.example.com",
                "api_key": "alpha-key",
                "url_style": "anthropic",
                "thinking_budget_tokens": 0,
            }
        },
    }
    # We don't pin the exact error code/message — the handler returns
    # error.InvalidThinkingBudgetTokens which the HTTP layer maps
    # to 400 with a body. We just verify it's a 400 and the body
    # mentions either "InvalidThinkingBudgetTokens" or "thinking_budget".
    response = config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body,
        expect=400,  # we'll check the status code manually
    )
    assert response.status == 400, (
        f"Expected 400 for thinking_budget_tokens=0, got "
        f"{response.status}: {response.body.decode('utf-8', errors='replace')[:200]}"
    )
    body = response.body.decode('utf-8', errors='replace')
    assert "thinking_budget" in body.lower() or "invalidthinking" in body.lower(), (
        f"Error body should mention the bad field; got: {body[:200]}"
    )


# ─── Test 3: PUT rejects thinking_budget_tokens > 2_000_000 ───────────────


def test_profile_thinking_budget_too_large_rejected(
    config_harness: FunctionalHarness,
) -> None:
    """thinking_budget_tokens > 2_000_000 would violate Anthropic's
    strict-less-than-max_tokens rule for any reasonable max_tokens.
    Backend rejects with HTTP 400."""
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "alpha": {
                "model": "claude-test",
                "base_url": "https://api.example.com",
                "api_key": "alpha-key",
                "url_style": "anthropic",
                "thinking_budget_tokens": 3_000_000,  # > 2_000_000 cap
            }
        },
    }
    response = config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=400,
    )
    assert "thinking_budget" in response.body.decode('utf-8', errors='replace').lower(), (
        f"Error body should mention the bad field; got: {response.body.decode('utf-8', errors='replace')[:200]}"
    )


# ─── Test 4: PUT rejects garbage reasoning_effort ────────────────────────


def test_profile_reasoning_effort_invalid_value_rejected(
    config_harness: FunctionalHarness,
) -> None:
    """reasoning_effort outside {low, medium, high, auto} is rejected.
    Backend returns HTTP 400 with InvalidReasoningEffort in the body."""
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "alpha": {
                "model": "o1-test",
                "base_url": "https://api.example.com",
                "api_key": "alpha-key",
                "url_style": "openai",
                "reasoning_effort": "super",  # not in the 4-value set
            }
        },
    }
    response = config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=400,
    )
    body = response.body.decode('utf-8', errors='replace')
    assert "reasoning_effort" in body.lower() or "invalidreasoning" in body.lower(), (
        f"Error body should mention the bad field; got: {body[:200]}"
    )


# ─── Test 5: omitted fields default to null on round-trip ─────────────────


def test_profile_thinking_knobs_default_to_null_when_omitted(
    config_harness: FunctionalHarness,
) -> None:
    """Backward compatibility: a profile without the new fields must
    parse cleanly with both fields as null (not missing)."""
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "alpha": {
                "model": "claude-test",
                "base_url": "https://api.example.com",
                "api_key": "alpha-key",
                "thinking": "auto",
                "temperature": "auto",
                "url_style": "anthropic",
                # No thinking_budget_tokens / reasoning_effort here.
            }
        },
    }
    config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=200,
    )

    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    alpha = (r.get("profiles") or {}).get("alpha")
    assert alpha is not None
    # On the wire, the field IS present (we default to null) so the
    # form has something to bind to on the next edit.
    assert alpha.get("thinking_budget_tokens") is None
    assert alpha.get("reasoning_effort") is None


# ─── Test 6: explicit JSON null for the new fields is accepted ──────────
# Regression test for the "cannot save profile" bug (task_1787586032476_9)
# where PUT /api/config/pabrik returned 400 InvalidThinkingBudgetTokens
# for legitimate `null` values. Root cause: the on-disk shape validator
# (`validateModelThinkingOnDiskProfileMap` in
# pabrik_config_put.zig) used a `switch` whose `else` arm rejected any
# non-integer JSON value, including `.null`. JSON `null` IS the
# legitimate "no override" sentinel for both
# `thinking_budget_tokens` (matches `LlmProfile.thinking_budget_tokens:
# ?u32 = null` in Config.zig) and `reasoning_effort` (matches
# `LlmProfile.reasoning_effort: ?[]const u8 = null`). The fix: a single
# `.null => {}` arm added to each switch.


def test_profile_thinking_budget_null_is_accepted(
    config_harness: FunctionalHarness,
) -> None:
    """Single profile with `thinking_budget_tokens: null` (and a valid
    `reasoning_effort` string) round-trips through PUT → GET. Pre-fix
    this returned 400 InvalidThinkingBudgetTokens.
    """
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "alpha": {
                "model": "claude-test",
                "base_url": "https://api.example.com",
                "api_key": "alpha-key",
                "url_style": "anthropic",
                "thinking_budget_tokens": None,  # the explicit-null case
                "reasoning_effort": "high",
            }
        },
    }
    config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=200,
    )

    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    alpha = (r.get("profiles") or {}).get("alpha")
    assert alpha is not None
    assert alpha.get("thinking_budget_tokens") is None, (
        f"thinking_budget_tokens=null did not round-trip; "
        f"got {alpha.get('thinking_budget_tokens')!r}"
    )
    assert alpha.get("reasoning_effort") == "high"


def test_profile_reasoning_effort_null_is_accepted(
    config_harness: FunctionalHarness,
) -> None:
    """Single profile with `reasoning_effort: null` (and a valid
    `thinking_budget_tokens` integer) round-trips through PUT → GET.
    Pre-fix this returned 400 InvalidReasoningEffort.
    """
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "beta": {
                "model": "o1-test",
                "base_url": "https://api.example.com",
                "api_key": "beta-key",
                "url_style": "openai",
                "thinking_budget_tokens": 4096,
                "reasoning_effort": None,  # the explicit-null case
            }
        },
    }
    config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=200,
    )

    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    beta = (r.get("profiles") or {}).get("beta")
    assert beta is not None
    assert beta.get("thinking_budget_tokens") == 4096
    assert beta.get("reasoning_effort") is None, (
        f"reasoning_effort=null did not round-trip; "
        f"got {beta.get('reasoning_effort')!r}"
    )


def test_multiple_profiles_with_null_thinking_budget_is_accepted(
    config_harness: FunctionalHarness,
) -> None:
    """The user's exact bug case: 5 profiles where most have
    `thinking_budget_tokens: null` (and `reasoning_effort: null`).
    Only one profile sets non-null values. All 5 must be saved in one
    PUT. Pre-fix this returned 400 on the first profile whose
    `thinking_budget_tokens` was null, aborting the save entirely.

    This is the EXACT scenario the user reported — the curl in the
    task ticket `task_1787586032476_9` had 5 profiles with these
    shapes and the save was rejected.
    """
    put_body = {
        "api_endpoint": "https://api.example.com",
        "api_key": "test-key",
        "model": "test-model",
        "url_style": "openai",
        "profiles": {
            "p1-nothing": {
                "model": "m", "base_url": "https://x", "api_key": "k1",
                "url_style": "openai",
                "thinking_budget_tokens": None,
                "reasoning_effort": None,
            },
            "p2-just-budget": {
                "model": "m", "base_url": "https://x", "api_key": "k2",
                "url_style": "anthropic",
                "thinking_budget_tokens": 1024,
                "reasoning_effort": None,
            },
            "p3-just-effort": {
                "model": "m", "base_url": "https://x", "api_key": "k3",
                "url_style": "openai",
                "thinking_budget_tokens": None,
                "reasoning_effort": "high",
            },
            "p4-both-set": {
                "model": "m", "base_url": "https://x", "api_key": "k4",
                "url_style": "anthropic",
                "thinking_budget_tokens": 8192,
                "reasoning_effort": "medium",
            },
            "p5-both-null-again": {
                "model": "m", "base_url": "https://x", "api_key": "k5",
                "url_style": "openai",
                "thinking_budget_tokens": None,
                "reasoning_effort": None,
            },
        },
    }
    config_harness.http(
        "PUT", "/api/config/pabrik", json_body=put_body, expect=200,
    )

    # All 5 user-supplied profiles survive the PUT. The harness-installed
    # `stub` profile may also be present (PUT replaces the map, but
    # the harness's pre-installed profile is read back into the merge
    # target before the new map overwrites — see
    # `pabrik_config_put.zig:179-187`). Either way the 5 user profiles
    # MUST all be present.
    r = config_harness.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = r.get("profiles") or {}
    for expected_name in (
        "p1-nothing", "p2-just-budget", "p3-just-effort", "p4-both-set", "p5-both-null-again"
    ):
        assert expected_name in profiles, (
            f"PUT'd profile {expected_name!r} missing from GET; got {sorted(profiles.keys())}"
        )

    # Spot-check the null fields round-trip.
    assert profiles["p1-nothing"]["thinking_budget_tokens"] is None
    assert profiles["p1-nothing"]["reasoning_effort"] is None
    assert profiles["p5-both-null-again"]["thinking_budget_tokens"] is None
    assert profiles["p5-both-null-again"]["reasoning_effort"] is None
    # And the non-null fields round-trip too.
    assert profiles["p2-just-budget"]["thinking_budget_tokens"] == 1024
    assert profiles["p3-just-effort"]["reasoning_effort"] == "high"
    assert profiles["p4-both-set"]["thinking_budget_tokens"] == 8192
    assert profiles["p4-both-set"]["reasoning_effort"] == "medium"
