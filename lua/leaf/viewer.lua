---Viewer lifecycle: windows (Window/Split/Float/Tab), jobs (Static/
---Interactive), live re-render on save. One Viewer per window; closing is
---scoped to the focused window's Viewer.
---
---Static frames are never repainted in place: an nvim_open_term channel owns
---cursor state that a buffer wipe corrupts, so every render swaps a fresh
---terminal buffer into the Viewer's window and disposes of the old one.

local config = require("leaf.config")

local M = {}

---@class leaf.ViewerState
---@field win integer Window showing the render
---@field buf integer Current terminal buffer inside the window
---@field job? integer Running job id (static render or interactive TUI)
---@field chan? integer nvim_open_term channel (static mode)
---@field request leaf.Request What is being shown and how
---@field tmpfile? string Temp file holding unsaved buffer content
---@field augroup integer Autocmds owned by this Viewer
---@field wipe_au? integer Close-on-wipe autocmd for the current frame buffer
---@field tabpage? integer Owning tabpage — set for Tab placement only
---@field prev_buf? integer Buffer displaced by a Window take-over, restored on close
---@field leave_au? integer Close-on-swap autocmd for the current frame (Window placement)
---@field known_wins table<integer, boolean>? Windows existing at open (Window placement)
---@field pending_wins table<integer, boolean>? Windows born showing the Explorer (Window placement)

---@type table<integer, leaf.ViewerState> Viewers by host window id
local viewers = {}

---@param win? integer Limit to the viewer hosted by this window
---@return boolean
function M.is_open(win)
  if win then
    local st = viewers[win]
    return st ~= nil and vim.api.nvim_win_is_valid(st.win)
  end
  for _, st in pairs(viewers) do
    if vim.api.nvim_win_is_valid(st.win) then
      return true
    end
  end
  return false
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

---Close one Viewer. Window placement normally restores the displaced
---buffer; pass keep_buf when a new buffer (explorer-opened file) is taking
---the seat instead.
---@param st leaf.ViewerState
---@param keep_buf? integer Buffer to leave in the host window (fold path)
local function close_state(st, keep_buf)
  local win, buf, tabpage = st.win, st.buf, st.tabpage
  stop_job(st)
  cleanup_autocmds(st)
  cleanup_tmpfile(st)
  if st.request.placement == "window" then
    -- Take-over placement: the window stays, geometry untouched.
    local swap = keep_buf or st.prev_buf
    if vim.api.nvim_win_is_valid(win) and swap and vim.api.nvim_buf_is_valid(swap) then
      pcall(vim.api.nvim_win_set_buf, win, swap)
    end
  elseif tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
    -- Tab placement: closing the Viewer closes its tabpage. Jump back to
    -- the last-visited tab, but only when focus is still inside the
    -- Viewer tab — from elsewhere the user's focus must not move.
    local back ---@type integer?
    if vim.api.nvim_get_current_tabpage() == tabpage then
      local nr = vim.fn.tabpagenr("#")
      if nr > 0 then
        back = nr
      end
    end
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tabpage))
    if back then
      pcall(vim.cmd, "tabnext " .. math.min(back, vim.fn.tabpagenr("$")))
    end
  elseif vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  viewers[st.win] = nil
end

---Close the Viewer hosted by the given (default: current) window.
---@param win? integer
function M.close(win)
  win = win or vim.api.nvim_get_current_win()
  local st = viewers[win]
  if st then
    close_state(st)
  end
end

---Window hosting the Viewer rendering this source buffer, if any — lets a
---bare :Leaf typed in the *source* buffer close its adjacent render.
---@param bufnr integer
---@return integer? win
function M.find_by_source(bufnr)
  for win, st in pairs(viewers) do
    if st.request.source.bufnr == bufnr and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
end

---Close from a mapping/autocmd; safe when already closed.
---@param st leaf.ViewerState
local function close_mapping(st)
  vim.schedule(function()
    if viewers[st.win] == st then
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
---visited content window, then any content window in the tab.
---@return integer win
local function target_window()
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
  -- Degenerate layout (no content window at all): take the current one.
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
    -- tabnew's empty placeholder is swapped out by fresh_frame(); don't
    -- let it linger as a hidden buffer.
    vim.bo[vim.api.nvim_win_get_buf(win)].bufhidden = "wipe"
    return win
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, float_opts())
  -- The float's placeholder buffer is replaced by fresh frame buffers;
  -- don't let it linger as a hidden buffer after a swap.
  vim.bo[buf].bufhidden = "wipe"
  return win
end

---Close-on-wipe for a frame buffer: user-driven :bwipe kills the Viewer;
---frame swaps delete the autocmd first so it stays silent there.
---@param st leaf.ViewerState
---@param buf integer
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

---Window placement only: the user swapping the taken-over window to another
---buffer (:b …) counts as closing the Viewer. The check runs scheduled
---against the viewer's OWN window — a frame duplicated into another window
---(:vsplit) leaving that window must not kill the render. Static frame
---swaps delete the autocmd first, so live re-render stays silent.
---@param st leaf.ViewerState
---@param buf integer
local function bind_leave(st, buf)
  st.leave_au = vim.api.nvim_create_autocmd("BufWinLeave", {
    group = st.augroup,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if viewers[st.win] ~= st then
          return
        end
        if vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_get_buf(st.win) ~= buf then
          close_state(st)
        end
      end)
    end,
  })
end

---Swap a fresh scratch buffer into the Viewer's window. The caller attaches
---the terminal surface (open_term for Static, termopen for Interactive) —
---termopen refuses a buffer open_term already touched.
---@param st leaf.ViewerState
---@return integer buf
local function fresh_frame(st)
  local old = st.buf
  if st.wipe_au then
    pcall(vim.api.nvim_del_autocmd, st.wipe_au)
    st.wipe_au = nil
  end
  if st.leave_au then
    pcall(vim.api.nvim_del_autocmd, st.leave_au)
    st.leave_au = nil
  end
  -- Listed, named frame: the render shows as a normal buffer tab, same as
  -- any opened file.
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(st.win, buf)
  if old and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  st.buf = buf
  local src = st.request.source.path
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    "leaf://" .. (src and vim.fn.fnamemodify(src, ":t") or ("buffer-" .. tostring(st.request.source.bufnr)))
  )
  vim.bo[buf].filetype = "leaf"
  local opts = { silent = true, buffer = buf }
  vim.keymap.set("n", "q", function()
    close_mapping(st)
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    close_mapping(st)
  end, opts)
  bind_wipe(st, buf)
  if st.request.placement == "window" then
    bind_leave(st, buf)
  end
  return buf
end

---@param st leaf.ViewerState
---@param buf integer
local function attach_term_channel(st, buf)
  st.chan = vim.api.nvim_open_term(buf, {})
end

---Path leaf should render: the temp file for unsaved buffer content,
---otherwise the on-disk path.
---@param st leaf.ViewerState
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
---@param st leaf.ViewerState
local function render_static(st)
  if not M.is_open(st.win) then
    return
  end
  stop_job(st)
  local buf = fresh_frame(st)
  attach_term_channel(st, buf)
  local width = vim.api.nvim_win_get_width(st.win)
  st.job = vim.fn.jobstart(inline_cmd(st, width), {
    on_stdout = function(_, data)
      if viewers[st.win] ~= st or not st.chan or not data then
        return
      end
      local out = table.concat(data, "\r\n")
      if out ~= "" then
        vim.api.nvim_chan_send(st.chan, out)
      end
    end,
  })
end

---@param st leaf.ViewerState
local function setup_live_reload(st)
  local request = st.request
  local autocmd_opts = {
    group = st.augroup,
    callback = function()
      vim.schedule(function()
        if viewers[st.win] == st then
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

  -- Source disappearing closes the Viewer.
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
---@param st leaf.ViewerState
local function attach_static(st)
  setup_live_reload(st)
  render_static(st)
end

---Key hints on the Viewer's winbar; the window persists across frame
---swaps, so this is set once per open.
---@param st leaf.ViewerState
local function apply_hint(st)
  if not config.options.show_hints then
    return
  end
  if st.request.mode == "interactive" then
    vim.wo[st.win].winbar = " leaf · wheel scrolls · <C-\\><C-n> your keys "
  else
    vim.wo[st.win].winbar = " leaf · q/<Esc> close · j/k · <C-d>/<C-u> scroll "
  end
end

---Interactive Mode: run the leaf TUI in the window.
---@param st leaf.ViewerState
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
    if viewers[st.win] ~= st or not st.job then
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

---@param request leaf.Request
function M.open(request)
  local win = open_window(request.placement)
  -- A viewer already hosted here is replaced (retarget).
  if viewers[win] then
    close_state(viewers[win])
  end
  -- Window placement: the window still shows the buffer being displaced
  -- (fresh_frame swaps it out next); remember it for restore-on-close.
  local prev_buf = request.placement == "window" and vim.api.nvim_win_get_buf(win) or nil
  local st = {
    win = win,
    buf = -1, -- set by fresh_frame()
    request = request,
    augroup = vim.api.nvim_create_augroup("LeafViewer" .. win, { clear = true }),
    tabpage = request.placement == "tab" and vim.api.nvim_get_current_tabpage() or nil,
    prev_buf = prev_buf,
  }
  viewers[win] = st
  -- User-closed window unloads the whole Viewer (job, autocmds, temp file).
  vim.api.nvim_create_autocmd("WinClosed", {
    group = st.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        local cur = viewers[st.win]
        if cur and not vim.api.nvim_win_is_valid(st.win) then
          close_state(cur)
        end
      end)
    end,
  })

  if request.placement == "window" then
    st.known_wins = {}
    st.pending_wins = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      st.known_wins[w] = true
    end
    -- Explorers won't :edit into a terminal window, so opening a file while
    -- a Window Viewer holds the content window forces them into a split.
    -- Fold that split back: the file takes the Viewer's seat, the spare
    -- window closes, layout untouched.
    -- WinNew arms: a window born showing the sidebar is the explorer
    -- routing around our terminal-hosting window (BufWinEnter does not
    -- fire for the sidebar's duplicated buffer, so WinNew is the tell).
    vim.api.nvim_create_autocmd("WinNew", {
      group = st.augroup,
      callback = function()
        if viewers[st.win] ~= st then
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
        if viewers[st.win] ~= st then
          return
        end
        -- Capture at event time: :edit chains queue several of these
        -- before the event loop drains, changing focus at each step.
        local win = vim.api.nvim_get_current_win()
        local buf = ev.buf
        if vim.bo[buf].filetype == "neo-tree" then
          st.pending_wins[win] = true
          return
        end
        if st.pending_wins[win] then
          st.pending_wins[win] = nil
          st.known_wins[win] = true
          local host = st.win
          local host_ok = vim.api.nvim_win_is_valid(host)
            and vim.bo[buf].buftype == ""
            and vim.api.nvim_buf_get_name(buf) ~= ""
          if host_ok then
            vim.schedule(function()
              if viewers[st.win] ~= st then
                return
              end
              close_state(st, buf)
              if vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim_win_close, win, true)
              end
              pcall(vim.api.nvim_set_current_win, host)
            end)
          end
          return
        end
        st.known_wins[win] = true
      end,
    })
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
