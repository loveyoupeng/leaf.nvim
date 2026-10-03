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
  return {
    arg = opts.fargs and opts.fargs[1] or nil,
    bang = opts.bang == true,
    bufnr = vim.api.nvim_get_current_buf(),
    ft = vim.bo.filetype,
    bufname = vim.api.nvim_buf_get_name(0),
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

---:Leaf entry point. Toggle semantics: an open Viewer closes regardless of args.
---@param opts { fargs?: string[], bang?: boolean }?
function M.toggle(opts)
  if viewer.is_open() then
    viewer.close()
    return
  end
  dispatch(resolve.decide(context(opts)))
end

---Open the Viewer for an explicit path (Picker launch path).
---Always a Float in the configured default Mode: no source window exists.
---@param path string
function M.open_path(path)
  if viewer.is_open() then
    viewer.close()
  end
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
