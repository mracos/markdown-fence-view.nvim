-- markdown_fence_view.blocks
-- Walk the markdown treesitter tree for fenced_code_block nodes whose
-- first info-string word matches a given language.
--
-- render-markdown.nvim passes ctx.root scoped to an injected language
-- subtree (e.g. `query`, `mermaid`), which contains no fenced_code_block
-- nodes. Grab the markdown parser's own root here so the query matches.

local M = {}

--- Return a list of { info = string, body = string, close_row = int }.
function M.gather(buf, lang)
  local parser = vim.treesitter.get_parser(buf, "markdown")
  if not parser then return {} end
  local trees = parser:parse()
  if not trees or not trees[1] then return {} end
  local root = trees[1]:root()
  local query = vim.treesitter.query.parse("markdown", [[
    (fenced_code_block
      (info_string) @info
      (code_fence_content)? @body
      (fenced_code_block_delimiter) @close .
    ) @block
  ]])
  local out = {}
  for _, match in query:iter_matches(root, buf, 0, -1, { all = true }) do
    local info_nodes = match[1]
    local block_nodes = match[4]
    if info_nodes then
      local info_text = vim.treesitter.get_node_text(info_nodes[1], buf):gsub("%s+$", "")
      local lang_word = info_text:match("^(%S+)") or ""
      if lang_word == lang then
        local body_nodes = match[2]
        local close_nodes = match[3]
        local body = body_nodes and vim.treesitter.get_node_text(body_nodes[1], buf) or ""
        local close_node = close_nodes and close_nodes[1] or nil
        local close_row = close_node and select(1, close_node:end_()) or 0
        local block_node = block_nodes and block_nodes[1] or nil
        local start_row = block_node and select(1, block_node:start()) or close_row
        table.insert(out, {
          info = info_text, body = body,
          start_row = start_row, close_row = close_row,
        })
      end
    end
  end
  return out
end

return M
