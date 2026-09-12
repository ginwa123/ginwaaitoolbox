"""Wire tests for the `spawn_sub_agent` required-tools + worktree wording.

What this covers
================
`spawn_sub_agent` (`src/modules/agent/tools/spawn_sub_agent.zig`) now
requires an explicit per-sub-agent `tools` allowlist (missing, empty, or
`["all"]` is a parse error — no omit-means-all) and teaches the
explorer-shares / writer-isolates worktree rule. The model learns both
rules from the tool-level `description`, which is exactly what
`GET /api/agent-tools/registry` exposes (`{tools: [{name,
description}]}` built from `UNIFIED_TOOL_REGISTRY()`, the same source
the workflow fills the LLM's `tools[]` from).

There is NO HTTP hook that executes a spawn: the only production caller
is the exec adapter (`tools_exec_spawn_sub_agent.zig`), which runs
exclusively inside the LLM agentic loop and therefore needs live LLM API
credentials (unavailable in this environment). So these tests drive the
strongest feasible path without creds — the same approach as
`progressive_tool_search_regex_test.py`:

  1. `GET /api/agent-tools/registry`, index by name.
  2. Assert the `spawn_sub_agent` description carries the load-bearing
     sentences (not just keywords), and that the old omit-means-all
     sentence stays dead.

What this does NOT cover (needs LLM creds)
==========================================
The `<results>` envelope for missing/empty/`all` tools is never produced
here — no chat completion is issued. That parse rejection IS covered by
the Zig unit tests inline in `spawn_sub_agent.zig` (MissingSubAgentTools
/ EmptySubAgentTools / AllToolsNotAllowed). A regression in the envelope
rendering would fail `zig build test`, not this file. The `parameters`
schema text and per-tool `system_prompt` are not exposed by any HTTP
route, so their wording is locked by the inline description/prompt tests
in the same Zig file instead.

Run:
    NALAR_BIN=<worktree>/zig-out/bin/nalarcore-linux-x86_64 \
      python3 -m pytest tests/functional/spawn_sub_agent_tools_required_test.py -v
"""

from __future__ import annotations

from typing import Any

from harness import FunctionalHarness


def _registry(h: FunctionalHarness) -> dict[str, dict[str, Any]]:
    """`GET /api/agent-tools/registry` → {name: {name, description}}."""
    body = h.http("GET", "/api/agent-tools/registry", expect=200).json()
    tools = body["tools"]
    assert isinstance(tools, list) and tools, f"empty registry: {body!r}"
    for t in tools:
        assert "name" in t, f"registry entry missing 'name': {t!r}"
        assert "description" in t, f"registry entry missing 'description': {t!r}"
    return {t["name"]: t for t in tools}


def test_spawn_description_requires_explicit_tools(harness: FunctionalHarness) -> None:
    """The model-facing description must demand an explicit allowlist.

    The WHAT is the point of the feature: without this sentence the model
    keeps omitting `tools` and every child silently receives ALL tools.
    Asserting the sentences (not just the word "required") is what keeps
    the rule from being edited away later.
    """
    tools = _registry(harness)
    assert "spawn_sub_agent" in tools, (
        f"spawn_sub_agent missing from registry: {sorted(tools)}"
    )
    desc = tools["spawn_sub_agent"]["description"]

    # WHAT: required explicit allowlist, with the three rejected shapes named.
    assert "REQUIRED, explicit allowlist" in desc
    assert 'Missing, empty, or ["all"] is rejected' in desc
    assert "There is no omit-means-all" in desc
    # The old omit-means-all sentence must stay dead.
    assert "Omit \"tools\" to give the sub-agent access to ALL" not in desc
    # Unknown names are ignored (allowlistFilter), never an error.
    assert "Unknown names are ignored" in desc


def test_spawn_description_teaches_explorer_shares_writer_isolates(
    harness: FunctionalHarness,
) -> None:
    """The description must carry the worktree rule with its trigger.

    Explorer-code (read-only) shares the parent cwd — NO new worktree.
    A writer must be told explicitly in `instruction` to call
    `set_git_worktree` first, work there, then summarize (and optionally
    push). Without the trigger words the model either isolates explorers
    (wasted worktrees) or shares writers (dirty parent checkout).
    """
    tools = _registry(harness)
    desc = tools["spawn_sub_agent"]["description"]

    assert "Explorer-code sub-agent" in desc
    assert "NO new worktree" in desc
    assert "set_git_worktree" in desc
    assert "return a summary of changed files" in desc
    assert "whether it pushed" in desc
