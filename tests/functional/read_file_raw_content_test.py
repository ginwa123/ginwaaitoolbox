"""read_file returns raw content (no per-line number prefixes).

Task: i-think-we-dont-need-line-number-in-content-output.
The `read_file` tool used to prefix every line with a padded line number
(`"   1\\t..."`). Positioning is already carried by `start_line` /
`end_line` / `total_lines`, so the prefix was redundant token spend and a
copy-paste hazard (LLM copying `"  12\\tfoo"` into write_file/text_replace).

A full end-to-end LLM agent run is too heavy for a wire test (it needs a
stub LLM returning a tool_call), so this file verifies the wire-visible
half — the same strategy as command_tool_test.py — while the exec-level
raw-content contract is pinned by the Zig tests in
src/modules/agent/tools/read_file.zig ("returns raw content without
line-number prefixes", "paginated slice is raw ...", "toXMLSuccess
envelope carries raw content ..."):

  * REGISTRY — GET /api/agent-tools/registry exposes `read_file` whose
    description documents raw content (no "prefixed with its line number"
    promise). This is the exact JSON body the frontend receives for tool
    definitions.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \
      python3 -m pytest tests/functional/read_file_raw_content_test.py -v
"""

from __future__ import annotations

from harness import FunctionalHarness


def _registry(harness: FunctionalHarness) -> list[dict]:
    r = harness.http("GET", "/api/agent-tools/registry", expect=200)
    body = r.json()
    tools = body.get("tools")
    assert isinstance(tools, list), f"registry should be {{tools: list}}, got {body!r}"
    return tools


class TestReadFileRawContent:
    def test_registry_read_file_description_documents_raw_content(
        self, harness: FunctionalHarness
    ) -> None:
        """read_file description promises raw content, not prefixed lines."""
        tools = _registry(harness)
        descs = {t["name"]: t.get("description", "") for t in tools}
        assert "read_file" in descs, f"registry missing read_file; got {sorted(descs)!r}"
        desc: str = descs["read_file"]
        assert "prefixed with its line number" not in desc, (
            f"read_file description still promises prefixed lines: {desc!r}"
        )
        assert "Each returned line is prefixed" not in desc, (
            f"read_file description still promises prefixed lines: {desc!r}"
        )
        assert "raw" in desc.lower(), (
            f"read_file description should document raw content, got: {desc!r}"
        )
        assert "start_line" in desc, (
            f"read_file description should point at start_line for positioning, got: {desc!r}"
        )
