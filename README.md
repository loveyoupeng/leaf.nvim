# leaf.nvim

Markdown preview in Neovim powered by the
[leaf](https://github.com/RivoLink/leaf) CLI — static render or live
interactive TUI, in a split, a float, or a new tab, with a fuzzy Markdown
picker. glow.nvim-style glue, in the spirit of LazyVim.

## Requirements

- Neovim ≥ 0.10
- the `leaf` binary on `$PATH` (install from
  <https://github.com/RivoLink/leaf>) — or point `leaf_path` at it
- Optional picker: `ibhagwan/fzf-lua`
- Optional explorer: `nvim-neo-tree/neo-tree.nvim` (`:Leaf` reads the file
  under its cursor)

## Install (lazy.nvim)

```lua
{
  "loveyoupeng/leaf.nvim",
  cmd = "Leaf",
  opts = {},
  keys = {
    { "<leader>cp", "<cmd>Leaf<cr>", ft = "markdown", desc = "Preview (leaf)" },
  },
}
```

## Usage

- `:Leaf` — preview the current Markdown buffer (toggle: run again, from
  anywhere, to close)
- `:Leaf path/to/file.md` — render another file in a **new tab**; explicit
  path while a Viewer is open retargets it instead of closing
- `:Leaf!` — bang flips the mode: leaf's interactive TUI with `--watch`,
  live-reloading whenever you `:w` in Neovim
- `:Leaf` with the cursor on a Markdown file in **neo-tree** — render that
  file in a new tab; a non-Markdown file or directory errors
- `:Leaf` anywhere else (non-Markdown buffer, nothing to infer) — opens the
  Markdown **Picker** (fzf-lua)
- Static viewer keys: `q`/`<Esc>` close; `j`/`k`/`<C-d>`/`<C-u>` and the
  mouse wheel scroll the render (it's a normal terminal buffer, full
  scrollback). Interactive: wheel scrolls (forwarded as arrow keys —
  Neovim does not forward wheel events to terminal apps), leaf's own keys
  quit; `<C-\>` force-closes.
- Both modes show a one-line key hint in the winbar; hide with
  `show_hints = false`.

Unsaved edits render in static mode (buffer snapshot). Interactive mode
tracks the file on disk, so untitled buffers get an instructive error
instead — save first, then live reload follows every `:w`.

`:checkhealth leaf` reports the binary (path + version) and picker backend.

### Placement

`position = "auto"` (default): previewing the Markdown buffer you're
editing opens a **vertical split to its right**; a file source (explicit
path, explorer node, picker selection) renders fullscreen in a **new tab**
that closes back to where you came from. A float is opt-in only. Force any
placement with `"split"` / `"float"` / `"tab"`.

## Options

```lua
require("leaf").setup({
  leaf_path = nil,        -- leaf binary; nil = search $PATH
  interactive = false,    -- default mode; bang on :Leaf flips it
  position = "auto",      -- "auto" | "split" | "float" | "tab"
  theme = nil,            -- leaf --theme
  border = "rounded",     -- float border
  width_ratio = 0.7,      -- float width
  height_ratio = 0.7,     -- float height
  split_ratio = 0.5,      -- split width, relative to the source window
  scroll_lines = 3,       -- lines per wheel notch in the interactive viewer
  show_hints = true,      -- key hints in the viewer winbar
  markdown_filetypes = { "markdown", "markdown.pandoc", "markdown.gfm", "vimwiki", "telekasten" },
  markdown_extensions = { "md", "markdown", "mkd", "mkdn", "mdwn", "mdown", "mdtxt", "mdtext", "rmd", "wiki" },
})
```

## Design and development

- `SPEC.md` — feature spec; `CONTEXT.md` — domain glossary;
  `docs/adr/` — architectural decisions; `tasks.md` — ticket board.
- Tests (pure decision layer, plenary):

  ```sh
  nvim --headless -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory tests/leaf/ { minimal_init = 'tests/minimal_init.lua' }"
  ```

  (expects plenary.nvim at `~/.local/share/nvim/lazy/plenary.nvim`)

- End-to-end smoke (real binary): `nvim --headless -l tests/smoke.lua`

## License

Apache-2.0 — see `LICENSE`.
