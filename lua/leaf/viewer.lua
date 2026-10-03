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
  local win, buf = state.win, state.buf
  stop_job()
  cleanup_autocmds()
  cleanup_tmpfile()
  if vim.api.nvim_win_is_valid(win) then
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

---@param placement "split"|"float"
---@return integer win
local function open_window(placement)
  if placement == "split" then
    local source_win = vim.api.nvim_get_current_win()
    local source_width = vim.api.nvim_win_get_width(source_win)
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(win, math.ceil(source_width * config.options.split_ratio))
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
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.win, buf)
  if old and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  state.buf = buf
  vim.bo[buf].filetype = "leaf"
  local opts = { silent = true, buffer = buf }
  vim.keymap.set("n", "q", close_mapping, opts)
  vim.keymap.set("n", "<Esc>", close_mapping, opts)
  bind_wipe(buf)
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
  if request.source.kind == "buffer" then
    autocmd_opts.buffer = request.source.bufnr
  else
    autocmd_opts.pattern = vim.fn.fnamemodify(request.source.path, ":p")
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
  -- Escape hatch when the TUI misbehaves.
  vim.keymap.set("t", "<C-\\>", close_mapping, { buffer = buf, desc = "Close leaf viewer" })
  vim.cmd("startinsert")
end

---@param request leaf.Request
function M.open(request)
  M.close()
  local augroup = vim.api.nvim_create_augroup("LeafViewer", { clear = true })
  local win = open_window(request.placement)
  state = {
    win = win,
    buf = -1, -- set by fresh_frame()
    request = request,
    augroup = augroup,
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
end

return M
