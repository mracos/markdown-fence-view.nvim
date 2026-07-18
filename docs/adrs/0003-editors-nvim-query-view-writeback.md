# [ADR editors - 0003]: Query-view write-back via scratch buffer with extmark row identity

**Status:** Accepted

> Date: 2026/07/18
>
> Authors: `Marcos Ferreira`
>
> **Depends on:** [editors-0001](0001-editors-nvim-markdown-query-view.md) (query view), [editors-0002](0002-editors-nvim-markdown-fence-view.md) (fence view module). Extends both.

## Context

[editors-0001](0001-editors-nvim-markdown-query-view.md) shipped virtual query rendering as a **render-only** MVP:

> Render-only MVP, no write-back.
> ...
> If render-only is insufficient within ~1 month, expand to write-back (no `[id::]` migration needed).

That off-ramp is now the ask. Concrete pain: opening the daily lists TODOs pulled from `todos/**` and `people/**`, but toggling any of them requires jumping to the source file, finding the line, and toggling it there. The daily is a dashboard I can't act on.

The write-back locator problem — how to identify which source line each virtual row came from — is already solved at the CLI: `notes todos query --format json` emits `{path, state, section, due, owner, source, desc, raw, lineno}` per row (see `lib/shell/notes/notes-todos-query:24`). Line numbers are ground truth from the awk pipeline that produced the row. No `[id::]` field needed.

The remaining problem is UX. Virtual lines are extmarks; nvim cannot put the cursor on one. So the interaction cannot be "cursor on the row, hit a key" — it has to be indirect.

Three shapes considered:

- **A. Picker over cached rows** — cursor on the fence, hit a key, mini.pick opens listing the rendered rows, select one → toggle in source file. Simple. One-at-a-time only.
- **B-simple. Scratch buffer with checkbox-only sync** — open a floating buffer with the rendered lines as real editable text. `<C-Space>` (fixed to support visual range, see the sibling change) toggles in the scratch. On save, only checkbox-state changes sync back.
- **B-full. Scratch buffer with full-line sync** — same buffer shape as B-simple, but any edit to a row (checkbox, due date, description, category, delete) syncs to the source. Additions are rejected v1. This ADR chooses B-full.

The extra complexity of B-full over B-simple is small: once you have the file-level sync infrastructure for one field, syncing the whole line is a single `nvim_buf_set_lines` call. The extra complexity of B-full over A is real, but so is the payoff — batch operations (close five, reschedule due dates, drop stale rows) are the common case in a morning review, not the exception.

## Decision

**Add write-back to the query view via a floating scratch buffer whose rows carry extmark-based identity to their source `(path, lineno)`. Any single-line edit — including deletion — syncs to source on `:w`. Additions are rejected v1.**

### 1. `transform_output` hook in `markdown_fence_view`

Add an optional per-view hook to the fence-view spec:

```lua
transform_output = function(stdout) -> { lines = {string, ...}, metadata = {?, ...} }
```

Called with the raw stdout string from the executed body. Returns display lines (rendered as virt_lines by fv) plus arbitrary per-row metadata (opaque to fv). fv caches metadata alongside the result table so any downstream action can look it up by (name, body, cwd).

Views without a `transform_output` behave exactly as today: stdout split by newline → display lines, metadata omitted.

### 2. Query view uses JSON as its wire format

Query view's spec sets:

```lua
transform_output = function(stdout)
  local lines, metadata = {}, {}
  for jline in stdout:gmatch("[^\n]+") do
    local ok, obj = pcall(vim.json.decode, jline)
    if ok and obj.raw then
      table.insert(lines, obj.raw)
      table.insert(metadata, {
        path = obj.path, lineno = obj.lineno, state = obj.state,
      })
    else
      table.insert(lines, jline)   -- fallback: raw text, no metadata slot
    end
  end
  return { lines = lines, metadata = metadata }
end
```

Fence bodies that already use `--format json` get metadata for every row. Fence bodies still on `--format daily` (the default) fall through the pcall path — display works, write-back keymaps show `"no metadata"` on those blocks.

### 3. Daily template switches to `--format json`

`lib/shell/notes/templates/daily.md` fence bodies gain `--format json`:

```
notes todos query --category owed-by-me --due-before today --format json
notes todos query --category trampo,fazer,compras,inbox --due-before today --format json
```

`~/Notes/templates/daily.md` mirrored. Existing dailies untouched — they continue rendering (fallback path); toggle just doesn't fire for them. Rewriting old dailies would break `notes doctor` and other diff-based checks for no gain.

### 4. `<C-Space>` visual-mode bulk toggle

Prerequisite change (already applied ahead of this ADR): the existing `<C-Space>` binding in `config/langs/markdown.lua` was bound in `{"n", "v"}` mode but only rewrote the cursor line. Now it detects visual mode and iterates the range. Lines without a checkbox are skipped, so mixed selections are safe. This ADR relies on that fix so the scratch buffer flow feels natural — select five rows, hit `<C-Space>`, all toggled.

### 5. Scratch buffer flow

**Trigger.** `<localleader>tt` (todos-toggle) when the cursor is on a query fence or its virt_lines anchor row (the blank line after the closing ` ``` `). If cursor isn't near a fence, fall back to a picker of all fences in the buffer.

**Open.** Create a floating buffer:

```lua
local scratch = vim.api.nvim_create_buf(false, true)
vim.bo[scratch].buftype = "acwrite"
vim.bo[scratch].filetype = "markdown"
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, display_lines)
```

`acwrite` means `:w` fires `BufWriteCmd` (writeable-but-no-file semantics) so we can intercept the write and run sync logic. `filetype = "markdown"` inherits all markdown mappings including the now-bulk-capable `<C-Space>`.

**Row identity via extmarks.** On open, create one extmark per row in a dedicated namespace and record what the mark ID stands for:

```lua
local ns = vim.api.nvim_create_namespace("fence_view_scratch")
local shadow = {}   -- [extmark_id] = { path, source_lineno, source_mtime, original }
for i, meta in ipairs(metadata) do
  local id = vim.api.nvim_buf_set_extmark(scratch, ns, i - 1, 0, {})
  shadow[id] = {
    path = meta.path,
    source_lineno = meta.lineno,
    source_mtime = get_mtime(meta.path),
    original = display_lines[i],
  }
end
```

Extmarks move with lines. Reorders, deletions, mid-buffer insertions all preserve `id → line` mapping without our involvement.

**Sync-back on `:w`** (bound via `BufWriteCmd` autocmd on the scratch buffer):

```
1. Enumerate live marks: nvim_buf_get_extmarks(scratch, ns, 0, -1)
2. Group changes by source path.
3. Per path, check current mtime > source_mtime -> refuse this file's writes with a clear message; other paths still apply.
4. For each live mark:
   - Read current text at its row.
   - If unchanged from shadow.original -> skip.
   - Else -> replace source[path][lineno] with current text.
5. For each shadow ID not seen in live marks:
   - The row was deleted. Mark source[path][lineno] as `[-]` (dropped),
     leaving the rest of the line intact. Rollover cleans it up later.
6. For each live row without a shadow entry:
   - Added by user. v1: reject the whole write with
     ":w failed - N new lines have no source. Use `notes capture` to add TODOs."
     Leave the scratch buffer open.
7. Apply changes per path via a single nvim_buf_call block:
   - vim.fn.bufadd(path) + vim.fn.bufload(bufnr)
   - nvim_buf_set_lines for each edit
   - :silent write
8. Trigger fv.exec.invalidate("query") so the render refreshes.
9. Close the scratch buffer.
```

**Confirmation.** If the batch contains more than 3 deletions (dropped rows), prompt once: `"Mark N TODOs as [-] dropped? [y/N]"`. Rationale: single-line deletions are usually intentional; ten-at-a-time deletion is more likely an accident.

**Concurrency policy.** Per-path `source_mtime` check. If the source file changed on disk since the scratch opened, this path's writes are refused with the message shown above. This is per-path — a stale one file doesn't block writes to others in the same batch. User re-opens the scratch to pick up the drift.

### 6. Layout

The scratch buffer opens in a floating window sized to fit the row count + margin:

```
+- query: owed-by-me + trampo, due-before today ----------------+
| - [ ] Buscar herramientas de AEO [ai] [due:: 2026-06-26]        |
| - [ ] Fernanda: hospedaje [due:: 2026-05-15] [ai]              |
| - [ ] Oscar: Retomar Daxter [ai] [due:: 2026-07-07]            |
|                                                                 |
| :w to sync back  :q to cancel                                   |
+-----------------------------------------------------------------+
```

Title bar shows the fence body summary (roughly the flags in play). Footer is a virt_text line rendered via extmark, not real content.

### 7. Mappings inside the scratch buffer

Inherited from markdown filetype:

- `<C-Space>` — toggle checkbox (now range-aware via the sibling fix)
- `<Tab>` / `<S-Tab>` — next/prev link
- `<CR>` — follow wiki link (would jump to source; useful for "see this in context")
- All the todos leader keys under `<localleader>t` (due date, defer, extract, etc.)

Scratch-buffer-local additions:

- `:w` — sync back and close (rebinds via `BufWriteCmd`)
- `:q` / `<Esc>` — cancel without syncing
- `?` — floating help for the flow

The scratch buffer is transient. It doesn't participate in sessions, mini.sessions, or the vault git commit.

## Alternatives considered

**1. Picker only (Option A).** Rejected as the primary interaction — batch toggle is the common case. A picker still fits as a fallback for "cursor isn't near any fence" cases; kept as a hidden secondary path.

**2. B-simple: scratch buffer, checkbox-only sync.** Rejected because the incremental cost from B-simple to B-full is small (one more `nvim_buf_set_lines` per row) but the ergonomics win is large (edit due date inline, not via a separate command).

**3. Free-form additions supported v1.** Rejected. Adding a new row has no unambiguous target — which category? Which file? Guessing is worse than saying "use `notes capture`." Revisit if a natural default emerges (e.g. `--category X` in the fence body implies "additions go to `todos/X.md`"). See open question below.

**4. Inline edit via LSP-style code actions.** Considered — a code action on the fence line that opens a menu. Too many clicks for a batch flow, and requires an LSP shim we don't have. Discarded.

**5. Own the extmark namespace and skip render-markdown.** Not necessary for write-back; the display path stays as-is. Only the scratch buffer flow is new.

## Consequences

**Positive:**

- Batch toggle, batch re-schedule, and drop-by-delete become natural morning-review operations.
- The daily really becomes a dashboard — read + act in place, no context switch to the source file.
- Reads and TODOs are now first-class projections, and their consumers can `:w` them.
- `transform_output` is a general hook — future views (jq blocks, dataview) can attach their own metadata payloads and their own keymaps against them.

**Negative:**

- One more moving piece in fv. The `transform_output` API needs to stay backwards-compatible if fv is ever extracted (see [editors-0002](0002-editors-nvim-markdown-fence-view.md)).
- Daily template migration required to `--format json`. Old dailies keep working via the fallback; new dailies get toggle. Two-shape template era.
- `BufWriteCmd` semantics are a bit magical; a reader landing on the scratch buffer's config has to know that `:w` doesn't write a file, it runs the sync. Documented in the scratch buffer's floating window title.

**Trade-offs:**

- Deletion sync writes `[-]` rather than removing the source line. Preserves undo history and keeps the source diff-reviewable. Downside: dropped rows linger in the source file until rollover reaps them.
- Concurrency policy is refuse-on-drift, not merge. Simpler, and drift is rare when the daily is the only writer.
- Additions rejected v1. Non-obvious to first-time users; documented in the reject message.

## Open questions

- **Additions to a target category.** If the fence body is `--category trampo`, is there a natural way to send new rows to `todos/trampo.md`? Prompt on save? Auto-route? Deferred to a follow-up.
- **Cross-fence multi-select.** If the buffer has three query blocks and the user wants to move a row from block 1 to block 2, do we support that? v1 says no (one fence per scratch session); revisit if the workflow surfaces.
- **Undo model.** `:w` currently applies file-by-file writes. If write to file 2 fails, do we roll back file 1? v1: no rollback, per-file errors are surfaced; user can re-open and retry. Revisit if partial-write states become confusing.

## Implementation order

Each phase ships independently and can be reviewed on its own.

1. **`<C-Space>` visual-mode bulk toggle** — landed alongside this ADR. Standalone; useful outside the scratch buffer too.
2. **`transform_output` hook in fv** — plus store `metadata` in the cache entry, exposed via `fv.exec.get(name, body, opts).metadata`. Unit test covers a spec whose transform emits both lines and metadata.
3. **Query view uses JSON** — spec's `transform_output` parses `--format json`. Fallback pcall path keeps `--format daily` blocks rendering.
4. **Daily template flip** — `lib/shell/notes/templates/daily.md` and `~/Notes/templates/daily.md`. New dailies get toggle; old ones don't.
5. **Scratch buffer flow (open + display)** — floating window, extmark identity, no sync yet. Cursor lands in the scratch, edits are lost on close. Just verifies the layout.
6. **Sync-back on `:w`** — the big piece. Grouped by path, mtime concurrency check, deletion → `[-]`, additions rejected. Followed by cache invalidate + render refresh.
7. **Multi-deletion confirmation prompt** — polish.
8. **Docs update in `markdown_fence_view/README.md`** — document `transform_output` hook, link to this ADR.

Rough total: 2-3 days if I hit no surprises. Phase 5 and 6 are the meat; 1-4 are small.

## Related decisions

- Extends [editors-0001](0001-editors-nvim-markdown-query-view.md) — this is the write-back off-ramp 0001 reserved.
- Extends [editors-0002](0002-editors-nvim-markdown-fence-view.md) — adds the `transform_output` hook to the fv spec surface.
- Depends on [notes-0059](../notes/0059-notes-daily-query-first.md) semantics: `[extracted:: YYYY-MM-DD]` and query-first daily. Toggle in the daily is only useful once capture writes straight to the domain; otherwise the daily still holds mutable TODOs that toggling doesn't help with.
