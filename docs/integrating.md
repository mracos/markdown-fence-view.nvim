# Integrating

Configure views at plugin load, then wire the handlers into render-markdown.

```lua
local fv = require("markdown_fence_view")

fv.setup({
  views = {
    {
      name = "query",
      labels = {
        error = "query error",
        timeout = "query timed out",
        running = "running notes todos query...",
        empty = "(no results)",
        extra = { path = "query skipped (path not allowed)" },
      },
      engines = { default = "bash", map = { bash = fv.engines.bash } },
      gate = fv.gates.path_allow_list("allow_paths"),
      extra_config = { allow_paths = { vim.fn.expand("~/Notes") } },
      timeout_ms = 10000,
      commands = "MarkdownQuery",
      write_invalidate = fv.write_invalidate.checkbox_lines("allow_paths"),
    },
    {
      name = "mermaid",
      labels = {
        error = "mermaid error",
        timeout = "mermaid timed out",
        running = "rendering mermaid...",
        empty = "(no output)",
        extra = { missing = "mermaid-ascii not installed" },
      },
      engines = {
        default = "mermaid-ascii",
        map = { ["mermaid-ascii"] = fv.engines.stdin_pipe({ "mermaid-ascii", "--file", "-" }) },
      },
      gate = fv.gates.executable("mermaid-ascii"),
      ok_footer = function(_n, ms) return string.format("  // rendered in %dms", ms) end,
      timeout_ms = 3000,
      commands = "MarkdownMermaid",
    },
  },
})

require("render-markdown").setup({
  custom_handlers = fv.handlers(),
})
```

## Public API

| Function                      | Purpose |
|-------------------------------|---------|
| `fv.setup({ views = {...} })` | Register N views. Each spec goes through `new()` then `setup()`. |
| `fv.handlers()`               | Return `{ [name] = handler_table }` for `render-markdown.custom_handlers`. |
| `fv.get(name)`                | Look up a registered view instance. |
| `fv.new(spec)`                | Build a view without registering it (low-level; tests). |
| `fv.engines.bash`             | Engine: `bash -c <body>`, no stdin. |
| `fv.engines.stdin_pipe(cmd)`  | Engine factory: pipe body to stdin of a fixed cmd. |
| `fv.gates.path_allow_list(k)` | Gate factory: reject blocks outside `config[k]` roots. |
| `fv.gates.executable(bin)`    | Gate factory: reject when binary is not on PATH. |
| `fv.write_invalidate.checkbox_lines(k)` | Autocmd factory: drop cache when saved `.md` under `config[k]` roots contains `- [` lines. |
| `fv.exec.invalidate(name?)`   | Manually invalidate cache (per-view or global). |

### Per-view helpers (on the view instance)

| Method                             | Purpose |
|------------------------------------|---------|
| `view.handler()`                   | Handler table for `render-markdown.custom_handlers`. |
| `view.parse(ctx)`                  | Handler parse function (also accessible via `handler()`). |
| `view.configure(opts)`             | Merge into the view's config table at runtime. |
| `view.setup(opts)`                 | One-shot setup — apply opts, register commands + autocmds. |
| `view.set_buf_enabled(buf, bool)`  | Skip rendering in a specific buffer. |
| `view.invalidate()`                | Drop this view's cache entries. |
| `view.refresh_buffer(buf)`         | Trigger a render-markdown redraw for a buffer. |
| `view.result_for_block(buf, blk)`  | Return the cached result (with `.metadata`) for a fence block. |
| `view.blocks_in_buf(buf)`          | Enumerate all fence blocks in `buf` matching this view. |

## Spec reference

Fields on the spec table passed to `fv.setup({ views = { spec, ... } })`. Only `name` is required.

| Field              | Type                                    | Notes |
|--------------------|-----------------------------------------|-------|
| `name`             | `string`                                | Info-string first word to match. Also cache-key namespace. |
| `labels`           | `{error, timeout, running, empty, extra}` | Text for each `reason` in the status line. `extra = { <reason> = <text> }` handles view-specific reasons like `path` / `missing`. |
| `engines`          | `{default = string, map = table}`       | `map[<engine>] = function(body) -> cmd, stdin`. `default` is used when the info string has no suffix. |
| `gate`             | `function(buf_path, config) -> reason \| nil` | Called once per parse. If it returns a reason string, blocks aren't spawned and the status_line shows the reason's label (via `labels.extra[reason]`). |
| `cwd`              | `function(buf_path, config) -> string \| nil` | Override the spawn cwd; default is the buffer's directory. |
| `ok_footer`        | `function(n_lines, elapsed_ms) -> string` | Footer line appended to successful results. Default: `"  // %d row(s), %dms"`. |
| `timeout_ms`       | `number`                                | Default 2000. |
| `extra_config`     | `table`                                 | Merged into the view's config table (accessible from `gate` / `cwd`). Ex: `{ allow_paths = {} }`. |
| `commands`         | `string`                                | Prefix for user commands. `"MarkdownQuery"` creates `:MarkdownQueryEnable/Disable/Refresh`. |
| `write_invalidate` | `{ patterns, require }`                 | Register `BufWritePost` cache invalidation. `patterns(config) -> string[]` returns the autocmd patterns; `require` is a lua-pattern that the saved buffer must contain for the cache to be dropped. |
| `transform_output` | `function(stdout) -> { lines, metadata }` | Called on any `ok` result before caching. Returns display `lines` (replace naive newline-split) and per-row `metadata` (opaque to fv). Metadata rides along in the cache entry so downstream write-back flows can look up `path`/`lineno`/etc by row. A pcall failure falls back to naive lines + `vim.notify`. |
