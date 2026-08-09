-- markdown_fence_view.write_invalidate
-- Reusable `write_invalidate` factories for `fv.new(spec)`.
--
-- A write_invalidate spec is `{ patterns = fn(config) -> string[], require = pattern }`.
-- setup() registers BufWritePost autocmds for each pattern; if `require` is
-- set, the cache is only dropped when the saved buffer contains a line
-- matching that lua-pattern.

local M = {}

--- Factory: patterns are derived from `config[config_key]` (a list of vault
--- roots), and the cache is only dropped if the saved file contains a
--- checkbox line (`- [`). Editing checkbox-less notes keeps the cache warm.
function M.checkbox_lines(config_key)
  return {
    patterns = function(config)
      local pats = {}
      for _, root in ipairs(config[config_key] or {}) do
        table.insert(pats, root .. "/**/*.md")
      end
      return pats
    end,
    require = "%- %[",
  }
end

return M
