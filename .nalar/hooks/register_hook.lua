-- Project hook for ginwaaitoolbox: auto-format edited sources.
--
-- nalar loads this file fresh on every tool call as the project tier:
--   <repo>/.nalar/hooks/register_hook.lua
-- (global <config_dir>/hooks/register_hook.lua runs first when present).
--
-- Contract: init("pre_tool_use" | "post_tool_use", data). Return nil to do
-- nothing. See examples/hooks/register_hook.lua + docs/hooks.md for the
-- full table of return shapes. Everything fails open.
--
-- What this does: on post_tool_use for write_file / text_replace, format
-- the edited file on disk — prettier for Vue/TS, zig fmt for Zig. The tool
-- output is left untouched: formatting is a disk side effect, not a chat
-- edit, so the model never sees a diff it did not ask for.
--
-- zig fmt rewrites the whole file, not just the edited region. That is
-- fine here — it is what "formatted" means for Zig, and the resulting
-- cleanup is wanted rather than fought.
--
-- NOTE: every subprocess here goes through os.execute, never io.popen.
-- The vendored Lua (vendor/lua/liolib.c) only compiles io.popen when
-- LUA_USE_POSIX / LUA_USE_WINDOWS is defined, and build.zig defines
-- neither — the ISO-C fallback raises "'popen' not supported" at runtime.

local PRETTIER_EXTS = {
  [".vue"] = true,
  [".ts"] = true,
  [".mts"] = true,
  [".tsx"] = true,
}

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

local function shell_quote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- cmd.exe has no single-quote form and treats " as a metacharacter, so
-- double any embedded quote instead.
local function win_quote(s)
  return '"' .. string.gsub(s, '"', '""') .. '"'
end

local function quote(s)
  if is_windows() then
    return win_quote(s)
  end
  return shell_quote(s)
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

local function file_exists(abs)
  local f = io.open(abs, "r")
  if f == nil then
    return false
  end
  f:close()
  return true
end

local function try_format_prettier(abs)
  if is_windows() then
    local q = quote(abs)
    pcall(os.execute, "prettier --write " .. q .. " >NUL 2>&1 || npx --yes prettier --write " .. q .. " >NUL 2>&1")
  else
    local q = shell_quote(abs)
    local inner = "prettier --write " .. q .. " >/dev/null 2>&1 || npx --yes prettier --write " .. q .. " >/dev/null 2>&1"
    pcall(os.execute, "timeout 30s sh -c " .. shell_quote(inner) .. " >/dev/null 2>&1; exit 0")
  end
end

-- Whole-file format, unconditionally. A file that does not parse is left
-- byte-for-byte unchanged (zig fmt exits non-zero without writing), so a
-- mid-edit file is never corrupted.
local function try_format_zig(abs)
  if is_windows() then
    pcall(os.execute, "zig fmt " .. quote(abs) .. " >NUL 2>&1")
  else
    pcall(os.execute, "timeout 30s sh -c " .. shell_quote("zig fmt " .. shell_quote(abs)) .. " >/dev/null 2>&1; exit 0")
  end
end

function init(event, data)
  if event == "post_tool_use" then
    if data.tool_name == "write_file" or data.tool_name == "text_replace" then
      local path = extract_path(data.arguments)
      if path ~= nil then
        local ext = file_ext_lower(path)
        local abs = resolve_abs(path, data.cwd)
        if ext ~= nil and file_exists(abs) then
          if ext == ".zig" then
            try_format_zig(abs)
          elseif PRETTIER_EXTS[ext] then
            try_format_prettier(abs)
          end
        end
      end
    end
  end
  return nil
end