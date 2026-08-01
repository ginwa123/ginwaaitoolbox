# show_preview `html` content_type — Live HTML/CSS Rendering in Side Panel

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `html` as a 5th valid value for `show_preview`'s `content_type`, so the LLM can render full HTML/CSS (and optionally JS) snippets — landing pages, dashboards, prototypes — in the side panel with a live, sandboxed preview.

**Architecture:** Mirror the existing `markdown` / `text` / `code` / `image` content_types. Extend the Zig tool's `validateContentType` enum + schema description, then teach the Vue `PreviewSidePanel` to render `html` inside a `<iframe sandbox="allow-scripts" srcdoc="…">` (the EXACT pattern already used by `DesignElementPreview.vue` for design previews — no new security model to invent). No backend viewport/style work — the iframe fills the panel and the inner HTML scrolls itself.

**Tech Stack:** Zig 0.16 (existing `show_preview.zig`), Vue 3 + `<script setup lang="ts">` (existing `PreviewSidePanel.vue`), Vitest + Vue Test Utils (existing `previewSidePanel.spec.ts`), Zig `std.testing` (existing `show_preview_test.zig`).

## Global Constraints

- **NO static-contract tests** — user rule (2026-07-29). All new tests must be behavioural: call a function and assert the return value, or mount a component and assert the DOM. Pre-existing static tests in `show_preview_test.zig` are grandfathered; do NOT add new ones.
- **Surgical patches only** — don't refactor `show_preview.zig` or `PreviewSidePanel.vue`. Add minimal targeted changes. If the existing `renderedContent` computed branches feel like they need a refactor, leave it for a follow-up.
- **Sandbox must be `allow-scripts`** — matches the existing `DesignElementPreview.vue:148` pattern. Without `allow-scripts`, the preview can't run landing-page JS (animations, React mounts, etc.). The alternative (`sandbox=""` with no flags) is too restrictive for the primary use case.
- **HTML must be attribute-escaped, not sanitized** — the iframe's `srcdoc` attribute accepts HTML. We escape `"`, `&`, `<`, `>` for the attribute value so the attribute itself stays valid; the browser then un-escapes and parses the inner HTML. We do NOT sanitize the HTML (no DOMPurify, no tag whitelist) — the iframe sandbox is the security boundary.
- **1 MiB cap already covers HTML** — `MAX_CONTENT_BYTES = 1024 * 1024` is plenty for any sane landing page. Do NOT raise the cap.
- **Cross-platform** — Zig + Vue paths work identically on Linux/macOS/Windows. No platform-specific code.
- **Existing frontend test conventions** — use `setActivePinia(createPinia())` in `beforeEach` for any `useNotificationStore` mock; mount via `vue-test-utils` `mount()`; assert with `wrapper.html()` / `wrapper.find(...)`.

## File Structure

### Files to modify (surgical patches only)

| File | Why |
|---|---|
| `src/modules/agent/tools/show_preview.zig` | Add `"html"` to `validateContentType`; add `"html"` to `validateContentType`'s error message; add `"html"` to the schema description for `content_type`; add a hint about `html` in the tool-level description. |
| `src/modules/agent/tools/show_preview_test.zig` | Add 3 behavioural tests: (a) `html` accepted by `validateContentType`, (b) `executeShowPreviewToString` returns success envelope for `html` input, (c) `html` content with embedded `<script>` and `</script>` doesn't break the envelope. |
| `src/apps/desktop/src/components/preview/PreviewSidePanel.vue` | Add `html` to the `ICONS` map; add a new computed `htmlContent` (or extend `renderedContent` with a 5th branch); add a `<iframe>` template branch gated on `activeContentType === 'html'`. |
| `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue` | No code change needed — `contentType` is already extracted from the response envelope and falls through to rendering. Verify with the manual test. |
| `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts` | Add 3 behavioural tests: (a) `html` preview renders an iframe, (b) iframe has `sandbox="allow-scripts"` and `srcdoc` containing the user HTML, (c) HTML containing `"` is attribute-escaped in the srcdoc. |
| `docs/agent-tools.md` | Document the new `html` content_type in the `show_preview` section. |
| `docs/SPEC.md` §10.2.1 (PR index) — add a new PR entry for this feature once merged. |

### Files NOT to modify (intentionally out of scope)

- `src/modules/agent/tools/schemas.zig` — `AgentTool` schema is generic; no per-tool changes needed.
- `src/ai_workflow/tui/agentic_loop/tools_exec_show_preview.zig` — the executor is generic; no per-content_type branch.
- `src/apps/desktop/src/components/preview/PreviewSidePanel.vue` resize logic — the iframe just fills the existing flex-1 scroll container.
- `src/apps/desktop/src/components/design/DesignElementPreview.vue` — already implements the iframe pattern; we replicate the pattern but do NOT extract a shared component (would be a follow-up refactor).

---

## Task 1 — Backend: extend `validateContentType` + schema for `html` (TDD)

Wire `html` as a valid content_type in the Zig tool. Test first.

### 1.1 Write the failing test

- [ ] **Open** `src/modules/agent/tools/show_preview_test.zig` and add a new behavioural test at the end of the behavioural-tests section (after the existing UTF-8 test):

```zig
test "validateContentType accepts 'html' alongside the existing 4 types" {
    const alloc = testing.allocator;

    // All 4 pre-existing types must continue to pass.
    try testing.expect(try show_preview.validateContentType(alloc, "markdown") == null);
    try testing.expect(try show_preview.validateContentType(alloc, "text") == null);
    try testing.expect(try show_preview.validateContentType(alloc, "code") == null);
    try testing.expect(try show_preview.validateContentType(alloc, "image") == null);

    // The new "html" type must also pass — this is the fix.
    try testing.expect(try show_preview.validateContentType(alloc, "html") == null);

    // Make sure the new "html" doesn't accidentally accept "htmlx" or similar.
    {
        const err = try show_preview.validateContentType(alloc, "htmlx");
        defer if (err) |e| alloc.free(e);
        try testing.expect(err != null);
    }
}

test "executeShowPreviewToString returns success envelope for html input" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = show_preview.ShowPreviewInput{
        .content_type = "html",
        .content = "<!DOCTYPE html><html><body><h1>Hello</h1></body></html>",
        .title = "Landing page",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>html</content_type>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "executeShowPreviewToString accepts html content with embedded script and closing slashes" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Real-world landing pages have <script> blocks (GA, animations).
    // The tool must accept them and put the content_length in the envelope
    // without truncating the "</script>" sequence.
    const input = show_preview.ShowPreviewInput{
        .content_type = "html",
        .content = "<html><body><script>console.log('hi');</script></body></html>",
        .title = "with script",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    // The XML envelope itself must NOT contain raw "</script>" — the
    // success envelope wraps content in <content_length>NN</content_length>,
    // not in a literal CDATA, so the envelope stays well-formed.
    // (The user's HTML content is NOT embedded in the response — it lives
    //  in the `parameters` field of the llm_history row, not in the XML
    //  envelope returned to the LLM. So there's no XSS surface to test.)
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>html</content_type>") != null);
}
```

- [ ] **Run the tests** to confirm they fail (red):

```bash
timeout 60 zig build test --summary all 2>&1 | tail -n 25
```

Expected output: `validateContentType accepts 'html'...` fails because `validateContentType` doesn't recognize `"html"`; `executeShowPreviewToString returns success envelope for html input` fails because the validator rejects `"html"` and returns an error envelope.

### 1.2 Implement the fix

- [ ] **Open** `src/modules/agent/tools/show_preview.zig` and find the `validateContentType` function (around line 208-220).
- [ ] **Add the `"html"` branch** below the existing `"image"` branch:

```zig
    if (std.mem.eql(u8, content_type, "image")) return null;
    if (std.mem.eql(u8, content_type, "html")) return null;
    return try std.fmt.allocPrint(
        allocator,
        \\invalid content_type '{s}'. Must be one of: "markdown", "text", "code", "image", "html".
    , .{content_type});
```

- [ ] **Update the schema description for `content_type`** (around line 87) to include `html`:

```zig
.description = "One of: \"markdown\", \"text\", \"code\", \"image\", \"html\". Determines how the side panel renders the content.",
```

- [ ] **Update the tool-level description** (around line 75-79) to mention `html` and the iframe sandbox. The description must keep the phrase "side panel" intact (the LLM uses it to pick this tool). Replace the content_type sentence:

```zig
\\The content_type must be one of "markdown", "text", "code", "image", or "html". For "code", you MUST also pass the language field (e.g. "zig", "python", "javascript") so the side panel can apply syntax highlighting. For "html", the content is rendered inside a sandboxed iframe with allow-scripts enabled (no allow-forms, no allow-same-origin) — so it can run JS but cannot read the app's cookies, submit forms, or navigate the parent window. Optional `title` renders above the content (a short heading), and optional `caption` renders below (a longer description). The content payload is capped at 1 MiB; for larger content, split across multiple calls.
```

### 1.3 Verify the tests pass

- [ ] **Run the tests** to confirm they pass (green):

```bash
timeout 60 zig build test --summary all 2>&1 | tail -n 10
```

Expected output: 3 new tests pass; no existing tests regress.

- [ ] **Cross-compile** to confirm Windows + macOS still work:

```bash
timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc src/modules/agent/tools/show_preview.zig 2>&1 | tail -n 5
timeout 60 zig build-obj -fno-emit-bin -target aarch64-macos -lc src/modules/agent/tools/show_preview.zig 2>&1 | tail -n 5
```

Expected output: both exit 0 with no errors.

### 1.4 Commit

- [ ] **Commit** the backend changes:

```bash
git add src/modules/agent/tools/show_preview.zig src/modules/agent/tools/show_preview_test.zig
git commit -m "feat(show_preview): accept 'html' content_type

Backwards-compatible: the existing 4 content_types (markdown, text, code,
image) continue to work unchanged. The new 'html' value lets the LLM render
full HTML pages (landing pages, dashboards, prototypes) in the side panel.

The frontend (next commit) will render 'html' inside a sandboxed iframe
with allow-scripts enabled — identical to the existing
DesignElementPreview.vue pattern. No new security model needed.

3 new behavioural tests in show_preview_test.zig:
  - validateContentType accepts 'html'
  - executeShowPreviewToString returns success envelope for html input
  - executeShowPreviewToString accepts html content with embedded <script>"
```

---

## Task 2 — Frontend: render `html` in PreviewSidePanel via iframe

Wire the iframe render path in the Vue side panel. Test first.

### 2.1 Write the failing test

- [ ] **Open** `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts` and add 3 new behavioural tests inside the existing `describe('PreviewSidePanel', ...)` block (find the closing `});` near the end of the file). The tests follow the existing pattern — mount the component with a `previews` prop shaped like the real `llm_history` row's tool-output envelope.

```ts
import { vi } from 'vitest'

// ... existing imports ...

describe('PreviewSidePanel — html content_type', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    localStorage.clear()
  })

  it('renders an iframe with sandbox="allow-scripts" for html content_type', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'msg-html-1',
            content: '<tool>show_preview</tool>' +
              '<parameters>' +
              '<content_type>html</content_type>' +
              '<content><h1>Hello</h1></content>' +
              '<title>Tests</title>' +
              '</parameters>',
          },
        ],
      },
    })
    const iframe = wrapper.find('iframe')
    expect(iframe.exists()).toBe(true)
    expect(iframe.attributes('sandbox')).toBe('allow-scripts')
  })

  it('passes the user HTML into the iframe via srcdoc (verified by content match)', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'msg-html-2',
            content: '<tool>show_preview</tool>' +
              '<parameters>' +
              '<content_type>html</content_type>' +
              '<content><!DOCTYPE html><html><body><h1>Hi</h1></body></html></content>' +
              '</parameters>',
          },
        ],
      },
    })
    const iframe = wrapper.find('iframe')
    expect(iframe.exists()).toBe(true)
    // The srcdoc is attribute-escaped for the wrapping attribute scope,
    // so the user's "<!DOCTYPE html>" lands as "&lt;!DOCTYPE html&gt;" inside
    // the srcdoc ATTRIBUTE. The browser un-escapes it when parsing the iframe.
    const srcdoc = iframe.attributes('srcdoc') ?? ''
    expect(srcdoc).toContain('&lt;!DOCTYPE html&gt;')
    expect(srcdoc).toContain('&lt;h1&gt;Hi&lt;/h1&gt;')
  })

  it('attribute-escapes double quotes in the srcdoc so the wrapping attribute stays valid', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'msg-html-3',
            content: '<tool>show_preview</tool>' +
              '<parameters>' +
              '<content_type>html</content_type>' +
              '<content><a href="x" title="Y">link</a></content>' +
              '</parameters>',
          },
        ],
      },
    })
    const iframe = wrapper.find('iframe')
    expect(iframe.exists()).toBe(true)
    const srcdoc = iframe.attributes('srcdoc') ?? ''
    // A raw " inside the user's HTML would close the srcdoc attribute early —
    // the render code must escape it to &quot; so the attribute stays valid.
    expect(srcdoc).toContain('&quot;x&quot;')
    expect(srcdoc).toContain('&quot;Y&quot;')
  })
})
```

- [ ] **Run the tests** to confirm they fail (red):

```bash
cd src/apps/desktop
timeout 60 bunx vitest run previewSidePanel 2>&1 | tail -n 30
```

Expected output: 3 new tests fail because the iframe shape isn't recognized yet (the existing `renderedContent` returns `''` for non-markdown/text/code/image branches, so the `<img>` branch falls through to the `v-html` of empty string).

### 2.2 Implement the fix

- [ ] **Open** `src/apps/desktop/src/components/preview/PreviewSidePanel.vue` and find the `renderedContent` computed (around line 199-211). The current code returns `''` (empty string) for any content_type not in the four branches. The template uses `v-html="renderedContent"` for the `text`/`markdown`/`code` branch and a separate `<img>` for `image`. We need a fifth branch rendered by a separate `<iframe>`.

- [ ] **Add a new computed `htmlSrcDoc`** immediately after the `renderedContent` computed (around line 211). It does the attribute-escaping for the iframe's `srcdoc` attribute:

```ts
/**
 * Attribute-escape the user HTML for the iframe's `srcdoc` attribute.
 * Only needs to escape the four characters that would break the wrapping
 * attribute (`< > & "`) — NOT a full HTML sanitizer. The iframe sandbox
 * is the security boundary, not escape quality.
 *
 * We also wrap the HTML in a tiny `<style>` reset so the preview doesn't
 * get a default-margin surprise from the browser body. Mirrors the pattern
 * in DesignElementPreview.vue:45-50.
 */
const htmlSrcDoc = computed<string | null>(() => {
  if (activeContentType.value !== 'html') return null
  const raw = activeArgs.value.content ?? ''
  const escaped = raw
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
  return `<style>html,body{margin:0;padding:0;background:#fff;}</style>${escaped}`
})
```

- [ ] **Add `html` to the `ICONS` map** (line 220):

```ts
const ICONS: Record<string, string> = { markdown: 'M', text: 'T', code: 'C', image: 'I', html: 'H' }
```

- [ ] **Replace the renderedContent tail** (line 210) so the `html` branch returns `''` (the iframe will render separately, not via `v-html`). This keeps the existing `v-html` branch correct for `text`/`markdown`/`code`:

```ts
  if (ct === 'code') {
    const lang = activeArgs.value.language ?? 'plaintext'
    return `<pre><code class="language-${escapeHtml(lang)}">${escapeHtml(c)}</code></pre>`
  }
  // 'image' and 'html' have dedicated template branches below — no content via v-html.
  return ''
```

- [ ] **Update the template** in `PreviewSidePanel.vue` to add the iframe branch. Find the `<div v-if="activeContentType === 'image'" ...>` block (around line 308) and add an `<div v-else-if="activeContentType === 'html'" ...>` block immediately after the `image` block and BEFORE the `v-else` `<div v-html="renderedContent" />`:

```vue
        <div v-if="activeContentType === 'image'" class="flex justify-center bg-black/[0.04] p-2 rounded">
          <img v-if="imageSrc" :src="imageSrc" :alt="activeArgs.title || activeArgs.caption || 'Preview image'" class="max-w-full max-h-96 object-contain" @error="(e) => { (e.target as HTMLImageElement).style.display = 'none' }" />
          <div v-else class="text-xs text-red-500 italic">Image source invalid (expected data: URL or http(s) URL)</div>
        </div>
        <div v-else-if="activeContentType === 'html' && htmlSrcDoc" class="h-full min-h-[480px] rounded overflow-hidden border border-[var(--color-border)] bg-white">
          <iframe
            sandbox="allow-scripts"
            :srcdoc="htmlSrcDoc"
            class="w-full h-full min-h-[480px] border-0 block"
            :title="activeArgs.title || 'HTML preview'"
            data-testid="preview-html-iframe"
          />
        </div>
        <div v-else class="text-xs text-[var(--semantic-text)] markdown-content" v-html="renderedContent" />
```

Notes:
- `sandbox="allow-scripts"` (no allow-same-origin, no allow-forms) — JavaScript runs in the iframe's null origin so it can NEVER read the parent's cookies, localStorage, or window. Forms are blocked (no submit). Top-navigation is blocked (no `window.open` from the iframe). This is the same shape as `DesignElementPreview.vue:148`.
- `min-h-[480px]` — guarantees a usable preview even when the panel is collapsed narrow; the iframe's own body scrolls for content overflow.
- `border-0 block` — remove the default iframe border so the surrounding styled border shows; `block` removes the inline baseline gap.
- The `data-testid` is a debug hook for future E2E tests; not strictly needed for the unit tests (which find by tag).

### 2.3 Verify the tests pass

- [ ] **Run the vitest tests** to confirm they pass (green):

```bash
cd src/apps/desktop
timeout 60 bunx vitest run previewSidePanel 2>&1 | tail -n 30
```

Expected output: 3 new tests pass; existing tests untouched. Total tests in the file: 27 + 3 = 30.

- [ ] **Run the full vitest suite** to confirm no regressions anywhere else:

```bash
cd src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 10
```

Expected output: same total pass count as before (1522 + 3 = 1525), zero failures.

- [ ] **Type-check** (vitest does NOT type-check — `vue-tsc --build` is required):

```bash
cd src/apps/desktop
timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 10
```

Expected output: zero errors. (If `vue-tsc --build` emits `.js` files next to `.ts` source per the `vue-tsc-build-emits-js-files` skill, delete them before committing: `git clean -f src/`.)

- [ ] **Build** to confirm the production build still works:

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected output: build succeeds.

### 2.4 Commit

- [ ] **Commit** the frontend changes:

```bash
git add src/apps/desktop/src/components/preview/PreviewSidePanel.vue src/apps/desktop/src/__tests__/previewSidePanel.spec.ts
git commit -m "feat(show_preview): render html content_type in a sandboxed iframe

The 'html' content_type (added in the previous commit) now renders inside
an iframe with sandbox=allow-scripts, matching the existing
DesignElementPreview.vue pattern.

Security:
  - allow-scripts: lets landing-page JS run (GA, animations, React mounts)
  - NO allow-same-origin: iframe gets a null origin, so its JS cannot
    read the parent app's cookies, localStorage, or window
  - NO allow-forms: <form> tags render but cannot submit
  - NO allow-top-navigation: window.open() from the iframe is blocked

Attribute-escapes the HTML for the srcdoc attribute (escapes < > & \" so
the wrapping attribute stays valid). The iframe sandbox is the security
boundary — no HTML sanitization needed.

3 new behavioural tests in previewSidePanel.spec.ts:
  - iframe has sandbox=allow-scripts
  - user HTML is attribute-escaped into srcdoc
  - double quotes in user HTML are escaped to &quot;"
```

---

## Task 3 — Documentation updates

### 3.1 Update `docs/agent-tools.md`

- [ ] **Open** `docs/agent-tools.md` and update the `show_preview` section:
  - Line 10: change `"content_type" (required): one of "markdown", "text", "code", "image"` to `one of "markdown", "text", "code", "image", "html"`.
  - Line 30-37: add a new bullet under "Frontend rendering" describing the HTML iframe behavior.
  - Add a new "Example usage" JSON block for the `html` content_type after the existing examples.

### 3.2 Update `docs/SPEC.md` §10.2.1 PR index

- [ ] **Open** `docs/SPEC.md` and find the PR index (the table/list near line 590 based on the grep). Add a new entry at the top (newest-first):

```markdown
#NNN  feat(agent): show_preview html content_type (sandboxed iframe)
```

(The actual PR number is filled in when the PR is opened — leave the number blank or use a placeholder like `#TBD` until the PR is created.)

### 3.3 Commit

- [ ] **Commit** the docs:

```bash
git add docs/agent-tools.md docs/SPEC.md
git commit -m "docs(agent-tools): document show_preview 'html' content_type"
```

---

## Task 4 — End-to-end manual verification

The Zig unit tests cover the tool layer and the Vue unit tests cover the render layer. But the wiring between them (the `parameters` extraction in `ShowPreview.vue` + the side panel pop-up on click) needs an eyeball check.

### 4.1 Start a dev server on port 8080 (NEVER 8081 — that's the user's always-running dev)

- [ ] **Confirm** port 8081 is NOT your `nalar` process:

```bash
ss -tlnp 2>/dev/null | grep -E ':8081|:8080' || netstat -tlnp 2>/dev/null | grep -E ':8081|:8080'
```

If 8081 is occupied, do NOT touch it. Use 8080.

- [ ] **Start the nalar backend** on port 8080 (from the project root):

```bash
timeout 10 ./zig-out/bin/nalar --port 8080 --static-dir src/apps/desktop/dist 2>&1 | tee /tmp/nalar-8080.log &
sleep 3
curl -s http://localhost:8080/api/health
```

Expected output: `{"status":"ok"}` (or similar — confirm the server is up).

### 4.2 Drive a `show_preview` html call via the chat API

- [ ] **Find the chat endpoint** by checking `src/apps/desktop/src/api/` or `src/modules/agent/`. The test goal is to fire a `show_preview` whose `content_type` is `html` and observe the response. The simplest path is to use the existing TUI workflow that goes through `tool_registry.zig`. If the API surface allows a direct POST to the chat endpoint with a synthetic message, use that path.

### 4.3 Eyeball the side panel

- [ ] **Open** the desktop app in a browser pointing at `http://localhost:8080`.
- [ ] **Trigger** the agent to call `show_preview` with `content_type: "html"` and a small landing page payload.
- [ ] **Verify**:
  - The side panel auto-opens.
  - The iframe is visible with `sandbox="allow-scripts"` (DevTools Elements panel).
  - The HTML inside the iframe renders (text, images, basic CSS).
  - A `<script>` tag in the HTML runs (e.g. `<script>document.body.style.background = 'red'</script>` should turn the iframe body red).
  - The iframe JS cannot access `window.parent.localStorage` (test in DevTools console: `window.parent.localStorage` should be undefined inside the iframe).
  - The tab label in the side panel shows `H` icon + the title (e.g. `H Landing page`).
  - The status footer at the bottom of the preview shows `html · preview_id: pv_...`.
  - Resize the panel — the iframe should fill the new width (its content scrolls vertically).

### 4.4 Commit the manual test notes (if any)

- [ ] If you found anything during the eyeball check that needs a follow-up (e.g. the iframe scrolled-to-top behaviour is wonky), file a separate task. Do NOT fix in this PR.

---

## Task 5 — Final verification (mandatory trio)

Per AGENTS.md, the MANDATORY verification before declaring done:

### 5.1 Backend

- [ ] ```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: pass count went up by 3 (the new behavioural tests in Task 1.1). No regressions.

- [ ] ```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: builds cleanly. (The `cp` to `/usr/local/bin/nalar` may fail on permissions — that's harmless.)

- [ ] ```bash
timeout 360 bash -c 'rm -rf zig-out/bin && zig build' 2>&1 | tail -n 5
```

Expected: full rebuild succeeds.

### 5.2 Frontend

- [ ] ```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: build succeeds.

- [ ] ```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 10
```

Expected: pass count went up by 3 (Task 2.1). No regressions.

- [ ] ```bash
cd src/apps/desktop
timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 10
```

Expected: zero errors. Delete any `.js` files emitted next to `.ts` source per `vue-tsc-build-emits-js-files` skill.

### 5.3 Cross-compile

- [ ] ```bash
timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc src/modules/agent/tools/show_preview.zig 2>&1 | tail -n 5
timeout 60 zig build-obj -fno-emit-bin -target aarch64-macos -lc src/modules/agent/tools/show_preview.zig 2>&1 | tail -n 5
```

Expected: both exit 0.

### 5.4 Done

- [ ] Move the kanban task to `merged` (only after the PR is merged to main; per the kanban column rules).

---

## Out of scope (future PRs)

- **Sandbox toggle on the input** — let the LLM request `sandbox="strict"` (no scripts) for purely static HTML. Easy follow-up: add a `sandbox` field to the schema, pass it through, use it in the iframe attribute.
- **Viewport presets** — `viewport="mobile" (375x667)` / `viewport="tablet" (768x1024)` / `viewport="desktop" (1280x800)`. Useful for Figma-style preview, but the current "fill the panel" approach matches the existing UX.
- **Hot-reload** — re-render the iframe when the source changes (e.g. the LLM edits the HTML). The Vue reactivity already triggers the iframe's srcdoc to update; explicit hot-reload with a toolbar would be a UX feature.
- **Refactor: extract `SandboxedIframe.vue`** — pull the iframe-and-reset pattern into a shared component, used by both `PreviewSidePanel` and `DesignElementPreview`. Small refactor; do it once we have 2 consumers using the same shape.
- **External resource blocking** — current sandbox allows `<img src="https://...">` and `<link rel="stylesheet" href="https://...">` to load. If we want a "sandboxed" preview that blocks external network (e.g. for security review), add a CSP meta tag inside the `srcdoc`. Not needed for v1.
- **Print / save as PDF** — let the user print the previewed HTML. Out of scope.
