# `web_search` Agent Tool — Real Google-Style Search (rev 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent a `web_search` tool that does an actual Google-style web search — "latest FIFA World Cup news today" returns ranked `{title, url, snippet, site_name}` results — instead of the URL-browser shim that currently squats the name. The user configures it with **exactly two values: a `url` and an `api_key`**. TinyFish (`https://api.search.tinyfish.ai`, 1000 req/day free) is the first supported provider. When the provider's quota is exhausted, the tool returns a structured error that **recommends the next provider to configure** rather than a raw quota body.

**Architecture:** Three layers, no new table.

1. **Provider catalogue** — a `comptime` table in the tool module maps a provider *host* to its auth-header name, query-param name, and signup URL. The user pastes a URL; we look up the host and build the correct request. An unknown host still works via `Authorization: Bearer` + `?q=`, with a note in the result that the provider was not recognised. This is the whole reason "just pass url + api_key" can work.
2. **Config** — a new optional `web_search: {url, api_key}` key on `LlmConfig`, mirroring the existing `tools` key (`Config.zig:466`) and the MCP server shape (`Config.zig:519`). It rides the existing `GET`/`PUT /api/config/nalar` round-trip, so per-user isolation (`users.config_json` → `UserConfigStore`) comes free. **No migration is required.**
3. **The tool** — `execute_web_search` replaces the `agent-browser` shell-out with a real `GET`, following the `generate_image` outbound-HTTP pattern byte for byte (kabelweb `client`, `Options`, `MAX_RESPONSE_BYTES`, `toJSONError`).

**Tech Stack:** Zig 0.16 (`AgentTool`, `ToolProperty`, `ToolExecContext`, `wrapToolOutput`), `kabelweb` HTTP client, `LlmConfig` JSON config, Vue 3 + vitest, python functional harness.

## Global Constraints

- **Never touch the process on port 8081.** Functional tests use the harness's random port (8080–8199).
- **No live-server `curl` for verification.** Per the repo's anti-pattern list, `nohup ./zig-out/bin/nalar… --port 8080 &` + `curl` leaks the process and misses route-order / empty-slice-binds-as-NULL / strict-validator bugs. Use `tests/functional/harness.py`.
- **`SqliteBackend.exec` binds `""` as SQL NULL.** Relevant here: `web_search.url` and `web_search.api_key` are JSON strings, and an unset key must be *absent from the JSON object*, never `""`. If the config is stored as a row, an empty url violates `NOT NULL` semantics — another reason to keep it in `config_json`.
- **No `// NEW (plan: …)` comments** in source. Plan references belong here and in the PR body.
- **`///` doc comments cannot be attached to a `test` decl** in Zig — use `//` inside test blocks.
- **`std.json.ObjectHashMap` has no `.has()`** — use `.get(k) != null`.
- **Per-request arena:** `ctx.allocator` is arena-backed — do not `defer free` arena slices inside exec adapters.
- **Cross-platform:** the implementation must not shell out. The current shim calls `agent-browser`, which does not exist on Windows; replacing it with an HTTP call is also a platform fix.
- **Never surface a raw provider quota body to the LLM.** It may contain the account's plan name or an internal error code. Map it to a fixed, actionable message (see D6).
- **Verification gates:**
  - `zig build test --summary all`
  - `(cd src/apps/desktop && pnpm test:unit)` and `pnpm run build` (`vue-tsc` must stay clean)
  - `zig build install:linux` then
    `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/web_search_config_test.py -v`

## Current State (verified 2026-10-02 in this worktree, `origin/main` @ `25f1ed19`)

### The `web_search` name is occupied by dead code

| Fact | Location |
|---|---|
| `web_search.zig` is a **URL browser**, not a search: it shells out to `agent-browser snapshot {url}` and returns raw stdout as `content` | `src/modules/agent/tools/web_search.zig:10` |
| Its schema is `{url}` only — no query string, no ranking, no results array | `src/modules/agent/tools/web_search.zig:70-85` |
| **It is unreachable.** The registry entry is commented out | `src/agentic_loop/tools_equipped.zig:306` — `// .{ .name = "web_search", .exec = tools.execWebSearch, … }` |
| It is **absent from `equips()`** — the list the LLM is actually shown | `src/agentic_loop/tools_equipped.zig:78` (no `web_search` entry; only the alias on `:41`) |
| The exec adapter exists and is wired into the adapter table | `src/agentic_loop/tools_exec_web_search.zig:12`, re-exported at `src/agentic_loop/tools.zig:48` |
| `const web_search_mod = nalarcore.web_search;` in the prompt builder is declared and **never referenced** — a dead const | `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig:68` (single hit in the file) |

**Consequence:** nothing a user does today can produce a `web_search` call, so repurposing the name breaks no live session. The old capability (`agent-browser snapshot <url>`) is a shell command the unified `command` tool can run verbatim, so it is not lost by deleting the shim.

### The existing structs are browser-shaped and must be replaced

| Struct | Location | Problem |
|---|---|---|
| `WebSearchInput { url, cwd }` | `src/modules/agent/tools/schemas.zig:100` | No `query`. `cwd` is only there to drive the `agent-browser` shell-out. |
| `WebSearchResult { success, content, exit_code, error_msg }` | `src/modules/agent/tools/schemas.zig:107` | `exit_code` and `content`-as-stdout are bash-shaped. `deinit` frees exactly two fields. |

`generate_image` keeps its input/result types **local to its own module** (`src/modules/agent/tools/generate_image.zig:51`, `:78`) rather than in `schemas.zig`, and its exec adapter imports them from there. Follow that: it keeps the tool's wire contract next to the code that produces it.

### The outbound-HTTP pattern to copy

`src/modules/agent/tools/generate_image.zig` is the in-repo reference for a tool that calls a third-party JSON API.

| Step | Location (all `src/modules/agent/tools/generate_image.zig`) | Note |
|---|---|---|
| Client import | `:14` | `const custom_http_client = @import("kabelweb").client;` |
| Response cap | `:24` | `pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;` |
| Scheme validation before the request | `:548-556` | Rejects a URL with no `http://`/`https://` prefix with an actionable message, citing `Agent.zig:1799-1821` |
| Headers | `:564-567` | `[_]custom_http_client.Header{ .{ .name = …, .value = … } }` |
| Request | `:569-574` | `Request{ .method, .url, .headers, .body }` |
| Options | `:578-582` | `Options{ .timeout_ms, .connect_timeout_ms, .follow_redirects, .verify_ssl }` |
| Perform | `:586-590` | `Client.init(allocator)` … `client.perform(req, options)` … `defer client.deinit()` |
| Status check | `:601-614` | `>= 400` → extract the provider's message, prefix `HTTP {d}` |
| Size cap | `:619-628` | Checked **before** parsing |
| Error envelope | `:472` | `toJSONError(allocator, msg)` → `{"error": msg}` |
| Exec adapter | `src/agentic_loop/tools_exec_generate_image.zig:80-103` | Re-parses its own JSON payload and re-wraps with `success=false` when `error` is present, keeping the full payload as `data` |

### Config plumbing (no migration needed)

| Fact | Location |
|---|---|
| `ToolExecContext.config` is the resolved per-user `*const LlmConfig` | `src/agentic_loop/tools.zig:101` |
| JSON parse struct for `config.json`; `tools: ?[]const []const u8 = null` is the shape to mirror | `src/modules/config/Config.zig:466` |
| `McpServerConfig { url, headers, … }` — the existing url+secret config shape | `src/modules/config/Config.zig:519-553` |
| Frontend mirror `NalarConfig.tools?: string[] \| null` | `src/apps/desktop/src/api/index.ts:4519` |
| Per-user config round-trips through `users.config_json` | `src/modules/config/UserConfigStore.zig:3` |
| Settings sections are mounted in one place | `src/apps/desktop/src/components/NalarSettings.vue:852` (SkillEvals), `:876` (McpServers), `:884` (Tools) |
| MCP servers section is the url+headers UI precedent | `src/apps/desktop/src/components/nalar/McpServersSection.vue`, `McpServerModal.vue`, `McpHeadersEditor.vue`, `mcpServers.ts` |

### Every place a tool name must appear

Adding a tool name to the LLM is **not** enough — a name present in `equips()` with no registry entry renders in the UI exactly like a hung tool. The guard test at `tools_equipped.zig:449` catches alias drift, but there is no equivalent for `equips()` ↔ registry.

| Surface | Location | Required |
|---|---|---|
| Tool definition | `src/modules/agent/tools/web_search.zig` | new `web_search_tool` + `.system_prompt` |
| Registry (dispatch) | `src/agentic_loop/tools_equipped.zig:305-306` | **uncomment + rewrite** |
| Equipped list (LLM visibility) | `src/agentic_loop/tools_equipped.zig:78` | **add** |
| Default seed | `src/agentic_loop/tools_equipped.zig:331` `DEFAULT_AGENT_TOOLS` | add (optional — see D7) |
| Exec adapter export | `src/agentic_loop/tools.zig:48` | already present |
| Root export | `src/root.zig:958` | already present |
| Settings → Tools tab group | `src/apps/desktop/src/components/nalar/ToolsSection.vue:83` `GROUP_BY_TOOL` | `web_search: 'Search'` (the group already exists at `:68`) |
| Settings → default-on list | `ToolsSection.vue:27` `BUILTIN_DEFAULT_TOOLS` | mirror the backend decision from D7 |
| Settings → category label | `ToolsSection.vue:99` / `:126` | check whether an entry is needed |
| Chat inline preview | `src/apps/desktop/src/helpers/renderResponse.ts:212-220` | decide whether the query renders inline |
| Tool-output parser | `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts` (see `generate_image` at `:738`) | `parseWebSearch` |
| Tool-output component | `src/apps/desktop/src/components/tool_outputs/WebSearch.vue` | new (pattern: `GenerateImage.vue`) |
| Android tool card | `src/apps/android_mobile/app/src/main/java/com/nalar/mobile/chat/ToolCardModel.kt:565-572` | `toolName == "web_search" -> ToolKind.WebSearch` + its test at `ToolCardModelTest.kt` |

## Design Decisions (for reviewer)

**D1 — Reclaim `web_search`; delete the URL-browser shim.**
*Rejected:* keeping the shim under a new name (`web_fetch`). The shim is unreachable dead code whose entire behaviour is `agent-browser snapshot <url>` — a shell command the unified `command` tool runs verbatim, on any platform where `agent-browser` is installed. A second name costs a new registry entry, a settings-group entry, an Android `ToolKind`, and a permanent maintenance surface for zero capability.
*Why:* the task says "add new agent tool name `web_search`". The name must mean "search". `agent-browser` is also absent on Windows, so keeping the shim would mean keeping a platform hole.
*Cost:* `docs/superpowers/plans/2026-08-06-show-preview-local-file.md:110` cites `web_search` as URL-fetch coverage — that line must be corrected in the same PR.

**D2 — Configuration is one `{url, api_key}` pair, not a provider list.**
*Rejected:* a `web_search.providers: [...]` array where the user adds several providers and the tool round-robins them. The requirement is literally "we just pass the url and api key" (singular). An array adds a settings UI for a second provider the user probably will not add, and it makes the "recommend another provider" path ambiguous (which one is next?).
*Why:* one pair is the smallest thing that satisfies the requirement, and it leaves the door open — D4's catalogue can grow into a real picker later without a config-shape break, because the object already has a `provider` field.

**D3 — Infer the provider from the pasted URL, via a compile-time host table.**
*Rejected:* a dropdown in Settings ("TinyFish / Brave / Serper") that writes the provider id into config. That makes the user know TinyFish exists before they have a key, and it does not survive a provider rename.
*Why:* the user asked for "just pass the url and api key". Matching the host of the URL they pasted is the only design where the *provider decides its own auth header*, which is what lets a single unknown-provider path stay correct.

**D4 — The provider table carries auth shape + signup URL, so fallback is a message, not a guess.**

```zig
pub const Provider = struct {
    id: []const u8,
    label: []const u8,
    /// Host suffix that selects this provider (matched against the configured url).
    host_suffix: []const u8,
    /// Auth header NAME. TinyFish uses `X-API-Key`; most others use `Authorization: Bearer <key>`.
    auth_header: []const u8,
    /// When true, the key is sent as `<auth_header>: Bearer <key>`.
    /// When false, the raw key is sent as `<auth_header>: <key>` (TinyFish).
    auth_bearer: bool,
    /// Query parameter carrying the search text.
    query_param: []const u8,
    /// Free-tier allowance, rendered into the exhaustion message. Null = metered/paid.
    free_tier: ?[]const u8,
    /// Where the user goes when this provider is exhausted.
    signup_url: []const u8,
};

const PROVIDERS = [_]Provider{
    .{ .id = "tinyfish", .label = "TinyFish", .host_suffix = "search.tinyfish.ai",
       .auth_header = "X-API-Key", .auth_bearer = false, .query_param = "query",
       .free_tier = "1000 requests/day", .signup_url = "https://tinyfish.ai" },
    // + the 2-3 closest alternatives, chosen by the reviewer
};
```

`Bearer` prefixing is encoded as a boolean `auth_bearer` on the entry (TinyFish sends the raw key in `X-API-Key`; the others send `Authorization: Bearer <key>`) rather than by parsing `auth_header`, so the table stays a literal.

**D5 — Provider fallback is an error message with a next step, not an automatic switch.**
*Rejected:* silently retrying against a second provider. **We cannot** — we hold exactly one `api_key` (D2), so an automatic retry to a different host would send the wrong credential to a third party. That is both useless and a mild secret-leak.
*Why:* the requirement is "the tool can recommend another provider". Recommend, not switch. When the provider signals exhaustion, return:

```json
{ "error": "Search provider quota exhausted.",
  "provider": "TinyFish",
  "exhausted": true,
  "free_tier": "1000 requests/day",
  "next_provider": "Brave Search API",
  "next_provider_url": "https://brave.com/search/api/",
  "hint": "Get an API key from next_provider_url, then set Web Search URL + API key in Settings → Web Search." }
```

The LLM reads that and tells the user what to do. A raw `429` body from the provider is never forwarded.

**D6 — Exhaustion detection is status-code first, body-pattern second.**
`429`, or `401`/`403` with a body matching `/quota|rate.?limit|exceeded|free.?tier/i`, ⇒ exhaustion (D5's envelope). Any other `>= 400` ⇒ ordinary error with the provider's own message, matching `generate_image.zig:601-614`. Keeping the two apart means a genuinely bad API key (`401`, no quota wording) reports "check your API key", not "you used up your free tier" — which is the difference between a useful and a misleading message.

**D7 — `web_search` is default-ON for agent + kanban items.**
*Rejected:* default-off (needs an explicit toggle). `DEFAULT_AGENT_TOOLS` (`tools_equipped.zig:331`) is the seed every new agent and kanban item is born with, and it mirrors the frontend's `BUILTIN_DEFAULT_TOOLS` (`ToolsSection.vue:27`); both must change together or the two lists disagree — which the comment at `tools_equipped.zig:322-329` explicitly calls out as something the repo cares about.
*Why:* an agent that cannot search is materially less useful, and the tool costs **nothing when unconfigured** — it returns a one-line "not configured" message instead of erroring (see the task's own requirement). Defaulting it on means the capability is discoverable the moment the user adds a key, with no second trip to the Tools tab.
*Risk:* `web_search` will appear in every new agent's `tools[]` payload for users who never configure it. That is a prompt-cost regression for them. **Flagged for the reviewer** — the alternative is default-off plus a `run_skill_eval`-style config gate like `skill_evals`.

**D8 — Configure the provider through a dedicated Settings section, not a JSON blob.**
New `WebSearchSection.vue` mounted in `NalarSettings.vue` next to `McpServersSection` (`:876`), with the url + api-key fields and a **test button** that fires one live search and reports the result. It is a small, near-literal sibling of `McpServerModal.vue`, so there is no new pattern to invent.

**D9 — The tool returns structured results, not a text blob.**
The envelope mirrors the TinyFish response so the frontend parser is trivial:

```json
{ "provider": "TinyFish",
  "query": "latest FIFA World Cup news today",
  "total_results": 10,
  "results": [ { "position": 1, "title": "…", "url": "…", "site_name": "…", "snippet": "…" } ] }
```

`position`, `site_name`, `title`, `url`, `snippet`, `total_results` are the five fields TinyFish returns and the four the LLM actually reasons over. Snippets are truncated to a cap (`SUMMARY_MAX`-style, `progressive_catalog.zig:820`) so a 10-result page cannot flood the context.

## Wire Contract

### `config.json` (new optional key — **no migration**)

```jsonc
{
  "web_search": {
    "url":  "https://api.search.tinyfish.ai",
    "api_key": "skkkk",
    "provider": "tinyfish"   // optional, written back by the backend for display only
  }
}
```

| Field | Type | Absence means |
|---|---|---|
| `web_search` | object | tool reports "not configured" |
| `url` | string, non-empty | ditto |
| `api_key` | string, non-empty | ditto |
| `provider` | string | re-inferred from the host; never trusted for auth |

Round-trips through the existing `GET`/`PUT /api/config/nalar`, so it lands in `users.config_json` per user and needs **no** new table and **no** Migration 100.

### Outbound request (inferred from the URL host)

```http
GET /?query=latest%20FIFA%20World%20Cup%20news%20today&location=US&language=en HTTP/1.1
Host: api.search.tinyfish.ai
X-API-Key: skkkk
```

Unknown host ⇒ `Authorization: Bearer <key>` and `?q=<query>`, plus `"provider_known": false` in the result so the UI can hint.

### Tool envelope

Success:

```json
{ "provider": "TinyFish", "query": "latest FIFA World Cup news today",
  "total_results": 10, "provider_known": true,
  "results": [ { "position": 1, "title": "AI News: …", "url": "https://…",
                 "site_name": "aiweekly.co", "snippet": "…" } ] }
```

Not configured (D7's reason for defaulting on):

```json
{ "error": "web_search is not configured. Set Web Search URL and API key in Settings → Web Search.",
  "configured": false }
```

Quota exhausted (D5):

```json
{ "error": "Search provider quota exhausted.",
  "provider": "TinyFish", "exhausted": true, "free_tier": "1000 requests/day",
  "next_provider": "Brave Search API",
  "next_provider_url": "https://brave.com/search/api/",
  "hint": "Get an API key from next_provider_url, then set Web Search URL + API key in Settings → Web Search." }
```

## File Map

| Action | File | Responsibility |
|---|---|---|
| **Rewrite** | `src/modules/agent/tools/web_search.zig` | `Provider` table (D4), `resolveProvider`, URL/param building, `execute_web_search`, `parseSearchResponse`, result truncation, `toJSONError`. Removes the `bash.zig` import entirely. |
| **Edit** | `src/modules/agent/tools/schemas.zig` | **Delete** `WebSearchInput`/`WebSearchResult` (`:100-117`); the new types live in `web_search.zig` like `generate_image`'s do. |
| **Rewrite** | `src/agentic_loop/tools_exec_web_search.zig` | Parse `{query, count?, location?, language?}`; read `ctx.config.web_search`; call `execute_web_search`; re-wrap `error` payloads as `success=false` per `tools_exec_generate_image.zig:80-103`. |
| **Edit** | `src/agentic_loop/tools_equipped.zig` | `:41` alias stays; `:306` uncomment + point at the new `tool_def`; add to `equips()` at `:78`; add to `DEFAULT_AGENT_TOOLS` at `:331` (D7). |
| **Edit** | `src/modules/config/Config.zig` | Add `WebSearchConfig` struct next to `McpServerConfig` (`:519`); add `web_search: ?std.json.Value = null` to the JSON parse struct next to `tools` (`:466`); add the owned field + parse + free on `LlmConfig`. |
| **Edit** | `src/http_handlers/nalar_config_put.zig` | Accept and persist the `web_search` key; **coerce empty string → absent** so a manual JSON edit of `""` deletes the key rather than persisting a blank url. |
| **Edit** | `src/apps/desktop/src/api/index.ts` | `web_search?: { url: string; api_key: string; provider?: string } \| null` on `NalarConfig` (`:4519` vicinity). |
| **New** | `src/apps/desktop/src/components/nalar/WebSearchSection.vue` | url + api-key inputs, masked key, provider label, **test button** (D8). |
| **Edit** | `src/apps/desktop/src/components/NalarSettings.vue` | Import + mount `WebSearchSection` beside `McpServersSection` (`:876`); wire the emit into the same config save path (`:636` comment region). |
| **Edit** | `src/apps/desktop/src/components/nalar/ToolsSection.vue` | `GROUP_BY_TOOL` += `web_search: 'Search'` (`:83`, group exists at `:68`); `BUILTIN_DEFAULT_TOOLS` += `'web_search'` (`:26`) iff D7 holds. |
| **New** | `src/apps/desktop/src/components/tool_outputs/WebSearch.vue` | Renders the ranked result list; pattern from `GenerateImage.vue`. |
| **Edit** | `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts` | `parseWebSearch` + `ParsedWebSearch` (pattern from `:738`). |
| **Edit** | `src/apps/desktop/src/helpers/renderResponse.ts` | Decide whether `web_search` joins the inline-preview list at `:211-218` or renders as a bare name (recommended — a query preview plus 10 results is too wide for an inline chip). |
| **Edit** | `src/apps/android_mobile/.../chat/ToolCardModel.kt` | `toolName == "web_search" -> ToolKind.WebSearch` at `:565-572` + the `ToolCardModelTest.kt` case. |
| **New** | `tests/functional/web_search_config_test.py` | Proves `web_search` round-trips through `PUT`/`GET /api/config/nalar` and that an **unconfigured** tool yields the "not configured" envelope rather than a crash. |
| **Edit** | `docs/superpowers/plans/2026-08-06-show-preview-local-file.md` | `:110` cites `web_search` as URL-fetch coverage — now false (D1). |

## Tasks

- [ ] **Task 1 — Provider table + config types.**
  `Provider` struct, the `PROVIDERS` table (TinyFish + the reviewer's chosen alternates), `resolveProvider(url)` returning the entry or a `Bearer`-default synthetic entry, `WebSearchConfig { url, api_key }` in `Config.zig`, the `web_search` JSON key on both `LlmConfigJson` and the owned `LlmConfig`, and the free/parse. Unit tests: host match, suffix match, unknown-host default, empty-string handling.
  Verify: `zig build test --summary all` — the `Config.zig` tests compile and the round-trip test passes.
  Commit: `feat(web-search): provider catalogue + LlmConfig.web_search key`

- [ ] **Task 2 — HTTP layer.**
  `buildSearchUrl` (query-param encoding + `count`/`location`/`language`), the header set chosen by `resolveProvider`, scheme validation copied from `generate_image.zig:548-556`, `MAX_RESPONSE_BYTES` (1 MiB is plenty for 10 results), `isQuotaExhausted(status, body)` (D6), and `parseSearchResponse` into `SearchResult{ position, title, url, site_name, snippet }`. Pure functions, no I/O, so they are directly testable with a recorded TinyFish body as a comptime fixture.
  Verify: `zig build test --summary all`, including a test that replays the task's sample response and asserts 10 parsed results.
  Commit: `feat(web-search): url building, quota detection, response parsing`

- [ ] **Task 3 — `execute_web_search` + error envelopes.**
  Assemble the success envelope (D9), the not-configured envelope (D7), and the exhausted envelope (D5). `toJSONError` mirrors `generate_image.zig:472`. Snippet truncation cap applied to every field before they enter the envelope.
  Verify: `zig build test --summary all` — the three envelopes are asserted as literal JSON strings.
  Commit: `feat(web-search): execute_web_search + structured error envelopes`

- [ ] **Task 4 — Rewrite the tool module + schemas.**
  Delete `bash.zig` import and `execute_bash` call; delete `WebSearchInput`/`WebSearchResult` from `schemas.zig:100-117`; write the new `web_search_tool` `AgentTool` with a verbose `description` (the `generate_image.zig:109-137` pattern: INPUT / BEHAVIOUR / OUTPUT / AUTH sections) and a `.system_prompt` block that tells the model to search rather than guess, and to prefer `search`/`glob` for the repo.
  Verify: `zig build test --summary all`; grep that no file still references the deleted `schemas.WebSearchResult`.
  Commit: `refactor(web-search): replace the URL-browser shim with the real search tool`

- [ ] **Task 5 — Exec adapter + registry wiring.**
  Rewrite `tools_exec_web_search.zig` to read `ctx.config.web_search` and pass it down; uncomment and rewrite `tools_equipped.zig:306`; add the entry to `equips()` (`:78`); add to `DEFAULT_AGENT_TOOLS` (`:331`) if D7 holds. **Add a guard test** asserting every name in `equips()` resolves to a registry entry — the gap that made this tool invisible in the first place, and the one that lets a future mistake render as a hung tool.
  Verify: `zig build test --summary all`; the new guard test fails when the registry line is commented out (prove it by temporarily re-commenting).
  Commit: `feat(web-search): register the tool + equip/registry parity guard test`

- [ ] **Task 6 — `nalar_config_put` accepts and persists the key.**
  Parse `web_search` on PUT, coerce `""` → absent (the empty-slice-binds-as-NULL trap, and the reason this stays in `config_json` rather than a table), free the previous owned value, and hot-reload `di.llm_config` the way the sibling MCP path already does.
  Verify: `zig build test --summary all`; the functional test in Task 9 is the real proof.
  Commit: `feat(web-search): persist web_search config through the nalar config PUT`

- [ ] **Task 7 — Frontend settings section (D8).**
  `WebSearchSection.vue` (url, masked api key, inferred-provider label, free-tier text, test button), mounted in `NalarSettings.vue` beside `:876`; `NalarConfig.web_search` in `api/index.ts`. The test button calls one real search and renders success **or** the D5 exhausted envelope, so the user can see quota state before the agent does.
  Verify: `(cd src/apps/desktop && pnpm run build)` clean (`vue-tsc` included) + a vitest spec asserting the section emits the parsed config and that an empty key is omitted rather than sent as `""`.
  Commit: `feat(web-search): Settings → Web Search section`

- [ ] **Task 8 — Tool output rendering + Android card.**
  `parseWebSearch` + `ParsedWebSearch` in `toolOutputParser.ts`, `WebSearch.vue`, the `renderResponse.ts:212-220` decision, and the Android `ToolCardModel.kt:565-572` mapping + test case.
  Verify: `pnpm test:unit` in `src/apps/desktop`; the Android unit test task.
  Commit: `feat(web-search): render results in the desktop + Android tool card`

- [ ] **Task 9 — Functional test.**
  `tests/functional/web_search_config_test.py`: PUT a `web_search` config, GET it back, assert the round-trip; then assert an **unconfigured** session's tool call yields the not-configured envelope. This is the layer where the empty-slice and route-order failures are actually visible.
  Verify: `zig build install:linux && NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/web_search_config_test.py -v` — on a harness port, never 8081.
  Commit: `test(web-search): config round-trip + unconfigured envelope`

- [ ] **Task 10 — Docs + stale-reference sweep.**
  Correct `2026-08-06-show-preview-local-file.md:110`. Grep the whole repo for surviving claims that `web_search` browses a URL (`docs/superpowers/plans/2026-08-14-pwsh-tool.md:35`, `:1327`, `:1339`; `2026-09-18-agent-tool-output-json-schema.md:121`) and decide per line whether it is historical (leave it) or a live claim (correct it). Add the tool to the user-facing tool list if one exists.
  Commit: `docs(web-search): correct stale web_search references`

## Verification

| Gate | Command | What it proves |
|---|---|---|
| Zig unit | `zig build test --summary all` | Provider resolution, URL building, quota detection, parsing, all three envelopes, and the new equip↔registry parity guard |
| Equip parity (negative) | comment out `tools_equipped.zig:306`, re-run | The new guard test **fails** — this is the specific bug that made the tool invisible, so the guard is only real if it can fail |
| Frontend types | `(cd src/apps/desktop && pnpm run build)` | `vue-tsc` clean; no stray emitted `.js` next to `.ts` |
| Frontend unit | `(cd src/apps/desktop && pnpm test:unit)` | `WebSearch.vue`, `parseWebSearch`, `WebSearchSection.vue` |
| Android unit | the `ToolCardModelTest` task | The new `ToolKind.WebSearch` mapping |
| Functional (wire) | `zig build install:linux` then `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/web_search_config_test.py -v` | The config key survives the real `PUT`/`GET` round-trip, and an unconfigured tool returns the not-configured envelope rather than crashing |
| No-regression | the full set above on the branch **and** on `origin/main` | Establishes which failures (if any) are pre-existing; CI is currently known to have a `fix ci main zig build` card open |
| Manual (human) | paste a real TinyFish key in Settings → Web Search, press **Test**, then ask the agent "what happened in the AI news this week?" | The one thing no automated gate can prove: that a live key produces live results, and that the exhausted envelope reads well when the 1000/day runs out |

**Known-unprovable in CI:** every quota path needs a real exhausted account. The exhaustion envelope is therefore covered by a unit test that replays a recorded 429 body, and the manual gate above is the only real proof of the live path. Stated plainly rather than implied.

## Out of Scope

- **Any provider other than TinyFish being fully wired.** D4's table ships TinyFish plus the alternates the reviewer picks; each alternate's *response shape* differs and is not parsed in this PR. The unknown-host path (D3) covers them functionally, just unstyled.
- **Automatic provider switching.** Impossible with one key (D5) and not what was asked for.
- **Search-result caching, rate limiting, or a daily-budget counter.** TinyFish enforces the quota server-side; a local counter would be a second source of truth that drifts.
- **A `web_fetch` / URL-reader tool.** See D1 — the `command` tool covers it, and the `agent-browser` dependency does not exist on Windows.
- **A DB migration.** Config lives in `config_json`; Migration 100 is not needed for this feature.
- **Search in the Android app's UI beyond the tool card.** The Android client gets the `ToolKind` mapping so the card renders; a native search screen is separate work.
- **Promoting `web_search` into the progressive-tool catalogue.** It is an ordinary equipped tool. `progressive_catalog.zig` / `tool_eligibility.zig` need no entry (verified: neither mentions `web_search` today).

## Open Questions for the reviewer

1. **D7 — default-on or default-off?** Default-on makes search available everywhere but adds a `web_search` schema to every new agent's `tools[]` for users who never configure it. The unconfigured path is a one-line message, not a crash, which is what makes this defensible — but it is a real prompt-cost regression for the majority. **My recommendation: default-on**, consistent with how `ask_user` and `search_tool` are seeded.
2. **D4 — which alternates belong in the table?** TinyFish is verified from the task's curl. I would add Brave Search API and Serper (both free tiers, both `Authorization: Bearer` + `?q=`), but I have not verified their current free-tier terms — please confirm or name the ones you want.
3. **TinyFish's `location` and `language` parameters** are in the task's curl but were not described. Should the tool expose them to the model, or keep the surface to `query` + `count` and hard-default `location=US&language=en`?
4. **Should `count` be model-controllable?** TinyFish returned 10 for an unset `count`. A 10-result page is ~2–3 K tokens of snippets; capping at 5 and truncating snippets may serve the model better than letting it ask for 25.
5. **The API key is stored in `config.json` in plaintext**, exactly as LLM profile keys already are (`Config.zig:117`). Confirm that is acceptable for a third-party key, or whether this one should go to the OS keychain — which would be a larger, separate change affecting LLM keys too.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **The name collides with existing dead code** and an implementer "adds" a second tool instead of replacing the shim, leaving two definitions and a registry conflict | High | Task 4 explicitly deletes the shim and `schemas.WebSearchInput`; Task 5's parity guard test fails on a duplicate |
| **Only `equips()` gets the entry, the registry line stays commented** → the model calls a tool that dispatches nowhere, and the UI renders it exactly like a hung tool | High | This already happened once (`:306`). The parity guard test in Task 5 exists specifically to make it impossible to repeat silently, and is verified negative (temporarily re-comment `:306`, watch it fail) |
| **`api_key` persisted as `""` through the config PUT**, violating the empty-slice/NULL trap or leaving a "configured" tool with a blank key | Medium | Task 6 coerces empty → absent; the frontend omits rather than sends `""`; covered by the Task 7 and Task 9 tests |
| **The key leaks into `llm_history`** because the tool echoes its resolved config on error | High | The error envelopes (D5/D7) are fixed strings that never interpolate the key; a grep-for-`api_key` review gate on the diff |
| **An arbitrary user-supplied `url` becomes an SSRF vector** (the agent can be steered to an internal host) | Medium | Validate the scheme (copy `generate_image.zig:548-556`) and **reject private/loopback/link-local hosts**. Not in the current plan's task list explicitly — add it to Task 2. This is the one thing I would not ship without |
| **TinyFish changes its response shape** | Low | `parseSearchResponse` tolerates a missing `site_name`/`snippet` (both optional) and only hard-requires `url` + `title`; a shape change degrades to fewer fields, not a crash |
| **D7's prompt-cost regression turns out to matter** | Low | Reversible by removing one line from `DEFAULT_AGENT_TOOLS` + `BUILTIN_DEFAULT_TOOLS`; no migration needed either way |

## Plan saved checklist

- [x] Plan written and committed inside the worktree branch
- [x] PR opened against `main` with Goal / design decisions / task table / traps closed
- [x] Every load-bearing fact carries a `path:line` verified first-hand in this worktree
- [ ] User reviewed before execution
