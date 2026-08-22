# Integrating

The [README](../README.md) quick start gets two views running. This is the rest: how a view is built, how to write engines and gates, and the full spec and API reference.

## Wiring

Declare every view in one `setup()`, then hand the handlers to render-markdown.

```lua
local fv = require("markdown_fence_view")

fv.setup({
  views = {
    { name = "run", engine = fv.engines.bash },
    -- ...more views
  },
  commands = "MarkdownFence",  -- optional, one global command set
})

require("render-markdown").setup({
  custom_handlers = fv.handlers(),
})
```

`fv.handlers()` returns `{ [view_name] = handler }`, keyed by the fence language each view matches. Views registered after that call are not in the table, so `setup()` first.

---

## Adding a view

A view is a spec table. `name` is the only field the constructor asserts, and it is the fence's first word: `name = "run"` matches `` ```run ``. In practice a useful view also needs `engines` (something to run) and a `gate` (a reason not to).

### Engines

An engine is `function(body) -> cmd, stdin`. `cmd` is an argv list for `vim.system`, `stdin` is a string or nil. Two ship built in and cover most tools:

| Engine | Shape |
|--------|-------|
| `fv.engines.bash` | `bash -c <body>`, no stdin |
| `fv.engines.stdin_pipe(cmd)` | fixed `cmd`, body on stdin |

Most views run exactly one thing. Give it as `engine`:

```lua
{
  name = "python",
  engine = fv.engines.stdin_pipe({ "python3", "-" }),
  gate = fv.gates.executable("python3"),
}
```

An engine name exists only so a fence can pick between several, as the second info-string word. When there is a choice to make, use `engines` instead, with a `default` for the bare `` ```query `` fence:

```lua
engines = {
  default = "bash",
  map = { bash = fv.engines.bash, zsh = fv.engines.stdin_pipe({ "zsh" }) },
},
```

Now `` ```query `` runs bash and `` ```query zsh `` pipes the body to zsh. `default` is inferred when `map` holds a single entry, and setting both `engine` and `engines` is an error at `setup()`.

Either way, an unmatched suffix resolves to no engine and renders as an `unknown engine: <info-string>` error, so a typo is visible instead of silently falling back to the default.

Write the engine yourself when the tool needs more than a fixed argv. It sees the body, so it can pick a command from the content, or refuse:

```lua
local function jq_engine(body)
  local file = body:match("^%s*#%s*file:%s*(%S+)")
  if not file then
    return { "bash", "-c", 'echo "first line must be # file: <path>" >&2; exit 1' }, ""
  end
  return { "jq", "-f", "-", file }, body
end
```

Rejecting via a failing command (rather than returning nil) puts the message in the `error` status line, where the reader will see it.

### Gates

A gate runs once per parse and decides whether any block executes at all. It returns a reason string to block, or nil to allow.

| Gate | Blocks when |
|------|-------------|
| `fv.gates.path_allow_list(key)` | buffer's realpath is not under any root in `config[key]` |
| `fv.gates.executable(bin)` | `bin` is not on PATH |

The reason is looked up in `labels.extra`, so pair every gate with its message:

```lua
gate = fv.gates.path_allow_list("allow_paths"),
extra_config = { allow_paths = { vim.fn.expand("~/notes") } },
labels = { extra = { path = "skipped (path not allowed)" } },
```

`path_allow_list` defaults its reason to `"path"`, `executable` to `"missing"`; both take an override as the second argument. A custom gate is the same contract, `function(buf_path, config) -> reason|nil`:

```lua
gate = function(buf_path, config)
  if vim.b.big_scary_file then return "unsafe" end
end
```

Untrusted markdown executes on render, so a view without a gate runs anywhere. Treat the gate as required.

### Labels

`labels` names each outcome in the status line rendered under the fence.

| Key | Shown when |
|-----|------------|
| `running` | command spawned, not finished |
| `error` | non-zero exit (stderr appended) |
| `timeout` | killed at `timeout_ms` |
| `empty` | exit 0, no stdout |
| `extra[<reason>]` | a gate returned `<reason>` |

Every key has a fallback, so a view with no `labels` still renders sane text. Resolution order is in [how-it-works](how-it-works.md#reason-lifecycle).

### Where it runs

Default cwd is the buffer's directory. Override per view:

```lua
cwd = function(buf_path, config)
  return vim.fs.root(buf_path, ".git")
end,
```

The cwd is part of the cache key, so the same body in two projects caches separately.

### Footer

Successful results get a footer line, default `"  // %d row(s), %dms"`:

```lua
ok_footer = function(n_lines, elapsed_ms)
  return ("  // rendered in %dms"):format(elapsed_ms)
end,
```

---

## Commands

`setup({ commands = "MarkdownFence" })` registers one set that acts on every registered view.

| Command | Effect |
|---------|--------|
| `:MarkdownFenceRefresh` | Invalidate all view caches and re-render the current buffer. |
| `:MarkdownFenceDisable` | Disable all views in the current buffer (`!` = globally). |
| `:MarkdownFenceEnable` | Enable all views in the current buffer (`!` = globally). |

A single view can expose its own set with `spec.commands = "MarkdownQuery"`, giving `:MarkdownQueryEnable/Disable/Refresh`. Use it only when one view needs toggling independently; the global set is usually what you want.

---

## Cache and invalidation

Results are cached on `view name + sha256(body) + cwd`. A re-render costs nothing until the body changes, and every result is cached, including timeouts and errors. Three ways back out:

- `:MarkdownFenceRefresh` clears every view.
- `fv.exec.invalidate(name?)` clears one view, or all of them when called bare.
- `write_invalidate` clears on `BufWritePost`.

`write_invalidate` is `{ patterns = fn(config) -> string[], require = <lua pattern> }`. The patterns become autocmd patterns; `require` keeps the cache warm unless the saved buffer contains a matching line. One factory ships built in:

```lua
write_invalidate = fv.write_invalidate.checkbox_lines("allow_paths"),
```

That watches `<root>/**/*.md` for every root in `config.allow_paths` and only drops the cache when the saved file has a `- [` line, so editing prose around a query does not re-run it. A view whose output depends on something else declares its own:

```lua
write_invalidate = {
  patterns = function(config) return { config.data_dir .. "/*.csv" } end,
  require = nil,  -- any write to a matching file invalidates
},
```

---

## Structured output and write-back

`transform_output` turns raw stdout into display lines plus per-row metadata, before caching:

```lua
transform_output = function(stdout)
  local lines, metadata = {}, {}
  for row in stdout:gmatch("[^\n]+") do
    local path, lineno, raw = row:match("^(.-):(%d+):(.*)$")
    table.insert(lines, raw)
    table.insert(metadata, { path = path, lineno = tonumber(lineno), raw = raw })
  end
  return { lines = lines, metadata = metadata }
end,
```

`lines` replaces the naive newline split. `metadata` is opaque to this plugin and rides along in the cache entry, one entry per row, reachable via `view.result_for_block(buf, block)`.

It is also what makes results editable. When metadata carries `{path, lineno, raw}`, `scratch.lua` opens the rows in a floating buffer and writes edits back to their source files on `:w`:

```lua
local scratch_mod = require("markdown_fence_view.scratch")
local block = scratch_mod.block_under_cursor(view, buf)
if block then scratch_mod.open({ view = view, buf = buf, block = block }) end
```

Bind that from the parent buffer. Mechanics and safety rules (mtime checks, drop confirmation, rejected inserts) are in [how-it-works](how-it-works.md#write-back-via-scratch-buffer).

A `transform_output` that errors falls back to naive lines and notifies, so a bad transform degrades instead of breaking the render.

---

## Spec reference

Fields on a spec passed to `fv.setup({ views = { spec, ... } })`. Only `name` is required.

| Field | Type | Notes |
|-------|------|-------|
| `name` | `string` | Info-string first word to match. Also the cache-key namespace. |
| `engine` | `function(body) -> cmd, stdin` | The view's only engine. Mutually exclusive with `engines`. |
| `engines` | `{default?, map}` | Named engines a fence suffix can pick between. `default` is inferred when `map` holds one entry. |
| `gate` | `function(buf_path, config) -> reason \| nil` | Runs once per parse. A reason string blocks every block and shows `labels.extra[reason]`. |
| `labels` | `{error, timeout, running, empty, extra}` | Status-line text per reason. `extra = { <reason> = <text> }` covers gate reasons. |
| `cwd` | `function(buf_path, config) -> string \| nil` | Spawn cwd. Default: the buffer's directory. Part of the cache key. |
| `ok_footer` | `function(n_lines, elapsed_ms) -> string` | Footer on successful results. Default `"  // %d row(s), %dms"`. |
| `timeout_ms` | `number` | Default 2000. A kill at the deadline reports as `timeout`, not `error`. |
| `extra_config` | `table` | Merged into the view's config, readable from `gate` / `cwd` / `write_invalidate.patterns`. |
| `commands` | `string` | Per-view command prefix. Prefer the global `setup({ commands = ... })` set. |
| `write_invalidate` | `{patterns, require}` | `BufWritePost` cache invalidation. `patterns(config) -> string[]`; `require` is a lua-pattern the saved buffer must contain. |
| `transform_output` | `function(stdout) -> {lines, metadata}` | Post-process ok results before caching. |

---

## Public API

| Function | Purpose |
|----------|---------|
| `fv.setup({views, commands?})` | Register N views; with `commands`, also the global command set. |
| `fv.handlers()` | `{ [name] = handler }` for `render-markdown.custom_handlers`. |
| `fv.get(name)` | Look up a registered view instance. |
| `fv.new(spec)` | Build a view without registering it (low-level, tests). |
| `fv.register_commands(prefix)` | Register `<prefix>Enable/Disable/Refresh` across all views. |
| `fv.engines.bash` | Engine: `bash -c <body>`, no stdin. |
| `fv.engines.stdin_pipe(cmd)` | Engine factory: pipe body to a fixed cmd's stdin. |
| `fv.gates.path_allow_list(key, reason?)` | Gate factory: reject buffers outside `config[key]` roots. |
| `fv.gates.executable(bin, reason?)` | Gate factory: reject when `bin` is not on PATH. |
| `fv.write_invalidate.checkbox_lines(key)` | Autocmd factory: drop cache when a saved `.md` under `config[key]` has `- [` lines. |
| `fv.exec.invalidate(name?)` | Invalidate cache, per-view or global. |

### Per-view helpers

On the instance returned by `fv.get(name)` or `fv.new(spec)`.

| Method | Purpose |
|--------|---------|
| `view.handler()` | Handler table for `render-markdown.custom_handlers`. |
| `view.parse(ctx)` | The handler's parse function, directly. |
| `view.configure(opts)` | Merge into the view's config at runtime. |
| `view.setup(opts)` | One-shot: apply opts, register commands and autocmds. |
| `view.set_buf_enabled(buf, bool)` | Skip rendering in one buffer. |
| `view.invalidate()` | Drop this view's cache entries. |
| `view.refresh_buffer(buf)` | Trigger a render-markdown redraw. |
| `view.result_for_block(buf, blk)` | Cached result (with `.metadata`) for a fence block. |
| `view.blocks_in_buf(buf)` | Every fence block in `buf` matching this view. |
