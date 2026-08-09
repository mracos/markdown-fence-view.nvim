-- Minimal globals for pure-function specs. Each spec that needs a richer `vim`
-- builds its own and restores it in before_each/after_each; this only
-- guarantees `_G.vim` exists so `original_vim = _G.vim` has something to save.
if not vim then
  _G.vim = {
    fn = {},
    o = {},
    api = {},
  }
end
