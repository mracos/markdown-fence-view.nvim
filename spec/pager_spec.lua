describe("markdown_fence_view/pager", function()
  local pager
  local original_vim
  local state

  local function make_view(name, result, blocks)
    return {
      name = name,
      result_for_block = function()
        return result
      end,
      blocks_in_buf = function()
        return blocks or {}
      end,
    }
  end

  before_each(function()
    original_vim = _G.vim
    state = {
      buf_lines = {},
      bo = {},
      wo = {},
      win_config = nil,
      cmds = {},
      keymaps = {},
      notified = {},
      cursor_row = 1,
      names = {},
    }

    _G.vim = {
      o = { columns = 100, lines = 40 },
      bo = setmetatable({}, {
        __index = function(_, bufnr)
          state.bo[bufnr] = state.bo[bufnr] or {}
          return state.bo[bufnr]
        end,
      }),
      wo = setmetatable({}, {
        __index = function(_, win)
          state.wo[win] = state.wo[win] or {}
          return state.wo[win]
        end,
      }),
      fn = {
        strdisplaywidth = function(s)
          return #s
        end,
      },
      log = { levels = { ERROR = 0, WARN = 1, INFO = 2 } },
      notify = function(msg, level)
        table.insert(state.notified, { msg = msg, level = level })
      end,
      cmd = function(c)
        table.insert(state.cmds, c)
      end,
      keymap = {
        set = function(_mode, lhs, _rhs, opts)
          state.keymaps[lhs] = opts
        end,
      },
      api = {
        nvim_create_buf = function()
          return 7
        end,
        nvim_buf_set_lines = function(bufnr, _s, _e, _strict, lines)
          state.buf_lines[bufnr] = lines
        end,
        nvim_buf_set_name = function(bufnr, name)
          state.names[bufnr] = name
        end,
        nvim_get_current_buf = function()
          return 1
        end,
        nvim_get_current_win = function()
          return 200
        end,
        nvim_win_set_buf = function() end,
        nvim_win_get_cursor = function()
          return { state.cursor_row, 0 }
        end,
        nvim_open_win = function(_bufnr, _enter, config)
          state.win_config = config
          return 100
        end,
      },
    }

    package.loaded["markdown_fence_view.pager"] = nil
    pager = require("markdown_fence_view.pager")
  end)

  after_each(function()
    _G.vim = original_vim
    package.loaded["markdown_fence_view.pager"] = nil
  end)

  local block = { info = "mermaid", start_row = 2, close_row = 6 }

  it("copies the cached lines into a read-only scratch buffer", function()
    local view = make_view("mermaid", { status = "ok", lines = { "a", "bb" } })

    local bufnr = pager.open({ view = view, buf = 1, block = block })

    assert.are.equal(7, bufnr)
    assert.same({ "a", "bb" }, state.buf_lines[7])
    assert.is_false(state.bo[7].modifiable)
    assert.are.equal("wipe", state.bo[7].bufhidden)
  end)

  it("keeps wrap off so wide output scrolls horizontally", function()
    local view = make_view("mermaid", { status = "ok", lines = { string.rep("x", 300) } })

    pager.open({ view = view, buf = 1, block = block })

    assert.is_false(state.wo[100].wrap)
    assert.are.equal(0, state.wo[100].sidescrolloff)
  end)

  it("caps the float at the screen width and height", function()
    local lines = {}
    for i = 1, 80 do
      lines[i] = string.rep("x", 300)
    end
    local view = make_view("mermaid", { status = "ok", lines = lines })

    pager.open({ view = view, buf = 1, block = block })

    assert.are.equal(96, state.win_config.width)
    assert.are.equal(32, state.win_config.height)
  end)

  it("opens in a new tab when style is tab", function()
    local view = make_view("mermaid", { status = "ok", lines = { "a" } })

    pager.open({ view = view, buf = 1, block = block, style = "tab" })

    assert.same({ "tabnew" }, state.cmds)
    assert.is_nil(state.win_config)
  end)

  it("refuses while the fence is still running", function()
    local view = make_view("query", { status = "in_progress" })

    local bufnr = pager.open({ view = view, buf = 1, block = block })

    assert.is_nil(bufnr)
    assert.matches("not ready", state.notified[1].msg)
  end)

  it("surfaces stderr when the fence produced no lines", function()
    local view = make_view("mermaid", { status = "ok", lines = {}, stderr = "boom" })

    local bufnr = pager.open({ view = view, buf = 1, block = block })

    assert.is_nil(bufnr)
    assert.matches("boom", state.notified[1].msg)
  end)

  it("locates the view owning the fence under the cursor", function()
    local mermaid = make_view("mermaid", nil, { { start_row = 0, close_row = 4 } })
    local query = make_view("query", nil, { { start_row = 10, close_row = 14 } })
    state.cursor_row = 12

    local view, found = pager.locate({ mermaid, query }, 1)

    assert.are.equal("query", view.name)
    assert.are.equal(10, found.start_row)
  end)

  it("falls back to the nearest fence when the cursor is outside every block", function()
    local mermaid = make_view("mermaid", nil, { { start_row = 0, close_row = 4 } })
    state.cursor_row = 30

    local view, found = pager.locate({ mermaid }, 1)

    assert.are.equal("mermaid", view.name)
    assert.are.equal(0, found.start_row)
  end)

  it("notifies instead of opening when the buffer has no fences", function()
    local bufnr = pager.open_at_cursor({ make_view("mermaid", nil, {}) }, 1)

    assert.is_nil(bufnr)
    assert.matches("No rendered fence", state.notified[1].msg)
  end)
end)
