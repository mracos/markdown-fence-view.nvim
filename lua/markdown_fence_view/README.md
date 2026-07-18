# markdown_fence_view

Spec-driven [`render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim) handler for fenced code blocks. Configure N views (each matches a fence language and describes how to execute the body) in a single `setup()` call. Nothing about the module is coupled to notes or any specific engine — any fence language with an executable body works.

Designed to be extraction-ready: only depends on `render-markdown.nvim` at runtime, and only on the `markdown` treesitter parser at parse time.

## What it does

Given a fenced code block whose info-string first word matches a configured view's `name`, the module:

1. Walks the markdown treesitter tree, finds the block.
2. Resolves the info-string suffix (or default) to a shell command via the view's engines.
3. Spawns the command asynchronously (`vim.system` with callback).
4. Shows `// running <label>...` as `virt_lines` immediately.
5. On completion, caches by `<view_name> + sha256(body) + cwd`, re-renders, replaces the spinner with stdout as `virt_lines`.
6. Anchors marks one line past the closing fence so UFO's fenced_code_block fold doesn't hide them.
7. Classifies SIGKILL from `:wait(timeout)` as `timeout` (not generic error).

## Requirements

- Neovim 0.10+ (`vim.system`, `vim.uv.hrtime`, `vim.treesitter.query.parse` all-inclusive)
- [`render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim) — this module registers as a custom handler
- `nvim-treesitter` with the `markdown` parser installed

## Integration

Configure views at plugin load, then wire the handlers into render-markdown:

```lua
local fv = require("m.markdown_fence_view")

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

### Reason lifecycle

A `result.reason` is one of `ok`, `empty`, `running`, `timeout`, `error`, or any custom string returned by `gate`. The status line resolves it in this order:

1. `labels.extra[reason]` if present (view-specific reasons — `path`, `missing`, etc.)
2. Built-in cases: `running`, `timeout`, `error` (with stderr / signal / exit fallback), `empty`
3. `nil` (no status line — ok results with rows already have the footer)

### Cache invariants

- Keys are namespaced by view name: `<name>\0<sha256(body)>\0<cwd>`. Different views can't collide.
- In-progress marker prevents double-spawn if `parse` is called re-entrantly before the first spawn completes.
- Timeouts are cached like any other result. Retry paths: `:<Prefix>Refresh` clears entries for that view; saving a file whose contents match `write_invalidate.require` also clears them.

## Module layout

```
init.lua              -- setup{views}, new(spec), handlers(), get(name)
blocks.lua            -- gather(buf, lang) via markdown treesitter root
marks.lua             -- append() with fold-safe close_row + 1 anchor
exec.lua              -- name-namespaced cache; get / run / run_async / invalidate
engines.lua           -- bash, stdin_pipe(cmd), build(spec) resolver
gates.lua             -- path_allow_list(key), executable(bin)
write_invalidate.lua  -- checkbox_lines(key)
```

No side effects at require-time. All state (config, cache, autocmds) is per-view or in the shared exec cache; nothing global.

## Extraction

To lift this out as a standalone plugin:

1. Copy `lua/m/markdown_fence_view/` to `lua/markdown_fence_view/`.
2. Update the `require` paths (`m.markdown_fence_view.*` → `markdown_fence_view.*`) inside the module.
3. Ship the built-ins under `fv.engines`, `fv.gates`, `fv.write_invalidate` — they're generic and buy consumers a lot.
4. Add `plugin/markdown_fence_view.lua` if you want a global `:MarkdownFenceViewInvalidate` command that clears all views' caches.
5. Runtime dep: `render-markdown.nvim`. Parse-time dep: treesitter `markdown` parser (typical nvim setups already have it).

There is no direct Neovim API assumption beyond `vim.system`, `vim.uv.hrtime`, `vim.uv.fs_realpath`, `vim.treesitter.*`, `vim.api.nvim_buf_*`, `vim.api.nvim_create_user_command`, `vim.api.nvim_create_autocmd`, `vim.schedule`. All present on 0.10+.

Alternative extraction target: rename to `render-markdown-fence-view.nvim` or fold upstream into `render-markdown.nvim` as a first-class handler for arbitrary shell/exec fences (out-of-scope for now — the plugin author has held the line on execution-inside-render-markdown for security reasons).

## Design rationale

See [ADR editors-0002](../../../../../../docs/adrs/editors/0002-editors-nvim-markdown-fence-view.md) for the extraction decision. See [ADR editors-0001](../../../../../../docs/adrs/editors/0001-editors-nvim-markdown-query-view.md) for the original `markdown_query_view` design.

## Tests

`test/files/editors/dot_config/nvim/lua/m/markdown_fence_view/*_spec.lua`. Run with:

```bash
/Users/<you>/.luarocks/bin/busted test/files/editors/dot_config/nvim/lua/m/markdown_fence_view/
```

Covers: engine resolution, sync + async exec paths, SIGKILL classification, per-view cache invalidation, status line label routing, spec validation, `setup({views})` registration, `handlers()` output, `get(name)` lookup, `commands` autocmd registration, `write_invalidate` pattern derivation, all built-in engines/gates/write_invalidate factories.
