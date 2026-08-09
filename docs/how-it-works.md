# How it works

## Render pipeline

Given a fenced code block whose info-string first word matches a configured view's `name`, the module:

1. Walks the markdown treesitter tree, finds the block.
2. Resolves the info-string suffix (or default) to a shell command via the view's engines.
3. Spawns the command asynchronously (`vim.system` with callback).
4. Shows `// running <label>...` as `virt_lines` immediately.
5. On completion, caches by `<view_name> + sha256(body) + cwd`, re-renders, replaces the spinner with stdout as `virt_lines`.
6. Anchors marks one line past the closing fence so UFO's fenced_code_block fold doesn't hide them.
7. Classifies SIGKILL from `:wait(timeout)` as `timeout` (not generic error).

There is no direct Neovim API assumption beyond `vim.system`, `vim.uv.hrtime`, `vim.uv.fs_realpath`, `vim.treesitter.*`, `vim.api.nvim_buf_*`, `vim.api.nvim_create_user_command`, `vim.api.nvim_create_autocmd`, `vim.schedule`. All present on 0.10+.

## Reason lifecycle

A `result.reason` is one of `ok`, `empty`, `running`, `timeout`, `error`, or any custom string returned by `gate`. The status line resolves it in this order:

1. `labels.extra[reason]` if present (view-specific reasons — `path`, `missing`, etc.)
2. Built-in cases: `running`, `timeout`, `error` (with stderr / signal / exit fallback), `empty`
3. `nil` (no status line — ok results with rows already have the footer)

## Cache invariants

- Keys are namespaced by view name: `<name>\0<sha256(body)>\0<cwd>`. Different views can't collide.
- In-progress marker prevents double-spawn if `parse` is called re-entrantly before the first spawn completes.
- Timeouts are cached like any other result. Retry paths: `:<Prefix>Refresh` clears entries for that view; saving a file whose contents match `write_invalidate.require` also clears them.

## Write-back via scratch buffer

Views whose `transform_output` returns metadata with `{path, lineno, raw}` per row can be edited in place via `scratch.lua`. Trigger the scratch from the parent buffer (e.g. `<localleader>tt` on a query fence) and:

```lua
local scratch_mod = require("markdown_fence_view.scratch")
local block = scratch_mod.block_under_cursor(view, buf)
scratch_mod.open({ view = view, buf = buf, block = block })
```

`scratch.open` creates a floating buffer with `buftype = "acwrite"` and `filetype = "markdown"` (so `<C-Space>` and other markdown mappings work unchanged), populates it with the source-form `raw` lines from metadata, and places identity extmarks. On `:w`:

- Each live extmark whose row text differs from its `original` → `replace` in source.
- Each shadow entry with no live extmark → `drop` (rewrite the source checkbox as `[-]`).
- Each row without an extmark (newly added) → v1 rejects the whole write.
- >3 drops in a batch → confirm-once prompt.
- Per-path mtime check before applying — refuses writes to paths that changed on disk since the scratch opened.

After a successful write, the view's cache is invalidated and the parent buffer re-renders. Design details in [ADR editors-0003](adrs/0003-editors-nvim-query-view-writeback.md).

## Module layout

```
init.lua              -- setup{views}, new(spec), handlers(), get(name)
blocks.lua            -- gather(buf, lang) via markdown treesitter root
marks.lua             -- append() with fold-safe close_row + 1 anchor
exec.lua              -- name-namespaced cache; get / run / run_async / invalidate
engines.lua           -- bash, stdin_pipe(cmd), build(spec) resolver
gates.lua             -- path_allow_list(key), executable(bin)
write_invalidate.lua  -- checkbox_lines(key)
scratch.lua           -- floating scratch buffer + BufWriteCmd sync-back
```

No side effects at require-time. All state (config, cache, autocmds) is per-view or in the shared exec cache; nothing global.

## Design rationale

- [ADR editors-0002](adrs/0002-editors-nvim-markdown-fence-view.md) — the extraction into this shared module.
- [ADR editors-0003](adrs/0003-editors-nvim-query-view-writeback.md) — `transform_output`, the scratch buffer, and extmark row identity.
- [ADR editors-0005](adrs/0005-editors-nvim-persist-inline-results.md) — persisting computed results inline.
