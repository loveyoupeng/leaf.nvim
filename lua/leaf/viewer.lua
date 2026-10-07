---Viewer lifecycle: windows (Window/Split/Float/Tab), jobs (Static/
---Interactive), live re-render on save. Each Viewer is a listed
---`leaf://<file>` buffer (the "buffer tab"); Viewers coexist and a Viewer
---is closed only via its own close path (q/<Esc> on the render, :bd of its
---buffer, :Leaf toggle from its source) — never by opening another file.
---
---Static frames are never repainted in place: an nvim_open_term channel owns
---cursor state that a buffer wipe corrupts, so every render swaps a fresh
---terminal buffer into the Viewer's window and disposes of the old one.

local config = require("leaf.config")

local M = {}

---@class leaf.ViewerState
---@field buf integer Frame buffer id (registry key)
---@field job? integer Running job id (static render or interactive TUI)
---@field chan? integer nvim_open_term channel (static mode)
---@field request leaf.Request What is being shown and how
---@field tmpfile? string Temp file holding unsaved buffer content
---@field augroup integer Autocmds owned by this Viewer
---@field wipe_au? integer Close-on-wipe autocmd for the current frame buffer
---@field width integer Last render width (window may be hidden on reload)
---@field prev_buf? integer Buffer displaced by a Window take-over, restored on close
---@field tabpage? integer Owning tabpage — set for Tab placement only
---@field home_win integer Window the frame was opened into (non-window placements own it)
---@field shown_once? boolean Frame has entered a window at least once (Window placement)
---@field pending_wins table<integer, boolean>? Windows born showing the Explorer (Window placement)

---@type table<integer, leaf.ViewerState> Viewers by frame buffer id
local viewers = {}

-- forward declarations (mutually recursive lifecycle functions)
local close_state, apply_hint, target_window

---Window the frame should go to: wherever it's displayed; else the owning
---window for owned placements; else the take-over home until first shown
---(after which a hidden frame STAYS hidden until :Leaf jumps to it).
---@return integer winid or -1
local function display_win(st)
  local win = vim.fn.bufwinid(st.buf)
  if win ~= -1 then
    return win
  end
  if st.request.placement ~= "window" then
    if vim.api.nvim_win_is_valid(st.home_win) then
      return st.home_win
    end
    return -1
  end
  if not st.shown_once and vim.api.nvim_win_is_valid(st.home_win) then
    return st.home_win
  end
  return -1
end

---@param win? integer Limit to the viewer shown in this window; nil = any
---@return boolean
function M.is_open(win)
  if win then
    return vim.api.nvim_win_is_valid(win) and viewers[vim.api.nvim_win_get_buf(win)] ~= nil
  end
  return next(viewers) ~= nil
end

---Viewer currently displayed in this window, if any.
---@param win integer
---@return leaf.ViewerState?
function M.at_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return viewers[vim.api.nvim_win_get_buf(win)]
end

---Viewer rendering the file at this absolute path — jump-or-open support.
---@param path string
---@return leaf.ViewerState?
function M.find_by_path(path)
  local want = vim.fn.fnamemodify(path, ":p")
  for _, st in pairs(viewers) do
    local src = st.request.source.path
    if src and vim.fn.fnamemodify(src, ":p") == want then
      return st
    end
  end
end

---Viewer rendering this source buffer — the classic "toggle off from the
---source buffer" case for buffer-source previews.
---@param bufnr integer
---@return leaf.ViewerState?
function M.find_by_source(bufnr)
  for _, st in pairs(viewers) do
    if st.request.source.bufnr == bufnr then
      return st
    end
  end
end

---Jump to a Viewer: its owning tabpage/window when displayed, else surface
---its frame in the current content window (analogous to :buffer).
---@param st leaf.ViewerState
function M.focus(st)
  if st.tabpage and vim.api.nvim_tabpage_is_valid(st.tabpage) then
    vim.api.nvim_set_current_tabpage(st.tabpage)
    local win = vim.fn.bufwinid(st.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
    return
  end
  local win = vim.fn.bufwinid(st.buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    return
  end
  if st.request.placement == "window" then
    -- hidden frame: surface it in the render/content window (never a panel)
    local target = target_window()
    vim.api.nvim_win_set_buf(target, st.buf)
    vim.api.nvim_set_current_win(target)
    apply_hint(st)
    return
  end
  -- owned window is gone (split/float closed by hand): retire the viewer
  close_state(st)
end

---@param st leaf.ViewerState
local function stop_job(st)
  if st.job then
    pcall(vim.fn.jobstop, st.job)
    st.job = nil
  end
end

---@param st leaf.ViewerState
local function cleanup_autocmds(st)
  if st.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, st.augroup)
    st.augroup = nil
  end
end

---@param st leaf.ViewerState
local function cleanup_tmpfile(st)
  if st.tmpfile then
    pcall(vim.fn.delete, st.tmpfile)
    st.tmpfile = nil
  end
end

---Close exactly this Viewer. Window placement restores the displaced buffer
---when the frame is on display; other placements retire their window/tab.
---@param st leaf.ViewerState
close_state = function(st)
  stop_job(st)
  cleanup_autocmds(st)
  cleanup_tmpfile(st)
  viewers[st.buf] = nil
  local placement = st.request.placement
  if placement == "tab" then
    if st.tabpage and vim.api.nvim_tabpage_is_valid(st.tabpage) then
      local back ---@type integer?
      if vim.api.nvim_get_current_tabpage() == st.tabpage then
        local nr = vim.fn.tabpagenr("#")
        if nr > 0 then
          back = nr
        end
      end
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(st.tabpage))
      if back then
        pcall(vim.cmd, "tabnext " .. math.min(back, vim.fn.tabpagenr("$")))
      end
    end
  elseif placement == "window" then
    local win = vim.fn.bufwinid(st.buf)
    if win ~= -1 and st.prev_buf and vim.api.nvim_buf_is_valid(st.prev_buf) then
      -- swap the displaced buffer back into the showing window
      pcall(vim.api.nvim_win_set_buf, win, st.prev_buf)
    end
  else
    -- split/float own their window: retired with the viewer
    local win = vim.fn.bufwinid(st.buf)
    if win == -1 and vim.api.nvim_win_is_valid(st.home_win) then
      win = st.home_win
    end
    if win ~= -1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if vim.api.nvim_buf_is_valid(st.buf) then
    pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
  end
end

---Close a Viewer: by state, or the one shown in the given (default:
---current) window.
---@param x? integer|leaf.ViewerState window id or viewer state
function M.close(x)
  local st ---@type leaf.ViewerState?
  if type(x) == "table" then
    st = x
  else
    st = M.at_window(x or vim.api.nvim_get_current_win())
  end
  if st and viewers[st.buf] == st then
    close_state(st)
  end
end

---Close from a mapping/autocmd; safe when already closed.
local function close_mapping(st)
  vim.schedule(function()
    if viewers[st.buf] == st then
      close_state(st)
    end
  end)
end

---Float geometry from the configured ratios.
---@return table win_opts
local function float_opts()
  local win_height = math.ceil(vim.o.lines * config.options.height_ratio) - 2
  local win_width = math.ceil(vim.o.columns * config.options.width_ratio)
  return {
    style = "minimal",
    relative = "editor",
    width = win_width,
    height = win_height,
    row = math.ceil((vim.o.lines - win_height) / 2 - 1),
    col = math.ceil((vim.o.columns - win_width) / 2),
    border = config.options.border,
  }
end

---The window a Window take-over occupies: where a normal :edit would land.
---Only a content window (normal buffer) is eligible — never a sidebar or
---panel, whose manager (neo-tree, edgy) would fight the take-over by
---rebalancing into a new window. From a panel, fall back to the previously
---visited content window, then any content window in the tab, then the
---window already showing a render (the de-facto content area — the render
---being replaced stays alive as a listed buffer). Never a panel.
---@return integer win
target_window = function()
  local cur = vim.api.nvim_get_current_win()
  local function is_content(win)
    return vim.api.nvim_win_is_valid(win) and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
  end
  if is_content(cur) then
    return cur
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and prev ~= cur and is_content(prev) then
    return prev
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= cur and is_content(w) then
      return w
    end
  end
  if viewers[cur] then
    return cur
  end
  -- no content window anywhere: reuse a window showing a render
  for buf in pairs(viewers) do
    local w = vim.fn.bufwinid(buf)
    if w ~= -1 then
      return w
    end
  end
  -- Truly degenerate (only panels): take the current one; better a usable
  -- render than an error.
  return cur
end

---@param placement "split"|"float"|"tab"|"window"
---@return integer win
local function open_window(placement)
  if placement == "window" then
    local win = target_window()
    vim.api.nvim_set_current_win(win)
    return win
  end
  if placement == "split" then
    local source_win = vim.api.nvim_get_current_win()
    local source_width = vim.api.nvim_win_get_width(source_win)
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(win, math.ceil(source_width * config.options.split_ratio))
    return win
  end
  if placement == "tab" then
    -- Like |:edit| into a fresh tabpage: one normal window, render only.
    vim.cmd("tabnew")
    local win = vim.api.nvim_get_current_win()
    vim.bo[vim.api.nvim_win_get_buf(win)].bufhidden = "wipe"
    return win
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, float_opts())
  vim.bo[buf].bufhidden = "wipe"
  return win
end

---Key hints on the window displaying the frame; reapplied when a hidden
---frame resurfaces.
---@param st leaf.ViewerState
apply_hint = function(st)
  if not config.options.show_hints then
    return
  end
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 then
    return
  end
  if st.request.mode == "interactive" then
    vim.wo[win].winbar = " leaf · wheel scrolls · <C-\\><C-n> your keys · <leader>bd close "
  else
    vim.wo[win].winbar = " leaf · <leader>bd close · j/k · <C-d>/<C-u> · wheel scroll "
  end
end

---Close-on-wipe for a frame buffer: user-driven :bwipe kills the Viewer;
---frame swaps delete the autocmd first so it stays silent there.
local function bind_wipe(st, buf)
  st.wipe_au = vim.api.nvim_create_autocmd("BufWipeout", {
    group = st.augroup,
    buffer = buf,
    once = true,
    callback = function()
      close_mapping(st)
    end,
  })
end

---Swap a fresh scratch buffer into the Viewer's window. The caller attaches
---the terminal surface (open_term for Static, termopen for Interactive) —
---termopen refuses a buffer open_term already touched.
---@return integer buf
local function fresh_frame(st)
  local old = st.buf
  if st.wipe_au then
    pcall(vim.api.nvim_del_autocmd, st.wipe_au)
    st.wipe_au = nil
  end
  viewers[old] = nil
  -- Listed, named frame: the render shows as a normal buffer tab, same as
  -- any opened file.
  local buf = vim.api.nvim_create_buf(true, true)
  local win = display_win(st)
  if win ~= -1 then
    vim.api.nvim_win_set_buf(win, buf)
    st.shown_once = true
  end
  -- delete AFTER the new frame is in place (and registry re-keyed)
  if old and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  st.buf = buf
  viewers[buf] = st
  local src = st.request.source.path
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    "leaf://" .. (src and vim.fn.fnamemodify(src, ":t") or ("buffer-" .. tostring(st.request.source.bufnr)))
  )
  vim.bo[buf].filetype = "leaf"
  -- No buffer-local keys: the render is a normal listed buffer, closed with
  -- the user's own tooling (<leader>bd / :bd / bufferline); the BufWipeout
  -- watch in bind_wipe is what cleans the Viewer up.
  bind_wipe(st, buf)
  return buf
end

local function attach_term_channel(st, buf)
  st.chan = vim.api.nvim_open_term(buf, {})
end

---Path leaf should render: the temp file for unsaved buffer content,
---otherwise the on-disk path.
---@return string
local function render_path(st)
  local request = st.request
  if request.source.kind == "buffer" then
    if not st.tmpfile then
      st.tmpfile = vim.fn.tempname() .. ".md"
    end
    vim.fn.writefile(vim.api.nvim_buf_get_lines(request.source.bufnr, 0, -1, false), st.tmpfile)
    return st.tmpfile
  end
  return request.source.path
end

---@return string[] cmd
local function inline_cmd(st, width)
  local cmd = { config.executable(), "--inline", "ansi:" .. tostring(width) }
  if config.options.theme then
    vim.list_extend(cmd, { "--theme", config.options.theme })
  end
  table.insert(cmd, render_path(st))
  return cmd
end

---One static frame: materialize the source, swap a fresh terminal buffer
---in, pipe `leaf --inline` output into it.
local function render_static(st)
  if viewers[st.buf] ~= st then
    return
  end
  stop_job(st)
  local buf = fresh_frame(st)
  attach_term_channel(st, buf)
  local win = display_win(st)
  if win ~= -1 then
    st.width = vim.api.nvim_win_get_width(win)
  end
  st.job = vim.fn.jobstart(inline_cmd(st, st.width), {
    on_stdout = function(_, data)
      if viewers[st.buf] ~= st or not st.chan or not data then
        return
      end
      local out = table.concat(data, "\r\n")
      if out ~= "" then
        vim.api.nvim_chan_send(st.chan, out)
      end
    end,
  })
end

local function setup_live_reload(st)
  local request = st.request
  local autocmd_opts = {
    group = st.augroup,
    callback = function()
      vim.schedule(function()
        if viewers[st.buf] == st then
          render_static(st)
        end
      end)
    end,
  }
  if request.source.path then
    -- Path pattern, not buffer-local: any buffer writing this file (even
    -- one loaded later, e.g. :e on a path the Explorer rendered) retriggers
    -- the render. Unnamed buffer sources have no path — buffer-local only.
    autocmd_opts.pattern = vim.fn.fnamemodify(request.source.path, ":p")
  else
    autocmd_opts.buffer = request.source.bufnr
  end
  vim.api.nvim_create_autocmd("BufWritePost", autocmd_opts)

  -- Source buffer wiped closes the Viewer with it.
  if request.source.kind == "buffer" then
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      group = st.augroup,
      buffer = request.source.bufnr,
      callback = function()
        close_mapping(st)
      end,
    })
  end
end

---Static Mode: pipe `leaf --inline` output into terminal frame buffers.
local function attach_static(st)
  setup_live_reload(st)
  render_static(st)
end

---Interactive Mode: run the leaf TUI in the window.
local function attach_interactive(st)
  local buf = fresh_frame(st)
  local cmd = { config.executable(), "--watch" }
  if config.options.theme then
    vim.list_extend(cmd, { "--theme", config.options.theme })
  end
  table.insert(cmd, st.request.source.path)
  st.chan = nil -- interactive owns the terminal itself
  vim.api.nvim_buf_call(buf, function()
    st.job = vim.fn.termopen(cmd, {
      on_exit = function()
        close_mapping(st)
      end,
    })
  end)
  -- No <C-\> mapping: overriding it would kill the native <C-\><C-n>
  -- terminal-mode escape, trapping the user's keys inside the TUI.
  -- Neovim does not forward wheel events to mouse-capturing terminal jobs;
  -- forward them ourselves as arrow keys (the TUI's line scroll). Arrows
  -- over j/k so they stay harmless if a leaf popup/search has key focus.
  local function forward_wheel(down)
    if viewers[st.buf] ~= st or not st.job then
      return
    end
    local seq = string.rep(down and "\x1b[B" or "\x1b[A", math.max(1, config.options.scroll_lines))
    pcall(vim.fn.chansend, st.job, seq)
  end
  vim.keymap.set("t", "<ScrollWheelDown>", function()
    forward_wheel(true)
  end, { buffer = buf, desc = "Scroll leaf viewer down" })
  vim.keymap.set("t", "<ScrollWheelUp>", function()
    forward_wheel(false)
  end, { buffer = buf, desc = "Scroll leaf viewer up" })
  vim.cmd("startinsert")
end

---Explorer-fold for Window placement: explorers won't :edit into a terminal
---window, so opening a file while a Window Viewer sits in the content
---window forces them into a split. Fold it back: the file takes the
---window, the spare split closes, layout untouched. WinNew arms (a window
---born showing the sidebar; BufWinEnter never fires for the duplicated
---sidebar buffer), BufWinEnter(file) folds.
local function setup_fold(st)
  st.pending_wins = {}
  vim.api.nvim_create_autocmd("WinNew", {
    group = st.augroup,
    callback = function()
      if viewers[st.buf] ~= st then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
        st.pending_wins[win] = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = st.augroup,
    callback = function(ev)
      if viewers[st.buf] ~= st then
        return
      end
      -- Capture at event time: :edit chains queue several of these before
      -- the event loop drains, changing focus at each step.
      local win = vim.api.nvim_get_current_win()
      local buf = ev.buf
      if st.pending_wins[win] then
        st.pending_wins[win] = nil
        local host = display_win(st)
        if host ~= -1 and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" and buf ~= st.buf then
          vim.schedule(function()
            if viewers[st.buf] ~= st then
              return
            end
            close_state(st)
            pcall(vim.api.nvim_win_set_buf, host, buf)
            if vim.api.nvim_win_is_valid(win) then
              pcall(vim.api.nvim_win_close, win, true)
            end
            pcall(vim.api.nvim_set_current_win, host)
          end)
        end
      end
    end,
  })
end

---@param request leaf.Request
function M.open(request)
  local win = open_window(request.placement)
  -- Window placement: the window still shows the buffer being displaced
  -- (fresh_frame swaps it out next); remember it for restore-on-close.
  -- If that buffer is a live frame, its Viewer survives hidden (listed
  -- buffer — jump back with :Leaf on its file).
  local prev_buf = request.placement == "window" and vim.api.nvim_win_get_buf(win) or nil
  -- Placeholder owns the registry until the first fresh_frame re-keys.
  local placeholder = vim.api.nvim_create_buf(true, true)
  local st = {
    buf = placeholder,
    request = request,
    augroup = vim.api.nvim_create_augroup("LeafViewer" .. tostring(placeholder), { clear = true }),
    width = vim.api.nvim_win_get_width(win),
    prev_buf = prev_buf,
    tabpage = request.placement == "tab" and vim.api.nvim_get_current_tabpage() or nil,
    home_win = win,
  }
  viewers[placeholder] = st
  -- The placeholder is display-fodder only: drop it once a real frame is
  -- in the window, and never let it leak as an empty listed buffer.
  vim.bo[placeholder].bufhidden = "wipe"

  -- Owned-window went away (user :q on a split/float): retire the Viewer.
  -- Window placement deliberately has no WinClosed watch: the frame is a
  -- normal listed buffer; closing its window hides, not closes, it.
  if request.placement ~= "window" then
    vim.api.nvim_create_autocmd("WinClosed", {
      group = st.augroup,
      pattern = tostring(win),
      once = true,
      callback = function()
        vim.schedule(function()
          if viewers[st.buf] == st and not vim.api.nvim_win_is_valid(win) then
            close_state(st)
          end
        end)
      end,
    })
  else
    setup_fold(st)
  end

  if request.mode == "interactive" then
    attach_interactive(st)
  else
    attach_static(st)
    -- Static Split doesn't grab focus from the source in split placement:
    -- editing stays where the user was.
    if request.placement == "split" then
      vim.cmd("wincmd p")
    end
  end
  apply_hint(st)
end

return M
