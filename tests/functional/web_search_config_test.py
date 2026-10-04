"""Functional tests for the `web_search` provider config (plan
2026-10-02-web-search-tool.md, matrix rows 72-73 + the mask contract).

Covers the three things a unit test cannot see, because they only exist on
the wire:

  1. PUT persists a two-provider map and GET reflects it.
  2. GET returns each `key` MASKED — the credential must not reach the
     browser, and this is the only place that proves it end to end.
  3. PUT of a whole config WITHOUT a `web_search` key (a Settings save
     from another tab) does NOT erase the providers from disk. This is the
     PUT-strip footgun `config_tools_test.py` already covers for `tools`;
     the same class of bug for the new key would silently delete a user's
     API key.
  4. PUT with a malformed provider → 400 naming the provider and the
     reason, disk untouched. Without this the entry would be `warn`-logged
     and DROPPED at load, and the symptom would be "Settings shows a
     provider, the agent says none are configured".
  5. PUT with an EMPTY key omits the field rather than storing "" —
     `SqliteBackend.exec` binds an empty slice as SQL NULL.
  6. PUT echoing the MASK back preserves the stored credential.

Each test boots a fresh pabrik against an isolated tmpdir HOME via the
shared preboot fixture. Ports come from the harness's random picker
(never 8081).
"""

from __future__ import annotations

import json

import pytest

from config_tools_test import PROFILE, _on_disk, _platform_config_dir, preboot  # noqa: F401

# The `preboot` fixture is imported rather than redefined: it is the
# platform-correct seeding path, and a second copy would drift.

TINYFISH = {
    "url": "https://api.search.tinyfish.ai",
    "key": "sk-tinyfish-secret-value",
    "curl": 'https://api.search.tinyfish.ai?query=PLACEHOLDER&location=US -H "X-API-Key: {key}"',
    "description": "Best for news.",
}

BRAVE = {
    "url": "https://api.search.brave.com",
    "key": "sk-brave-secret-value",
    "curl": 'https://api.search.brave.com/res/v1/web/search?q=PLACEHOLDER -H "X-Subscription-Token: {key}"',
}


def _base_config(**extra) -> dict:
    cfg = {"profiles_models": {"p1": dict(PROFILE)}, "active_profile": "p1"}
    cfg.update(extra)
    return cfg


def _settings_body(web_search_marker=...):
    """The whole-config shape PabrikSettings.vue sends on Save."""
    body = {
        "profiles": {"p1": dict(PROFILE)},
        "active_profile": "p1",
        "mcp_servers": None,
        "notify_on_complete": False,
        "notify_on_error": False,
        "web_launch_enabled": False,
        "model_compaction_size_kb": 100,
        "max_capacity_token_model": None,
        "compaction_threshold_percent": None,
        "retry_delay_ms": 0,
    }
    if web_search_marker is not ...:
        body["web_search"] = web_search_marker
    return body


# ─── (a) PUT persists and GET reflects ────────────────────────────────────


def test_web_search_round_trips_through_put_and_get(preboot) -> None:
    h = preboot(_base_config())

    r = h.http("PUT", "/api/config/pabrik", json_body=_settings_body({"tinyfish": TINYFISH, "brave": BRAVE}), expect=200).json()
    assert r.get("success") in (True, None) or "error" not in r or not r.get("error"), f"PUT failed: {r!r}"

    got = h.http("GET", "/api/config/pabrik", expect=200).json()
    ws = got.get("web_search")
    assert isinstance(ws, dict), f"web_search missing or not an object: {got!r}"
    assert set(ws) == {"tinyfish", "brave"}, f"provider names did not round-trip: {ws!r}"
    assert ws["tinyfish"]["url"] == TINYFISH["url"]
    assert ws["tinyfish"]["description"] == TINYFISH["description"]
    # The template round-trips with its {key} placeholder intact.
    assert "{key}" in ws["tinyfish"]["curl"]


# ─── (b) GET MASKS the credential ─────────────────────────────────────────


def test_get_masks_the_api_key(preboot) -> None:
    """The single most important assertion in this file: the credential
    must not appear anywhere in the GET response body."""
    h = preboot(_base_config(web_search={"tinyfish": TINYFISH, "brave": BRAVE}))

    r = h.http("GET", "/api/config/pabrik", expect=200)
    raw = r.body.decode("utf-8", "replace")
    assert TINYFISH["key"] not in raw, "the real TinyFish key leaked through GET"
    assert BRAVE["key"] not in raw, "the real Brave key leaked through GET"

    ws = r.json()["web_search"]
    # Masked, but still recognisable as a mask so the Settings form can
    # round-trip it back as "unchanged".
    assert "…" in ws["tinyfish"]["key"], f"expected a mask, got {ws['tinyfish']['key']!r}"


def test_get_masks_a_short_key_without_leaking_it_entirely(preboot) -> None:
    """A 6-character key masked as `abc…xyz` would leak 6 of 6 characters —
    worse than leaking none. Anything under 10 chars gets a fixed-length
    marker instead."""
    short = {
        "url": "https://api.example.com",
        "key": "sk1234",
        "curl": 'https://api.example.com?q=PLACEHOLDER -H "X-Api-Key: {key}"',
    }
    h = preboot(_base_config(web_search={"short": short}))

    r = h.http("GET", "/api/config/pabrik", expect=200)
    assert "sk1234" not in r.body.decode("utf-8", "replace"), (
        "a short key leaked in full through the mask"
    )
    ws = r.json()["web_search"]["short"]
    assert ws["key"] != "sk1234"
    assert len(ws["key"]) <= 8, f"mask should not reveal the length: {ws['key']!r}"


# ─── (c) A Settings save from ANOTHER tab must not erase the providers ────


def test_settings_save_without_web_search_does_not_erase_it(preboot) -> None:
    """The PUT-strip footgun. If `web_search` is missing from the write
    struct, every save from another Settings tab silently deletes the
    user's API key — with no error anywhere."""
    h = preboot(_base_config(web_search={"tinyfish": TINYFISH}))

    # Save from "another tab": no web_search key in the body.
    h.http("PUT", "/api/config/pabrik", json_body=_settings_body(), expect=200)

    disk = _on_disk(h)
    assert "web_search" in disk, "web_search was erased from disk by an unrelated save"
    assert disk["web_search"]["tinyfish"]["key"] == TINYFISH["key"], "the credential was lost"


def test_masked_key_round_trips_back_as_unchanged(preboot) -> None:
    """The Settings form echoes the MASK on save. If PUT stored that, the
    user would overwrite their own credential with four dots the first time
    they changed an unrelated setting."""
    h = preboot(_base_config(web_search={"tinyfish": TINYFISH}))

    masked = h.http("GET", "/api/config/pabrik", expect=200).json()["web_search"]["tinyfish"]["key"]
    assert masked != TINYFISH["key"]

    echoed = dict(TINYFISH)
    echoed["key"] = masked
    h.http("PUT", "/api/config/pabrik", json_body=_settings_body({"tinyfish": echoed}), expect=200)

    assert _on_disk(h)["web_search"]["tinyfish"]["key"] == TINYFISH["key"], (
        "PUT stored the mask over the real credential"
    )


# ─── (d) A malformed provider is a 400, not a silent drop ────────────────


@pytest.mark.parametrize(
    "bad,expect_in_message",
    [
        ({"key": "k", "curl": "https://e.com?q=X"}, "url"),
        ({"url": "http://e.com", "curl": "https://e.com?q=X"}, "https"),
        ({"url": "https://127.0.0.1", "curl": "https://127.0.0.1?q=X"}, "loopback"),
        ({"url": "https://169.254.169.254", "curl": "https://169.254.169.254/q"}, "link-local"),
        ({"url": "https://e.com"}, "curl"),
        (
            {"url": "https://e.com", "key": "k", "curl": "https://e.com?q=X"},
            "{key}",
        ),
        (
            {"url": "https://e.com", "curl": 'curl -X POST https://e.com?q=X -H "A: {key}"'},
            "GET",
        ),
    ],
)
def test_malformed_provider_is_rejected_with_a_useful_message(preboot, bad, expect_in_message) -> None:
    h = preboot(_base_config())

    r = h.http("PUT", "/api/config/pabrik", json_body=_settings_body({"broken": bad}), expect=400).json()
    message = r.get("error") or ""
    assert "broken" in message, f"the 400 does not name the offending provider: {message!r}"
    assert expect_in_message in message, f"the 400 does not say what is wrong: {message!r}"
    assert "web_search" not in _on_disk(h), "a rejected provider was still written to disk"


# ─── (e) An empty key is OMITTED, never stored as "" ──────────────────────


def test_empty_key_is_omitted_not_stored_as_empty_string(preboot) -> None:
    """`SqliteBackend.exec` binds `""` as SQL NULL, and an empty string is
    exactly the shape that survives a JSON round-trip while meaning unset."""
    h = preboot(_base_config())

    no_auth = {
        "url": "https://search.example.net",
        "key": "",
        "curl": "https://search.example.net/search?q=PLACEHOLDER",
    }
    h.http("PUT", "/api/config/pabrik", json_body=_settings_body({"searxng": no_auth}), expect=200)

    stored = _on_disk(h)["web_search"]["searxng"]
    assert "key" not in stored, f'an empty credential was stored: {stored!r}'


# ─── (f) GET reports an absent key as absent, not as an empty map ─────────


def test_get_reports_web_search_null_when_absent(preboot) -> None:
    h = preboot(_base_config())

    r = h.http("GET", "/api/config/pabrik", expect=200).json()
    assert "web_search" in r, "the key must be PRESENT so the frontend can tell 'not configured' from 'field never shipped'"
    assert r["web_search"] is None, f"expected null, got {r['web_search']!r}"
