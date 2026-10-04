## Rename: the project is now **pabrik**

A clean break. The previous name is gone from the tree — a case-insensitive
grep matches exactly one line, and that is the English word `finalArrived` in a
design-context doc.

### What changed

- **Binaries**: `pabrik`, `pabrik-desktop`, `pabrikcli`, `pabrik-tui`,
  `pabrik-dev`, and the cross-target `pabrikcore-<triple>` artifacts. The Zig
  module is `pabrikcore` (410 `@import` sites across 335 files).
- **Paths**: `~/.config/pabrik`, `~/.local/state/pabrik`, `<cwd>/.pabrik/`,
  `PABRIK.md`, `~/.config/pabrik/skills|memories|agents`.
- **Wire**: `/api/config/pabrik`, the `pabrik_session` cookie, the
  `pabrik://` deep links, `PABRIK_*` / `PABRIKCLI_*` env vars, the
  `zig build pabrik-desktop` step.
- **Mobile**: `com.pabrik.mobile` end to end — package, `applicationId`,
  resources, all 207 Kotlin files, and the navgraph tool that reads them.
- **Prompt surface**: the agent's self-identification (`You are Pabrik`),
  every tool description, the memory/skills contract, and the
  `[Agent Pabrik System error]` sentinel the frontend parses.
- **Docs**: including the dated plan/spec archives and four archive filenames.

### What this costs

There is no compatibility layer, so an existing install is a new install:

| Surface | Consequence |
|---|---|
| `~/.config/pabrik`, `agent.db` | starts empty; sessions, workspaces, kanban and credentials are not migrated |
| `~/.config/pabrik/skills\|memories\|agents` | must be moved over by hand |
| `<project>/.pabrik/` | must be moved per checkout |
| `PABRIK.md` | must be renamed per project |
| `pabrik_session` cookie | every logged-in user is signed out |
| `localStorage` keys | UI state resets (sidebar, tabs, kanban layout, cached media) |
| Android `applicationId` | installs under a new package id; keystore entries and SharedPreferences are orphaned, so the app signs users out and re-downloads its cache |

### Side effect worth knowing

The Android manifest now claims the `chats` and `project` deep-link hosts,
which the nav graph declared but nothing ever registered. The navgraph
auditor went from **2 errors to 0**, and its `known_unclaimed` pin — which
existed only to stop that gap being forgotten — is now empty.

### Verification

| Gate | Result |
|---|---|
| `zig build test` | 4455/4465 pass (10 skipped), 8/8 steps — identical to the pre-rename baseline |
| `vue-tsc --build` | clean |
| `vitest` | 19 failed / 490 passed (509 files) — byte-identical to the pre-rename checkout |
| `oxlint` + `eslint` | clean; the banned-code baseline is intact |
| `navgraph build.py --check` | up to date, 0 audit errors |
| `navgraph_contract_test.py` | 20/20 |

The 19 failing spec files are **pre-existing and unrelated**: the ChatView
specs mount the component without a router, so `useRoute()` returns
undefined and `route.query` throws. Confirmed by running the same suite on
the pre-rename checkout and diffing the failure sets — the rename introduces
none.

Also removed: two stale committed ELFs under `bin/` (65 MB) that no build
step produced and nothing referenced. `bin/` is now gitignored.
