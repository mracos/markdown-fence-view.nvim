-- markdown_fence_view
-- Spec-driven render-markdown handler for fenced code blocks.
--
-- See README.md in this directory for full docs. In short: a consumer
-- calls `fv.new(spec)` and gets back a view instance whose `handler()`
-- plugs into render-markdown's `custom_handlers`. The instance's
-- `setup(opts)` is called at plugin-load time to register user commands
-- and BufWritePost invalidation.
--
-- The shared module handles: treesitter walk, fold-safe extmark
-- placement, async spawn + spinner, cache with double-spawn protection,
-- SIGKILL-as-timeout, and error surfacing via vim.notify.

local M = {}

local blocks = require("markdown_fence_view.blocks")
local marks = require("markdown_fence_view.marks")
local exec = require("markdown_fence_view.exec")
local engines_mod = require("markdown_fence_view.engines")

M.exec = exec
M.engines = engines_mod           -- exposes bash + stdin_pipe factories
M.gates = require("markdown_fence_view.gates")
M.write_invalidate = require("markdown_fence_view.write_invalidate")

-- Registry of view instances built via M.setup({ views = ... }).
local views = {}
M._views = views

local function refresh_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local ok_api, api = pcall(require, "render-markdown.api")
    if ok_api and api.render then
      pcall(api.render, { buf = buf, event = "fence_view_async" })
    end
  end)
end

local function status_line(labels, result)
  local extra = labels.extra or {}
  if extra[result.reason] then
    return { { "  // " .. extra[result.reason], "Comment" } }
  end
  if result.reason == "running" then
    return { { "  // " .. (labels.running or "running..."), "Comment" } }
  elseif result.reason == "timeout" then
    return { { "  // " .. (labels.timeout or "timed out"), "DiagnosticWarn" } }
  elseif not result.ok then
    local msg
    if result.stderr and result.stderr ~= "" then
      msg = result.stderr
    elseif result.signal and result.signal ~= 0 then
      msg = "killed by signal " .. tostring(result.signal)
    else
      msg = "exit " .. tostring(result.code or "?")
    end
    return { { "  // " .. (labels.error or "error") .. ": " .. msg, "DiagnosticError" } }
  elseif #result.lines == 0 then
    return { { "  // " .. (labels.empty or "(no output)"), "Comment" } }
  end
  return nil
end

--- Build a fence-view instance from a spec.
function M.new(spec)
  assert(type(spec) == "table" and type(spec.name) == "string",
    "markdown_fence_view.new: spec.name (string) required")

  local name = spec.name
  local labels = spec.labels or {}
  local engines = engines_mod.build(spec.engines)
  local gate = spec.gate
  local cwd_fn = spec.cwd
  local transform_output = spec.transform_output
  local ok_footer = spec.ok_footer or function(n_lines, elapsed_ms)
    return string.format("  // %d row(s), %dms", n_lines, elapsed_ms)
  end
  local default_timeout = spec.timeout_ms or 2000

  local config = {
    enabled = true,
    buf_disabled = {},
    timeout_ms = default_timeout,
  }
  -- Copy any consumer-supplied additional config fields (e.g. allow_paths).
  for k, v in pairs(spec.extra_config or {}) do config[k] = v end

  local function configure(opts)
    for k, v in pairs(opts or {}) do config[k] = v end
  end

  local function set_buf_enabled(buf, enabled)
    config.buf_disabled[buf] = not enabled
  end

  local function resolve_cwd(buf_path)
    if cwd_fn then
      local override = cwd_fn(buf_path, config)
      if override then return override end
    end
    return vim.fn.fnamemodify(buf_path, ":h")
  end

  local function parse(ctx)
    if not config.enabled then return {} end
    -- render-markdown invokes this once per matching subtree; run only on
    -- the last pass so we don't multiply-render the same fences.
    if ctx.last == false then return {} end
    local buf = ctx.buf
    if config.buf_disabled[buf] then return {} end

    local buf_path = vim.api.nvim_buf_get_name(buf)
    local gate_reason
    if gate then gate_reason = gate(buf_path, config) end

    local list = blocks.gather(buf, name)
    local out_marks = {}
    local cwd = resolve_cwd(buf_path)

    for _, b in ipairs(list) do
      local result
      if gate_reason then
        result = { ok = false, lines = {}, stderr = "",
                   reason = gate_reason, elapsed_ms = 0 }
      else
        local engine = engines.resolve(b.info)
        if not engine then
          result = { ok = false, lines = {},
                     stderr = "unknown engine: " .. b.info,
                     reason = "error", elapsed_ms = 0 }
        else
          local run_opts = {
            cmd = engine, cwd = cwd, timeout_ms = config.timeout_ms,
            transform_output = transform_output,
          }
          local cached = exec.get(name, b.body, run_opts)
          if cached and cached.status ~= "in_progress" then
            result = cached
          elseif cached and cached.status == "in_progress" then
            result = { ok = false, lines = {}, stderr = "",
                       reason = "running", elapsed_ms = 0 }
          else
            local ok_kick, err = pcall(exec.run_async, name, b.body, run_opts, function()
              refresh_buffer(buf)
            end)
            if not ok_kick then
              local msg = tostring(err)
              vim.schedule(function()
                vim.notify("markdown_fence_view[" .. name .. "]: " .. msg,
                  vim.log.levels.ERROR)
              end)
              result = { ok = false, lines = {}, stderr = msg,
                         reason = "error", elapsed_ms = 0 }
            else
              result = { ok = false, lines = {}, stderr = "",
                         reason = "running", elapsed_ms = 0 }
            end
          end
        end
      end

      local virt_lines = {}
      for _, line in ipairs(result.lines) do
        table.insert(virt_lines, { { line, "Normal" } })
      end
      local status = status_line(labels, result)
      if status then table.insert(virt_lines, status) end
      if result.reason == "ok" and #result.lines > 0 then
        table.insert(virt_lines, {
          { ok_footer(#result.lines, math.floor(result.elapsed_ms or 0)), "Comment" }
        })
      end

      marks.append(out_marks, buf, b.close_row, virt_lines)
    end

    return out_marks
  end

  local view = {
    name = name,
    handler = function()
      return { extends = false, parse = parse }
    end,
    parse = parse,
    configure = configure,
    set_buf_enabled = set_buf_enabled,
    invalidate = function() exec.invalidate(name) end,
    refresh_buffer = refresh_buffer,
    -- Look up the cached result (including .metadata) for a block. Used
    -- by write-back consumers to pair rendered rows with their source.
    result_for_block = function(buf, block)
      local buf_path = vim.api.nvim_buf_get_name(buf)
      local cwd = resolve_cwd(buf_path)
      return exec.get(name, block.body, { cwd = cwd })
    end,
    -- Enumerate the fence blocks matching this view in `buf`.
    blocks_in_buf = function(buf) return blocks.gather(buf, name) end,
    _internals = {
      config = function() return config end,
      set_config = configure,
      status_line = function(result) return status_line(labels, result) end,
      engines = engines,
      exec = exec,
    },
  }

  --- One-shot setup: apply runtime opts, register commands + autocmds.
  --- Runtime opts merge into config (e.g. allow_paths, timeout_ms).
  --- Setup-time behaviors declared in the spec:
  ---   commands: "MarkdownQuery"    - creates :MarkdownQueryEnable/Disable/Refresh
  ---   write_invalidate: {          - registers BufWritePost invalidation
  ---     patterns   = fn(config) -> string[]      -- ex. { root .. "/**/*.md", ... }
  ---     require    = "%- %["                     -- lua-pattern; buffer must match
  ---   }
  function view.setup(opts)
    configure(opts)

    local commands_prefix = spec.commands
    if commands_prefix then
      vim.api.nvim_create_user_command(commands_prefix .. "Disable", function(args)
        if args.bang then configure({ enabled = false })
        else set_buf_enabled(0, false) end
        exec.invalidate(name)
        refresh_buffer(vim.api.nvim_get_current_buf())
      end, { bang = true, desc = "disable " .. name .. " (use ! for global)" })

      vim.api.nvim_create_user_command(commands_prefix .. "Enable", function(args)
        if args.bang then configure({ enabled = true })
        else set_buf_enabled(0, true) end
        exec.invalidate(name)
        refresh_buffer(vim.api.nvim_get_current_buf())
      end, { bang = true, desc = "enable " .. name .. " (use ! for global)" })

      vim.api.nvim_create_user_command(commands_prefix .. "Refresh", function()
        exec.invalidate(name)
        refresh_buffer(vim.api.nvim_get_current_buf())
      end, { desc = "invalidate " .. name .. " cache and re-render" })
    end

    local wi = spec.write_invalidate
    if wi and wi.patterns then
      local patterns = wi.patterns(config) or {}
      local require_re = wi.require
      local group = vim.api.nvim_create_augroup("markdown_fence_view_" .. name,
        { clear = true })
      for _, pattern in ipairs(patterns) do
        vim.api.nvim_create_autocmd("BufWritePost", {
          group = group,
          pattern = pattern,
          callback = function(args)
            if not require_re then
              exec.invalidate(name)
              return
            end
            local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
            for _, line in ipairs(lines) do
              if line:find(require_re) then
                exec.invalidate(name)
                return
              end
            end
          end,
        })
      end
    end
  end

  return view
end

--- Register global commands acting on ALL registered views. Prefer these over
--- per-view `spec.commands` when you just want one set of controls:
---   <prefix>Refresh           invalidate every view's cache and re-render
---   <prefix>Enable  (! global) enable every view (buffer-local, ! for global)
---   <prefix>Disable (! global) disable every view
function M.register_commands(prefix)
  local function apply(fn)
    for _, view in pairs(views) do fn(view) end
    refresh_buffer(vim.api.nvim_get_current_buf())
  end

  vim.api.nvim_create_user_command(prefix .. "Disable", function(args)
    apply(function(view)
      if args.bang then view.configure({ enabled = false })
      else view.set_buf_enabled(0, false) end
      view.invalidate()
    end)
  end, { bang = true, desc = "disable all markdown fence views (! = global)" })

  vim.api.nvim_create_user_command(prefix .. "Enable", function(args)
    apply(function(view)
      if args.bang then view.configure({ enabled = true })
      else view.set_buf_enabled(0, true) end
      view.invalidate()
    end)
  end, { bang = true, desc = "enable all markdown fence views (! = global)" })

  vim.api.nvim_create_user_command(prefix .. "Refresh", function()
    apply(function(view) view.invalidate() end)
  end, { desc = "invalidate all markdown fence caches and re-render" })
end

--- Top-level entry point: register N views at once.
---
---   fv.setup({
---     views = {
---       { name = "query", ...spec + runtime opts... },
---       { name = "mermaid", ... },
---     },
---     commands = "MarkdownFence",  -- optional: one global command set
---   })
---
--- Each spec is passed to `M.new` and then `.setup()` is called on it with
--- the same table (so runtime opts like `allow_paths` land in config). When
--- `opts.commands` is set, one global `<prefix>Enable/Disable/Refresh` set is
--- registered across all views (instead of per-view `spec.commands`).
function M.setup(opts)
  opts = opts or {}
  for _, spec in ipairs(opts.views or {}) do
    local view = M.new(spec)
    view.setup(spec)
    views[view.name] = view
  end
  if opts.commands then M.register_commands(opts.commands) end
end

--- Return `{ [name] = handler_table }` for `render-markdown`'s `custom_handlers`.
function M.handlers()
  local out = {}
  for name, view in pairs(views) do out[name] = view.handler() end
  return out
end

--- Look up a registered view by name (for tests, manual invalidation, etc.).
function M.get(name) return views[name] end

return M
