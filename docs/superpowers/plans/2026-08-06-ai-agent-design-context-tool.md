# Plan: AI Agent tools — `get_design_context` + `preview_design_page`

## Goal

Two new LLM agent tools so the agent can **see** and **inspect** the design
canvas without going through bash + read_file:

| Tool | Input | Output |
|---|---|---|
| `get_design_context` | `page_id` (one page) OR `workspace_item_id` (all pages of the design) | Structured XML envelope listing pages + elements + every attribute |
| `preview_design_page` | `page_id` | SVG visualization rendered in the side panel (via existing `show_preview` `html` content-type pipeline) |

The user described these as "the tools its like eye or screenshot for ai agent" —
the agent can look at the design and read its data structure on demand.

## User-facing description

### `get_design_context`

> Inspect the structure of a design canvas. Pass EITHER `page_id` to get one
> page with its elements, OR `workspace_item_id` to get ALL pages of the
> design item. Exactly one of the two must be provided.
>
> Returns an XML envelope:
> ```xml
> <design_context>
>   <pages count="N">
>     <page id="page_X" name="Login" width="1440" height="1024" position="0">
>       <design_page_elements count="M">
>         <element id="..." page_id="..." name="..." type="rectangle"
>                 x="..." y="..." width="..." height="..." rotation="..."
>                 fill="..." stroke="..." corner_radius="..." opacity="..."
>                 text_content="..." image_url="..." parent_id="..."
>                 file_path="..." z_index="..." position="..."
>                 created_at="..." updated_at="..." />
>       </design_page_elements>
>     </page>
>   </pages>
> </design_context>
> ```
>
> Each element attribute matches the wire shape of the design DB row (so the
> agent can spot `x`/`y`/`width`/`height` for layout reasoning, `parent_id`
> for grouping reasoning, `text_content` for content, etc.).
>
> HTML bodies are intentionally NOT included — the agent can read them
> individually with `read_file` if needed (matches the existing
> `set_design_page` convention).

### `preview_design_page`

> Render a design page as an SVG in the side panel so the agent can SEE it.
> Takes `page_id` (required) and an optional `scale` (default 1.0, max 4.0).
>
> Generates an SVG that renders every element on the page:
> - `rectangle` → `<rect>` with fill, stroke, corner_radius, rotation
> - `ellipse` → `<ellipse>` with fill, stroke, rotation
> - `text` → `<text>` with text_content + text_style (font/size)
> - `image` → `<image>` with image_url as href
> - `frame`/`group` → `<g>` container; children render inside the group's bbox
>
> Returns a `<show_preview>` envelope (same shape as the `show_preview` tool),
> so the LLM sees the same success/failure semantics.

## Architecture

Both tools follow the existing tool pattern (5 files each, similar to
`set_design_page` / `show_preview`):

| File | Role |
|---|---|
| `src/modules/agent/tools/get_design_context.zig` | Tool definition (`get_design_context_tool` constant) + `executeGetDesignContextToString` impl |
| `src/modules/agent/tools/get_design_context_test.zig` | Behavioural tests (in-memory SQLite) + static source-check wiring tests |
| `src/modules/agent/tools/preview_design_page.zig` | Tool definition (`preview_design_page_tool` constant) + `executePreviewDesignPageToString` impl |
| `src/modules/agent/tools/preview_design_page_test.zig` | Behavioural tests + static source-check wiring tests |
| `src/ai_workflow/tui/agentic_loop/tools_exec_get_design_context.zig` | Thin `execGetDesignContext(ctx, tc) -> ToolExecResult` wrapper that parses JSON input, calls the impl, wraps the XML envelope |
| `src/ai_workflow/tui/agentic_loop/tools_exec_preview_design_page.zig` | Same pattern for the preview tool |

The impl files live under `src/modules/agent/tools/` (matching `set_design_page.zig`,
`show_preview.zig`); the exec wrappers live under `agentic_loop/` (matching the
existing `tools_exec_*.zig` migration that moved every exec function out of
`tool_registry.zig`).

### Wire integration (4 edits)

1. `src/root.zig` — add two `pub const` aliases (matches the existing pattern
   at line 338-343 where all design tools are listed).
2. `src/ai_workflow/tui/mod.zig` — add the two `pub const` aliases that
   `agentic_loop/tools_equipped.zig` reaches through (`pabrikcore.ai_mod.show_preview`).
3. `src/ai_workflow/tui/agentic_loop/tools.zig` — add two `pub const exec*`
   re-exports (matches the existing line 33-39 pattern).
4. `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` — add two module
   imports + two entries in both the `tools_list` array (line 54) and the
   `UNIFIED_TOOL_REGISTRY()` array (line 165).

### Backend: zero changes

Both tools use the existing `design_model` API (`listPages`,
`getPageWithElements`, `listPagesWithElements`, `listElements`,
`loadElementHtml`) — no DB schema changes, no new HTTP endpoints, no
migrations.

### Frontend: zero changes

The side-panel rendering reuses the existing `PreviewContentRenderer` html
path (sandboxed iframe with `srcdoc`). The chat-history tool-output
component already handles `<show_preview>` envelopes via
`ShowPreview.vue`. The agent's two new tools return envelopes the existing
frontend already understands.

## TDD plan

### Chunk 1 — `get_design_context` (read-only XML)

1. Write `get_design_context_test.zig` with:
   - **Behavioural** (with in-memory SQLite + v6 schema):
     - page_id mode → returns single page + elements in expected XML shape
     - workspace_item_id mode → returns all pages in `position` order
     - exactly-one-of validation: both null → error; both set → error
     - empty pages → `<design_context><pages count="0"></pages>...</design_context>`
     - element attributes mirror the wire shape (x, y, width, height, type,
       rotation, fill, stroke, corner_radius, opacity, text_content,
       image_url, parent_id, file_path, z_index, position, created_at,
       updated_at)
     - empty parent_id renders as `parent_id=""` (NOT omitted — keeps the
       slot visible to the agent)
   - **Static source-check** wiring:
     - tool is in `tools_equipped.zig` `tools_list` + `UNIFIED_TOOL_REGISTRY`
     - tool is in `root.zig` `pub const` aliases
     - exec function is in `tools_exec_get_design_context.zig`
     - exec is re-exported in `agentic_loop/tools.zig`
2. Run the tests → RED (file doesn't exist).
3. Write `get_design_context.zig`:
   - Input struct with `page_id: ?[]const u8` + `workspace_item_id: ?[]const u8`
   - `executeGetDesignContextToString(allocator, db, input) ![]u8` returning
     the XML envelope. Errors wrapped in `<design_context><error>...</error></design_context>`.
   - Internal helper `validateExactlyOne(page_id, workspace_item_id) !?[]u8`
     that returns null on success or an error XML string on failure.
   - `xmlEscape` helper (copy-pasted from `set_design_page.zig` — the
     project convention is local duplication for self-contained tool files).
4. Write `tools_exec_get_design_context.zig` (~50 lines, same shape as
   `tools_exec_set_design_page.zig`):
   - `parseFromSlice` the input
   - call `executeGetDesignContextToString`
   - detect `<error>` substring → wrap with `wrapToolOutput` as failure
   - else wrap with `wrapToolOutput` as success
5. Wire the 4 file edits.
6. Run tests → GREEN.

### Chunk 2 — `preview_design_page` (SVG renderer)

1. Write `preview_design_page_test.zig` with:
   - **Behavioural** (with in-memory SQLite):
     - empty page → returns `<show_preview>...</show_preview>` envelope with
       valid SVG (just the page background)
     - page with 1 rectangle → SVG contains a `<rect>` at the right x/y/w/h
     - page with 1 ellipse → SVG contains `<ellipse>`
     - page with 1 text → SVG contains `<text>` with the text_content
     - page with 1 image → SVG contains `<image>` with image_url href
     - page with nested group → SVG contains `<g>` with children inside
     - `scale=2.0` → SVG width/height are 2x
     - unknown page_id → error envelope
   - **Static source-check** wiring (same 5 wiring assertions).
2. Run tests → RED.
3. Write `preview_design_page.zig`:
   - Input struct: `page_id: []const u8`, `scale: f64 = 1.0`
   - SVG generator: walk `design_page_elements` in z_index/position order
     and emit one SVG element per row (see table above)
   - Wrap in a minimal HTML envelope (the existing `PreviewContentRenderer`
     already wraps it in `<style>html,body{margin:0;...}</style>`)
   - Returns the same `<show_preview>` envelope shape as `show_preview.zig` —
     so the existing frontend pipeline renders it without changes.
   - Internally reuses `show_preview.successEnvelope` to keep the envelope
     shape byte-for-byte consistent.
4. Write `tools_exec_preview_design_page.zig` (~50 lines, same shape).
5. Wire the 4 file edits.
6. Run tests → GREEN.

### Chunk 3 — Cross-platform + final verification

1. `zig build test --summary all` → all tests pass (existing 2168 + new 14ish)
2. `zig build install:linux:system` → builds
3. `rm -rf zig-out/bin && zig build` → both `pabrik` + `pabrik-desktop` produced
4. `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep pabrikcore
   -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig` → clean
5. `zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep pabrikcore
   -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig` → clean
6. Live smoke on port 8080: start `pabrik` with a fresh $HOME, hit
   `POST /api/.../tools/exec` with a `get_design_context` payload, verify
   the response contains the expected XML shape.

## Files

**New (6):**
- `src/modules/agent/tools/get_design_context.zig`
- `src/modules/agent/tools/get_design_context_test.zig`
- `src/modules/agent/tools/preview_design_page.zig`
- `src/modules/agent/tools/preview_design_page_test.zig`
- `src/ai_workflow/tui/agentic_loop/tools_exec_get_design_context.zig`
- `src/ai_workflow/tui/agentic_loop/tools_exec_preview_design_page.zig`

**Modified (4):**
- `src/root.zig` (+2 lines)
- `src/ai_workflow/tui/mod.zig` (+2 lines)
- `src/ai_workflow/tui/agentic_loop/tools.zig` (+2 lines)
- `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (+2 imports + 4 entries)

**Total: 6 new + 4 edits ≈ ~600 lines new code + ~600 lines new tests.**

## Out of scope

- Per-element preview (`preview_design_element`) — deferred; the page
  preview covers most use cases and the LLM can scroll/zoom on the SVG.
- Live `auto_refresh` between agent edits — the LLM calls `preview_design_page`
  explicitly when it wants to re-render.
- 3D / multi-resolution preview — single static SVG is enough for v1.
- Editing the SVG from the agent side — out of scope; the agent edits via
  `add_element` / `update_element` / etc., then calls `preview_design_page`
  again to see the result.