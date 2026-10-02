# Lua Hooks

Run your own Lua code around every agent tool call. Two tiers, one
function each.

## Locations

| Tier | Path |
|---|---|
| Global | `<config_dir>/hooks/register_hook.lua` |
| Project | `<cwd>/.nalar/hooks/register_hook.lua` (the tool call's working directory) |

`<config_dir>` per OS:

| OS | Global path |
|---|---|
| Linux | `~/.config/nalar/hooks/register_hook.lua` |
| macOS | `~/Library/Application Support/nalar/hooks/register_hook.lua` |
| Windows | `%APPDATA%/nalar/hooks/register_hook.lua` |

Both files are optional; missing files are skipped silently. The global
hook runs first, then the project hook sees whatever the global hook
left (modified args / replaced output chain forward). The first `deny`
wins and stops the chain; a pre `mock` also stops the chain and skips
the real tool.

No settings, no reload command: each file is loaded fresh on every tool
call, so edits apply immediately. Lua is embedded on all platforms
(vendored, no system dependency) — hooks work on Linux, macOS, and
Windows.

## Contract

```lua
function init(event, data)
  -- event is "pre_tool_use" or "post_tool_use", data is a table.
  return nil -- do nothing
end
```

`data` fields (all strings):

| Field | pre | post |
|---|---|---|
| `tool_name` | yes | yes |
| `arguments` | yes (raw JSON) | yes (raw JSON, post-modify) |
| `output` | no | yes (tool result text) |
| `session_id` | yes | yes |
| `cwd` | yes | yes |
| `model` | yes | yes |

Return `nil` (or `false`, or nothing) to do nothing. Return a table to act:

| Event | Return | Effect |
|---|---|---|
| pre | `{ deny = "reason" }` | Block the tool; the agent sees an error envelope with your reason |
| pre | `{ arguments = "{...}" }` | Run the tool with your JSON instead (must parse, else ignored) |
| pre | `{ output = "..." }` | Skip the tool entirely; use your text as its output |
| post | `{ output = "..." }` | Replace the tool output (redact, reformat, …) |
| post | `{ deny = "reason" }` | Replace the tool output with an error envelope |

Unknown keys and wrong-typed values are ignored. Applies to builtin
tools and `mcp_*` tools alike.

## Failure semantics (fail-open)

Hooks are your scripts, and scripts break. Any of these logs one line
and runs the tool normally:

- file missing, `init` missing, `init` not a function
- Lua syntax or runtime error
- non-table return, empty `deny`, invalid `arguments` JSON

Only an explicit, well-formed table changes behavior.

## Example

See [`examples/hooks/register_hook.lua`](../examples/hooks/register_hook.lua):
deny `rm -rf` shell commands pre-tool, redact `sk-` secrets post-tool.

## Running commands from a hook

Hooks commonly shell out (a formatter, a linter). Two platform facts
constrain how:

**`io.popen` is not available.** The embedded Lua compiles it only under
`LUA_USE_POSIX` / `LUA_USE_WINDOWS`; without one of those it falls back to
the ISO C stub, which raises `'popen' not supported` when called. Use
`os.execute` instead — it returns `true` on success and
`nil, "exit", code` on a non-zero exit, so the exit code is available:

```lua
local ok, how, code = os.execute("zig fmt --check " .. q)
if ok then          -- exit 0
elseif how == "exit" then return code end
```

For output you need to read back, redirect to a temp file and use
`os.tmpname()` / `os.remove()` rather than a pipe. Quote paths per platform:
POSIX uses `'...'`, `cmd.exe` uses `"..."` with embedded `"` doubled.

Every hook run is synchronous on the tool-dispatch path, so cap anything
slow with `timeout 30s sh -c '...'` on POSIX.

## Format-on-edit, without the churn

The project hook at `.nalar/hooks/register_hook.lua` uses exactly this to
format what the agent edits: prettier for Vue/TS, `zig fmt` for Zig.

The Zig case is not "just run the formatter". `zig fmt` rewrites the whole
file, not the edited region, and this repo's Zig tree is deliberately not
fmt-clean (`.github/workflows/ci.yml` says so on purpose, because gating on
it would turn every PR red on a change nobody made). Running it
unconditionally turns a small edit into a large diff of unrelated
reformatting.

So the hook gates on history: it runs `zig fmt` only when the file's
committed version (`git show HEAD:<file>`) was already `zig fmt --check`-clean.
Then anything the formatter still changes is either what this edit
introduced or what the formatter already wanted to change — churn cannot
leak into legacy hand-style. Untracked (new) files count as clean, since
there is no history to disturb.

If you copy this pattern, note that `zig fmt` leaves a file that does not
parse byte-for-byte unchanged (it exits non-zero without writing), so a
mid-edit file is never corrupted.

## Debugging

Hook problems appear in the nalar log prefixed with `[hooks]`, e.g.
`[hooks] /home/you/.config/nalar/hooks/register_hook.lua load failed:
...: <name> expected near ...`.
