-- End-to-end smoke: real leaf binary, real buffer, real :Leaf flow.
-- Run: nvim --headless -l tests/smoke.lua   (from the repo root)
local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(script, ":h:h")
vim.opt.runtimepath:prepend(repo)
vim.cmd("filetype on")

local leaf = require("leaf")
leaf.setup({})

local function viewer_lines()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "leaf" then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  return {}
end

local function viewer_has(text)
  local ok = vim.wait(4000, function()
    for _, line in ipairs(viewer_lines()) do
      if line:find(text, 1, true) then
        return true
      end
    end
    return false
  end, 50)
  return ok
end

local function fail(msg)
  io.stderr:write("SMOKE FAIL: " .. msg .. "\n")
  vim.cmd("cquit 1")
end

-- 1. Static Viewer on the current Markdown buffer (auto → split placement).
local src = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Smoke Title", "", "body text with **bold**" }, src)
vim.cmd("edit " .. vim.fn.fnameescape(src))

-- 1b. Unsaved change must appear without writing first.
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved draft words" })
leaf.toggle({})
if not leaf.is_open() then
  fail("viewer did not open")
end
if #vim.api.nvim_list_wins() ~= 2 then
  fail("expected split placement (2 windows), got " .. #vim.api.nvim_list_wins())
end
if not viewer_has("Smoke Title") then
  fail("static render never showed 'Smoke Title'; viewer lines: " .. vim.inspect(viewer_lines()))
end
if not viewer_has("unsaved draft words") then
  fail("unsaved buffer content missing from the Viewer")
end

-- 2. Live re-render on save (static, buffer source).
vim.api.nvim_set_current_line("changed on save")
vim.cmd("write")
if not viewer_has("changed on save") then
  fail("viewer did not refresh after :write; lines: " .. vim.inspect(viewer_lines()))
end

-- 3. q in the static Viewer closes it.
local viewer_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "leaf" then
    viewer_win = win
  end
end
vim.api.nvim_set_current_win(viewer_win)
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(500, function()
  return not leaf.is_open()
end, 50)
if leaf.is_open() then
  fail("q did not close the static viewer")
end

-- 3b. Toggle opens, toggle closes.
leaf.toggle({})
if not leaf.is_open() then
  fail("viewer did not reopen on toggle")
end
leaf.toggle({})
if leaf.is_open() then
  fail("viewer did not close on toggle")
end

-- 4. Explicit path to another file → float placement.
vim.fn.writefile({ "# Second File" }, vim.fn.tempname() .. ".md")
local other = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Second File" }, other)
leaf.toggle({ fargs = { other } })
if not leaf.is_open() then
  fail("viewer did not open for explicit path")
end
if not viewer_has("Second File") then
  fail("float render never showed 'Second File'")
end
leaf.close()

-- 6. Interactive Mode: opens on the saved file, closes cleanly via API.
leaf.toggle({ fargs = {}, bang = true })
vim.wait(1500, function()
  return false
end, 100) -- let the TUI job settle headlessly regardless of outcome
leaf.close()
if leaf.is_open() then
  fail("interactive viewer did not close")
end

-- 7. Interactive Mode on a never-saved buffer errors with guidance.
vim.cmd("enew")
vim.bo.filetype = "markdown"
local notified
local old_notify = vim.notify
vim.notify = function(msg, level)
  notified = { msg = msg, level = level }
end
leaf.toggle({ bang = true })
vim.notify = old_notify
if not notified or not notified.msg:find("saved file", 1, true) then
  fail("interactive unsaved-buffer error not delivered: " .. vim.inspect(notified))
end
vim.cmd("bwipeout!")

-- 8. Missing binary → error notification, no crash.
require("leaf.config").setup({ leaf_path = "/nonexistent/leaf" })
local notified2
vim.notify = function(msg, level)
  notified2 = { msg = msg, level = level }
end
leaf.toggle({ fargs = { other } })
vim.notify = old_notify
if not notified2 or not notified2.msg:find("RivoLink/leaf", 1, true) then
  fail("missing binary notification not delivered: " .. vim.inspect(notified2))
end

vim.fn.delete(src)
print("SMOKE OK")
vim.cmd("quitall!")
