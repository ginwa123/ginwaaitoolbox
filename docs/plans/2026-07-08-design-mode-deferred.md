# Design Mode v6 — Deferred Items

> **Status:** Documented 2026-07-15 at the close of the v6 redesign (Chunks 1-9
> shipped, smoke test green). These 12 items were explicitly scoped OUT of
> v6 — they're listed here so future plans have a single entrypoint for
> follow-up work.
>
> **Source:** Section 14 ("Out-of-scope follow-ups") of the design doc at
> `docs/plans/2026-07-08-design-mode-redesign-design.md`. Tier numbering
> uses the docs' convention:
>
> - **Tier 2** = v6 ship (already done)
> - **Tier 3** = next-pass feature work (after v6 ships, before v7)
> - **Tier 4** = speculative / major-project scope
>
> Each item below says which tier it belongs to and why it was deferred
> (so a future reader can decide whether to pull it into their plan).

---

## 1. Multi-page export (zip)

**What:** Bundle a design's pages + element HTML into a downloadable
`.zip` file (`/api/design/:item_id/export` → `application/zip`).

**Why deferred:** No user demand yet — the design folder is
already file-backed (`<item.path>/.nalar/design/<page>/<elem>.html`)
so a power user can `tar`/`cp` it themselves. Until there's a
real ask for a UI button, shipping an extra endpoint + zip writer
is speculative work.

**Tier:** **3** — trivial pull-forward when a user reports they
want a "Download" button.

---

## 2. HTML sanitizer (DOMPurify)

**What:** Sanitize the element HTML body on write and/or render to
strip `<script>`, `on*` handlers, and other XSS vectors.

**Why deferred:** The v6 iframe already runs each element's HTML
in a sandboxed `<iframe sandbox="allow-same-origin">` (per §3 and
§7 of the design doc). The sandbox makes cross-frame script
execution impossible, which neutralizes the largest attack class.
Adding DOMPurify on top would be defense-in-depth, not security
critical. The design doc explicitly says "revisit if sandbox
proves insufficient" — sandbox hasn't been proven insufficient yet.

**Tier:** **3** — add only when a security audit or penetration
test surfaces an actual cross-frame leak.

---

## 3. iframe → parent `postMessage` for runtime error reporting

**What:** Each element iframe `try { ... } catch (e) { parent.postMessage({type:'design:error', e: String(e)}, '*') }`
swallows + reports errors instead of dying silently.

**Why deferred:** Phase-1 testing showed iframe errors are rare
(most user HTML is well-formed) and visible in DevTools when they
do happen. A `postMessage` channel adds a listener in Vue
(`window.addEventListener('message', ...)`) that the Vue
side then has to surface somewhere — UI cost without a current
user-visible benefit.

**Tier:** **3** — wire up when the design-debugger use case lands
(a way to inspect per-element runtime state from the parent UI).

---

## 4. Page-level permissions

**What:** Per-page ACL — some users can edit pages A and B but
have read-only access to page C; "share for review" links with
expiry tokens.

**Why deferred:** nalar's workspaces today have NO per-item
permission model (everything is `workspace_id` + `created_by`).
Adding page-level permissions before workspace-level permissions
would create two parallel security models that have to be
maintained in lockstep. The right order is to ship workspace
permissions first (next major task), then page-level as a simple
subset.

**Tier:** **4** — requires the (also-tier-4) workspace permissions
model first.

---

## 5. Page templates

**What:** A library of pre-built page templates ("Empty 1440×1024",
"Onboarding flow", "Settings page", "Dashboard with cards") that
users can pick from in the page-create dialog.

**Why deferred:** The current `design_pages_create` defaults
already provide a single sane template (1440×1024 canvas with
`width=1440 height=1024` named "Untitled"). A template LIBRARY
needs: a templates table, a seed script, a picker UI, version
tracking. None of that is justified by current usage where every
fresh design starts from a single 1440×1024 blank.

**Tier:** **3** — build when ≥3 distinct user personas ask for
distinct page layouts (currently they're all "blank canvas").

---

## 6. Visual edit mode (full WYSIWYG overlay — already partial via contenteditable)

**What:** A full design-mode WYSIWYG where the user sees element
bounding boxes overlaid on the rendered iframe, can drag/resize
visually, and the iframe updates in real time as they type.

**Why deferred:** Partially in v6 — the iframe's own
`contenteditable` lets the user type live (that's §7.1 item 6).
What's MISSING is a parent-side overlay rendering the design
metadata (selection box, drag handles) ON TOP of the iframe so
the user can drag without first clicking into the iframe to focus
it. That's a Canvas-like UX — significant Vue/component work for
what's currently a workable iframe-and-then-properties workflow.

**Tier:** **3** — upgrade the contenteditable-only path when the
"can't drag without clicking in first" friction becomes a common
complaint.

---

## 7. Real-time multiplayer / CRDT

**What:** Multiple users / multiple agents editing the same design
simultaneously, with operational-transform or Yjs-style conflict
resolution so two simultaneous `<p>Hello</p>` + `<p>World</p>`
edits don't clobber each other.

**Why deferred:** This is a major-project scope. It needs:
- A websocket connection per design (currently no socket infra).
- A CRDT layer on top of every HTML body (operational-transform
  text OR a Y.Array of DOM ops).
- Permissions (tier 4 — depends on page-level, which depends on
  workspace-level).
- Conflict resolution UI ("Alice and Bob both edited the same
  paragraph — keep yours, theirs, or merge?").
- LLM-side considerations (an agent streaming 50 edits in parallel
  with a user is a 50× conflict-resolution nightmare).

**Tier:** **4** — speculative, multi-month project with its own
design doc.

---

## 8. WebGL renderer

**What:** Replace the current DOM `<div>`-per-element canvas with a
WebGL-based renderer that can handle 1000+ elements per page at 60fps.

**Why deferred:** §5 of the design doc and the original v6 decision
log both explicitly say "Vue 3 DOM is sufficient for ≤100
elements/frame". The tier-2 soft limit is 100 elements/page with a
non-enforced warning. Until real user designs need >100 elements AND
the DOM path becomes a perf bottleneck (not just a warning), investing
in a WebGL renderer is throwing complexity at a problem that doesn't
exist yet. The benchmarks needed to validate the cutoff are
themselves significant work.

**Tier:** **4** — premature optimization until ≥100 elements/page
becomes common and the DOM path measurably lags.

---

## 9. Vector pen tool

**What:** A Bézier pen path tool to draw arbitrary vector shapes
(svg `<path d="...">`), distinct from the rectangle / ellipse
primitives currently supported (`<rect>`/`<ellipse>` only).

**Why deferred:** Adds a new element type (`vector`) that needs:
- Storage schema (the `path` data string lives where? — the
  existing `html` body, the `design_page_elements` columns, or a
  new table?).
- Render side (SVG `<path>` inside the iframe, plus bbox
  computation for hit-testing).
- Edit side (Bézier handle manipulation — at minimum a
  Canvas-overlay editor like Figma's pen tool; basically its own
  Vue component).
- LLM tool surface (the current `update_element` tool can update
  a `<rect>`'s x/y/width/height but can't author a Bézier path).
Each of these is a chunk-sized piece of work; combined, they
double the v6 scope.

**Tier:** **4** — large, multi-chunk project with its own design doc.

---

## 10. Auto-layout (flexbox for nodes)

**What:** A constraint-based layout engine where elements define
"stack vertically" / "space evenly horizontally" relationships
and the renderer computes actual positions on the fly (similar to
Figma's "Auto Layout" or SwiftUI's H/V/ZStack).

**Why deferred:** Conflicts with the v6 decision log's
canvas-interaction model = Tier 2 (manual drag/resize only). To ship
auto-layout properly, the storage schema needs a `layout_mode`
column on `design_page_elements` (none/none/horizontal/vertical),
every element needs a `layout_grow` flag, the SQL UPDATE path
needs to recompute positions across siblings on every drag — all
of which complicates every interaction in the current canvas.
Best saved for "Figma Tier 4" once Tier 2 manual layout is
well-understood and the user-facing pain is concrete.

**Tier:** **4** — significant rework of Tier 2 interaction model.

---

## 11. Component system with variants

**What:** A way for users to mark a set of elements as a "component"
(call it "Button"), save it to a component library, then drag
instances of it onto any page. Each instance can override
properties (variant = "primary" / "secondary"). Editing the
master propagates to all instances.

**Why deferred:** Requires:
- A new `components` + `component_variants` table pair.
- A "components panel" UI panel alongside the existing layers
  panel.
- An instance-vs-master data model (the instance stores a
  reference + overrides, not a copy).
- LLM-side considerations (the `update_element` tool would need a
  new `update_component` mode that targets all instances).

This is essentially Figma's "Components" feature, which is multi-year
work at Figma's scale and multi-month even for a tier-3 subset.

**Tier:** **4** — major feature, multi-month project.

---

## 12. Plugin system

**What:** Allow third-party developers to ship custom element
types (e.g. a "Chart" element that renders Chart.js inside the
iframe) or custom LLM tools (e.g. "ai_summarize_design" that
calls a different LLM provider with the design HTML as context)
via a stable API.

**Why deferred:** The v6 surface is intentionally small (3 LLM
tools, 6 element types, 9 HTTP endpoints). Until we know which
extensibility hooks users actually NEED, an open plugin system
would have to expose every surface point — element types,
LLM tool types, storage hooks, SSE event hooks — and maintenance
burden scales with surface area, not adoption. Once there's a
clear top-3 "if I could plug X in I'd use nalar more" ask, design
the plugin surface for THOSE three.

**Tier:** **4** — speculative, requires a separate "platform vs
product" design doc.

---

## Tier summary

| Tier | Count | Items |
|---|---|---|
| 3 (next pass) | 5 | Multi-page export, HTML sanitizer, postMessage, page templates, visual edit mode |
| 4 (speculative) | 7 | Page permissions, multiplayer/CRDT, WebGL renderer, vector pen, auto-layout, components, plugins |

Items 4, 7, 8, 9, 10, 11, 12 (the tier-4 bucket) are NOT scoped for
the v6 → v7 work plan. Pull them into separate design docs before
proposing implementation tasks.

---

**File location:** `docs/plans/2026-07-08-design-mode-deferred.md`
(per the plan's Task 9.4).
**Plan reference:** `docs/superpowers/plans/2026-07-08-design-mode-redesign.md` (Chunk 9).
**Design doc reference:** `docs/plans/2026-07-08-design-mode-redesign-design.md` §14.
