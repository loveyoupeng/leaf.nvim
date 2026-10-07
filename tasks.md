# leaf.nvim — Tasks

Tracker: this file (no external issue tracker configured). Tickets are
vertical slices in dependency order; each declares its blockers.
Status legend: `[ ]` todo · `[~]` in progress · `[x]` done

---

## 01: Core Viewer — config, resolve, static float, command, health

**Blocked by:** None (can start immediately)

**What to build:** Running `:Leaf` in a Markdown buffer opens a read-only
Static Viewer in a Float, rendered by the leaf binary (found via config or
`$PATH`). Running `:Leaf` again closes it. Missing binary produces a
notification naming `leaf`, pointing at https://github.com/RivoLink/leaf,
and is reported by `:checkhealth leaf`.

- [x] `:Leaf` on a Markdown buffer renders the file into a floating terminal buffer — smoke step 1 (split; step 4 float on explicit path)
- [x] `:Leaf` toggles: closes the Viewer if one is open — smoke step 3b
- [x] `q`/`<Esc>` close the static Viewer — smoke step 3
- [x] Missing binary → notify with install URL; `:checkhealth leaf` reports binary presence/version — smoke step 8; `lua/leaf/health.lua`
- [x] `leaf_path` config overrides `$PATH` lookup — config_spec executable resolution

## 02: Source semantics — unsaved buffer content and live re-render on save

**Blocked by:** 01 (needs the Static Viewer)

**What to build:** `:Leaf` previews the current buffer's content including
unsaved changes (temp file), and the Viewer refreshes automatically when the
source file is saved.

- [x] Dirty buffer content is rendered (unsaved lines visible in the Viewer) — smoke step 1b
- [x] `BufWritePost` on the source buffer re-renders the open Static Viewer — smoke step 2
- [x] Closing the source buffer or the Viewer cleans up the autocmd and temp files — BufDelete/BufWipeout + WinClosed autocmds in `viewer.lua`; teardown verified by smoke steps 3/3b rerun cycles

## 03: Placement — split beside source, float otherwise

**Blocked by:** 01 (window management base)

**What to build:** `position = "auto"` (default): when the focused buffer is
the Markdown being rendered, the Viewer opens as a vertical split to its
right (source left, render right, `split_ratio` width); otherwise it opens
as a Float. `position = "split"|"float"` forces a placement.

- [x] `:Leaf` on the focused Markdown buffer → vertical split, source left / render right — smoke step 1
- [x] `:Leaf <path>` or picker origin → Float — smoke step 4; resolve_spec "floats for an explicit path"
- [x] Forced `"split"`/`"float"` respected — resolve_spec forced-position cases

## 04: Interactive Mode — bang-flipped live TUI

**Blocked by:** 01, 02 (shares source resolution; toggle must own both modes)

**What to build:** `:Leaf!` (or `interactive = true` default) opens leaf's
TUI in the Viewer via `termopen`, watching the file so it re-renders when
Neovim saves it. Never-saved buffers get an instructive error.

- [x] Interactive Viewer runs leaf TUI with `--watch`; saving in Neovim refreshes it — `attach_interactive` termopens `leaf --watch`; lifecycle smoke step 6
- [x] leaf's own quit key closes the TUI and the plugin wipes the window — termopen `on_exit` → `close`
- [x] Force-close chord `<C-\>` closes the window (kills the job) — tnoremap in `attach_interactive`
- [x] Interactive Mode on a never-saved buffer → error telling the user to save first — smoke step 7 + resolve_spec need_saved_file

## 05: Picker — telescope/fzf-lua backends and non-Markdown fallback

**Blocked by:** 01 (opens the Viewer), independent of 02–04 otherwise

**What to build:** A Markdown file Picker over the project root
(`LazyVim.root()` → cwd fallback) with a leaf-rendered preview pane, on
whichever picker plugin is installed (telescope → `:Telescope leaf`
extension; fzf-lua → fzf native shell preview). Selecting a file opens it in
a Viewer using the configured default Mode. `:Leaf` with no argument on a
non-Markdown buffer opens the Picker; with neither plugin, that path errors
with a clear message.

- [x] Picker lists Markdown under project root (cwd fallback) with live leaf previews — fzf backend probe; telescope backend verified by construction (not installed in the dev env)
- [x] Selecting an entry opens the Viewer (default Mode, Float placement) — both backends call `open_path`, exercised by smoke step 4
- [x] `:Leaf` on a non-Markdown buffer launches the Picker — fallback probe
- [x] Missing picker backend → instructive error; core Viewer unaffected — `picker.open` guard; unit-level decision covered by resolve picker case

## 06: Tests, docs, packaging

**Blocked by:** 01–05

**What to build:** Plenary specs covering the pure decision layer (resolve:
mode bang-flip, placement rule, source selection, all failure variants;
config: merge/defaults/executable resolution), a headless smoke run
exercising the real `:Leaf` path end-to-end, README with lazy.nvim spec and
mapping snippets, and `:h leaf` vimdoc.

- [x] `nvim --headless` test run green for resolve + config specs — 23/23
- [x] Headless smoke: real binary, real buffer, Viewer opens and closes — tests/smoke.lua (also verified inside the full LazyVim profile)
- [x] README: install spec, options table, mappings; `doc/leaf.txt` vimdoc
- [x] Stylua clean; committed and pushed to origin/main — c19e27e

## 07: Inference chain and Tab placement — explorer source, retargeting toggle

**Blocked by:** 01–05

**What to build:** `:Leaf` infers its Source from more than the current
buffer: with focus in a neo-tree filesystem panel, the node under the
cursor becomes a File Source (Markdown extension); a non-Markdown file or
directory is a typed error, and only when nothing is inferable does the
Picker open. File Sources render in a new **Tab** placement (render-only
tabpage; closing the Viewer wipes the tab and returns focus) instead of a
Float, which is now opt-in via `position = "float"`. `:Leaf <path>` with a
Viewer open retargets instead of merely closing. Static live-reload keys
off the source path (`BufWritePost` pattern), not the owning buffer.

- [x] neo-tree probe resolves the cursor node; resolution precedence arg → markdown buffer → explorer node → picker — resolve_spec explorer inference block
- [x] Non-markdown/directory node → `not_markdown` error naming the path — resolve_spec + real-profile e2e probe
- [x] `auto` places File Sources in a new render-only Tab; `"tab"` accepted by config validation; Float opt-in — resolve_spec tab cases + config_spec
- [x] Closing a Tab Viewer wipes its tabpage and returns focus to the invoking tab — smoke steps 4/4c
- [x] `:Leaf <path>` while open retargets (close + reopen, no tab leak) — smoke step 4b
- [x] Static re-render fires when any buffer writes the source path — smoke step 4a
- [x] Verified against the real LazyVim profile with real neo-tree (headless e2e driver): probe, tab render, cross-tab toggle close, typed error
- [x] Picker cut down to fzf-lua only; the never-installable telescope backend and `:Telescope leaf` extension removed — picker.lua, health.lua, `lua/telescope/` deleted, docs updated
- [x] Docs: CONTEXT.md (Explorer term, Tab placement), SPEC.md, README.md, doc/leaf.txt

## 08: Scrolling — wheel forwarding into the TUI, key hints

**Blocked by:** 01, 04

**What to build:** make scrolling obvious and working in both Modes. Static
frames are terminal buffers with full scrollback — keys/wheel work natively,
no code needed beyond a hint. Neovim does not forward wheel events to
mouse-capturing terminal jobs (verified empirically: the event reaches
Nvim's input layer and dies), so the Interactive Viewer maps
`<ScrollWheelUp/Down>` in terminal mode and `chansend`s arrow keys — leaf's
line-scroll binding — `scroll_lines` (default 3) per notch. No CLI or
terminal-protocol dependency. Both modes get a one-line key hint in the
winbar (`show_hints`). Plan originally involved OSC cell-size queries,
kitty keyboard protocol, and `--scroll` in the leaf CLI — all dropped as
unneeded or undeliverable in this transport (evidence in commit history).

- [x] Wheel events forwarded into the interactive TUI as arrow-key scrolls — smoke step 6
- [x] Winbar key hints in both modes — smoke steps 1c/6; `show_hints` option, `scroll_lines` option
- [x] Docs: README, doc/leaf.txt, SPEC.md configuration surface + decisions

## 09: Window placement — file sources render like a normal :edit

**Blocked by:** 07 (supersedes its Tab default for file sources)

**What to build:** `position = "auto"` sends File Sources (explicit path,
explorer node, picker selection) to the **Window** placement instead of a
tabpage: the render takes over the content window like a normal `:edit`
(previous window when invoked from an explorer sidebar), leaving the
sidebar and all splits untouched; closing swaps the displaced buffer back
in; the user swapping that window to another buffer closes the Viewer.
`"tab"`/`"float"` remain opt-in values.

- [x] Take-over renders in the invoking/previous window; window and tab counts unchanged — smoke step 4
- [x] Live reload + retarget work under take-over — smoke steps 4a/4b
- [x] Close restores the displaced buffer into the same window — smoke step 4c
- [x] `:buffer` swap-away closes the Viewer (BufWinLeave) and survives static frame swaps — smoke step 4d + 4a
- [x] Verified against real LazyVim + neo-tree: no new tab, sidebar intact, sidebar-initiated toggle closes and restores — e2e driver
- [x] Docs: CONTEXT.md (Placement gains Window), SPEC.md, README.md, doc/leaf.txt

## 10: Render box behaves like a normal buffer — listed frames, explorer fold, no key shadowing

**Blocked by:** 09

**What to build:** three fixes from dogfooding. (a) Frames become listed,
named buffers (`leaf://<file>`) so a render appears as a normal buffer
tab. (b) `<cr>`-opening a file from the explorer while a Window Viewer is
showing no longer splits: explorers refuse terminal-hosting windows, so a
window born showing the sidebar (`WinNew`) that then receives a real file
(`BufWinEnter`) is folded — the file takes the Viewer's seat and the spare
split closes (event sequence verified by tracing real neo-tree+edgy).
(c) The interactive `<C-\>` force-close map is removed: it shadowed the
native `<C-\><C-n>` terminal escape and trapped all user keybindings.

- [x] Frames listed and named (`leaf://`) — smoke step 4
- [x] Explorer-forced split folds into the taken-over window, geometry intact — smoke step 4e + real-profile e2e (neo-tree event trace verified)
- [x] No terminal-mode mapping shadows `<C-\>`; native escape intact — code removal + smoke assertion
- [x] Docs: README, doc/leaf.txt, SPEC.md

## 11: Multi-viewer — one render per file, jump-or-open, panel-safe targeting

**Blocked by:** 09, 10

**What to build:** the Viewer stops being a singleton. Every render is a
live `leaf://<file>` listed buffer; `:Leaf x.md` is jump-or-open (focus
the existing render if the file is already open, else take over the
content window — previous renders survive as hidden buffer tabs). Bare
`:Leaf` closes the render shown in the focused window, or the one
rendering the focused buffer. Window take-over never targets a
sidebar/panel (buftype-guarded), so layout managers like edgy never see a
terminal inside their managed area.

- [x] Registry keyed by frame buffer; jump-or-open by absolute path; hidden renders survive — viewer.lua, smoke steps 4b–4d
- [x] Close scoped to the focused window's render; source-buffer toggle fallback — init.lua, smoke 4d/4f
- [x] Concurrent visible renders coexist; closing leaves the others — smoke step 4f
- [x] Take-over skips non-content windows (sidebar/panel guard) — viewer.target_window; real-profile e2e
- [x] Picker lists the *current working directory* with a pure-Lua walk (no ripgrep dependency — absent in the target env and silently yielded 0 entries) and fzf_exec fed an entry table (argv table became bogus pickable tokens) — e2e listing + selection open
- [x] Docs: README, doc/leaf.txt, SPEC.md (toggle/placement semantics)

## 12: No plugin keybindings — close via the user's own buffer tooling

**Blocked by:** 10

**What to build:** remove the buffer-local `q`/`<Esc>` close maps (they
shadow user/ LazyVim bindings). The render is a plain listed buffer:
closing goes through `BufWipeout` (`:bd`, `<leader>bd`, bufferline
pick-close), which the Viewer already watches. Winbar hints point at those
paths.

- [x] No `q`/`<Esc>` maps on frames; smoke guards `maparg("q")` stays unbound and drives close via `nvim_buf_delete` (the :bd path)
- [x] winbar hints reference `<leader>bd` close; `<C-\>` no-shadow guard stays
- [x] Docs: README, doc/leaf.txt, SPEC.md (story 9, Static/Interactive bullets)

## 13: Embedded-by-default — Interactive TUI for every open path, in-box window nav

**Blocked by:** 10, 12

**What to build:** `interactive = true` becomes the default Mode: every
`:Leaf` origin (arg, explorer cursor, picker, current buffer) embeds leaf's
full TUI (TOC sidebar, search, themes, `--watch`). `:Leaf!` flips to Static
— the escape hatch for unsaved buffer previews or the cheap one-shot. Leaf
frames gain terminal-mode `<C-h/j/k/l>` window jumps and `<leader>bd`
close (leaf's TUI binds none of them; navigation wins by design).

- [x] Default mode interactive; bang yields static; unnamed-preview static path still works via bang — config default; resolve_spec mode block inverted; smoke bang sites updated
- [x] t-mode nav/close maps on all frames, buffer-local — smoke step 6 guard maparg `<C-h>`/`<leader>bd`
- [x] Real-profile e2e: default `:Leaf <path>` embeds the TUI (headings painted incl. TOC content), maps present
- [x] Docs: CONTEXT.md (Mode default), SPEC.md (stories 5-6, config surface), README.md, doc/leaf.txt
