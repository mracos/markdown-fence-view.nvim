-- m.markdown_fence_view.scratch
-- Open a floating scratch buffer over a fence block's rendered rows so the
-- user can edit them and sync back to source files on :w.
--
-- Extmarks give each row a durable identity that survives reorders/edits:
--   shadow[extmark_id] = { path, source_lineno, source_mtime, original }
--
-- Design details: docs/adrs/editors/0003-editors-nvim-query-view-writeback.md

local M = {}

local ns = vim.api.nvim_create_namespace("markdown_fence_view_scratch")

local function get_mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime and st.mtime.sec or 0
end

local function feed_notify(msg, level)
  vim.schedule(function() vim.notify(msg, level or vim.log.levels.INFO) end)
end

--- Replace a single line in a source file. Uses a real buffer so undo,
--- BufWritePost autocmds, and other integrations fire correctly.
local function replace_source_line(path, lineno, new_text)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, lineno - 1, lineno, false, { new_text })
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
end

--- Rewrite the checkbox on `lineno` of `path` to `[-]` (dropped), preserving
--- the rest of the line. If there's no checkbox, do nothing.
local function drop_source_line(path, lineno)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  local line = vim.api.nvim_buf_get_lines(bufnr, lineno - 1, lineno, false)[1]
  if not line then return end
  local rewritten = line
  if line:match("%[ %]") then rewritten = line:gsub("%[ %]", "[-]", 1)
  elseif line:match("%[x%]") then rewritten = line:gsub("%[x%]", "[-]", 1)
  end
  if rewritten == line then return end
  vim.api.nvim_buf_set_lines(bufnr, lineno - 1, lineno, false, { rewritten })
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
end

--- Group `changes` by `path` and apply them, checking mtime before each file.
--- Returns { applied = int, refused = { path, ... } }.
local function apply_changes(changes, shadow)
  local by_path = {}
  for _, c in ipairs(changes) do
    by_path[c.path] = by_path[c.path] or {}
    table.insert(by_path[c.path], c)
  end
  local applied, refused = 0, {}
  for path, list in pairs(by_path) do
    local current = get_mtime(path)
    -- All shadow entries for this path share the same recorded mtime.
    local recorded = 0
    for _, entry in pairs(shadow) do
      if entry.path == path then recorded = entry.source_mtime; break end
    end
    if recorded > 0 and current > recorded then
      table.insert(refused, path)
    else
      for _, c in ipairs(list) do
        if c.kind == "replace" then
          replace_source_line(c.path, c.lineno, c.new_text)
        elseif c.kind == "drop" then
          drop_source_line(c.path, c.lineno)
        end
        applied = applied + 1
      end
    end
  end
  return { applied = applied, refused = refused }
end

--- Build the batch of changes from the current scratch state. Returns:
---   { changes = { {kind, path, lineno, new_text?} }, additions = int, needs_confirm = bool }
local function diff_batch(scratch, shadow)
  local live = vim.api.nvim_buf_get_extmarks(scratch, ns, 0, -1, {})
  local seen = {}
  local changes = {}
  local additions = 0
  local drops = 0

  for _, m in ipairs(live) do
    local id, row = m[1], m[2]
    seen[id] = true
    local entry = shadow[id]
    if entry then
      local text = vim.api.nvim_buf_get_lines(scratch, row, row + 1, false)[1] or ""
      if text ~= entry.original then
        table.insert(changes, {
          kind = "replace", path = entry.path, lineno = entry.source_lineno,
          new_text = text,
        })
      end
    end
  end

  -- Live lines with no shadow entry -> additions.
  local total_live = vim.api.nvim_buf_line_count(scratch)
  local extmark_rows = {}
  for _, m in ipairs(live) do extmark_rows[m[2]] = true end
  for r = 0, total_live - 1 do
    if not extmark_rows[r] then
      local text = vim.api.nvim_buf_get_lines(scratch, r, r + 1, false)[1] or ""
      if text:match("%S") then additions = additions + 1 end
    end
  end

  -- Shadow entries with no live extmark -> deletions -> drop in source.
  for id, entry in pairs(shadow) do
    if not seen[id] then
      table.insert(changes, {
        kind = "drop", path = entry.path, lineno = entry.source_lineno,
      })
      drops = drops + 1
    end
  end

  return { changes = changes, additions = additions, needs_confirm = drops > 3 }
end

--- Open a scratch buffer for `block` under `view`. Returns the scratch buf id
--- (or nil if there's nothing to render / no metadata).
function M.open(opts)
  local view = assert(opts.view, "scratch.open: view required")
  local block = assert(opts.block, "scratch.open: block required")
  local parent_buf = assert(opts.buf, "scratch.open: buf required")

  local cached = view.result_for_block(parent_buf, block)
  if not cached or cached.status == "in_progress" then
    feed_notify("Fence result not ready yet — try again in a second.", vim.log.levels.WARN)
    return nil
  end
  if not cached.metadata or #cached.metadata == 0 then
    feed_notify(
      "No metadata for this block. Add `--format json` to the fence body to enable toggle.",
      vim.log.levels.WARN)
    return nil
  end

  local display_lines = {}
  local metadata_index = {}
  for i, meta in ipairs(cached.metadata) do
    if meta and meta.path and meta.lineno then
      -- Prefer the source-form `raw` line (no display decoration) so edits
      -- roundtrip cleanly. Fall back to the rendered line if raw is missing.
      table.insert(display_lines, meta.raw or cached.lines[i])
      table.insert(metadata_index, meta)
    end
  end
  if #display_lines == 0 then
    feed_notify("Block has no rows with a source locator.", vim.log.levels.WARN)
    return nil
  end

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "acwrite"
  vim.bo[scratch].filetype = "markdown"
  vim.bo[scratch].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, scratch,
    string.format("fence-view://%s/%s", view.name, os.time()))
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, display_lines)

  local shadow = {}
  for i, meta in ipairs(metadata_index) do
    local id = vim.api.nvim_buf_set_extmark(scratch, ns, i - 1, 0, {})
    shadow[id] = {
      path = meta.path,
      source_lineno = meta.lineno,
      source_mtime = get_mtime(meta.path),
      original = display_lines[i],
    }
  end

  -- Float the buffer over the center of the editor, sized to content.
  local width = math.min(math.max(80, vim.o.columns - 20), 140)
  local height = math.min(#display_lines + 2, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  vim.api.nvim_open_win(scratch, true, {
    relative = "editor", width = width, height = height, row = row, col = col,
    style = "minimal", border = "rounded",
    title = string.format(" %s: %s ", view.name, block.info or ""),
    title_pos = "left",
    footer = " :w sync back to source  ·  :q cancel ",
    footer_pos = "right",
  })

  -- Buffer-local q for quick cancel without wiping the file (bufhidden = wipe
  -- already handles cleanup). Also bind <localleader>tt so the open/close
  -- keybind is symmetrical (same trigger toggles the scratch off).
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = scratch, desc = "cancel" })
  vim.keymap.set("n", "<localleader>tt", "<cmd>close<cr>", { buffer = scratch, desc = "cancel (toggle off)" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = scratch,
    callback = function()
      local batch = diff_batch(scratch, shadow)

      if batch.additions > 0 then
        feed_notify(
          string.format(":w failed — %d new line(s) have no source. " ..
            "Use `notes capture` to add TODOs.", batch.additions),
          vim.log.levels.ERROR)
        return
      end

      if batch.needs_confirm then
        local dropped = 0
        for _, c in ipairs(batch.changes) do
          if c.kind == "drop" then dropped = dropped + 1 end
        end
        local choice = vim.fn.confirm(
          string.format("Mark %d TODOs as [-] dropped?", dropped),
          "&Yes\n&No", 2)
        if choice ~= 1 then return end
      end

      local result = apply_changes(batch.changes, shadow)

      if #result.refused > 0 then
        feed_notify(
          "Some source files changed on disk since the scratch opened; " ..
          "refused writes to: " .. table.concat(result.refused, ", "),
          vim.log.levels.WARN)
      end

      view.invalidate()
      view.refresh_buffer(parent_buf)
      vim.bo[scratch].modified = false
      pcall(vim.cmd, "close")
      feed_notify(string.format("Synced %d change(s).", result.applied))
    end,
  })

  return scratch
end

--- Find the block under (or nearest to) the cursor in `buf`. Returns block or nil.
function M.block_under_cursor(view, buf)
  local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local best
  for _, block in ipairs(view.blocks_in_buf(buf)) do
    -- Fence spans [start_row, close_row]; virt_lines anchor at close_row + 1.
    if cur_row >= block.start_row and cur_row <= block.close_row + 1 then
      return block
    end
    -- Fallback: pick the closest fence if cursor isn't inside any.
    local dist = math.min(math.abs(cur_row - block.start_row),
      math.abs(cur_row - block.close_row))
    if not best or dist < best.dist then
      best = { block = block, dist = dist }
    end
  end
  return best and best.block or nil
end

M._internals = { diff_batch = diff_batch, ns = ns }

return M
