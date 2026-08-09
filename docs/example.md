# markdown_fence_view demo

Open this in Neovim with the plugin wired up (see [integrating.md](integrating.md)).
Each fence's first word picks a view; the body is executed and its output is
rendered inline, right under the closing fence (nothing is written to the file).

`mermaid` uses the `stdin_pipe` engine, the body is piped to `mermaid-ascii`.
It renders on any path where that binary is installed:

```mermaid
graph LR
  A[write fence] --> B[run body]
  B --> C[render inline]
  C --> D[edit + save re-renders]
```

`query` uses the `bash` engine, the body is run as a shell command. This view is
path-gated, so it renders only under an allowed root (e.g. `~/Notes`):

```query
echo "hello from the bash engine"; date -u +%Y-%m-%d
```

Edit a body and save to re-run it.
