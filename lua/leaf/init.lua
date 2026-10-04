---leaf.nvim public API: setup, command entry, and the Picker-facing open path.

local config = require("leaf.config")
local resolve = require("leaf.resolve")
local viewer = require("leaf.viewer")

local M = {}

---@param opts? leaf.SetupOpts
function M.setup(opts)
  config.setup(opts)
end

---Build the invocation context from the current editor state.
---@param opts { fargs?: string[], bang?: boolean }
---@return leaf.Context
local function context(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    arg = opts.fargs and opts.fargs[1] or nil,
    bang = opts.bang == true,
    bufnr = bufnr,
    ft = vim.bo.filetype,
    bufname = vim.api.nvim_buf_get_name(0),
    explorer = require("leaf.explorer").node(bufnr),
  }
end

---@param decision leaf.Decision
local function dispatch(decision)
  if decision.kind == "viewer" then
    viewer.open(decision.request)
  elseif decision.kind == "picker" then
    require("leaf.picker").open()
  else
    vim.notify(resolve.error_message(decision), vim.log.levels.ERROR)
  end
end

---:Leaf entry point. Toggle semantics are per window: bare :Leaf closes
---the Viewer hosted by the focused window, if any. An explicit file arg
---always means "show this": a Viewer in the focused window is closed and
---retargeted; Viewers in other windows stay open.
---@param opts { fargs?: string[], bang?: boolean }?
function M.toggle(opts)
  local ctx = context(opts)
  local cur = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_get_current_buf()
  -- Close priority: the focused window's Viewer, else the Viewer showing
  -- the focused buffer (the classic "toggle off from the source" case).
  -- Other Viewers are never affected.
  local target = viewer.is_open(cur) and cur or viewer.find_by_source(cur_buf)
  if target then
    viewer.close(target)
    if not ctx.arg or ctx.arg == "" then
      return
    end
  end
  dispatch(resolve.decide(ctx))
end

---Open the Viewer for an explicit path (Picker launch path).
---File Source: placement follows `position`, Window under "auto".
---@param path string
function M.open_path(path)
  dispatch(resolve.decide(context({ fargs = { path } })))
end

---@return boolean
function M.is_open()
  return viewer.is_open()
end

function M.close()
  viewer.close()
end

return M
