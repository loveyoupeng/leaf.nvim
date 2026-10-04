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

---:Leaf entry point. File targets (explicit arg, explorer node) are
---jump-or-open: the render buffer is created once per file and refocused,
---never duplicated and never killed by opening another file. A bare :Leaf
---closes the Viewer shown in the focused window, or the one rendering the
---focused buffer (the classic source toggle); otherwise it opens.
---@param opts { fargs?: string[], bang?: boolean }?
function M.toggle(opts)
  local ctx = context(opts)
  -- jump-or-open for file targets
  local want ---@type string?
  if ctx.arg and ctx.arg ~= "" then
    want = ctx.arg
  elseif ctx.explorer and not ctx.explorer.is_dir and config.is_markdown_ext(ctx.explorer.path) then
    want = ctx.explorer.path
  end
  if want then
    local hit = viewer.find_by_path(want)
    if hit then
      viewer.focus(hit)
      return
    end
    dispatch(resolve.decide(ctx))
    return
  end
  -- bare: close the selected render, else open
  local st = viewer.at_window(vim.api.nvim_get_current_win())
  if not st then
    st = viewer.find_by_source(vim.api.nvim_get_current_buf())
  end
  if st then
    viewer.close(st)
    return
  end
  dispatch(resolve.decide(ctx))
end

---Open the Viewer for an explicit path (Picker launch path).
---File Source: placement follows `position`, Window under "auto".
---@param path string
function M.open_path(path)
  dispatch(resolve.decide(context({ fargs = { path } })))
end

---@param win? integer Limit to the viewer shown in this window; nil = any
---@return boolean
function M.is_open(win)
  return viewer.is_open(win)
end

function M.close()
  viewer.close()
end

return M
