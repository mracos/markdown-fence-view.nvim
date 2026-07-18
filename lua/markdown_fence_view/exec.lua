-- m.markdown_fence_view.exec
-- Shared command runner + cache used by every fence view.
-- Cache keys are namespaced by view name so `notes todos query` and
-- `notes todos mermaid` (unlikely, but possible) don't collide.
--
--   get(name, body, opts)                 -> cached entry | in_progress | nil
--   run(name, body, opts)                 -- synchronous
--   run_async(name, body, opts, on_done)  -- non-blocking
--   invalidate(name?)                     -- name given: only that view

local M = {}

local cache = {}
M._cache = cache

local function hash(body) return vim.fn.sha256(body) end
local function key_for(name, body, cwd) return name .. "\0" .. hash(body) .. "\0" .. (cwd or "") end

function M.get(name, body, opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.expand("~")
  return cache[key_for(name, body, cwd)]
end

local function classify(result, timeout_ms, elapsed_ms)
  if result == nil then
    return { ok = false, lines = {}, stderr = "timed out after " .. timeout_ms .. "ms",
             elapsed_ms = elapsed_ms, reason = "timeout" }
  end
  local stdout = result.stdout or ""
  local lines = {}
  for line in stdout:gmatch("([^\n]*)\n?") do
    if line ~= "" then table.insert(lines, line) end
  end
  -- vim.system:wait(timeout) SIGKILLs on timeout instead of returning nil,
  -- surfacing as code=124 / signal=9. Reclassify so status_line shows the
  -- actual reason instead of a generic empty-stderr error.
  local timed_out = (result.signal == 9) or (result.code == 124 and (not result.stderr or result.stderr == ""))
  local reason
  if timed_out then
    reason = "timeout"
  elseif result.code == 0 then
    reason = "ok"
  else
    reason = "error"
  end
  return {
    ok = result.code == 0 and not timed_out,
    lines = lines,
    stderr = result.stderr or "",
    elapsed_ms = elapsed_ms,
    reason = reason,
    code = result.code,
    signal = result.signal,
  }
end
M._classify = classify

function M.run(name, body, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 2000
  local cwd = opts.cwd or vim.fn.expand("~")
  local cmd_fn = opts.cmd
  if not cmd_fn then error("markdown_fence_view.exec.run: opts.cmd required") end

  if body == nil or body:match("^%s*$") then
    return { ok = true, lines = {}, stderr = "", elapsed_ms = 0, reason = "empty" }
  end

  local key = key_for(name, body, cwd)
  local cached = cache[key]
  if cached and cached.status ~= "in_progress" and not opts.no_cache then
    return cached
  end

  local cmd, stdin = cmd_fn(body)
  local start = vim.uv.hrtime()
  local sys = vim.system(cmd, { text = true, cwd = cwd, stdin = stdin })
  local result = sys:wait(timeout_ms)
  local elapsed_ms = (vim.uv.hrtime() - start) / 1e6

  local out = classify(result, timeout_ms, elapsed_ms)
  cache[key] = out
  return out
end

function M.run_async(name, body, opts, on_done)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 2000
  local cwd = opts.cwd or vim.fn.expand("~")
  local cmd_fn = opts.cmd
  if not cmd_fn then error("markdown_fence_view.exec.run_async: opts.cmd required") end

  if body == nil or body:match("^%s*$") then
    local out = { ok = true, lines = {}, stderr = "", elapsed_ms = 0, reason = "empty" }
    if on_done then vim.schedule(function() on_done(out) end) end
    return "cached"
  end

  local key = key_for(name, body, cwd)
  local cached = cache[key]
  if cached and not opts.no_cache then
    if cached.status == "in_progress" then return "in_progress" end
    if on_done then vim.schedule(function() on_done(cached) end) end
    return "cached"
  end

  local start = vim.uv.hrtime()
  cache[key] = { status = "in_progress", started_at = start }
  local cmd, stdin = cmd_fn(body)

  vim.system(cmd, { text = true, cwd = cwd, stdin = stdin, timeout = timeout_ms }, function(result)
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    local out = classify(result, timeout_ms, elapsed_ms)
    cache[key] = out
    if on_done then vim.schedule(function() on_done(out) end) end
  end)

  return "started"
end

--- Drop cached entries. If `name` is given, only that view's entries.
function M.invalidate(name)
  if name then
    local prefix = name .. "\0"
    for k, _ in pairs(cache) do
      if k:sub(1, #prefix) == prefix then cache[k] = nil end
    end
  else
    for k, _ in pairs(cache) do cache[k] = nil end
  end
end

return M
