describe("markdown_fence_view/engines", function()
  local engines

  before_each(function()
    package.loaded["markdown_fence_view.engines"] = nil
    engines = require("markdown_fence_view.engines")
  end)

  local bash = function(body) return { "bash", "-c", body }, nil end
  local sh = function(body) return { "sh", "-c", body }, nil end

  --- A view spec declaring several named engines.
  local function spec()
    return { engines = { default = "bash", map = { bash = bash, sh = sh } } }
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
    local e = engines.build({ engines = { map = { bash = bash, sh = sh } } })
    assert.is_nil(e.resolve("query"))
  end)

  it("infers the default when the map holds a single engine", function()
    local e = engines.build({ engines = { map = { mermaid = bash } } })
    local fn = e.resolve("mermaid")
    assert.is_function(fn)
    assert.same({ "bash", "-c", "echo hi" }, fn("echo hi"))
  end)

  it("accepts `engine` as the view's only engine", function()
    local e = engines.build({ engine = bash })
    local fn = e.resolve("mermaid")
    assert.is_function(fn)
    assert.same({ "bash", "-c", "echo hi" }, fn("echo hi"))
  end)

  it("rejects a suffix when the view declared a single `engine`", function()
    -- Nothing to pick between, so a suffix is a typo, not a choice.
    local e = engines.build({ engine = bash })
    assert.is_nil(e.resolve("mermaid ascii"))
  end)

  it("errors when a spec declares both `engine` and `engines`", function()
    assert.has_error(function()
      engines.build({ engine = bash, engines = { map = { sh = sh } } })
    end)
  end)

  it("errors when `engines` is handed a bare function", function()
    assert.has_error(function() engines.build({ engines = bash }) end)
  end)

  it("returns nil for a nil or empty info", function()
    local e = engines.build(spec())
    -- No suffix -> default; empty string still counts as default.
    assert.is_function(e.resolve(nil))
    assert.is_function(e.resolve(""))
  end)
end)
