-- pabrik Lua hook example.
--
-- Copy this file to <config_dir>/hooks/register_hook.lua:
--   Linux:   ~/.config/pabrik/hooks/register_hook.lua
--   macOS:   ~/Library/Application Support/pabrik/hooks/register_hook.lua
--   Windows: %APPDATA%/pabrik/hooks/register_hook.lua
--
-- pabrik calls init(event, data) around EVERY tool call with exactly one
-- of these events:
--   "pre_tool_use"  — before the tool runs.
--     data = { tool_name, arguments, session_id, cwd, model }
--   "post_tool_use" — after the tool runs.
--     data = { tool_name, arguments, output, session_id, cwd, model }
--
-- Return nil to do nothing. Or return a table to act:
--   pre:  { deny = "reason" }               — block with an error envelope
--   pre:  { arguments = "{...new json...}" } — rewrite args (must be valid JSON)
--   pre:  { output = "..." }                 — mock: skip the tool, use this output
--   post: { output = "..." }                 — replace/redact the tool output
--   post: { deny = "reason" }                — replace output with an error envelope
--
-- Anything else (missing file, missing init, Lua error, bad return shape)
-- fails open: pabrik logs a line and runs the tool normally.

function init(event, data)
  if event == "pre_tool_use" then
    -- Example guard: refuse destructive shell commands.
    if data.tool_name == "command" or data.tool_name == "bash" then
      if string.find(data.arguments, "rm%s+%-rf", 1, false) ~= nil then
        return { deny = "hook: refusing destructive 'rm -rf' command" }
      end
    end
  end

  if event == "post_tool_use" then
    -- Example redaction: never let secret-looking output reach the chat.
    if string.find(data.output, "sk%-", 1, false) ~= nil then
      return { output = "[redacted by hook: possible secret in tool output]" }
    end
  end

  return nil
end
