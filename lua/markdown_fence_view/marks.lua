-- markdown_fence_view.marks
-- Emit extmarks with virt_lines anchored outside the fenced-code-block fold.
--
-- UFO closes fenced_code_block as its own inner fold on BufWinEnter.
-- Placing the anchor at the closing fence row hides the virt_lines along
-- with the fold. Anchoring one row past the fence with virt_lines_above
-- renders in the same visual spot but stays outside the fold.

local M = {}

function M.append(marks, buf, close_row, virt_lines)
  if #virt_lines == 0 then return end
  local anchor_row = close_row + 1
  local last_row = vim.api.nvim_buf_line_count(buf) - 1
  local above = true
  if anchor_row > last_row then
    anchor_row = close_row
    above = false
  end
  table.insert(marks, {
    start_row = anchor_row,
    start_col = 0,
    opts = {
      virt_lines = virt_lines,
      virt_lines_above = above,
      hl_mode = "combine",
    },
  })
end

return M
