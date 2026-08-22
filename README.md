# markdown_fence_view

Run fenced code blocks in a markdown buffer and render their output inline, as virtual text. Nothing is written to the file.

````markdown
```mermaid
graph LR
  A[write fence] --> B[run body] --> C[render inline]
```
````

![markdown_fence_view rendering a mermaid diagram and a query fence inline](docs/screenshot.png)

It is a custom handler for [`render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim). You declare N *views* in one `setup()` call; each view matches a fence language and says how to execute the body.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mracos/markdown-fence-view.nvim",
  dependencies = {
    "MeanderingProgrammer/render-markdown.nvim",
    "nvim-treesitter/nvim-treesitter",
  },
}
```

Requires Neovim 0.10+ and the `markdown` treesitter parser. Nothing happens at load; you wire the handlers into render-markdown yourself.

---

## Quick start

Two views: `run` executes the body as a shell command, `mermaid` pipes it to [`mermaid-ascii`](https://github.com/AlexanderGrooff/mermaid-ascii). Copy this in, open a markdown file under `~/notes`, write a fence.

```lua
local fv = require("markdown_fence_view")

fv.setup({
  views = {
    {
      name = "run",
      engine = fv.engines.bash,
      -- Only execute fences in files under these roots.
      gate = fv.gates.path_allow_list("allow_paths"),
      extra_config = { allow_paths = { vim.fn.expand("~/notes") } },
      labels = { extra = { path = "skipped (path not allowed)" } },
      timeout_ms = 5000,
    },
    {
      name = "mermaid",
      engine = fv.engines.stdin_pipe({ "mermaid-ascii", "--file", "-" }),
      gate = fv.gates.executable("mermaid-ascii"),
      labels = { extra = { missing = "mermaid-ascii not installed" } },
      ok_footer = function(_n, ms) return ("  // rendered in %dms"):format(ms) end,
    },
  },
  commands = "MarkdownFence",
})

require("render-markdown").setup({
  custom_handlers = fv.handlers(),
})
```

Now `` ```run `` and `` ```mermaid `` fences execute on render. Edit a body, save, it re-runs.

> [!WARNING]
> A matching fence runs its body as soon as the buffer renders, with no prompt. Markdown files arrive from repos, downloads and clones you did not write. Always ship a `gate`: `fv.gates.path_allow_list` restricts execution to roots you control, and `fv.gates.executable` keeps a view dark until its tool is installed.

`docs/example.md` has one fence per engine, open it to check the wiring.

### Commands

`commands = "MarkdownFence"` registers one set that acts on every view.

| Command | Effect |
|---------|--------|
| `:MarkdownFenceRefresh` | Drop all caches and re-render the buffer. |
| `:MarkdownFenceDisable` | Stop rendering in this buffer (`!` = globally). |
| `:MarkdownFenceEnable` | Resume (`!` = globally). |

Results are cached on `view name + sha256(body) + cwd`, so a re-render costs nothing until the body changes.

---

## Beyond the quick start

A view is a spec table, and an engine is just `function(body) -> cmd, stdin`, so wiring a new tool is usually three lines of config. Views can also set their own `cwd`, footer, cache invalidation on write, and `transform_output` for per-row metadata that feeds an editable scratch buffer.

- [Integrating](docs/integrating.md): adding views, writing engines and gates, cache control, spec and API reference.
- [How it works](docs/how-it-works.md): render pipeline, reason lifecycle, cache invariants, write-back, module layout.

---

## Tests

Busted specs live in `spec/*_spec.lua`. Run with `busted`.

## Provenance

Read-only mirror, generated and kept in sync by CI. PRs here are cherry-picked upstream and synced back, so open a PR rather than editing directly.
