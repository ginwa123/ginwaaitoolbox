"""Wire tests for the data the `list_sub_agent` agent tool reads.

What this covers
================
`list_sub_agent` (`src/modules/agent/tools/list_sub_agent.zig`,
`executeListSubAgent`) is a pure function over the session profile's
`sub_agents` list: it echoes `<profile>`, counts non-empty names into
`<count>`, renders each row's tuning verbatim, emits the FULL
`system_prompt` inside CDATA (never truncated, `]]>` split), omits
null optional tags, and NEVER emits `api_key`/`base_url`.

There is NO HTTP hook that executes the tool or returns its
`<list_sub_agent>` envelope: the only production caller is the exec
adapter (`tools_exec_list_sub_agent.zig`), which runs exclusively
inside the LLM agentic loop and therefore needs live LLM API
credentials (unavailable in this environment). So these tests drive
the strongest feasible path without creds — the same approach as
`agent_add_mcp_server_test.py`:

  1. Seed per-profile `sub_agents` via `PUT /api/config/pabrik`
     (object-map shape, the settings-UI path).
  2. `GET /api/config/pabrik` back and assert the round-tripped rows
     carry byte-for-byte the exact fields `executeListSubAgent`
     reads (`name`, `model`, `url_style`, `thinking`, `temperature`,
     optional tuning knobs, `system_prompt`).

What this does NOT cover (needs LLM creds)
==========================================
The `<list_sub_agent>...</list_sub_agent>` / `<empty/>` XML envelope
itself is never produced here — no chat completion is issued. That
envelope IS covered by the Zig unit tests inline in
`list_sub_agent.zig` (populated 2-row, null-omission, empty-name
skip, unknown-profile `<empty/>`, empty-name `<empty/>`,
secrets-absence, `]]>` CDATA split, no-truncation). A regression in
the envelope rendering would fail `zig build test`, not this file.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \
      python3 -m pytest tests/functional/list_sub_agent_test.py -v
"""

from __future__ import annotations

from harness import FunctionalHarness
from pabrik_config_test import config_harness  # noqa: F401  (shared fixture)

LONG_PROMPT = (
    "You are a strict code reviewer with deep expertise in systems programming, "
    "testing, refactoring, and mentoring junior engineers across many languages. "
    "Always explain the why behind every finding."
)

# A prompt containing the CDATA terminator the tool must split on the wire
# (`]]><![CDATA[>`). Seeded here so the round-trip proves the exact bytes
# the splitter consumes survive config persistence verbatim.
SPLIT_PROMPT = "First half ]]> second half with <tags> & \"quotes\"."

TUNED_AGENT = {
    "name": "coder",
    "model": "gpt-4o",
    "base_url": "https://api.openai.com/v1",
    "thinking": "on",
    "temperature": "0.2",
    "url_style": "openai",
    "api_key": "coder-key-not-real",
    "system_prompt": LONG_PROMPT,
    "max_capacity_tokens": 128000,
    "compaction_threshold_percent": 80,
    "reasoning_effort": "high",
}

# All-null optionals: mirrors the tool's "sparse row" unit fixture. Omitted
# keys must round-trip as absent-or-null (never invented defaults), because
# the tool treats absent tags as 'inherits the profile default'.
SPARSE_AGENT = {
    "name": "helper",
    "model": "",
    "base_url": "",
    "thinking": "",
    "temperature": "",
    "url_style": "",
    "api_key": "",
    "system_prompt": SPLIT_PROMPT,
}


def _put_profile(h: FunctionalHarness, profile: str, sub_agents: list) -> None:
    h.http(
        "PUT",
        "/api/config/pabrik",
        json_body={
            "profiles": {
                profile: {
                    "model": "stub-model",
                    "base_url": "http://127.0.0.1:1",
                    "api_key": "stub-key-not-real",
                    "url_style": "openai",
                    "sub_agents": sub_agents,
                },
            },
        },
        expect=200,
    )


def _profile_agents(h: FunctionalHarness, profile: str) -> list:
    body = h.http("GET", "/api/config/pabrik", expect=200).json()
    assert body.get("sub_agents") is None, (
        "top-level sub_agents must stay null (per-profile only), "
        f"got: {body.get('sub_agents')!r}"
    )
    profiles = body.get("profiles") or {}
    assert profile in profiles, f"profile {profile!r} missing: {sorted(profiles)}"
    return profiles[profile].get("sub_agents") or []


def test_populated_profile_round_trips_tool_inputs_verbatim(
    config_harness: FunctionalHarness,
) -> None:
    """Two seeded rows come back with the exact fields the tool renders.

    Covers test spec (1): names/count/full prompt verbatim/tuning
    present, plus spec (3): the >80-char prompt has no truncation
    marker — the full tail ("the why behind every finding.") must be
    present, and no "..." marker may appear inside the prompt.
    """
    _put_profile(config_harness, "stub", [TUNED_AGENT, SPARSE_AGENT])
    agents = _profile_agents(config_harness, "stub")

    assert [a.get("name") for a in agents] == ["coder", "helper"]
    assert len(agents) == 2

    coder = agents[0]
    assert coder.get("model") == "gpt-4o"
    assert coder.get("thinking") == "on"
    assert coder.get("temperature") == "0.2"
    assert coder.get("url_style") == "openai"
    assert coder.get("max_capacity_tokens") == 128000
    assert coder.get("compaction_threshold_percent") == 80
    assert coder.get("reasoning_effort") == "high"
    # Full prompt verbatim: head, middle, AND tail (a truncating
    # implementation would drop the tail).
    assert coder.get("system_prompt") == LONG_PROMPT
    assert len(coder.get("system_prompt")) > 80
    assert "the why behind every finding." in coder.get("system_prompt")
    assert "..." not in coder.get("system_prompt"), (
        "truncation marker inside round-tripped prompt: "
        f"{coder.get('system_prompt')!r}"
    )


def test_sparse_row_null_optionals_stay_absent_or_null(
    config_harness: FunctionalHarness,
) -> None:
    """Omitted tuning knobs must not gain invented defaults in storage.

    The tool renders optional tags ONLY when non-null; a GET that
    materialises `0`/`""`/defaults here would change the tool's output
    shape (phantom tags) versus what was seeded.
    """
    _put_profile(config_harness, "stub", [TUNED_AGENT, SPARSE_AGENT])
    agents = _profile_agents(config_harness, "stub")

    helper = next(a for a in agents if a.get("name") == "helper")
    for key in (
        "max_capacity_tokens",
        "compaction_threshold_percent",
        "thinking_budget_tokens",
        "reasoning_effort",
    ):
        assert helper.get(key) is None, (
            f"sparse row gained a default for {key!r}: {helper.get(key)!r}"
        )
    # The CDATA-terminator bytes survive persistence verbatim so the
    # tool's `]]><![CDATA[>` splitter sees the exact input it handles
    # in its unit tests.
    assert helper.get("system_prompt") == SPLIT_PROMPT


def test_empty_profile_yields_no_rows(
    config_harness: FunctionalHarness,
) -> None:
    """A profile with no subagents round-trips zero rows, no error.

    This is the storage precondition for the tool's `<empty/>`
    branch (empty list after seeding nothing). The envelope itself
    is covered by Zig unit tests; here we prove the wire state the
    branch reads is reachable and error-free over HTTP.
    """
    _put_profile(config_harness, "stub", [])
    agents = _profile_agents(config_harness, "stub")
    assert agents == []


def test_secrets_confined_to_their_own_keys(
    config_harness: FunctionalHarness,
) -> None:
    """Secret VALUES are confined to `api_key`/`base_url` keys only.

    Honesty note: `GET /api/config/pabrik` is the settings API and
    legitimately returns `api_key`/`base_url` (the settings UI needs
    them — cf. `subagents_per_profile_test.py`, whose fixture asserts
    the secrets round-trip). The no-leak contract belongs to the
    TOOL's `<list_sub_agent>` envelope, which is covered by the Zig
    unit tests (`executeListSubAgent: never emits api_key/base_url
    tags or values`). What this test proves at the wire level is the
    precondition that makes that exclusion well-defined: the marker
    secret values appear ONLY as the values of the `api_key` /
    `base_url` keys, never smeared into the fields the tool renders
    (`name`, `model`, `system_prompt`, tuning knobs) — so an envelope
    built from exactly these fields cannot leak them.
    """
    _put_profile(
        config_harness,
        "stub",
        [
            dict(
                TUNED_AGENT,
                api_key="sk-live-secret-marker-xyz",
                base_url="https://secret-host-marker-xyz.example/v1",
            ),
        ],
    )
    agents = _profile_agents(config_harness, "stub")
    assert len(agents) == 1
    row = agents[0]
    # Seeding worked: the secrets are present under their own keys.
    assert row.get("api_key") == "sk-live-secret-marker-xyz"
    assert row.get("base_url") == "https://secret-host-marker-xyz.example/v1"
    # ... and absent from every field the tool renders into the envelope.
    for key in (
        "name",
        "model",
        "url_style",
        "thinking",
        "temperature",
        "reasoning_effort",
        "system_prompt",
    ):
        val = row.get(key)
        assert isinstance(val, str)
        assert "sk-live-secret-marker-xyz" not in val, f"secret in {key!r}"
        assert "secret-host-marker-xyz" not in val, f"secret host in {key!r}"
    for key in (
        "max_capacity_tokens",
        "compaction_threshold_percent",
        "thinking_budget_tokens",
    ):
        assert not isinstance(row.get(key), str), (
            f"numeric knob {key!r} unexpectedly a string: {row.get(key)!r}"
        )
