# leaf.nvim

Neovim glue for the [leaf](https://github.com/RivoLink/leaf) Markdown
viewer: rendered previews inside Neovim, plus a Telescope picker for
Markdown discovery.

## Language

**Viewer**:
The window showing rendered Markdown. Exists on two orthogonal axes: Mode
and Placement. Read-only surface; editing happens in the normal Neovim
buffer.
_Avoid_: preview window, popup, pane

**Mode**:
How the Viewer produces its render, per invocation. **Static**: one-shot
`leaf --inline` output piped into a terminal buffer. **Interactive**: the
leaf TUI running live inside the window.
_Avoid_: style, flavor

**Placement**:
Where the Viewer appears. **Split**: vertical split right of the source
buffer. **Float**: centered floating window.
_Avoid_: layout, position (the config key, not the concept)

**Source**:
What gets rendered. Buffer content (possibly unsaved, via temp file) for
Static Mode on the current buffer; the on-disk file otherwise.
_Avoid_: input, target

**Picker**:
The telescope/fzf-lua surface that finds Markdown files under the project
root, previews them via leaf, and opens the selection in a Viewer.
_Avoid_: finder, telescope (the dependency, not the surface)

**Live rendering**:
The Viewer refreshing after the source file is saved (`:w`). Static Mode
re-renders via a buffer-local autocmd; Interactive Mode relies on leaf's
`--watch`.
_Avoid_: hot reload, auto refresh
