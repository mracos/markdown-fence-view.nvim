# markdown_fence_view demo

Open this in Neovim with the plugin wired up (see [integrating.md](integrating.md)).
Each fence below runs its body and renders the output inline, under the closing fence.

A `mermaid` fence (renders anywhere `mermaid-ascii` is on PATH):

```mermaid
graph LR
  A[write fence] --> B[run body]
  B --> C[render output inline]
```

A `query` fence (renders when the file is under an allowed root, e.g. `~/Notes`):

```query
echo "- [ ] ship the mirror"; echo "- [ ] screenshot the demo"
```

Edit a body and save: the cache invalidates and the block re-renders.
