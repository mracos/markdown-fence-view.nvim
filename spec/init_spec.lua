describe("markdown_fence_view (spec-driven handler)", function()
  local fv
  local original_vim
  local created_commands
  local created_autocmds

  before_each(function()
    original_vim = _G.vim
    created_commands = {}
    created_autocmds = {}

    _G.vim = {
      fn = {
        sha256 = function(s) return tostring(#s) end,
        expand = function(p) return p end,
        executable = function(_) return 1 end,
      },
      uv = {
        hrtime = function() return 0 end,
        fs_realpath = function(p) return p end,
      },
      bo = setmetatable({}, { __index = function() return {} end }),
      treesitter = {
        language = { get_lang = function() return "markdown" end },
        get_parser = function() return nil end,   -- gather returns {} under mock
      },
      api = {
        nvim_buf_get_name = function() return "" end,
        nvim_create_user_command = function(name, fn, opts)
          created_commands[name] = { fn = fn, opts = opts }
        end,
        nvim_create_augroup = function(name, _opts) return name end,
        nvim_create_autocmd = function(events, opts)
          table.insert(created_autocmds, { events = events, opts = opts })
        end,
      },
      cmd = function() end,
      log = { levels = { ERROR = 0, INFO = 1 } },
      schedule = function(fn) fn() end,
    }

    package.loaded["markdown_fence_view.blocks"] = nil
    package.loaded["markdown_fence_view.marks"] = nil
    package.loaded["markdown_fence_view.exec"] = nil
    package.loaded["markdown_fence_view.engines"] = nil
    package.loaded["markdown_fence_view.gates"] = nil
    package.loaded["markdown_fence_view.write_invalidate"] = nil
    package.loaded["markdown_fence_view"] = nil
    fv = require("markdown_fence_view")
  end)

  after_each(function() _G.vim = original_vim end)

  local function view()
    return fv.new({
      name = "test",
      labels = {
        error = "test error",
        timeout = "test timed out",
        running = "test running",
        empty = "(no results)",
        extra = { path = "test skipped (path)", missing = "test dep missing" },
      },
    })
  end

  describe("new()", function()
    it("errors without a name", function()
      assert.has_error(function() fv.new({}) end)
    end)

    it("returns handler/parse/configure surface", function()
      local v = view()
      assert.is_function(v.handler)
      assert.is_function(v.parse)
      assert.is_function(v.configure)
      assert.is_function(v.set_buf_enabled)
      assert.is_function(v.invalidate)
      local h = v.handler()
      assert.is_false(h.extends)
      assert.is_function(h.parse)
    end)

    it("returns empty marks when disabled", function()
      local v = view()
      v.configure({ enabled = false })
      assert.same({}, v.parse({ buf = 1, last = true }))
    end)

    it("returns empty marks when the buffer is disabled", function()
      local v = view()
      v.set_buf_enabled(7, false)
      assert.same({}, v.parse({ buf = 7, last = true }))
    end)

    it("returns empty marks on non-last render-markdown pass", function()
      local v = view()
      assert.same({}, v.parse({ buf = 1, last = false }))
    end)
  end)

  describe("status_line", function()
    it("uses labels.running for a running result", function()
      local v = view()
      local s = v._internals.status_line({ reason = "running" })
      assert.matches("test running", s[1][1])
    end)

    it("uses labels.timeout for a timeout", function()
      local v = view()
      local s = v._internals.status_line({ reason = "timeout" })
      assert.matches("test timed out", s[1][1])
    end)

    it("uses labels.empty when the run had no output", function()
      local v = view()
      local s = v._internals.status_line({ ok = true, lines = {}, reason = "ok" })
      assert.matches("no results", s[1][1])
    end)

    it("returns nil for an ok result with rows", function()
      local v = view()
      assert.is_nil(v._internals.status_line({
        ok = true, lines = { "row" }, reason = "ok",
      }))
    end)

    it("prefixes error with labels.error and stderr", function()
      local v = view()
      local s = v._internals.status_line({
        reason = "error", ok = false, stderr = "boom",
      })
      assert.matches("test error", s[1][1])
      assert.matches("boom", s[1][1])
    end)

    it("falls back to exit code when stderr is empty", function()
      local v = view()
      local s = v._internals.status_line({
        reason = "error", ok = false, stderr = "", code = 2,
      })
      assert.matches("exit 2", s[1][1])
    end)

    it("surfaces signal when stderr is empty", function()
      local v = view()
      local s = v._internals.status_line({
        reason = "error", ok = false, stderr = "", signal = 15,
      })
      assert.matches("signal 15", s[1][1])
    end)

    it("routes labels.extra reasons via the extra table", function()
      local v = view()
      local s = v._internals.status_line({ reason = "path" })
      assert.matches("test skipped %(path%)", s[1][1])
      s = v._internals.status_line({ reason = "missing" })
      assert.matches("test dep missing", s[1][1])
    end)
  end)

  describe("setup({ views = ... })", function()
    it("registers every view and exposes handlers()", function()
      fv.setup({
        views = {
          { name = "a", labels = { error = "a" } },
          { name = "b", labels = { error = "b" } },
        },
      })
      local h = fv.handlers()
      assert.is_not_nil(h.a)
      assert.is_not_nil(h.b)
      assert.is_function(h.a.parse)
      assert.is_false(h.a.extends)
    end)

    it("get() returns the registered view instance", function()
      fv.setup({ views = { { name = "a" } } })
      assert.is_not_nil(fv.get("a"))
      assert.is_nil(fv.get("nope"))
    end)

    it("creates :<Prefix>Enable/Disable/Refresh when spec.commands is set", function()
      fv.setup({ views = { { name = "x", commands = "MdX" } } })
      assert.is_not_nil(created_commands["MdXEnable"])
      assert.is_not_nil(created_commands["MdXDisable"])
      assert.is_not_nil(created_commands["MdXRefresh"])
    end)

    it("Refresh command redraws via render-markdown api (not :RenderMarkdown cmd)", function()
      local cmd_calls, render_calls = {}, {}
      _G.vim.cmd = function(s) table.insert(cmd_calls, s) end
      _G.vim.api.nvim_get_current_buf = function() return 7 end
      _G.vim.api.nvim_buf_is_valid = function(_) return true end
      package.loaded["render-markdown.api"] = {
        render = function(ctx) table.insert(render_calls, ctx) end,
      }
      fv.setup({ views = { { name = "x", commands = "MdX" } } })
      created_commands["MdXRefresh"].fn({})
      assert.same({}, cmd_calls)
      assert.are.equal(1, #render_calls)
      assert.are.equal(7, render_calls[1].buf)
      package.loaded["render-markdown.api"] = nil
    end)

    it("skips command creation when spec.commands is absent", function()
      fv.setup({ views = { { name = "x" } } })
      assert.same({}, created_commands)
    end)

    it("registers one global command set when setup.commands is set", function()
      fv.setup({
        views = { { name = "a" }, { name = "b" } },
        commands = "MarkdownFence",
      })
      assert.is_not_nil(created_commands["MarkdownFenceEnable"])
      assert.is_not_nil(created_commands["MarkdownFenceDisable"])
      assert.is_not_nil(created_commands["MarkdownFenceRefresh"])
      -- no per-view commands were requested
      assert.is_nil(created_commands["aRefresh"])
    end)

    it("global Refresh invalidates every view", function()
      _G.vim.api.nvim_get_current_buf = function() return 3 end
      _G.vim.api.nvim_buf_is_valid = function(_) return true end
      fv.setup({
        views = { { name = "a" }, { name = "b" } },
        commands = "MarkdownFence",
      })
      -- exec is a shared singleton across views, so one patch covers both.
      local cleared = {}
      fv.get("a")._internals.exec.invalidate = function(n) cleared[n] = true end
      created_commands["MarkdownFenceRefresh"].fn({})
      assert.is_true(cleared["a"])
      assert.is_true(cleared["b"])
    end)

    it("registers BufWritePost autocmds when spec.write_invalidate is set", function()
      fv.setup({
        views = {
          {
            name = "x",
            extra_config = { roots = { "/tmp/a", "/tmp/b" } },
            write_invalidate = fv.write_invalidate.checkbox_lines("roots"),
          },
        },
      })
      assert.are.equal(2, #created_autocmds)
      assert.are.equal("BufWritePost", created_autocmds[1].events)
      assert.are.equal("/tmp/a/**/*.md", created_autocmds[1].opts.pattern)
    end)
  end)

  describe("engines / gates factories", function()
    it("engines.bash builds a bash -c invocation", function()
      local cmd, stdin = fv.engines.bash("echo hi")
      assert.same({ "bash", "-c", "echo hi" }, cmd)
      assert.is_nil(stdin)
    end)

    it("engines.stdin_pipe returns a factory that pipes body to stdin", function()
      local eng = fv.engines.stdin_pipe({ "cat", "-" })
      local cmd, stdin = eng("hello\nworld")
      assert.same({ "cat", "-" }, cmd)
      assert.are.equal("hello\nworld", stdin)
    end)

    it("gates.path_allow_list returns reason when buf is outside all roots", function()
      local gate = fv.gates.path_allow_list("roots")
      local config = { roots = { "/notes" } }
      assert.are.equal("path", gate("/other/foo.md", config))
      assert.is_nil(gate("/notes/foo.md", config))
    end)

    it("gates.path_allow_list rejects empty / nil buf_path", function()
      local gate = fv.gates.path_allow_list("roots")
      assert.are.equal("path", gate("", { roots = { "/x" } }))
      assert.are.equal("path", gate(nil, { roots = { "/x" } }))
    end)

    it("gates.executable returns reason when binary missing", function()
      _G.vim.fn.executable = function(_) return 0 end
      local gate = fv.gates.executable("nowhere")
      assert.are.equal("missing", gate())
      _G.vim.fn.executable = function(_) return 1 end
      assert.is_nil(gate())
    end)

    it("write_invalidate.checkbox_lines builds patterns from config", function()
      local wi = fv.write_invalidate.checkbox_lines("roots")
      local pats = wi.patterns({ roots = { "/a", "/b" } })
      assert.same({ "/a/**/*.md", "/b/**/*.md" }, pats)
      assert.are.equal("%- %[", wi.require)
    end)
  end)
end)
