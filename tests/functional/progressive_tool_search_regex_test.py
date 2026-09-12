"""Functional tests for `search_tool`'s regex + paging contract.

Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search-regex.md

What is verifiable at the real wire (booted binary, isolated HOME, no live LLM):

  * `GET /api/agent-tools/registry` is built from
    `tools_equipped.UNIFIED_TOOL_REGISTRY()` — the SAME source the workflow
    reads to fill the LLM's `tools[]`. So `search_tool`'s description asserted
    here is byte-for-byte what the model is sent (after JSON decoding), which
    is what makes this the right level to lock the "why regex / why paging"
    wording: a regression that drops it from the schema changes model
    behaviour, and no in-process test can see that.

  * The matching itself (regex vs literal, the invalid-pattern fallback,
    limit/offset windows) is covered where it is reachable:
    `src/agentic_loop/progressive_catalog.zig` (pure matcher) and
    `src/agentic_loop/tools_exec_progressive_tools.zig` (the real adapter over
    the real registry + a real `:memory:` DB). There is no HTTP route that
    dispatches an agent tool and the harness has no stub LLM server, so the
    wire test deliberately stops at the registry payload rather than pretending
    to exercise the agent loop.

Run:
    pytest tests/functional/progressive_tool_search_regex_test.py -v
"""

from __future__ import annotations

import json
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


def test_search_tool_description_teaches_regex_with_a_reason(harness: FunctionalHarness) -> None:
    """The model-facing description must say WHAT (regex, literal) and WHY.

    The WHY is the point of the feature: a substring query cannot express "any
    MCP create-tool on any server" or "this capability under either spelling",
    and the model only reaches for a pattern if the description gives it the
    examples. Asserting the examples (not just the word "regex") is what keeps
    the justification from being edited away later.
    """
    tools = _registry(harness)
    assert "search_tool" in tools, f"search_tool missing from registry: {sorted(tools)}"
    desc = tools["search_tool"]["description"]

    # WHAT: regex by default, with the literal escape hatch.
    assert "REGEX" in desc
    assert "case-insensitive" in desc
    assert "literal: true" in desc
    assert "view_tool" in desc  # the existing workflow hint must survive

    # WHY: concrete patterns, one per reason the substring form cannot serve.
    assert "^mcp_.*_create" in desc, "the anchored/wildcard example is gone"
    assert "doc|documentation" in desc, "the alternation example is gone"
    assert "\\bsearch\\b" in desc, "the word-boundary example is gone"
    # The reason itself, in words — the registry carries the tool-level
    # description (the `query` PARAM description is not exposed by any HTTP
    # route, so its wording is locked by the inline schema tests instead).
    assert "one pattern reaches a capability spelled several ways" in desc


def test_search_tool_description_documents_paging_for_big_catalogs(harness: FunctionalHarness) -> None:
    """A catalog full of MCP tools must not be dumped into the context window.

    `limit`/`offset` exist for exactly that, so the description has to say so —
    otherwise the model treats a 40-row page as the whole catalog and gives up
    on the tool it was looking for.
    """
    tools = _registry(harness)
    desc = tools["search_tool"]["description"]

    assert "PAGED" in desc
    assert "limit" in desc and "offset" in desc
    assert "total" in desc  # the true count is what makes paging navigable


def test_registry_payload_is_json_clean_and_search_tool_stayed_in_it(harness: FunctionalHarness) -> None:
    """Guard the envelope shape the frontend/LLM consume.

    The endpoint returns `{tools: [{name, description}]}`; both progressive
    meta-tools must remain listed (they are ordinary tools as far as the
    registry is concerned), and the payload must round-trip through JSON —
    which is where a stray control character in a hand-written description
    would surface.
    """
    raw = harness.http("GET", "/api/agent-tools/registry", expect=200).body
    parsed = json.loads(raw)
    names = [t["name"] for t in parsed["tools"]]
    assert names == sorted(names) or "search_tool" in names
    assert {"search_tool", "view_tool", "use_tool"}.issubset(set(names))
    # No raw control bytes smuggled into the JSON string fields.
    for t in parsed["tools"]:
        assert t["description"].strip() == t["description"]
        assert "\x08" not in t["description"], f"stray backspace in {t['name']!r} description"
