# leaf.nvim — Spec

A LazyVim-first Neovim plugin that renders Markdown with the
[leaf](https://github.com/RivoLink/leaf) CLI, in the spirit of
[ellisonleao/glow.nvim](https://github.com/ellisonleao/glow.nvim), plus an
fzf-lua picker for finding Markdown files.

## Problem Statement

The user reads and writes Markdown in Neovim and wants a rendered preview
without leaving the editor. Their existing browser-based preview
(`markdown-preview.nvim`) is broken for them, and terminal viewers like glow
render inline but offer no interactivity. The leaf CLI on their machine
offers both a high-quality one-shot render (`--inline`) and a live TUI
(`--watch`), but there is no Neovim glue for it.

## Solution

A `:Leaf` command (with `<leader>cp` bound in the user's own config,
mirroring LazyVim's markdown extra) that opens a **Viewer** — rendered
output beside the source buffer or in its own tabpage. Editing stays in the
normal Neovim buffer; the Viewer refreshes whenever the file is saved.
An fzf-lua **Picker** provides fuzzy Markdown discovery with leaf-rendered
previews, and doubles as the fallback when `:Leaf` can infer nothing from
its argument or the editor focus — a focused neo-tree panel supplies the
file under its cursor instead.

> Note (recorded at implementation time): the original conversation pinned
> the Picker on Telescope, but the user's actual LazyVim environment runs
> fzf-lua (`editor.telescope` in `lazyvim.json` is a stale extra — telescope
> is absent from `lazy-lock.json`). A telescope backend existed briefly but
> could never be exercised in the target environment, so it was cut; the
> Picker is fzf-lua-only.

## User Stories

1. As a Markdown author, I want to run `:Leaf` while editing a `.md` file so
   that I see the rendered result without leaving Neovim.
2. As a Markdown author, I want the rendered result in a vertical split to
   the right of my source buffer so that I can read both side by side.
3. As a Markdown author, I want the Viewer to refresh when I save the file
   so that the render never silently goes stale.
4. As a Markdown author, I want unsaved buffer changes to appear in the
   static render so that I can preview before committing to disk.
5. As a Markdown author, I want `:Leaf!` to open leaf's interactive TUI
   instead, so that I can use navigation and themes while it live-reloads
   on save.
6. As a Markdown author on a brand-new unsaved buffer, I want `:Leaf!` to
   tell me to save the file first, so that I understand interactive mode
   needs an on-disk file.
7. As a Markdown author, I want `:Leaf path/to/file.md` to render a file
   other than the current buffer in a new tabpage, so I get a fullscreen
   render that drops me back where I was when closed.
8. As a Markdown author, I want bare `:Leaf` to close the Viewer from
   anywhere (toggle semantics, matching `MarkdownPreviewToggle`), while
   `:Leaf path.md` with a Viewer open retargets it to that file.
9. As a Markdown author, I want `q`/`<Esc>` to close the static Viewer and
   leaf's own quit key to close the interactive one, so the UI is never
   trapping.
10. As a user on a non-Markdown buffer with nothing else to infer, I want
    `:Leaf` to open a file Picker so that I can choose a Markdown file to
    view.
11. As a user browsing Markdown files, I want a picker (fzf-lua) over the
    project root with a leaf-rendered preview pane, so that I can see
    content before opening.
12. As a user selecting a file in the Picker, I want it to open in a Viewer
    using my configured mode, so the picker is a launcher, not a dead end.
13. As a user without fzf-lua installed, I want the Viewer to keep working
    and the Picker to explain what's missing, so the plugin degrades
    gracefully.
14. As a user without the leaf binary, I want a notification naming the
    binary and linking its install page, and a `:checkhealth leaf` section,
    so I can fix my environment quickly.
15. As a user with a nonstandard leaf install, I want a `leaf_path` option,
    so I can point the plugin at a binary outside `$PATH`.
16. As a plugin author (future me), I want a small, pure decision module
    separating "what to open, how, and where" from window management, so the
    semantics are testable without a UI.
17. As a LazyVim user, I want to install via a normal lazy.nvim spec from
    GitHub, with `opts = {}` for configuration, so the plugin follows
    ecosystem conventions.
18. As a user browsing files in neo-tree, I want `:Leaf` with the cursor on
    a Markdown file to render that file in a new tab, and on anything else
    to say why not, so the explorer is a first-class launch surface.

## Implementation Decisions

- **Domain model** (see `CONTEXT.md`): *Viewer* on two axes — **Mode**
  (Static | Interactive) × **Placement** (Split | Float | Tab); *Picker* is
  the fzf-lua discovery surface; *Explorer* is the neo-tree panel whose
  cursor node can become a File Source.
- **Static Mode**: spawn `leaf --inline ansi:<width> <path>`, pipe stdout
  into `nvim_open_term` in a scratch buffer (glow.nvim's mechanism,
  verified against its source). Read-only; `q`/`<Esc>` close.
- **Interactive Mode**: `termopen("leaf --watch <path>")` in the window's
  buffer. Keys pass to the TUI; leaf's quit ends the job and the plugin
  wipes the window. A `<C-\>` terminal-map force-closes.
- **Placement rule** (`position = "auto"`, default): a Buffer Source
  renders in a Split right of the invoking window (`split_ratio = 0.5`); a
  File Source (explicit path, explorer node, picker selection) renders in
  a new Tab holding only the render — closing the Viewer wipes the tabpage
  and returns focus to the previously active tab. Float (centered,
  `width_ratio`/`height_ratio` 0.7, rounded border) is opt-in only:
  `position = "float"`, and `"split"`/`"tab"` force their placement for
  any source. Rationale: a file render has no source window to sit beside,
  and a transient fullscreen render behaves like opening the file itself
  in a new tab (`:tabedit`), which is the muscle memory explorer users
  already have.
- **Source semantics**: Static renders *buffer content* when targeting the
  current buffer (dump lines to a temp `.md`; unsaved edits included) and
  the *file on disk* for file sources. Interactive always uses the on-disk
  file with `--watch`; a never-saved buffer errors in Interactive Mode.
  Both refresh on `:w`: Static re-renders via a `BufWritePost` pattern on
  the source's absolute path — any buffer writing that file retriggers the
  render, even one loaded after the Viewer opened (buffer-local only for
  never-saved buffers); Interactive relies on leaf's own watcher.
  Rationale: ADR-0001.
- **`:Leaf[!] [file?]`** — bang flips the configured default Mode. Source
  precedence: explicit arg → focused Markdown buffer → neo-tree node under
  the cursor (non-Markdown file or directory → `not_markdown` error) →
  Picker fallback (error if fzf-lua is absent).
  Bare `:Leaf` toggles an open Viewer closed from anywhere; an explicit
  arg retargets an open Viewer instead of closing it.
- **Module seams** (new, deliberately few):
  - *resolve*: pure function from invocation context (args, bang, buffer
    filetype/dirty/on-disk state, explorer node, config) to a Viewer
    request `{ mode, placement, source }` or a typed failure
    (`missing_binary`, `need_saved_file`, `not_a_file`, `not_markdown`).
    THE test seam.
  - *explorer*: neo-tree probe — resolves the node under the cursor in a
    focused filesystem panel to `{ path, is_dir }` for the resolve seam;
    `nil` when focus is elsewhere, so resolve stays pure.
  - *config*: defaults + `setup()` merge + validation; `executable()`
    resolution of `leaf_path` (option → `$PATH`).
  - *viewer*: window/job lifecycle for Static and Interactive across all
    three placements (including tabpage create/teardown with focus return);
    owns the live-reload autocmd.
  - *picker*: file discovery over the project root (`LazyVim.root()` with
    cwd fallback; Markdown extension filter; `leaf --inline` preview pane;
    selection opens the Viewer). Single backend: fzf-lua, probed lazily at
    open time.
  - *health*: `:checkhealth leaf` — binary presence/version, picker plugin
    availability.
- **Configuration surface**: `leaf_path`, `interactive = false`,
  `position = "auto" | "split" | "float" | "tab"`, `theme`,
  `border = "rounded"`, `width_ratio`, `height_ratio`, `split_ratio = 0.5`.
- **Dependencies**: zero hard plugin dependencies. fzf-lua and neo-tree
  are `pcall`-ed at their entry points; the user declares whichever they
  actually use.
- **Distribution**: standard lazy.nvim plugin layout, Neovim ≥ 0.10,
  LazyVim-first (no Vim support), Apache-2.0 license kept from repo init.

## Testing Decisions

- **Good test definition**: external behavior only — given an invocation
  context and config, the decision result; never window geometry internals,
  buffer handles, or job plumbing.
- **Tested modules**: *resolve* (mode bang-flip, auto placement rule,
  buffer-content vs. on-disk source selection, every typed failure) and
  *config* (merge/defaults, executable resolution and missing-binary
  reporting shape). Both are pure or near-pure by construction.
- **Why not the viewer/picker**: window and job lifecycle is verified by a
  scripted headless smoke run against the real leaf binary, not unit tests —
  asserting on terminal escape output tests leaf's renderer, not ours.
- **Prior art**: none — greenfield repo. Harness follows the ecosystem norm:
  plenary.nvim busted-style specs run via `nvim --headless`, same shape as
  glow.nvim's `tests/` and typical LazyVim plugin suites.

## Out of Scope

- Auto-downloading/installing the leaf binary (Q5 decision: notify +
  health check only; leaf has its own `--update`).
- leaf's history (`--history`), shell completions, config management
  (`--config`), shelling into leaf's own `--picker` TUI.
- In-Viewer editing — editing is Neovim's job (ADR-0001).
- Vim (non-Neovim) support; Windows-specific QA.
- CI, release automation, lazy-lock pinning, LuaLS type annotation
  completeness.
- Fixing `markdown-preview.nvim` — it gets disabled in user config.

## Further Notes

- Development happens against a local checkout referenced by `dir =` in the
  user's LazyVim spec; the spec flips to the GitHub URL after first push.
- The user's personal mappings live in their dotfiles config, not in the
  plugin: `<leader>cp` (ft=markdown) → `:Leaf`, and
  `markdown-preview.nvim` gets `enabled = false`.
