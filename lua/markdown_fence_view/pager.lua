-- markdown_fence_view.pager
-- Open a fence's rendered output in a real buffer.
--
-- Virtual lines cannot be scrolled, searched or yanked, so output wider or
-- taller than the window (a mermaid chart, a long query result) is simply
-- cut off at the edge. The pager copies the cached result into a scratch
-- buffer where the normal motions, `/` and `y` all work. Read-only: it is a
-- viewport onto the cache, not an editor (that is `scratch.lua`).

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

--- Cached rendered lines for `block`. Returns lines, or nil plus a reason.
local function result_lines(view, buf, block)
  local cached = view.result_for_block(buf, block)
  if not cached or cached.status == "in_progress" then
    return nil, "Fence result not ready yet - try again in a second."
  end
  if not cached.lines or #cached.lines == 0 then
    local stderr = cached.stderr
    if stderr and stderr ~= "" then
      return nil, "Fence errored: " .. stderr
    end
    return nil, "Fence produced no output."
  end
  return cached.lines
end

--- Widest line, in display cells.
local function max_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > width then
      width = w
    end
  end
  return width
end

--- Float over the editor, sized to the content and capped by the screen. A
--- chart wider than the cap stays scrollable horizontally (`wrap` is off).
local function open_float(bufnr, lines, title)
  local width = math.max(math.min(max_width(lines) + 1, vim.o.columns - 4), 20)
  local height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.8)), 1)
  return vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    footer = " q close  ·  w wrap ",
    footer_pos = "right",
  })
end

--- Open the rendered output of `block` in a scratch buffer.
--- opts: { view, buf, block, style = "float" | "tab" }
--- Returns the scratch bufnr, or nil when there is nothing to show.
function M.open(opts)
  local view = assert(opts.view, "pager.open: view required")
  local block = assert(opts.block, "pager.open: block required")
  local parent_buf = assert(opts.buf, "pager.open: buf required")

  local lines, reason = result_lines(view, parent_buf, block)
  if not lines then
    notify(reason, vim.log.levels.WARN)
    return nil
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  pcall(
    vim.api.nvim_buf_set_name,
    bufnr,
    string.format("fence-view://%s/output/%s", view.name, tostring(block.start_row))
  )

  local title = string.format(" %s: %s (%d lines, %d cols) ", view.name, block.info or "", #lines, max_width(lines))

  local win
  if opts.style == "tab" then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  else
    win = open_float(bufnr, lines, title)
  end

  vim.wo[win].wrap = false
  -- Let the cursor reach the true edge of a wide diagram; `sidescroll` itself
  -- is a global option, so how far each step jumps stays the user's setting.
  vim.wo[win].sidescrolloff = 0

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = bufnr, desc = "close output" })
  vim.keymap.set("n", "<esc>", "<cmd>close<cr>", { buffer = bufnr, desc = "close output" })
  vim.keymap.set("n", "w", function()
    vim.wo[win].wrap = not vim.wo[win].wrap
  end, { buffer = bufnr, desc = "toggle wrap" })

  return bufnr
end

--- Find the fence under (or nearest to) the cursor across `views`.
--- `views` is a map or list of view instances. Returns view, block or nil.
function M.locate(views, buf)
  local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local best
  for _, view in pairs(views) do
    for _, block in ipairs(view.blocks_in_buf(buf)) do
      -- Fence spans [start_row, close_row]; virt_lines anchor at close_row + 1.
      if cur_row >= block.start_row and cur_row <= block.close_row + 1 then
        return view, block
      end
      local dist = math.min(math.abs(cur_row - block.start_row), math.abs(cur_row - block.close_row))
      if not best or dist < best.dist then
        best = { view = view, block = block, dist = dist }
      end
    end
  end
  if best then
    return best.view, best.block
  end
  return nil, nil
end

--- Open the output of the fence under the cursor. Returns the bufnr or nil.
function M.open_at_cursor(views, buf, style)
  buf = buf or vim.api.nvim_get_current_buf()
  local view, block = M.locate(views, buf)
  if not view then
    notify("No rendered fence near cursor", vim.log.levels.INFO)
    return nil
  end
  return M.open({ view = view, buf = buf, block = block, style = style })
end

M._internals = { max_width = max_width, result_lines = result_lines }

return M
