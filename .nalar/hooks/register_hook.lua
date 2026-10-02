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

-- The null sink and the flag that hides stderr, per platform.
local function null_sink()
  if is_windows() then
    return "NUL"
  end
  return "/dev/null"
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

local function dir_of(path)
  return string.match(path, "^(.*)[/\\][^/\\]*$")
end

local function base_of(path)
  return string.match(path, "^.*[/\\]([^/\\]*)$")
end

local function file_exists(abs)
  local f = io.open(abs, "r")
  if f == nil then
    return false
  end
  f:close()
  return true
end

-- Run `cmd` and return its exit code, or nil when it could not be run.
-- os.execute yields (true) on success and (nil, "exit", code) otherwise.
local function run_exit_code(cmd)
  local ok, how, code = os.execute(cmd)
  if ok == true then
    return 0
  end
  if how == "exit" then
    return code
  end
  return nil
end

-- True when the committed version of `abs` was already zig-fmt clean, or
-- when there is no committed version to judge it by.
--
-- This guard is the reason the .zig branch is not simply `zig fmt <file>`.
-- `zig fmt` rewrites the WHOLE file, not the edited region, and this tree
-- is deliberately not fmt-clean (see .github/workflows/ci.yml: "the tree
-- is not fmt-clean today"). Running it unconditionally on a legacy
-- hand-styled file turns a 3-line edit into a 300+ line diff of churn that
-- belongs to nobody — the exact failure recorded when design_model.zig
-- (1251 diff lines) or llm_history.zig (557) got swept up that way.
--
-- So the rule is: format only when HEAD's copy was already clean. Then
-- anything zig fmt still changes is either what this edit introduced or
-- what zig fmt already wanted to change — churn cannot leak into legacy
-- hand-style, and a file nobody has committed yet is free to be canonical.
--
-- `git -C <dir> show HEAD:./<base>` resolves the path relative to <dir>,
-- so no rev-parse round trip is needed to learn the repo-relative name.
local function was_fmt_clean_at_head(abs)
  local dir = dir_of(abs)
  local base = base_of(abs)
  if dir == nil or base == nil then
    return true
  end

  local tmp = os.tmpname()
  local dump = "git -C " .. quote(dir) .. " show " .. quote("HEAD:./" .. base) .. " >" .. quote(tmp) .. " 2>" .. null_sink()
  if run_exit_code(dump) ~= 0 then
    -- Not in git at HEAD (new file, or no git here): no committed style to
    -- protect, so formatting is safe and is what the caller wants.
    os.remove(tmp)
    return true
  end

  local check = run_exit_code("zig fmt --check " .. quote(tmp) .. " >" .. null_sink() .. " 2>&1")
  os.remove(tmp)
  return check == 0
end

local function try_format_prettier(path, cwd)
  local ext = file_ext_lower(path)
  if ext == nil or not PRETTIER_EXTS[ext] then
    return
  end
  local abs = resolve_abs(path, cwd)
  if not file_exists(abs) then
    return
  end
  local q = quote(abs)
  if is_windows() then
    pcall(os.execute, "prettier --write " .. q .. " >NUL 2>&1 || npx --yes prettier --write " .. q .. " >NUL 2>&1")
  else
    local inner = "prettier --write " .. q .. " >/dev/null 2>&1 || npx --yes prettier --write " .. q .. " >/dev/null 2>&1"
    pcall(os.execute, "timeout 30s sh -c " .. shell_quote(inner) .. " >/dev/null 2>&1; exit 0")
  end
end

local function try_format_zig(path, cwd)
  if file_ext_lower(path) ~= ".zig" then
    return
  end
  local abs = resolve_abs(path, cwd)
  if not file_exists(abs) then
    return
  end
  if not was_fmt_clean_at_head(abs) then
    return
  end
  -- A syntax-broken file is left byte-for-byte alone by zig fmt (it exits
  -- non-zero without writing), so a mid-edit file is never corrupted.
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
        try_format_prettier(path, data.cwd)
        try_format_zig(path, data.cwd)
      end
    end
  end
  return nil
end