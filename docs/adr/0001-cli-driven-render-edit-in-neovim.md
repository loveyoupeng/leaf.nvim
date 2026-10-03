# Drive the leaf CLI; editing stays in Neovim; live rendering means re-render on save

leaf.nvim does not embed a Markdown renderer: it shells out to the leaf CLI
(two execution paths — piped `--inline` output for Static Mode, `termopen`
for Interactive Mode). Editing is deliberately kept out of the Viewer: the
user edits the normal Neovim buffer, and "live rendering" is defined as
re-render-on-save — a `BufWritePost` autocmd in Static Mode, leaf's own
`--watch` in Interactive Mode.

Rejected alternatives: embedding a Lua/JS renderer (duplicates the user's
existing, good CLI; large maintenance surface), and in-Viewer editing via
leaf's external-editor flag (nested editor inside a Neovim terminal is a
broken interaction model). Consequence: unsaved content renders only in
Static Mode (buffer snapshot); Interactive Mode tracks the on-disk file,
which is documented semantics in CONTEXT.md, not a stray limitation.
