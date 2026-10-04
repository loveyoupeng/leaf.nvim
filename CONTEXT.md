# leaf.nvim

Neovim glue for the [leaf](https://github.com/RivoLink/leaf) Markdown
viewer: rendered previews inside Neovim, plus an fzf-lua picker for
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
Where the Viewer appears. **Window**: the render, a listed named buffer,
takes over the content window like a normal `:edit` (previous window when
invoked from an explorer sidebar); closing swaps the displaced buffer back
in, and a file the explorer opens around it folds into its window.
**Split**: vertical split right of the invoking window. **Float**:
centered floating window; opt-in only, never the default. **Tab**: new
tabpage holding only the render; closing the Viewer closes the tab.
`position = "auto"`: Split for a Buffer Source, Window for a File Source.
_Avoid_: layout, position (the config key, not the concept), popup

**Source**:
What gets rendered. **Buffer Source**: the current buffer's content
(possibly unsaved, via temp file) for Static Mode. **File Source**: an
on-disk file — given as a `:Leaf` argument, taken from the Explorer node
under the cursor, or chosen in the Picker.
_Avoid_: input, target

**Explorer**:
The neo-tree filesystem panel. When `:Leaf` runs with focus in the
Explorer, the Markdown file under the cursor becomes the File Source;
a non-Markdown file or directory under the cursor is an error.

**Picker**:
The fzf-lua surface that finds Markdown files under the project root,
previews them via leaf, and opens the selection in a Viewer.
_Avoid_: finder, fzf (the dependency, not the surface)

**Live rendering**:
The Viewer refreshing after the source file is saved (`:w`). Static Mode
re-renders when the source path is written, whether or not it is the
current buffer; Interactive Mode relies on leaf's `--watch`.
_Avoid_: hot reload, auto refresh
