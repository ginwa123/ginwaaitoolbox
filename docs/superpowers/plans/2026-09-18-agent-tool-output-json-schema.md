# Tool Output JSON Schema (XML → JSON migration)

**Date:** 2026-09-18 · **Status:** contract (Phase 0 of `2026-09-18-agent-tool-output-xml-to-json.md`)
**Rule:** hard cut, no XML fallback. New code must build JSON via `std.json`
serialization (backend) / plain objects (frontend) — never string-concat.

## 1. Outer envelope (replaces `<tool>…</tool>`)

Produced by `wrapToolOutput` (`src/agentic_loop/tools_wrap_output.zig`),
consumed by `parsing.zig` (backend), `tool_envelope.zig` (CLI),
`unwrapToolOutput.ts` (desktop). Stored verbatim in `llm_history.response_content`.

```json
{
  "tool": "read_file",
  "parameters": { "path": "/foo.txt", "offset": 0 },
  "success": true,
  "data": { "path": "/foo.txt", "content": "hi", "total_lines": 10, "start_line": 0, "end_line": 10 },
  "error": null,
  "v": 1
}
```

| Field | Type | Rule |
|---|---|---|
| `tool` | string | Registered tool name, verbatim (no escaping layer — JSON handles it). |
| `parameters` | object | Parsed args object. Malformed args → `{"_raw": "<original string>"}` (mirrors today's `<raw>` fallback). Empty args → `{}`. |
| `success` | boolean | `true` → `data` is an object, `error` is null. `false` → `data` is null, `error` is a string. Mutually exclusive, same as today. |
| `data` | object \| null | Per-tool payload (§2). Object on success, null on error. |
| `error` | string \| null | Human-readable message on error, null on success. |
| `v` | integer | Schema version, always `1`. All three parsers reject (raw-fallback) when `v` is missing or unknown. |

Serialization: `std.json.Stringify.valueAlloc` (precedent: `agent_tools_registry.zig:100`).
Control-char sanitizer (NUL/C0 → U+FFFD, today's `xml_escape.zig` ranges) runs
**before** serialization — JSON strings cannot hold NUL either, and NUL still
truncates SQLite TEXT. Fixture: `tests/fixtures/tool_output/json/envelope_binary_stdout.json`.

## 2. Inner `data` payloads (replace per-tool XML 1:1 — tag names become keys)

### 2.1 `read_file` (from `read_file.zig:86-100`)

```json
{ "path": "/x.txt", "content": "foo\nbar\n", "total_lines": 2, "start_line": 0, "end_line": 1 }
```

`content` is raw file text — `<`/`&` need no escaping in JSON (this fixes the
current raw-interpolation hazard). Fixture: `envelope_success_read_file.json`.

### 2.2 `command` / `shell` / `bash` / `pwsh` (from `shell.zig:802 result_to_xml`, 9 tags)

```json
{
  "command": "ls",
  "stdout": "a\n",
  "stderr": "",
  "exit_code": 0,
  "truncated": false,
  "timeout": false,
  "stdout_lines": 1,
  "stderr_lines": 0,
  "is_self": false
}
```

Booleans stay booleans (today's `true`/`false` text). Fixture: `data_shell.json`.

### 2.3 `search` grouped (from `search.zig:945 search_result_to_string_grouped`)

```json
{
  "pattern": "foo",
  "path": "src/",
  "returned": 2,
  "total": 2,
  "truncated": false,
  "truncated_hint": null,
  "files": [
    { "path": "src/a.zig", "total": 1, "count": 1,
      "matches": [ { "line": 10, "text": "foo bar" } ] }
  ],
  "warning": null
}
```

No-matches case: `"files": []` + `"warning": "<today's warning body>"`.
`truncated_hint` carries today's `<truncated>N of M…</truncated>` prose, null otherwise.
Attribute-style metadata (`pattern=`, `returned=`) becomes plain keys.
Fixture: `data_search.json`.

### 2.4 `ask_user` (from `ask_user.zig:203 buildAskUserXml`)

```json
{
  "status": "answered",
  "question_id": "q1",
  "question": "Pick one",
  "answer": "a",
  "answers_count": 1,
  "header": null,
  "allow_free_text": true,
  "multi_select": false,
  "recommended": null,
  "options": ["a", "b"],
  "instruction": "…"
}
```

Omitted-when-empty XML tags become explicit nulls (`header`, `recommended`),
absent optionals stay absent-or-null consistently as null. `options: []` when none.
`ask_user_answer.zig` (HTTP handler) emits the same envelope shape server-side.
Fixture: `data_ask_user.json`.

### 2.5 Remaining families (Phase 2 — same 1:1 rule, fixtures added per PR)

File tools (`write_file`, `text_replace` incl. diff fields, `remove_file`,
`glob` `{pattern, files[]}`, `list_directory` `{path, entries[]}`),
memory/skill/kanban, design tools, `spawn_sub_agent`/`background_process`,
`update_plan`/`get_plan` (CDATA edge → plain strings), `web_search` /
`semantic_search`, `present_files`, `read_workspace_session`, MCP tools.
Each PR adds its fixture under `tests/fixtures/tool_output/json/`.

## 3. Frontend mapping

- `unwrapToolOutput.ts`: `JSON.parse` only. Same `UnwrappedToolOutput`
  interface, except `data` becomes the parsed object (`unknown`, null on
  error) and `parameters` is re-stringified via `JSON.stringify` so
  `ToolParameters.vue` keeps working. Error name `MalformedToolEnvelope`
  is kept (wire callers + specs reference it).
- `toolOutputParser.ts`: per-tool parsers take `data` as an object and read
  fields directly; `extractTag`/`extractAll`/`unescapeXml` deleted with the
  last caller. `parseShell(toolName, content)` keeps its dispatch signature
  but receives the object.
- Cards render from parsed JSON; no view-state/URL changes in this migration.

## 4. RED specs (Phase 0 — fail until Phase 1 lands)

- Zig: `src/agentic_loop/tool_output_json_contract_test.zig` (wired in
  `test_runner.zig`) — envelope keys, data/error mutual exclusion, `v` tag,
  `_raw` fallback, sanitizer (ELF-header fixture), JSON-only parse rejects
  `<tool>` input. RED: `wrapToolOutput` still emits XML.
- Frontend: `src/apps/desktop/src/helpers/unwrapToolOutput.json.spec.ts` —
  JSON happy-path + malformed-input errors. RED: impl still parses XML.
- Existing XML tests are the pre-refactor lock; Phase 1 rewrites them to JSON
  (no back-compat specs kept).

## 5. Verification (repo rules)

- Zig: `zig build test` (inline + contract tests), in-memory SQLite for
  `useCase` paths (empty-string vs null per Migration 079 precedent).
- Wire: `tests/functional/harness.py` only (isolated HOME, free port ≠ 8081).
  Never `nohup` + `curl`. Cover `file_path:""` empty case + ask_user round-trip.
- Frontend: `pnpm vitest --run` in `src/apps/desktop`.
- No new routes; route-order rule (`router.zig:182`) applies to test helpers.
