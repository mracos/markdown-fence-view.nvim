-- m.markdown_fence_view.gates
-- Reusable `gate` factories for `fv.new(spec)`.
--
-- A gate runs once per parse call and returns a reason string that maps to
-- `spec.labels.extra[reason]`, or nil to allow the block to execute.

local M = {}

--- Factory: reject blocks in buffers whose realpath is not under any of the
--- paths configured at `config[config_key]`.
---
--- Usage:
---   fv.new({
---     ...,
---     extra_config = { allow_paths = { NOTES_DIR } },
---     gate = fv.gates.path_allow_list("allow_paths"),
---   })
function M.path_allow_list(config_key, reason)
  reason = reason or "path"
  return function(buf_path, config)
    if not buf_path or buf_path == "" then return reason end
    local resolved = vim.uv.fs_realpath(buf_path) or buf_path
    for _, root in ipairs(config[config_key] or {}) do
      if root and root ~= "" then
        local root_resolved = vim.uv.fs_realpath(root) or root
        if resolved:sub(1, #root_resolved) == root_resolved then return nil end
      end
    end
    return reason
  end
end

--- Factory: reject if a required binary is not on PATH. Reason defaults to
--- "missing" so specs can point `labels.extra.missing` at a hint.
function M.executable(binary, reason)
  reason = reason or "missing"
  return function()
    if vim.fn.executable(binary) ~= 1 then return reason end
  end
end

return M
