-- markdown_fence_view.engines
-- Resolve an info-string suffix to a command builder.
--
-- Info-string shape: `<lang> [<engine-name>]`. Example fences:
--   ```query
--   ```query bash
--   ```mermaid
--   ```mermaid mermaid-ascii
--
-- Consumers declare available engines in a spec:
--   {
--     default = "bash",
--     map = {
--       bash = function(body) return { "bash", "-c", body }, nil end,
--       sh   = function(body) return { "bash", "-c", body }, nil end,
--     },
--   }

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

--- Build an engine table from a spec.
function M.build(spec)
  spec = spec or {}
  local map = spec.map or {}
  local default = spec.default
  return {
    resolve = function(info_string)
      if not info_string or info_string == "" then
        return default and map[default] or nil
      end
      local lang = info_string:match("^%S+")
      local rest = info_string:sub(#(lang or "") + 1):gsub("^%s+", "")
      if rest == "" then
        return default and map[default] or nil
      end
      return map[rest]
    end,
    _map = map,
    _default = default,
  }
end

return M
