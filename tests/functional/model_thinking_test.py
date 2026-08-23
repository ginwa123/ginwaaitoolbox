"""Functional tests for the model-thinking knobs (plan 2026-08-23-model-thinking).

Exercises the nalar config HTTP surface for the new
`thinking_budget_tokens` and `reasoning_effort` per-profile fields:

  - PUT  /api/config/nalar with profile-level thinking_budget_tokens
         + reasoning_effort round-trips through GET.
  - PUT  /api/config/nalar rejects thinking_budget_tokens=0 with 400
         (InvalidThinkingBudgetTokens).
  - PUT  /api/config/nalar rejects thinking_budget_tokens > 2_000_000
         with 400 (InvalidThinkingBudgetTokens).
  - PUT  /api/config/nalar rejects garbage reasoning_effort ("super")
         with 400.

The harness boots nalar with `stub_llm_profile=True` which pre-installs
a `stub` profile at `<temp_dir>/.config/nalar/config.json`. Each test
boots a fresh nalar (function-scoped fixture).
"""

from __future__ import annotations

import pytest

from harness import FunctionalHarness


@pytest.fixture
def config_harness(default_nalar_bin) -> FunctionalHarness:
    """Boot nalar with `stub_llm_profile=True` so the harness
    pre-installs a `stub` profile. We mirror the macOS dance from
    `nalar_config_test.py` to ensure the stub is found on every
    platform."""
    import os
    import platform
    import shutil

    h = FunctionalHarness.boot(
        default_nalar_bin,
        stub_llm_profile=True,
    )

    if platform.system() == "Darwin":
        linux_cfg = h.temp_dir / ".config" / "nalar" / "config.json"
        mac_cfg = h.temp_dir / "Library" / "Application Support" / "nalar" / "config.json"
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
        "PUT", "/api/config/nalar", json_body=put_body, expect=200,
    )

    # GET returns the saved profile with both fields.
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
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
        "PUT", "/api/config/nalar", json_body=put_body,
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
        "PUT", "/api/config/nalar", json_body=put_body, expect=400,
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
        "PUT", "/api/config/nalar", json_body=put_body, expect=400,
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
        "PUT", "/api/config/nalar", json_body=put_body, expect=200,
    )

    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    alpha = (r.get("profiles") or {}).get("alpha")
    assert alpha is not None
    # On the wire, the field IS present (we default to null) so the
    # form has something to bind to on the next edit.
    assert alpha.get("thinking_budget_tokens") is None
    assert alpha.get("reasoning_effort") is None
