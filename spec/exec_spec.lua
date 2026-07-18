describe("m/markdown_fence_view/exec", function()
  local exec
  local original_vim
  local fake_result
  local last_cmd
  local async_cb

  before_each(function()
    original_vim = _G.vim
    last_cmd = nil
    async_cb = nil

    _G.vim = {
      fn = {
        sha256 = function(s) return tostring(#s) end,
        expand = function(p) return p end,
      },
      uv = { hrtime = function() return 0 end },
      schedule = function(fn) fn() end,
      system = function(cmd, opts, cb)
        last_cmd = cmd
        if cb then
          async_cb = cb
          return {}
        end
        return { wait = function() return fake_result end }
      end,
    }

    package.loaded["m.markdown_fence_view.exec"] = nil
    exec = require("m.markdown_fence_view.exec")
    fake_result = { code = 0, stdout = "row1\nrow2\n", stderr = "" }
  end)

  after_each(function() _G.vim = original_vim end)

  local function bash(body) return { "bash", "-c", body }, nil end

  describe("run (sync)", function()
    it("returns empty for empty body", function()
      local r = exec.run("view", "", { cmd = bash })
      assert.are.equal("empty", r.reason)
    end)

    it("captures stdout lines", function()
      local r = exec.run("view", "echo", { cmd = bash })
      assert.same({ "row1", "row2" }, r.lines)
      assert.are.equal("ok", r.reason)
    end)

    it("flags non-zero exit as error and surfaces stderr", function()
      fake_result = { code = 1, stdout = "", stderr = "boom" }
      local r = exec.run("view", "false", { cmd = bash, no_cache = true })
      assert.are.equal("error", r.reason)
      assert.are.equal("boom", r.stderr)
    end)

    it("flags timeout when wait returns nil", function()
      _G.vim.system = function() return { wait = function() return nil end } end
      local r = exec.run("view", "sleep 99", { cmd = bash, no_cache = true })
      assert.are.equal("timeout", r.reason)
    end)

    it("reclassifies SIGKILL from wait(timeout) as timeout", function()
      fake_result = { code = 124, signal = 9, stdout = "", stderr = "" }
      local r = exec.run("view", "sleep 99", { cmd = bash, no_cache = true })
      assert.are.equal("timeout", r.reason)
      assert.are.equal(9, r.signal)
    end)

    it("errors when opts.cmd is missing", function()
      assert.has_error(function() exec.run("view", "body", {}) end)
    end)

    it("uses the engine's cmd as-is", function()
      exec.run("view", "echo a", { cmd = bash, no_cache = true })
      assert.same({ "bash", "-c", "echo a" }, last_cmd)
    end)

    it("caches by (name, body, cwd)", function()
      local calls = 0
      _G.vim.system = function()
        calls = calls + 1
        return { wait = function() return { code = 0, stdout = "r\n", stderr = "" } end }
      end
      exec.run("v", "b", { cmd = bash, cwd = "/x" })
      exec.run("v", "b", { cmd = bash, cwd = "/x" })
      assert.are.equal(1, calls)
      exec.run("v", "b", { cmd = bash, cwd = "/y" })
      assert.are.equal(2, calls)
      -- Different name is a different cache key too.
      exec.run("w", "b", { cmd = bash, cwd = "/x" })
      assert.are.equal(3, calls)
    end)
  end)

  describe("get / run_async", function()
    it("get returns nil for an unstarted body", function()
      assert.is_nil(exec.get("v", "never seen"))
    end)

    it("run_async returns 'started' and marks in_progress", function()
      local status = exec.run_async("v", "q", { cmd = bash })
      assert.are.equal("started", status)
      local pending = exec.get("v", "q")
      assert.are.equal("in_progress", pending.status)
    end)

    it("run_async does not double-spawn while in flight", function()
      local spawns = 0
      _G.vim.system = function() spawns = spawns + 1; return {} end
      exec.run_async("v", "q", { cmd = bash })
      exec.run_async("v", "q", { cmd = bash })
      exec.run_async("v", "q", { cmd = bash })
      assert.are.equal(1, spawns)
    end)

    it("run_async caches result on completion and invokes on_done", function()
      local seen
      exec.run_async("v", "q", { cmd = bash }, function(r) seen = r end)
      async_cb({ code = 0, stdout = "hello\n", stderr = "" })
      assert.same({ "hello" }, seen.lines)
      assert.are.equal("ok", exec.get("v", "q").reason)
    end)

    it("run_async classifies SIGKILL as timeout AND caches it", function()
      exec.run_async("v", "q", { cmd = bash })
      async_cb({ code = 124, signal = 9, stdout = "", stderr = "" })
      local cached = exec.get("v", "q")
      assert.are.equal("timeout", cached.reason)
    end)

    it("run_async short-circuits on cached result", function()
      exec.run("v", "q", { cmd = bash })
      local seen
      local status = exec.run_async("v", "q", { cmd = bash }, function(r) seen = r end)
      assert.are.equal("cached", status)
      assert.same({ "row1", "row2" }, seen.lines)
    end)

    it("run_async reports 'in_progress' for a re-entrant call", function()
      exec.run_async("v", "q", { cmd = bash })
      assert.are.equal("in_progress", exec.run_async("v", "q", { cmd = bash }))
    end)
  end)

  describe("transform_output", function()
    it("replaces lines and attaches metadata on an ok result", function()
      fake_result = {
        code = 0,
        stdout = [[{"raw":"- [ ] a","path":"a.md","lineno":10}
{"raw":"- [ ] b","path":"b.md","lineno":22}
]],
        stderr = "",
      }
      _G.vim.json = { decode = function(s) return require("cjson").decode(s) end }
      -- No cjson available under busted; hand-roll a tiny decoder for the test.
      _G.vim.json.decode = function(s)
        local raw = s:match('"raw":"([^"]+)"')
        local path = s:match('"path":"([^"]+)"')
        local lineno = tonumber(s:match('"lineno":(%d+)'))
        if not raw then error("bad json: " .. s) end
        return { raw = raw, path = path, lineno = lineno }
      end
      local transform = function(stdout)
        local lines, meta = {}, {}
        for jline in stdout:gmatch("[^\n]+") do
          local obj = _G.vim.json.decode(jline)
          table.insert(lines, obj.raw)
          table.insert(meta, { path = obj.path, lineno = obj.lineno })
        end
        return { lines = lines, metadata = meta }
      end
      local r = exec.run("v", "body", { cmd = bash, transform_output = transform })
      assert.same({ "- [ ] a", "- [ ] b" }, r.lines)
      assert.same({ { path = "a.md", lineno = 10 }, { path = "b.md", lineno = 22 } }, r.metadata)
      assert.are.equal("ok", r.reason)
    end)

    it("does not run transform on a non-ok result", function()
      fake_result = { code = 1, stdout = "", stderr = "boom" }
      local called = false
      exec.run("v", "body", {
        cmd = bash, no_cache = true,
        transform_output = function() called = true; return { lines = {}, metadata = {} } end,
      })
      assert.is_false(called)
    end)

    it("swallows a transform error and keeps the original lines", function()
      fake_result = { code = 0, stdout = "hello\nworld\n", stderr = "" }
      _G.vim.schedule = function(fn) fn() end
      _G.vim.log = { levels = { ERROR = 0 } }
      local notified
      _G.vim.notify = function(msg) notified = msg end
      local r = exec.run("v", "body", {
        cmd = bash, no_cache = true,
        transform_output = function() error("boom") end,
      })
      assert.same({ "hello", "world" }, r.lines)
      assert.is_nil(r.metadata)
      assert.matches("transform_output failed", notified or "")
    end)

    it("caches the transformed result", function()
      fake_result = { code = 0, stdout = "raw", stderr = "" }
      local calls = 0
      local transform = function(stdout)
        calls = calls + 1
        return { lines = { "TRANSFORMED:" .. stdout }, metadata = { { i = calls } } }
      end
      exec.run("v", "same", { cmd = bash, transform_output = transform })
      local r2 = exec.run("v", "same", { cmd = bash, transform_output = transform })
      assert.are.equal(1, calls, "transform runs only on cache miss")
      assert.same({ "TRANSFORMED:raw" }, r2.lines)
      assert.same({ { i = 1 } }, r2.metadata)
    end)
  end)

  describe("invalidate", function()
    it("with no name drops every entry", function()
      exec.run("v", "b", { cmd = bash })
      exec.run("w", "b", { cmd = bash })
      exec.invalidate()
      assert.is_nil(exec.get("v", "b"))
      assert.is_nil(exec.get("w", "b"))
    end)

    it("scoped to a name only drops that view's entries", function()
      exec.run("v", "b", { cmd = bash })
      exec.run("w", "b", { cmd = bash })
      exec.invalidate("v")
      assert.is_nil(exec.get("v", "b"))
      assert.is_not_nil(exec.get("w", "b"))
    end)
  end)
end)
