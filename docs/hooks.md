# Lua Hooks

Run your own Lua code around every agent tool call. One file, one function.

## Location

Create exactly one file:

| OS | Path |
|---|---|
| Linux | `~/.config/nalar/hooks/register_hook.lua` |
| macOS | `~/Library/Application Support/nalar/hooks/register_hook.lua` |
| Windows | `%APPDATA%/nalar/hooks/register_hook.lua` |

No file → hooks disabled, tools run normally. No settings, no reload
command: the file is loaded fresh on every tool call, so edits apply
immediately.

Linux-only in v1: other platforms boot and run normally with hooks
silently disabled.

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

## Debugging

Hook problems appear in the nalar log prefixed with `[hooks]`, e.g.
`[hooks] /home/you/.config/nalar/hooks/register_hook.lua load failed:
...: <name> expected near ...`.
