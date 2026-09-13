# Nalar first page (home / landing) — design (rev 1)

> **Status: approved by the user (2026-09-13) and implemented on the tab-mode
> branch** (`worktree/tab-mode-like-a-browser-1789300444735`, PR #476) at the
> user's request to combine the two. The copy below is exactly what shipped; the
> §4 steps are all done and the §5 gates are recorded in the PR body.

**Goal:** when Nalar opens, its first screen should say what Nalar is. Today it
shows one hardcoded fake assistant turn and nothing else.

**Scope (agreed with the user, 2026-09-13):** a **static brand page** —
wordmark, tagline, a few lines of blurb. Nothing interactive.

**Explicitly declined by the user:** composer / input box, `@`-file hint,
modes strip, recent-chats list, workspace chips, dashboard cards, quick-action
buttons. Do not add any of them "while we're here".

**Non-goals:** model/version footer, auto-send, per-workspace activity,
onboarding flow, tour, i18n, new brand assets.

---

## 1. Current state (verified 2026-09-13 at `2f1a5740`)

| Fact | Where |
|---|---|
| The landing page is `components/views/Chats.vue`, rendered by `<Chats v-else-if="currentView === 'chat'" />` — i.e. when the URL is `?view=chat` with **no session** | `AppLayout.vue:2682` |
| It is a 165-line stub whose content is one hardcoded assistant message: `'Hello! I am your AI coding assistant. How can I help you today?'` | `Chats.vue:13-20` |
| That message is stamped with `new Date()` at mount, so it always looks like the assistant just spoke; it can never be replied to (the page has no input) | `Chats.vue:18` |
| The message-list + scroll plumbing (`messagesContainer`, `isAtBottom`, `handleScroll`, `scrollToBottom`, the scroll-to-bottom button, the avatar/bubble markup) was copied from `ChatView` and **nothing feeds it** | `Chats.vue:22-64,67-151` |
| The page renders no actions at all — the only way to start work is the sidebar (`+ New Chat` / a workspace item) | `Chats.vue` (whole file) |
| The brand is deliberately **text-driven**: "Header. Minimal text-driven header — no logo gradient" | `Sidebar.vue:1339` |
| The project's own one-line description: "**Nalar** is an AI agent workspace tool" with chat, kanban, design canvas, file tree, settings | `docs/SPEC.md:11-17` |
| `index.html` still carries the Vite default browser-tab title | `index.html:16` (`<title>Vite App</title>`) |
| Git history: the file has never been redesigned — last touched by a scroll-gap fix, a CI change and a directory refactor | `git log -- views/Chats.vue` |

## 2. Design

A single centred column; everything vertically centred in the content area. No
scrolling content, no widgets, no interactions.

```
                    ✦

                  nalar

            AI agent workspace


   Nalar is an AI agent workspace. It runs your
   own model against real files: chat with it,
   break the work into kanban tasks, or design
   in a canvas — with the tools you attach.


   Open a chat in the sidebar, or start a new one.
```

### Copy (exact — this is what needs approval)

| Element | Text | Treatment |
|---|---|---|
| Accent glyph | `✦` | `--color-violet`, ~28px, `aria-hidden` |
| Wordmark | `nalar` | ~40px, `--semantic-text`, tight tracking |
| Tagline | `AI agent workspace` | ~13px, `--semantic-text-muted`, letterspaced uppercase |
| Blurb | `Nalar is an AI agent workspace. It runs your own model against real files: chat with it, break the work into kanban tasks, or design in a canvas — with the tools you attach.` | ~15px, `max-w-[520px]`, centred, `--semantic-text-muted` |
| Hint line | `Open a chat in the sidebar, or start a new one.` | ~12px, `--semantic-text-dim` |

Notes on the copy: it uses the project's own vocabulary (agent workspace,
kanban, design canvas, tools) from `docs/SPEC.md` §1, and "runs your own model"
is accurate — the app supports Anthropic / OpenAI-style / custom base URLs per
profile. It is *not* a claim about features that do not exist.

### Semantics and accessibility

- One `<h1>` = `nalar` (the app name). Tagline and blurb are plain `<p>`s, so the
  page has a sane heading outline.
- No interactive elements, so nothing needs focus management or keyboard
  handling. The page is inert by design.
- Data hooks for tests: `data-testid="home-landing"`, `"home-wordmark"`,
  `"home-tagline"`, `"home-blurb"`.
- Uses only existing CSS variables (`--semantic-text`, `--semantic-text-muted`,
  `--semantic-text-dim`, `--color-violet`, `--semantic-bg`) — no new tokens, no
  new asset, no logo file. Consistent with the text-driven sidebar header.
- Respects the app's fixed dark/light themes and window resizing (centred flex
  column, `px-6`, no fixed heights).

## 3. What changes

| File | Action | Responsibility |
|---|---|---|
| `src/apps/desktop/src/components/views/Chats.vue` | EDIT (rewrite) | 165 → ~55 lines: the hero only. Delete the fake `messages` array, the copied message-list/bubble markup, the scroll container/`isAtBottom`/`handleScroll`/`scrollToBottom`, the scroll-to-bottom button, the avatar gradients and the `formatTime` helper. No `onMounted`, no refs, no emits, no props. |
| `src/apps/desktop/src/helpers/tabTarget.ts` | EDIT | `fallbackTitle('home')` → `'Nalar'` (was `'Chats'`): the tab-mode home tab is the Nalar page now. One string. |
| `index.html` | EDIT (optional) | `<title>Nalar</title>` (currently the Vite default). Include it unless the reviewer objects — it is the browser-tab title on the web target and a typo-level loose end. |
| `src/apps/desktop/src/__tests__/ChatsLanding.spec.ts` | NEW | Renders wordmark/tagline/blurb; heading is an `h1`; **regression: the old hardcoded greeting string does not appear anywhere in the component** (grep the rendered text) and no `<input>`/`<textarea>`/`<button>` is rendered (guards the "static page" scope decision). |
| `src/apps/desktop/src/__tests__/TabBar.spec.ts` | EDIT | one expectation `'Chats'` → `'Nalar'` |
| `src/apps/desktop/src/__tests__/tabsStore.spec.ts` | EDIT | one expectation `'Chats'` → `'Nalar'` |

**Untouched:** `AppLayout.vue` (the page has no emits, so no listener is needed),
any `.zig` file, any store other than the one-string label, `ChatsList.vue`
(this is the `Chats.vue` *view*, not the sidebar list), `FileInput.vue`.

## 4. Implementation steps (small enough that this section *is* the plan)

- [ ] `ChatsLanding.spec.ts` first: renders `nalar` + `AI agent workspace` + the blurb; `<h1>` is the wordmark; harness asserts `queryByText(/AI coding assistant/)` is `null` and `wrapper.find('input, textarea, button').exists()` is `false`.
- [ ] Rewrite `Chats.vue` to the hero in §2. Delete the dead plumbing listed in §3. No `defineProps`/`defineEmits`/`onMounted`.
- [ ] `fallbackTitle('home')` → `'Nalar'`; flip the two existing expectations.
- [ ] `index.html` title → `Nalar`.
- [ ] `Commit:` `feat(home): replace the stub landing page with a Nalar brand page`

## 5. Verification

- [ ] `pnpm --dir src/apps/desktop test` — full suite vs the recorded baseline on the tab branch (`2f1a5740`: 4 failed / 3171 passed, 363 files). Expect the **same 4 pre-existing failures**, no new ones.
- [ ] `pnpm --dir src/apps/desktop run build` (`vue-tsc --build` + `vite build`) clean; `git status` shows no stray `.js`.
- [ ] `ChatsLanding.spec.ts` green, including the two scope guards (no greeting string, no form controls).
- [ ] Manual: launch (`pnpm dev`, 5173 — port 8081 is off-limits) → the first screen is the brand page, in both the light and dark theme, and at a narrow window width the copy still wraps without clipping.
- [ ] Manual: with tab mode on, the home tab is labelled `Nalar`; opening it from another tab still renders the page.
- [ ] Manual: browser-tab title reads `Nalar` on the web target.

## 6. Open questions for the reviewer

1. **The copy.** Approve the four strings in §2 as-is, or send replacements (this is the only thing genuinely open).
2. **The hint line** (`Open a chat in the sidebar, or start a new one.`) — keep it, or drop it for a pure brand page? *Implemented default: keep* (one dim line; it answers "so what do I do?" without adding a widget).
3. **`index.html` title** — include the `Nalar` fix here, or as a separate nit? *Implemented default: include.*

## 7. Risks

1. **The page becomes too empty to be useful.** Accepted: the user explicitly removed the composer, actions and modes strip. The sidebar remains the way to start work, and the hint line says so.
2. **Losing the scroll/message plumbing.** It was dead code (nothing populated `messages`), so deleting it cannot regress behaviour — the spec asserts no controls and no greeting remain.
3. **Copy drift.** The blurb deliberately mirrors `docs/SPEC.md` §1's own description rather than inventing marketing claims.
