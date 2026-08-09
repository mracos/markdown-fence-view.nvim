describe("markdown_fence_view/engines", function()
  local engines

  before_each(function()
    package.loaded["markdown_fence_view.engines"] = nil
    engines = require("markdown_fence_view.engines")
  end)

  local function spec()
    local bash = function(body) return { "bash", "-c", body }, nil end
    local sh = function(body) return { "sh", "-c", body }, nil end
    return {
      default = "bash",
      map = { bash = bash, sh = sh },
    }
  end

  it("resolves the default engine for a bare info string", function()
    local e = engines.build(spec())
    local fn = e.resolve("query")
    assert.is_function(fn)
    local cmd = fn("echo hi")
    assert.same({ "bash", "-c", "echo hi" }, cmd)
  end)

  it("resolves a suffix engine by name", function()
    local e = engines.build(spec())
    local fn = e.resolve("query sh")
    local cmd = fn("echo hi")
    assert.same({ "sh", "-c", "echo hi" }, cmd)
  end)

  it("returns nil for an unknown suffix", function()
    local e = engines.build(spec())
    assert.is_nil(e.resolve("query jq"))
  end)

  it("returns nil when no default is declared and info has no suffix", function()
    local e = engines.build({ map = spec().map })
    assert.is_nil(e.resolve("query"))
  end)

  it("returns nil for a nil or empty info", function()
    local e = engines.build(spec())
    -- No suffix -> default; empty string still counts as default.
    assert.is_function(e.resolve(nil))
    assert.is_function(e.resolve(""))
  end)
end)
