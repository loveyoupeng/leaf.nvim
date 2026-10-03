# leaf.nvim

Markdown preview in Neovim powered by the
[leaf](https://github.com/RivoLink/leaf) CLI — static render or live
interactive TUI, in a split or a float, with a fuzzy Markdown picker.
glow.nvim-style glue, in the spirit of LazyVim.

## Requirements

- Neovim ≥ 0.10
- the `leaf` binary on `$PATH` (install from
  <https://github.com/RivoLink/leaf>) — or point `leaf_path` at it
- Optional picker: `nvim-telescope/telescope.nvim` **or**
  `ibhagwan/fzf-lua` (whichever you already use; found automatically)

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

With telescope (use it instead of fzf-lua when both exist):

```lua
{
  "loveyoupeng/leaf.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  opts = {},
  config = function(_, opts)
    require("leaf").setup(opts)
    require("telescope").load_extension("leaf") -- adds :Telescope leaf
  end,
}
```

## Usage

- `:Leaf` — preview the current Markdown buffer (toggle: run again to close)
- `:Leaf path/to/file.md` — preview another file (always a float)
- `:Leaf!` — bang flips the mode: leaf's interactive TUI with `--watch`,
  live-reloading whenever you `:w` in Neovim
- `:Leaf` on a non-Markdown buffer — opens the Markdown **Picker**
  (telescope extension or fzf-lua, auto-detected)
- Static viewer keys: `q`/`<Esc>` close. Interactive: use leaf's own quit;
  `<C-\>` force-closes.

Unsaved edits render in static mode (buffer snapshot). Interactive mode
tracks the file on disk, so untitled buffers get an instructive error
instead — save first, then live reload follows every `:w`.

`:checkhealth leaf` reports the binary (path + version) and picker backend.

### Placement

`position = "auto"` (default): editing the Markdown file you're previewing
opens a **vertical split to its right**; any other origin (explicit path,
picker, non-Markdown buffer) opens a **centered float**. Force either with
`"split"` / `"float"`.

## Options

```lua
require("leaf").setup({
  leaf_path = nil,        -- leaf binary; nil = search $PATH
  interactive = false,    -- default mode; bang on :Leaf flips it
  position = "auto",      -- "auto" | "split" | "float"
  theme = nil,            -- leaf --theme
  border = "rounded",     -- float border
  width_ratio = 0.7,      -- float width
  height_ratio = 0.7,     -- float height
  split_ratio = 0.5,      -- split width, relative to the source window
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
