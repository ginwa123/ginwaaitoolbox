-- Project hook for ginwaaitoolbox: auto-format Vue/TS after agent edits.
--
-- nalar loads this file fresh on every tool call as the project tier:
--   <repo>/.nalar/hooks/register_hook.lua
-- (global <config_dir>/hooks/register_hook.lua runs first when present).
--
-- Contract: init("pre_tool_use" | "post_tool_use", data). Return nil to do
-- nothing. See examples/hooks/register_hook.lua + docs/hooks.md for the
-- full table of return shapes. Everything fails open.
--
-- What this does: on post_tool_use for write_file / text_replace, when the
-- edited path ends in .vue/.ts/.mts/.tsx, run prettier --write on the file
-- on disk (best-effort, silenced, 30s cap on POSIX). The tool output is
-- left untouched — the formatting is a disk side effect, not a chat edit.

local FORMAT_EXTS = {
  [".vue"] = true,
  [".ts"] = true,
  [".mts"] = true,
  [".tsx"] = true,
}

local function shell_quote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function file_ext_lower(path)
  local ext = string.match(path, "(%.[^./\\]+)$")
  if ext == nil then
    return nil
  end
  return string.lower(ext)
end

local function extract_path(arguments)
  if arguments == nil or arguments == "" then
    return nil
  end
  return string.match(arguments, '"path"%s*:%s*"([^"]+)"')
end

local function resolve_abs(path, cwd)
  if string.match(path, "^/") ~= nil then
    return path
  end
  if string.match(path, "^%a:") ~= nil then
    return path
  end
  if string.match(path, "^\\\\") ~= nil then
    return path
  end
  if cwd ~= nil and cwd ~= "" then
    return cwd .. "/" .. path
  end
  return path
end

local function try_format(path, cwd)
  local ext = file_ext_lower(path)
  if ext == nil or not FORMAT_EXTS[ext] then
    return
  end
  local abs = resolve_abs(path, cwd)
  local f = io.open(abs, "r")
  if f == nil then
    return
  end
  f:close()
  local is_win = package.config:sub(1, 1) == "\\"
  if is_win then
    local q = '"' .. string.gsub(abs, '"', '""') .. '"'
    pcall(os.execute, "prettier --write " .. q .. " >NUL 2>&1 || npx --yes prettier --write " .. q .. " >NUL 2>&1")
  else
    local q = shell_quote(abs)
    local inner = "prettier --write " .. q .. " >/dev/null 2>&1 || npx --yes prettier --write " .. q .. " >/dev/null 2>&1"
    pcall(os.execute, "timeout 30s sh -c " .. shell_quote(inner) .. " >/dev/null 2>&1; exit 0")
  end
end

function init(event, data)
  if event == "post_tool_use" then
    if data.tool_name == "write_file" or data.tool_name == "text_replace" then
      local path = extract_path(data.arguments)
      if path ~= nil then
        try_format(path, data.cwd)
      end
    end
  end
  return nil
end
