---Viewer lifecycle: windows (Float/Split), jobs (Static/Interactive),
---live re-render on save. One Viewer exists at a time.
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

---@type leaf.ViewerState?
local state

---@return boolean
function M.is_open()
  return state ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function stop_job()
  if state and state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
end

local function cleanup_autocmds()
  if state and state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

local function cleanup_tmpfile()
  if state and state.tmpfile then
    pcall(vim.fn.delete, state.tmpfile)
    state.tmpfile = nil
  end
end

function M.close()
  if not state then
    return
  end
  local win, buf, tabpage = state.win, state.buf, state.tabpage
  local placement = state.request.placement
  local prev_buf = state.prev_buf
  stop_job()
  cleanup_autocmds()
  cleanup_tmpfile()
  if placement == "window" then
    -- Take-over placement: the window stays, geometry untouched. Put the
    -- displaced buffer back; if it is gone, deleting the frame below lets
    -- Nvim swap in an alternate.
    if vim.api.nvim_win_is_valid(win) and prev_buf and vim.api.nvim_buf_is_valid(prev_buf) then
      pcall(vim.api.nvim_win_set_buf, win, prev_buf)
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
  state = nil
end

---Close from a mapping/autocmd; safe when already closed.
local function close_mapping()
  vim.schedule(M.close)
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
---Current window, except when the invoking focus is a file-explorer sidebar
---(neo-tree) — then the previously visited window, the same target an
---explorer's own "open" uses.
---@return integer win
local function target_window()
  local cur = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(cur)].filetype ~= "neo-tree" then
    return cur
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and prev ~= cur and vim.api.nvim_win_is_valid(prev) then
    return prev
  end
  -- Degenerate layout (no usable previous window): take the sidebar itself.
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
---@param buf integer
local function bind_wipe(buf)
  state.wipe_au = vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.augroup,
    buffer = buf,
    once = true,
    callback = close_mapping,
  })
end

---Window placement only: the user swapping the taken-over window to another
---buffer (:b …) counts as closing the Viewer. Static frame swaps delete the
---autocmd first, so live re-render stays silent.
---@param buf integer
local function bind_leave(buf)
  state.leave_au = vim.api.nvim_create_autocmd("BufWinLeave", {
    group = state.augroup,
    buffer = buf,
    once = true,
    callback = close_mapping,
  })
end

---Swap a fresh scratch buffer into the Viewer's window. The caller attaches
---the terminal surface (open_term for Static, termopen for Interactive) —
---termopen refuses a buffer open_term already touched.
---@return integer buf
local function fresh_frame()
  local old = state.buf
  if state.wipe_au then
    pcall(vim.api.nvim_del_autocmd, state.wipe_au)
    state.wipe_au = nil
  end
  if state.leave_au then
    pcall(vim.api.nvim_del_autocmd, state.leave_au)
    state.leave_au = nil
  end
  -- Listed, named frame: the render shows as a normal buffer tab, same as
  -- any opened file.
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(state.win, buf)
  if old and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  state.buf = buf
  local src = state.request.source.path
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    "leaf://" .. (src and vim.fn.fnamemodify(src, ":t") or ("buffer-" .. tostring(state.request.source.bufnr)))
  )
  vim.bo[buf].filetype = "leaf"
  local opts = { silent = true, buffer = buf }
  vim.keymap.set("n", "q", close_mapping, opts)
  vim.keymap.set("n", "<Esc>", close_mapping, opts)
  bind_wipe(buf)
  if state.request.placement == "window" then
    bind_leave(buf)
  end
  return buf
end

---@param buf integer
local function attach_term_channel(buf)
  state.chan = vim.api.nvim_open_term(buf, {})
end

---Path leaf should render: the temp file for unsaved buffer content,
---otherwise the on-disk path.
---@param request leaf.Request
---@return string
local function render_path(request)
  if request.source.kind == "buffer" then
    if not state.tmpfile then
      state.tmpfile = vim.fn.tempname() .. ".md"
    end
    vim.fn.writefile(vim.api.nvim_buf_get_lines(request.source.bufnr, 0, -1, false), state.tmpfile)
    return state.tmpfile
  end
  return request.source.path
end

---@return string[] cmd
local function inline_cmd(request, width)
  local cmd = { config.executable(), "--inline", "ansi:" .. tostring(width) }
  if config.options.theme then
    vim.list_extend(cmd, { "--theme", config.options.theme })
  end
  table.insert(cmd, render_path(request))
  return cmd
end

---One static frame: materialize the source, swap a fresh terminal buffer
---in, pipe `leaf --inline` output into it.
local function render_static()
  if not state or not M.is_open() then
    return
  end
  local request = state.request
  stop_job()
  local buf = fresh_frame()
  attach_term_channel(buf)
  local width = vim.api.nvim_win_get_width(state.win)
  state.job = vim.fn.jobstart(inline_cmd(request, width), {
    on_stdout = function(_, data)
      if not state or state.buf ~= buf or not state.chan or not data then
        return
      end
      local out = table.concat(data, "\r\n")
      if out ~= "" then
        vim.api.nvim_chan_send(state.chan, out)
      end
    end,
  })
end

local function setup_live_reload(request)
  local autocmd_opts = {
    group = state.augroup,
    callback = function()
      vim.schedule(render_static)
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
      group = state.augroup,
      buffer = request.source.bufnr,
      callback = close_mapping,
    })
  end
end

---Static Mode: pipe `leaf --inline` output into terminal frame buffers.
---@param request leaf.Request
local function attach_static(request)
  setup_live_reload(request)
  render_static()
end

---Key hints on the Viewer's winbar; the window persists across frame
---swaps, so this is set once per open.
local function apply_hint()
  if not config.options.show_hints then
    return
  end
  if state.request.mode == "interactive" then
    vim.wo[state.win].winbar = " leaf · wheel scrolls · <C-\\><C-n> your keys "
  else
    vim.wo[state.win].winbar = " leaf · q/<Esc> close · j/k · <C-d>/<C-u> scroll "
  end
end

---Interactive Mode: run the leaf TUI in the window.
---@param request leaf.Request
local function attach_interactive(request)
  local buf = fresh_frame()
  local cmd = { config.executable(), "--watch" }
  if config.options.theme then
    vim.list_extend(cmd, { "--theme", config.options.theme })
  end
  table.insert(cmd, request.source.path)
  state.chan = nil -- interactive owns the terminal itself
  vim.api.nvim_buf_call(buf, function()
    state.job = vim.fn.termopen(cmd, {
      on_exit = function()
        close_mapping()
      end,
    })
  end)
  -- No <C-\> mapping: overriding it would kill the native <C-\><C-n>
  -- terminal-mode escape, trapping the user's keys inside the TUI.
  -- Neovim does not forward wheel events to mouse-capturing terminal jobs;
  -- forward them ourselves as arrow keys (the TUI's line scroll). Arrows
  -- over j/k so they stay harmless if a leaf popup/search has key focus.
  local function forward_wheel(down)
    if not state or not state.job then
      return
    end
    local seq = string.rep(down and "\x1b[B" or "\x1b[A", math.max(1, config.options.scroll_lines))
    pcall(vim.fn.chansend, state.job, seq)
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
  M.close()
  local augroup = vim.api.nvim_create_augroup("LeafViewer", { clear = true })
  local win = open_window(request.placement)
  -- Window placement: the window still shows the buffer being displaced
  -- (fresh_frame swaps it out next); remember it for restore-on-close.
  local prev_buf = request.placement == "window" and vim.api.nvim_win_get_buf(win) or nil
  state = {
    win = win,
    buf = -1, -- set by fresh_frame()
    request = request,
    augroup = augroup,
    tabpage = request.placement == "tab" and vim.api.nvim_get_current_tabpage() or nil,
    prev_buf = prev_buf,
  }
  -- User-closed window unloads the whole Viewer (job, autocmds, temp file).
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if not M.is_open() then
          M.close()
        end
      end)
    end,
  })

  if request.placement == "window" then
    state.known_wins = {}
    state.pending_wins = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      state.known_wins[w] = true
    end
    -- Explorers won't :edit into a terminal window, so opening a file while
    -- a Window Viewer holds the content window forces them into a split.
    -- Fold that split back: the file takes the Viewer's seat, the spare
    -- window closes, layout untouched.
    -- WinNew arms: a window born showing the sidebar is the explorer
    -- routing around our terminal-hosting window (BufWinEnter does not
    -- fire for the sidebar's duplicated buffer, so WinNew is the tell).
    vim.api.nvim_create_autocmd("WinNew", {
      group = state.augroup,
      callback = function()
        if not state or state.request.placement ~= "window" then
          return
        end
        local win = vim.api.nvim_get_current_win()
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
          state.pending_wins[win] = true
        end
      end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = state.augroup,
      callback = function(ev)
        if not state or state.request.placement ~= "window" then
          return
        end
        -- Capture at event time: :edit chains queue several of these
        -- before the event loop drains, changing focus at each step.
        local win = vim.api.nvim_get_current_win()
        local buf = ev.buf
        if state.pending_wins[win] then
          state.pending_wins[win] = nil
          state.known_wins[win] = true
          local host = state.win
          if vim.api.nvim_win_is_valid(host) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
            vim.schedule(function()
              if not state or state.request.placement ~= "window" then
                return
              end
              local frame = state.buf
              stop_job()
              cleanup_autocmds()
              cleanup_tmpfile()
              pcall(vim.api.nvim_win_set_buf, host, buf)
              if vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim_win_close, win, true)
              end
              if vim.api.nvim_buf_is_valid(frame) then
                pcall(vim.api.nvim_buf_delete, frame, { force = true })
              end
              state = nil
              pcall(vim.api.nvim_set_current_win, host)
            end)
          end
          return
        end
        state.known_wins[win] = true
      end,
    })
  end

  if request.mode == "interactive" then
    attach_interactive(request)
  else
    attach_static(request)
    -- Static Viewer doesn't grab focus from the source in split placement:
    -- editing stays where the user was.
    if request.placement == "split" then
      vim.cmd("wincmd p")
    end
  end
  apply_hint()
end

return M
