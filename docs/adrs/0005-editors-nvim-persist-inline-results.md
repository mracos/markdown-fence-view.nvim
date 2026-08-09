# [ADR editors - 0005]: Persist inline computed results in markdown (change-gated, across all fence_view consumers)

> Date: 2026/08/07
>
> Authors: `Marcos Ferreira`
>
> Status: Proposed

## Context

The inline-query system has grown three consumers, all rendering computed output
as virtual text via `m.markdown_fence_view`:

- **editors-0001** ` ```query ` blocks: body is a shell command, stdout rendered
  as `virt_lines` after the fence. Render-only.
- **editors-0002** extracted `m.markdown_fence_view`: shared gather / marks /
  gates / exec, with an **in-memory body-hash cache** (`exec.lua`) and
  `write_invalidate.lua`. Second consumer was ` ```mermaid `.
- **editors-0004** ` ```calc ` blocks: per-line conversation-math results.

All three share one limitation: **results live only in the editor**. They are
`virt_lines`, never written to the file. Consequences:

- **They do not render anywhere but this editor.** On GitHub, in another editor,
  in an Obsidian preview, a ` ```query ` block shows its command and no output. A
  ` ```calc ` block shows expressions with no answers.
- **They recompute on every open.** The editors-0002 cache is in-memory and dies
  with the buffer. Reopening a daily re-runs every block's shell pipeline.

editors-0003 added write-back, but for a different axis: it edits *source rows*
(todos in canonical stores) back from a scratch buffer. That is source editing,
not output persistence. The block-output direction (block body -> rendered
result, written next to the block) has no design yet.

This is a system-wide gap, not a per-consumer one. Solving it once in
`m.markdown_fence_view` fixes ` ```query `, ` ```calc `, and ` ```mermaid `
together, which is why it is its own ADR rather than a section inside
editors-0004.

## Options Considered

1. **Status quo: virtual-only.** No file writes. Rejected: no external render,
   recompute every open.
2. **Persist output in-file next to the block, change-gated by a body hash.**
   Output is written into the markdown with hidden hash markers; recompute only
   when the block body changes. Chosen.
3. **Sidecar file** (`daily.md` + `daily.out.md`). Rejected: reintroduces the
   drift the projection model (notes-0036 / editors-0001) was built to avoid, and
   breaks "what you see is what's in the file".
4. **Full editors-0003 scratch-buffer round-trip for output too.** Rejected:
   that machinery is for bi-directional source editing. Output persistence is
   one-directional (body -> output) and does not need a scratch buffer, only a
   guarded in-place write.

## Decision

**Add opt-in, change-gated output persistence to `m.markdown_fence_view`. When a
block opts in, its computed result is written into the file inside hidden hash
markers and re-executed only when the block body (or spec/engine) changes.
Default stays virtual-only, so nothing writes to a file unless asked.**

### Opt-in

Per-block via the info-string, or per-view via the spec:

````markdown
```query persist
notes todos list --category owed-to-me --format waiting-for
```
````

No `persist` token, or `persist=false` in the spec, keeps today's ephemeral
`virt_lines` behavior unchanged. Opt-in is deliberate: silent file writes on
open would surprise, and most ad-hoc query blocks want fresh output every time.

### Persistence shapes

Two shapes matching the two render shapes already in the module:

**Block-output** (` ```query `, ` ```mermaid `): the stdout blob is written after
the closing fence, bracketed by markers carrying the body hash.

````markdown
```query persist
notes todos list --category owed-to-me --format waiting-for
```
<!-- fv:out 9f3a -->
- [ ] Reply to Adri on the data hire  [due:: 2026-08-11]
- [ ] Sign off Q3 platform plan
<!-- /fv:out -->
````

**Per-line** (` ```calc `): each expression line carries its own value and hash,
so editing one line does not rewrite the others.

```
budget - rent - food = 2600 <!-- fv:c 9f3a -->
```

The visible text (`= 2600`, the `- [ ]` lines) renders on GitHub. The
`<!-- fv:... hash -->` comments are invisible in rendered markdown and carry the
change-gate.

### Change-gate

The marker hash is `hash(body + engine + spec-relevant-flags)`. On open or edit:

1. Compute the current block's hash.
2. If it matches the stored marker hash, the persisted output is fresh: render
   it (or trust the in-file text), skip execution.
3. If it differs (or no marker exists), execute, then rewrite the output region
   and stamp the new hash.

This is the same key as editors-0002's in-memory cache, so the two layers
compose: in-memory is the hot cache within a session, the in-file marker is the
durable cache across sessions and across viewers.

### Re-entrancy

Writing output into the buffer fires `TextChanged`, which would re-trigger the
handler and loop. Guard exactly as editors-0003 does:

- a programmatic-write flag set around the in-place edit,
- diff-before-write (only write when the new output differs from what is there),
- extmark identity mapping each output region back to its owning block.

Reuse editors-0003's guard and extmark-identity code; do not reinvent it.

### Staleness

When a block opts into persistence, a fresh execution can still be forced
(`:MarkdownFenceRefresh` or the existing invalidate path). If execution fails or
times out, the last persisted output stays in the file and a virtual indicator
marks it stale, rather than destroying good output with an error blob.

## Consequences

**Positive:**

- Query and calc results render on GitHub, in other editors, and in previews,
  not just in this Neovim.
- Reopening a daily no longer re-runs every block; persisted output with a
  matching hash is trusted.
- One implementation in `m.markdown_fence_view` covers every current and future
  fence consumer.
- Canonical files stay self-contained (no sidecars), preserving the
  what-you-see-is-in-the-file contract.

**Negative:**

- Fence blocks that opt in now mutate the file on eval, so a daily can show as
  modified from rendering alone. Mitigated by diff-before-write (no write when
  output is unchanged) and opt-in default.
- Persisted output can go stale if the underlying data changes but the block
  body does not (the hash only tracks the body). Accepted: the gate is "body
  changed", refresh is explicit. A time-based staleness hint is possible later.
- The markdown carries hidden hash comments. Ugly in raw view, invisible
  rendered. Acceptable cost for cross-viewer output.

## Relationship to other ADRs

- Extends **editors-0001** (query-view) and **editors-0002**
  (`m.markdown_fence_view`): persistence is a new capability on the shared module.
- Reuses **editors-0003**'s write-back re-entrancy guard and extmark identity,
  applied to computed output instead of source rows.
- Unblocks the in-file caching that **editors-0004** (conversation math)
  deferred here; ` ```calc ` is the per-line consumer.
