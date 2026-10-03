---Pure decision layer: maps an invocation context to a Viewer request,
---a Picker fallback, or a typed failure. No window/job side effects here.

local config = require("leaf.config")

local M = {}

---@class leaf.Context
---@field arg? string File argument given to :Leaf ("" treated as none)
---@field bang boolean Command bang, flips the configured default Mode
---@field bufnr integer Current buffer
---@field ft string Current buffer filetype
---@field bufname string Current buffer name ("" when unnamed)

---@class leaf.Source
---@field kind "buffer"|"file" buffer = render current buffer content; file = render path on disk
---@field bufnr? integer Owning buffer (live-reload anchor) — set for kind "buffer"
---@field path? string On-disk path — set for kind "file", and for "buffer" when the buffer is named

---@class leaf.Request
---@field mode "static"|"interactive"
---@field placement "split"|"float"
---@field source leaf.Source

---@class leaf.Decision
---@field kind "viewer"|"picker"|"error"
---@field request? leaf.Request
---@field err? "missing_binary"|"not_a_file"|"need_saved_file"
---@field err_path? string Offending path for not_a_file

local err = setmetatable({}, {
  __call = function(_, code, path)
    return { kind = "error", err = code, err_path = path }
  end,
})

---Absolute, normalized comparison of two paths.
---@param a string
---@param b string
---@return boolean
local function same_path(a, b)
  return vim.fn.fnamemodify(a, ":p") == vim.fn.fnamemodify(b, ":p")
end

---@param ctx leaf.Context
---@return leaf.Decision
function M.decide(ctx)
  if not config.executable() then
    return err("missing_binary")
  end

  local mode = ctx.bang ~= config.options.interactive and "interactive" or "static"
  -- bang XOR default: bang flips whatever the user configured
  local arg = ctx.arg
  if arg == "" then
    arg = nil
  end

  local source ---@type leaf.Source
  local from_current ---@type boolean

  if arg then
    local path = vim.fn.fnamemodify(arg, ":p")
    if vim.fn.filereadable(path) == 0 then
      return err("not_a_file", arg)
    end
    -- An explicit path naming the current buffer keeps buffer semantics:
    -- unsaved content renders in Static Mode, split placement applies.
    if ctx.bufname ~= "" and same_path(path, ctx.bufname) and config.is_markdown_ft(ctx.ft) then
      source = { kind = "buffer", bufnr = ctx.bufnr, path = ctx.bufname }
      from_current = true
    else
      source = { kind = "file", path = path }
      from_current = false
    end
  else
    if not config.is_markdown_ft(ctx.ft) then
      return { kind = "picker" }
    end
    source = { kind = "buffer", bufnr = ctx.bufnr }
    if ctx.bufname ~= "" then
      source.path = ctx.bufname
    end
    from_current = true
  end

  if mode == "interactive" and not source.path then
    -- Interactive Mode watches the on-disk file; unnamed buffers have none.
    return err("need_saved_file")
  end

  local position = config.options.position
  local placement = position
  if position == "auto" then
    placement = from_current and "split" or "float"
  end

  return {
    kind = "viewer",
    request = {
      mode = mode,
      placement = placement,
      source = source,
    },
  }
end

---Human-facing messages for typed failures.
---@param decision leaf.Decision
---@return string
function M.error_message(decision)
  if decision.err == "missing_binary" then
    return "leaf.nvim: `leaf` binary not found. Install it from https://github.com/RivoLink/leaf"
      .. " or set `leaf_path` in setup()."
  elseif decision.err == "not_a_file" then
    return string.format("leaf.nvim: no readable file at %s", decision.err_path)
  elseif decision.err == "need_saved_file" then
    return "leaf.nvim: interactive mode needs a saved file; write the buffer or use :Leaf (static)."
  end
  return "leaf.nvim: unknown error"
end

return M
