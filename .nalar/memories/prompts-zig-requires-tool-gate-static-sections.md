# prompts.zig — static prompt sections must declare `.requires_tool` for conditional headers

## Symptom

A test like `build_agent_prompt omits GlobalMemorySystem section when list_memory tool is absent` (in `prompts_test.zig`) fails intermittently — passes in one seed, fails in another. Once new tests are added that touch the same prompt-rendering path, the test starts failing consistently. The static section's `## Some Header` keeps rendering into the prompt even when the relevant tool is NOT in the session's tool list.

## Root cause

`build_agent_prompt` in `src/ai_workflow/tui/prompts.zig` declares its static sections as a list of `Section` entries. A section's `.name` and `.content` are unconditional — the `## Global Memory System` header (or `## Dynamic Properties`, `## Cloakbrowser`, etc.) is appended for every session unless the section also sets `.requires_tool = "<tool_name>"`. Line 173 (the canonical `global_memory_system` case) declared the section with no tool gate, so the header leaked into sessions without `list_memory`.

Zig's test runner uses a randomized seed; failure order between independent tests varies. The "omits GlobalMemorySystem" test happened to pass in the initial seed run by luck, then started failing once the Available Skills tests were added and changed the ordering.

## Fix

Add `.requires_tool = "list_memory"` to the section declaration, matching the gating pattern already used by `dynamic_properties` (`set_agent_properties`) and `cloakbrowser` (`browse`):

```zig
.{
    .name = "global_memory_system",
    .content = GlobalMemorySystem,
    .requires_tool = "list_memory",  // ← one-line addition
}
```

The `appendSection` helper then checks `hasTool(tools, section.requires_tool)` and skips the section (including its header) when the gate fails.

## Pitfalls

- **Do NOT change the test** when this pattern surfaces — the test's name (`omits X section when Y tool is absent`) documents the intended behavior. Fix the static config.
- This is a test-validates-intent pattern: the test asserts the contract the code should implement; if the test exists but the code doesn't satisfy it, the code is wrong.
- Same one-line `.requires_tool` fix applies to ANY static section that should be tool-gated. Search for section declarations without a `.requires_tool` field if you suspect a similar leak.
- Lazy analysis may mask related errors in `zig build test` — verify with a full `zig build` (after `rm -rf zig-out/bin`) if the test passes but the integration fails.

## Verification

After the fix:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 5
```

Expect the conditional test to pass consistently across seeds (run multiple times to confirm). The reported good state was 252/255 tests pass (up from 251/255 with 1 flake).

## Related

- `zig-build-and-test.md` — lazy-analysis pitfall; `zig build test` may pass while `install:linux:system` still hides the bug behind cached compile artifacts.
- `prompts.zig::appendSkillsListing` — the dynamic-sibling helper that DOES gate on `list_skills` via `hasTool` at runtime; mirrors this static-section pattern.
- The test name itself is the contract: when a test asserts `omits X when Y is absent` but the code doesn't gate, the code is the bug.