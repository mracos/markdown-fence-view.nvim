-- markdown_fence_view.engines
-- Resolve a view spec to a command builder, and an info-string suffix to one
-- of several.
--
-- An engine is `function(body) -> cmd, stdin`. A view declares either one or
-- several, never both:
--
--   engine  = fv.engines.bash                                        -- one
--   engines = { default = "bash", map = { bash = ..., zsh = ... } }  -- several
--
-- Info-string shape: `<lang> [<engine-name>]`. Example fences:
--   ```mermaid        -> the view's only engine, or `engines.default`
--   ```query zsh      -> engines.map.zsh
--
-- A name exists only so a fence can pick between several, so the single-engine
-- form has none. An unmatched suffix resolves to nil either way, which the
-- caller reports as `unknown engine`, making a typo visible instead of
-- silently running the default.

local M = {}

--- Generic engine: `bash -c <body>`, no stdin.
function M.bash(body)
  return { "bash", "-c", body }, nil
end

--- Factory: pipe body to stdin of a fixed command.
--- Useful for tools that read from `-` (e.g. `mermaid-ascii --file -`).
function M.stdin_pipe(cmd)
  return function(body) return cmd, body end
end

--- The info-string suffix: everything after the first word, or "" if absent.
local function suffix(info_string)
  if not info_string or info_string == "" then return "" end
  local lang = info_string:match("^%S+") or ""
  return (info_string:sub(#lang + 1):gsub("^%s+", ""))
end

--- The lone key of a single-entry table, or nil.
local function single_key(t)
  local found, n = nil, 0
  for k in pairs(t) do
    found, n = k, n + 1
    if n > 1 then return nil end
  end
  return found
end

--- Build the engine resolver for a view spec (reads `.engine` / `.engines`).
function M.build(spec)
  spec = spec or {}
  local one, several = spec.engine, spec.engines

  if one and several then
    error("markdown_fence_view: set `engine` (one) or `engines` (several), not both")
  end
  if type(several) == "function" then
    error("markdown_fence_view: `engines` takes { default, map }; use `engine` for a single function")
  end
  if one and type(one) ~= "function" then
    error("markdown_fence_view: `engine` must be a function(body) -> cmd, stdin")
  end

  if one then
    return {
      resolve = function(info_string)
        if suffix(info_string) ~= "" then return nil end
        return one
      end,
    }
  end

  several = several or {}
  local map = several.map or {}
  local default = several.default or single_key(map)
  return {
    resolve = function(info_string)
      local name = suffix(info_string)
      if name == "" then
        return default and map[default] or nil
      end
      return map[name]
    end,
  }
end

return M
