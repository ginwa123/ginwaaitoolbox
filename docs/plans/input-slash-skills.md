# Plan: chat input slash-command skills (`/skill-<name>`)

Worktree: `/home/ginwa/.config/pabrik/.worktrees/input-support-command-skills-1791315235`
Branch: `worktree/input-support-command-skills-1791315235` (from `main` @ 6aea07b4)
Status: planning only — no code changed in this worktree.
Wireframe: `docs/plans/input-slash-skills-wireframe.html` (v2, interactive).

## 1. What exists today

### 1a. `@` file mention (frontend only, `FileInput.vue`)
- Trigger: `detectAtTrigger()` matches `/@([\w./\\:-]*)$/` on text-before-cursor.
- Debounce 150ms (`fileDebounceTimer` + `scheduleFileSearch` 150ms); immediate on open.
- Search: single round-trip `api.searchFiles(cwd, query, 50, 8, signal)`; `AbortController` + `fileSearchGen` guard discards stale responses.
- Cache: empty-query top-N per cwd only (`fileSearchCache`, max 3 cwds). Non-empty queries always hit server.
- Picker: dropdown over `filteredFiles` (server-ranked; client subsequence fallback only when `serverFailed`), cap 50 rows, keyboard ArrowUp/Down + Enter/Tab select + Esc close.
- Insert: keeps `@` trigger, inserts `@` + picked relative path as **plain text** (`@/folder/file`). No chip component, no backend expansion — the `@path` string is sent verbatim in the chat message.
- Placeholder: `Type a message... (@ to search files)`.
- Spec: `FileInput.search.spec.ts` (server search + caps + abort).

### 1b. Skills system (backend source of truth)
- Storage: workspace-scoped `skills` + `skill_assets` tables (Migration 101), via `src/agentic_loop/skills_store.zig`. `workspace_id` is a SQL `WHERE` param everywhere — never client-chosen.
- HTTP: `GET /api/workspaces/:workspace_id/skills` → `{skills: [{name, description}]}` (no body); `GET .../skills/:name` → full body + assets. Handlers: `src/http_handlers/skills_list.zig`, `skill_detail.zig`.
- Agent tools: `search_skills` / `use_skill` (+ add/edit/remove) in `src/modules/agent/tools/skill_tools.zig`, exec in `src/agentic_loop/tools_exec_skills.zig`. They resolve `workspace_id` **server-side** from `session_id` — the model never names a workspace.
- Prompt injection: loaded skills persist in `session_skills` table and are injected into the prompt (`workflow_compact_message.zig`, `prompts_make_skills_equiped_context.zig`).
- Frontend API already exists: `getSkills(workspaceId)`, `getSkillDetail(workspaceId, name)` in `src/apps/desktop/src/api/index.ts`.
- No `/` slash handling exists anywhere in the desktop app today (verified by search).

## 2. Proposed UX (v2 — per review: `/skill-` namespace)

- Trigger: typing `/skill` opens the skills picker with the full list; typing the dash (`/skill-`) and onward filters it (`/skill-co` → `code-review`, `commit-msg`). A bare `/` also opens the list (superset, harmless). Gate (unchanged): the `/` must sit at message start or after whitespace, so `http://` and `a/b` paths never trigger it. `@` keeps its current anywhere-behavior.
- The `-` (and `.`) must be part of the trigger regex character class (like the `@` regex already is) so typing past the dash keeps filtering instead of breaking the match.
- Picker rows: skill `name` + `description` (from the list endpoint), shown as `/skill-<name>`. Client-side substring filter as the user types; full list on empty query.
- Keyboard: same as `@` — ArrowUp/Down navigate, Enter/Tab accept, Esc dismisses. Both pickers must never be open at once (`/` closes `@` and vice versa); Esc/`@`-break rules mirror `closeFilePicker`.
- Insert: plain-text token preserving the typed form — accepting from `/skill-co` inserts `/skill-code-review`; accepting from a bare `/co` inserts `/code-review`. No chip in v1.
- Placeholder: `Type a message... (@ files, /skill- skills)`.
- Multi-skill: allow several tokens per message; each resolves independently.
- Unknown token at send: leave the literal text in the message and surface a toast (`Skill "x" not found in this workspace`) — never silently drop user text, never block the send.

## 3. Loading semantics (the key decision)

**Recommended: backend expands, frontend only inserts the token (Option B).**

- Frontend sends the message verbatim (with `/skill-<name>` tokens in the text), exactly like `@paths` today.
- The chat-send path (queue_message / llm session send handler — exact file to confirm at implementation time) detects both `/skill-<name>` and bare `/<name>` tokens, and for each: `skills_store.getSkill(db, workspace_id, name)` (workspace resolved server-side from session, same as `use_skill`), writes the `session_skills` row, and appends the skill body to the user-message context the same way `use_skill` does.
- Why backend, not frontend pre-fetch:
  1. Workspace isolation stays in SQL server-side (the `use_skill` guarantee). A frontend fetch-then-inline path would ship skill bodies through the chat input and re-implement scoping in JS.
  2. Reuses `session_skills` persistence + prompt injection + compaction paths for free (no second loading mechanism).
  3. Skill bodies can be up to 2 MiB (`MAX_CONTENT_BYTES`) — they must not transit the textarea/draft bucket.
- Rejected alternative (Option A — frontend `getSkillDetail` then inline body before submit): duplicates scoping, bloats drafts, breaks the 2 MiB cap story. Documented here so review can overturn explicitly.
- Assets: v1 loads the body only. Bundled-skill companion files (`skill_assets`, materialised to temp dir by `use_skill`) are a named follow-up — the plan records it so v1 doesn't accidentally promise it.

## 4. Implementation steps

1. **Frontend picker (`FileInput.vue` + spec):**
   - Add `showSkillPicker / skillQuery / skillList / selectedSkillIndex` state parallel to the file picker; `detectSlashTrigger()` with the `/skill-` namespace parse + start-or-after-whitespace gate; shared keydown handling with mutual exclusion.
   - Data: `getSkills(workspaceId)` once per workspace per mount (cache like `fileSearchCache`); client filter by substring; `serverFailed`-style fallback over the cached list. Needs the workspace id at the input — confirm prop threading from ChatView (workspace id source is the one open question on the FE side).
   - Insert `/skill-<name>` (or `/<name>` for the bare form) plain-text token; update placeholder; keep `@` behavior byte-identical.
   - Spec: mirror `FileInput.search.spec.ts` — `/skill` opens with full list, `/skill-co` filters without refetch storm, Esc closes, Enter inserts `/skill-<name>`.
2. **Backend expansion (chat send path):**
   - Locate the exact send handler (queue_message / session send) and add token detection (both shapes) + `getSkill` + `session_skills` insert + context append. Reuse `skills_store` + `workspace_scope.resolveWorkspaceId(session_id)` — no new scope logic.
   - Unknown name → keep literal + warning surfaced on the wire (shape TBD at implementation; must be distinguishable from success — no silent empty fallback).
   - No new HTTP route needed (reuses existing skills endpoints + send path). If a search endpoint is added later, register it **before** `/api/.../skills/:name` — `matchRoute` walks in registration order (`router.zig:182`).
3. **Verification (per repo rules):**
   - Functional test via `tests/functional/harness.py` (fresh tmpdir HOME, free port — never 8081, never `nohup`+curl): send a message containing `/skill-<name>`, assert the skill body lands in context / `session_skills` and the literal is preserved on unknown names.
   - Zig `useCase`-level test for the expansion (in-memory SQLite, like `skills_list.zig` tests).
   - No source-text grep tests (banned class) — assert resolved behavior / wire payloads.

## 5. Open questions for review

1. ~~Token shape: `/skill-name` bare token vs. `/skill skill-name` command-with-arg?~~ Decided per review: `/skill-<name>` namespace form (bare `/<name>` also accepted). Canonical insert preserves the typed form.
2. Should picking a skill also show a removable chip/badge in the composer (v2), or is plain-text token enough long-term?
3. Workspace id threading into `FileInput` — prop vs. store lookup? (Implementation detail, confirm at build time.)
4. Skill assets in v1 scope or follow-up? Plan says follow-up.

## 6. Out of scope

- Skill CRUD UI, skill-evals, global skills, `@` behavior changes, prompt-cache tuning.
