describe("markdown_fence_view/scratch (diff_batch)", function()
  local scratch
  local original_vim
  local scratch_lines
  local extmarks   -- [id] = row
  local next_id

  local function set_scratch(lines, mark_rows)
    scratch_lines = {}
    for _, l in ipairs(lines) do table.insert(scratch_lines, l) end
    extmarks = {}
    if mark_rows then
      for _, row in ipairs(mark_rows) do
        next_id = next_id + 1
        extmarks[next_id] = row
      end
    end
  end

  before_each(function()
    original_vim = _G.vim
    scratch_lines = {}
    extmarks = {}
    next_id = 1000

    _G.vim = {
      api = {
        nvim_create_namespace = function() return 42 end,
        nvim_buf_get_extmarks = function(_buf, _ns, _s, _e, _opts)
          local out = {}
          for id, row in pairs(extmarks) do table.insert(out, { id, row, 0 }) end
          table.sort(out, function(a, b) return a[2] < b[2] end)
          return out
        end,
        nvim_buf_get_lines = function(_buf, s, e, _strict)
          local out = {}
          for i = s + 1, e do out[#out + 1] = scratch_lines[i] end
          return out
        end,
        nvim_buf_line_count = function() return #scratch_lines end,
      },
      log = { levels = { ERROR = 0, WARN = 1, INFO = 2 } },
    }

    package.loaded["markdown_fence_view.scratch"] = nil
    scratch = require("markdown_fence_view.scratch")
  end)

  after_each(function() _G.vim = original_vim end)

  local function make_shadow(entries)
    -- entries: list of { path, source_lineno, original } in shadow order.
    -- Returns shadow table keyed by extmark ID (in order).
    local shadow = {}
    for i, entry in ipairs(entries) do
      shadow[1000 + i] = {
        path = entry.path,
        source_lineno = entry.source_lineno,
        source_mtime = 0,
        original = entry.original,
      }
    end
    return shadow
  end

  it("emits no changes when scratch matches shadow", function()
    set_scratch({ "- [ ] a", "- [ ] b" }, { 0, 1 })
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 10, original = "- [ ] a" },
      { path = "b.md", source_lineno = 20, original = "- [ ] b" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    assert.same({}, batch.changes)
    assert.are.equal(0, batch.additions)
    assert.is_false(batch.needs_confirm)
  end)

  it("emits a replace when a line changed", function()
    set_scratch({ "- [x] a", "- [ ] b" }, { 0, 1 })
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 10, original = "- [ ] a" },
      { path = "b.md", source_lineno = 20, original = "- [ ] b" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    assert.are.equal(1, #batch.changes)
    assert.are.equal("replace", batch.changes[1].kind)
    assert.are.equal("a.md", batch.changes[1].path)
    assert.are.equal(10, batch.changes[1].lineno)
    assert.are.equal("- [x] a", batch.changes[1].new_text)
  end)

  it("emits a drop when a shadow row's extmark is missing (row deleted)", function()
    -- Only one extmark alive (id 1002), id 1001 was deleted along with its line.
    set_scratch({ "- [ ] b" }, {})
    -- Manually place an extmark for the surviving row at position 0.
    extmarks[1002] = 0
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 10, original = "- [ ] a" },
      { path = "b.md", source_lineno = 20, original = "- [ ] b" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    -- Order not guaranteed since it iterates over a hash; find the drop.
    local drop = nil
    for _, c in ipairs(batch.changes) do
      if c.kind == "drop" then drop = c end
    end
    assert.is_not_nil(drop)
    assert.are.equal("a.md", drop.path)
    assert.are.equal(10, drop.lineno)
  end)

  it("counts additions when a scratch row has no extmark", function()
    set_scratch({ "- [ ] a", "- [ ] added by user" }, {})
    -- Only the first line has an extmark.
    extmarks[1001] = 0
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 10, original = "- [ ] a" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    assert.are.equal(1, batch.additions)
  end)

  it("ignores blank lines when counting additions", function()
    set_scratch({ "- [ ] a", "", "   " }, {})
    extmarks[1001] = 0
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 10, original = "- [ ] a" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    assert.are.equal(0, batch.additions)
  end)

  it("sets needs_confirm when >3 rows were dropped", function()
    -- Scratch is empty; every shadow entry becomes a drop.
    set_scratch({}, {})
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 1, original = "- [ ] a" },
      { path = "b.md", source_lineno = 2, original = "- [ ] b" },
      { path = "c.md", source_lineno = 3, original = "- [ ] c" },
      { path = "d.md", source_lineno = 4, original = "- [ ] d" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    assert.is_true(batch.needs_confirm)
    local drops = 0
    for _, c in ipairs(batch.changes) do
      if c.kind == "drop" then drops = drops + 1 end
    end
    assert.are.equal(4, drops)
  end)

  it("does not set needs_confirm at 3 drops", function()
    set_scratch({}, {})
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 1, original = "- [ ] a" },
      { path = "b.md", source_lineno = 2, original = "- [ ] b" },
      { path = "c.md", source_lineno = 3, original = "- [ ] c" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    assert.is_false(batch.needs_confirm)
  end)

  it("supports reordered rows via extmark identity", function()
    -- Scratch has b then a (reversed order).
    set_scratch({ "- [ ] b", "- [x] a" }, {})
    extmarks[1001] = 1  -- shadow id 1001 (a.md) is now at row 1
    extmarks[1002] = 0  -- shadow id 1002 (b.md) is now at row 0
    local shadow = make_shadow({
      { path = "a.md", source_lineno = 10, original = "- [ ] a" },
      { path = "b.md", source_lineno = 20, original = "- [ ] b" },
    })
    local batch = scratch._internals.diff_batch(0, shadow)
    -- b.md unchanged (extmark 1002 at row 0 -> "- [ ] b" == original)
    -- a.md toggled (extmark 1001 at row 1 -> "- [x] a" != original)
    assert.are.equal(1, #batch.changes)
    assert.are.equal("replace", batch.changes[1].kind)
    assert.are.equal("a.md", batch.changes[1].path)
    assert.are.equal("- [x] a", batch.changes[1].new_text)
  end)
end)
