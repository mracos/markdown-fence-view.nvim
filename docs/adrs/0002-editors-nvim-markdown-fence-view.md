# [ADR editors - 0002]: Extract `markdown_fence_view` as a shared spec-driven module

> Moved from `docs/adrs/notes/0061-notes-nvim-markdown-fence-view.md` (2026-07-18) as part of splitting editor/nvim decisions into their own ADR subdomain.

**Status:** Accepted

> Date: 2026/07/18
>
> Authors: `Marcos Ferreira`

## Context

ADR [editors-0001](0001-editors-nvim-markdown-query-view.md) shipped `markdown_query_view` as a render-markdown.nvim custom handler for ` ```query ` blocks. Later, a second consumer arrived: `markdown_mermaid_view` for ` ```mermaid ` blocks rendered as ASCII via `mermaid-ascii`. Both were built independently, copy-pasted from the same shape:

- Walk the markdown treesitter tree for `fenced_code_block` nodes whose info-string first word matches a target language.
- Execute the body via `vim.system` with a timeout.
- Render stdout as `virt_lines` after the closing fence.
- Cache by body hash.
- Expose `setup{}` + `handler()` for the plugin wiring.

The duplication showed its cost. In a single session (2026-07-17), three bugs had to be fixed in **both** files back-to-back:

1. **`ctx.root` misuse.** render-markdown passes the *injected* subtree root (`query` or `mermaid` language) into the handler. The gather query was iterating markdown against that root, matching zero `fenced_code_block` nodes.
2. **SIGKILL classification.** `vim.system:wait(timeout)` returns `{ code=124, signal=9 }` on timeout, not `nil` — both handlers were reporting `// error:` with empty stderr instead of `// timed out`.
3. **UFO fold hides virt_lines.** `nvim-ufo` folds each fenced_code_block as its own inner treesitter fold; anchoring the mark at the closing fence row placed it inside the fold and hid it.

Same bug shape × two files × three rounds = a tax that's already been paid several times. A third consumer is plausible (dataview blocks, jq blocks, duckdb blocks — all mentioned in [editors-0001](0001-editors-nvim-markdown-query-view.md) as future engine slots). The rule-of-three has been met.

## Decision

**Extract the shared render pipeline into `m.markdown_fence_view` as a spec-driven module. Each concrete view becomes a spec: engines, labels, gates, cwd. The shared module owns everything else.**

**1. Module layout:**

```
lua/m/markdown_fence_view/
  init.lua              -- setup{views}, new(spec), handlers(), get(name)
  blocks.lua            -- gather(buf, lang) via markdown treesitter root
  marks.lua             -- append() with fold-safe close_row + 1 anchor
  exec.lua              -- name-namespaced cache; get / run / run_async / invalidate
  engines.lua           -- bash, stdin_pipe(cmd), build(spec) resolver
  gates.lua             -- path_allow_list(key), executable(bin)
  write_invalidate.lua  -- checkbox_lines(key)
  README.md             -- module docs, extraction notes
```

**2. Single top-level configuration entry point:**

Both consumers (query, mermaid) are declared inline via `fv.setup({views = ...})`. No per-view wrapper modules — the shared module is configured, not wrapped.

```lua
local fv = require("m.markdown_fence_view")

fv.setup({
  views = {
    {
      name = "query",
      labels = { ..., extra = { path = "..." } },
      engines = { default = "bash", map = { bash = fv.engines.bash } },
      gate = fv.gates.path_allow_list("allow_paths"),
      extra_config = { allow_paths = { NOTES_DIR } },
      commands = "MarkdownQuery",
      write_invalidate = fv.write_invalidate.checkbox_lines("allow_paths"),
    },
    {
      name = "mermaid",
      labels = { ..., extra = { missing = "mermaid-ascii not installed" } },
      engines = {
        default = "mermaid-ascii",
        map = { ["mermaid-ascii"] = fv.engines.stdin_pipe({ "mermaid-ascii", "--file", "-" }) },
      },
      gate = fv.gates.executable("mermaid-ascii"),
      commands = "MarkdownMermaid",
    },
  },
})

require("render-markdown").setup({ custom_handlers = fv.handlers() })
```

`fv.new(spec)` is still exposed for low-level use / tests; `fv.setup` is `new + register`.

**3. Generic helpers ship as first-class factories:**

- `fv.engines.bash` — `bash -c <body>`, no stdin.
- `fv.engines.stdin_pipe(cmd)` — factory: pipe body to a fixed command's stdin.
- `fv.gates.path_allow_list(config_key)` — factory: reject blocks outside `config[key]` roots (buf realpath check).
- `fv.gates.executable(bin)` — factory: reject when binary is not on PATH.
- `fv.write_invalidate.checkbox_lines(config_key)` — factory: drop cache when saved `.md` under `config[key]` contains `- [` lines.

Consumers whose behavior fits these factories write no closures. Consumers with quirks (like the query view's `vault_for_cwd` override) still supply a lambda.

**4. What the shared module owns:**

- Treesitter walk from the markdown root (fixes the `ctx.root` trap).
- Fold-safe extmark anchoring one row past the closing fence with `virt_lines_above = true`.
- Async spawn via `vim.system(cmd, opts, callback)` with an in-progress cache marker to prevent double-spawn.
- SIGKILL / code 124 detection reclassified as `timeout`.
- Status-line label routing including `extra` for view-specific reasons.
- Cache keyed by `<name>\0<sha256(body)>\0<cwd>` — different views never collide.
- Declarative `commands` + `write_invalidate` setup — no per-view boilerplate.

**5. Testability:**

Specs for the shared module test the primitives directly (`engines`, `gates`, `write_invalidate`, `exec` sync + async paths, spec validation, status line label routing, `setup({views})` registration, `handlers()` output). Consumers no longer need per-view specs — they're declarative data over a shared, tested core.

## Alternatives considered

**1. Keep two independent files.**
Rejected — same bug shape hit in both files three times already in one session. Third consumer (dataview / jq blocks) would triple the tax.

**2. Inline both specs into `plugins/notes.lua`.**
Considered. Two fewer files, but the specs (~40 lines each with closures for engines, gates, path checks) belong in dedicated modules — `plugins/notes.lua` is plugin *wiring*, not view logic. The wrapper file being the natural require path (`m.markdown_query_view`) also preserves testability and search-ability.

**3. Base-class inheritance (query as base, mermaid extends).**
Rejected — mermaid isn't a subset of query. Spec-driven composition makes the *contract* explicit; inheritance would hide it.

**4. Fold `markdown_query_view` internals up into `render-markdown.nvim`.**
Long-term desirable but out of scope. The upstream plugin author has held the line on shell execution inside the render pipeline for security reasons. Local extraction gives us the maintenance win now.

## Consequences

**Positive:**

- One place to fix bugs in the render pipeline. The three bugs from 2026-07-17 (`ctx.root`, SIGKILL classification, UFO fold anchor) each live in exactly one file now.
- Cache is namespaced by view — cross-view collisions are impossible.
- New consumers require ~30-50 lines of spec, not a copy of the pipeline.
- Extraction-ready. See `README.md` — the module only depends on render-markdown.nvim (runtime) and the markdown treesitter parser (parse-time). Lifting it out is a copy + require-path rewrite.

**Negative:**

- One more layer of indirection. `markdown_query_view` no longer contains the render logic — reading top-down requires jumping into `markdown_fence_view`.
- The spec grammar is bespoke. Each new field is a small API decision.

**Trade-offs:**

- The wrappers stay thin — deliberately. If they grow, that's a signal to push more into the spec (e.g. a wrapper-specific `on_result` hook).
- Async completion refreshes via `render-markdown.api.render({ buf })` — a private-looking API. If render-markdown breaks it, the fallback is `vim.cmd("RenderMarkdown refresh")` (also private but publicly documented via the user command). Off-ramp: own the extmark namespace ourselves and drop the render-markdown dependency.

## Related decisions

- Follows [editors-0001](0001-editors-nvim-markdown-query-view.md) — this ADR extracts the shared shape after a second consumer landed.
- Coexists with any future engine additions (`jq`, `duckdb`, `sql`) — each becomes a spec, not a fork.
