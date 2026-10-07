-- End-to-end smoke: real leaf binary, real buffer, real :Leaf flow.
-- Run: nvim --headless -l tests/smoke.lua   (from the repo root)
local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(script, ":h:h")
vim.opt.runtimepath:prepend(repo)
vim.cmd("filetype on")
vim.o.mouse = "a" -- wheel events become <ScrollWheel*> keys only when mouse is on

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
-- Static arrives via :Leaf! — the default mode embeds the TUI.
local src = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Smoke Title", "", "body text with **bold**" }, src)
vim.cmd("edit " .. vim.fn.fnameescape(src))

-- 1b. Unsaved change must appear without writing first.
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved draft words" })
leaf.toggle({ bang = true })
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

-- 1c. Static viewer carries a scroll-hint winbar.
local hint_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "leaf" then
    hint_win = win
  end
end
if not vim.wo[hint_win].winbar:find("close", 1, true) then
  fail("static viewer shows no hint winbar: " .. vim.inspect(vim.wo[hint_win].winbar))
end
-- no plugin-owned close keys: closing belongs to the user's own tooling
if vim.fn.maparg("q", "n", false, true).buffer == 1 then
  fail("static viewer must not shadow q")
end

-- 2. Live re-render on save (static, buffer source).
vim.api.nvim_set_current_line("changed on save")
vim.cmd("write")
if not viewer_has("changed on save") then
  fail("viewer did not refresh after :write; lines: " .. vim.inspect(viewer_lines()))
end

-- 3. Deleting the frame buffer (the LazyVim close path: :bd, <leader>bd,
-- bufferline) closes just this Viewer and restores the window.
local viewer_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "leaf" then
    viewer_win = win
  end
end
local frame = vim.api.nvim_win_get_buf(viewer_win)
vim.api.nvim_buf_delete(frame, { force = true })
vim.wait(500, function()
  return not leaf.is_open()
end, 50)
if leaf.is_open() then
  fail("deleting the frame buffer did not close the static viewer")
end
if vim.api.nvim_win_is_valid(viewer_win) then
  -- split placement: the window is retired with the viewer
  fail("split window lingered after frame deletion")
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

-- 4. Explicit path to another file → Window placement: the render takes
-- over the invoking window like a normal :edit; geometry untouched.
local other = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Second File" }, other)
local wins_before = #vim.api.nvim_list_wins()
local tabs_before = #vim.api.nvim_list_tabpages()
local host_win = vim.api.nvim_get_current_win()
local host_buf = vim.api.nvim_win_get_buf(host_win)
leaf.toggle({ fargs = { other } })
if not leaf.is_open() then
  fail("viewer did not open for explicit path")
end
if #vim.api.nvim_list_wins() ~= wins_before then
  fail("window placement changed the window count: " .. #vim.api.nvim_list_wins())
end
if #vim.api.nvim_list_tabpages() ~= tabs_before then
  fail("window placement created a tabpage")
end
if vim.api.nvim_get_current_win() ~= host_win then
  fail("window placement did not stay in the invoking window")
end
if vim.bo[vim.api.nvim_win_get_buf(host_win)].filetype ~= "leaf" then
  fail("window placement did not take over the invoking window")
end
local frame_buf = vim.api.nvim_win_get_buf(host_win)
if not vim.bo[frame_buf].buflisted then
  fail("render frame is not a listed buffer")
end
if not vim.api.nvim_buf_get_name(frame_buf):find("^leaf://") then
  fail("render frame has no leaf:// name: " .. vim.api.nvim_buf_get_name(frame_buf))
end
if not viewer_has("Second File") then
  fail("render never showed 'Second File'")
end

-- 4a. Live re-render when ANOTHER buffer writes the rendered file
-- (BufWritePost pattern on the path, not buffer-local).
vim.cmd("vsplit")
vim.cmd("edit " .. vim.fn.fnameescape(other))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Rewritten Elsewhere" })
vim.cmd("write")
vim.cmd("close")
vim.api.nvim_set_current_win(host_win)
if not viewer_has("Rewritten Elsewhere") then
  fail("file-source viewer did not follow an external write; lines: " .. vim.inspect(viewer_lines()))
end

-- 4b. One render per file: a different file opens its OWN leaf:// buffer in
-- the same window; the first render survives hidden, never overridden.
local function leaf_buffers()
  local n = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b):find("^leaf://") then
      n = n + 1
    end
  end
  return n
end
local third = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Third File" }, third)
leaf.toggle({ fargs = { third } })
if not viewer_has("Third File") then
  fail("second file never rendered: " .. vim.inspect(viewer_lines()))
end
if leaf_buffers() ~= 2 then
  fail("expected two live leaf:// buffers, got " .. leaf_buffers())
end
if #vim.api.nvim_list_wins() ~= wins_before then
  fail("second render changed the window count")
end

-- 4c. Opening an already-open file jumps to its render — no duplicate, no
-- close, no count changes.
leaf.toggle({ fargs = { other } })
if leaf_buffers() ~= 2 then
  fail("jump created a duplicate render: " .. leaf_buffers())
end
if vim.bo[vim.api.nvim_win_get_buf(host_win)].filetype ~= "leaf" then
  fail("jump did not bring the render into view")
end
if not viewer_has("Rewritten Elsewhere") then
  fail("jumped render lost its content; lines: " .. vim.inspect(viewer_lines()))
end

-- 4d. Close on the jumped-back render restores the displaced buffer; the
-- hidden third render is untouched. Then close it via jump + close.
leaf.close()
if leaf.is_open(host_win) then
  fail("close did not close the shown viewer")
end
if vim.api.nvim_win_get_buf(host_win) ~= host_buf then
  fail("close did not restore the displaced buffer")
end
if leaf_buffers() ~= 1 then
  fail("close killed the hidden render too: " .. leaf_buffers())
end
leaf.toggle({ fargs = { third } }) -- jump back to the third file's render
if not leaf.is_open(host_win) then
  fail("jump-back did not resurface the hidden render")
end
leaf.close()
if leaf.is_open() then
  fail("third render did not close")
end
if #vim.api.nvim_list_wins() ~= wins_before then
  fail("window count drifted across the cycle")
end
vim.fn.delete(third)

-- 4e. A window born *showing the sidebar* (WinNew) that then receives a
-- real file folds back into the taken-over window: explorers refuse
-- terminal windows and route around them with a split. Mirrors the traced
-- neo-tree+edgy event sequence: fake sidebar stays open, its split folds.
leaf.toggle({ fargs = { other } })
if not vim.wait(4000, function()
  return leaf.is_open()
end, 50) then
  fail("viewer did not reopen for fold test")
end
vim.cmd("vsplit")
local side_win = vim.api.nvim_get_current_win()
local fake_sidebar = vim.api.nvim_create_buf(false, true)
vim.bo[fake_sidebar].filetype = "neo-tree"
vim.api.nvim_win_set_buf(side_win, fake_sidebar)
vim.api.nvim_set_current_win(side_win)
vim.cmd("vsplit") -- born showing the sidebar buffer, like neo-tree's route
local routed_win = vim.api.nvim_get_current_win()
local fourth = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Folded File" }, fourth)
vim.cmd("edit " .. vim.fn.fnameescape(fourth))
if not vim.wait(3000, function()
  return not leaf.is_open()
end, 50) then
  fail("explorer split was not folded into the viewer window")
end
if vim.api.nvim_win_is_valid(routed_win) then
  fail("fold left the spare split behind")
end
if
  vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(host_win)), ":p")
  ~= vim.fn.fnamemodify(fourth, ":p")
then
  fail("folded file is not in the taken-over window")
end
vim.api.nvim_win_close(side_win, true) -- tear down the fake sidebar
if #vim.api.nvim_list_wins() ~= wins_before then
  fail("fold changed the window count")
end
vim.cmd("bwipeout! " .. vim.fn.fnameescape(fourth))
vim.fn.delete(fourth)

-- 4f. Multiple Viewers coexist; closing affects only the focused one.
local function leaf_windows()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "leaf" then
      n = n + 1
    end
  end
  return n
end
leaf.toggle({ fargs = { other } })
if not vim.wait(4000, function()
  return leaf.is_open()
end, 50) then
  fail("first viewer did not open for coexistence test")
end
vim.cmd("vsplit")
local second_win = vim.api.nvim_get_current_win()
-- the vsplit briefly duplicates the frame; move this window to the source
vim.cmd("buffer " .. host_buf)
local fifth = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Fifth Wheel" }, fifth)
leaf.toggle({ fargs = { fifth } })
if not vim.wait(4000, function()
  return leaf_windows() == 2
end, 50) then
  fail("expected two concurrent viewers, got " .. leaf_windows())
end
leaf.close() -- closes the viewer in the focused (second) window only
if leaf_windows() ~= 1 then
  fail("closing the focused viewer closed others too: " .. leaf_windows())
end
vim.api.nvim_win_close(second_win, true)
if #vim.api.nvim_list_wins() ~= wins_before then
  fail("coexistence test changed the window count")
end
vim.fn.delete(fifth)
-- toggle from the source buffer still closes the remaining split-time viewer
-- (none here — single leftover is the host viewer): close it for step 6.
vim.api.nvim_set_current_win(host_win)
leaf.close()
if leaf.is_open() then
  fail("post-coexistence close failed")
end

-- 4g. Second explorer-driven open reuses the render window: once the
-- content window hosts a terminal frame, "no content window" must fall
-- back to the render window — never the sidebar (edgy rebalances a taken
-- panel into a stray split; user-reported bug).
leaf.toggle({ fargs = { other } })
if not vim.wait(4000, function()
  return leaf.is_open()
end, 50) then
  fail("viewer did not reopen for panel-target test")
end
vim.cmd("vsplit")
local side_win2 = vim.api.nvim_get_current_win()
local fake_sidebar2 = vim.api.nvim_create_buf(false, true)
vim.bo[fake_sidebar2].filetype = "neo-tree"
vim.api.nvim_win_set_buf(side_win2, fake_sidebar2)
vim.api.nvim_set_current_win(side_win2)
local sixth = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# Sixth File" }, sixth)
local wins_pre = #vim.api.nvim_list_wins()
leaf.toggle({ fargs = { sixth } })
if not viewer_has("Sixth File") then
  fail("second explorer open never rendered")
end
if #vim.api.nvim_list_wins() ~= wins_pre then
  fail("second explorer open created a window: " .. wins_pre .. " -> " .. #vim.api.nvim_list_wins())
end
if vim.bo[vim.api.nvim_win_get_buf(side_win2)].filetype ~= "neo-tree" then
  fail("the sidebar window was taken over")
end
if vim.bo[vim.api.nvim_win_get_buf(host_win)].filetype ~= "leaf" then
  fail("the render did not reuse the render window")
end
vim.api.nvim_win_close(side_win2, true)
leaf.close()
leaf.toggle({ fargs = { other } })
leaf.close()
if leaf.is_open() then
  fail("post-4g close failed")
end
vim.fn.delete(sixth)

-- 6. Interactive Mode: hint winbar, wheel forwarded as scroll keys, closes cleanly.
local big = vim.fn.tempname() .. ".md"
local big_lines = { "# Big Doc", "" }
for i = 1, 200 do
  table.insert(big_lines, ("body line %03d body"):format(i))
end
vim.fn.writefile(big_lines, big)
vim.cmd("edit " .. vim.fn.fnameescape(big))
leaf.toggle({ fargs = {} }) -- default mode = interactive TUI now
if not vim.wait(4000, function()
  return leaf.is_open()
end, 100) then
  fail("interactive viewer did not open")
end
local iwin = vim.api.nvim_get_current_win()
if vim.bo[vim.api.nvim_win_get_buf(iwin)].filetype ~= "leaf" then
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "leaf" then
      iwin = win
    end
  end
end
vim.api.nvim_set_current_win(iwin)
if not vim.wo[iwin].winbar:find("wheel scrolls", 1, true) then
  fail("interactive viewer shows no hint winbar: " .. vim.inspect(vim.wo[iwin].winbar))
end
if vim.fn.maparg("<C-\\>", "t", false, true).buffer == 1 then
  fail("interactive viewer must not shadow the native <C-\\><C-n> escape")
end
-- the render box keeps LazyVim-style window nav + buffer close in t-mode
if vim.fn.maparg("<C-h>", "t", false, true).buffer ~= 1 then
  fail("leaf frame lacks the <C-h> window-nav map")
end
if vim.fn.maparg("<leader>bd", "t", false, true).buffer ~= 1 then
  fail("leaf frame lacks the <leader>bd close map")
end
local function mu_has(text)
  for _, l in ipairs(viewer_lines()) do
    if l:find(text, 1, true) then
      return true
    end
  end
  return false
end
if not vim.wait(6000, function()
  return mu_has("body line 001 body")
end, 100) then
  fail("interactive TUI never painted the document")
end
-- The wheel binding exists on the frame buffer and its mechanism — arrow
-- keys into the job's pty — genuinely scrolls the TUI. (Headless feedkeys
-- cannot synthesize positioned mouse events; the two halves of the wheel
-- path are asserted instead of the keystroke itself.)
do
  local map = vim.fn.maparg("<ScrollWheelDown>", "t", false, true)
  if type(map) ~= "table" or map.buffer ~= 1 then
    fail("interactive viewer lacks the terminal-mode wheel binding")
  end
  local chan = vim.bo[vim.api.nvim_win_get_buf(iwin)].channel
  for _ = 1, 3 do
    vim.fn.chansend(chan, "\x1b[B")
  end
  if not vim.wait(6000, function()
    return not mu_has("body line 001 body")
  end, 100) then
    fail("arrow keys into the job did not scroll the TUI")
  end
  for _ = 1, 3 do
    vim.fn.chansend(chan, "\x1b[A")
  end
end
vim.wait(3000, function()
  return false
end, 100)
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
leaf.toggle({}) -- default mode is interactive: unnamed buffer must error
vim.notify = old_notify
if not notified or not notified.msg:find("saved file", 1, true) then
  fail("interactive unsaved-buffer error not delivered: " .. vim.inspect(notified))
end
vim.cmd("bwipeout!")
vim.cmd("bwipeout! " .. vim.fn.fnameescape(big))
vim.fn.delete(big)

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
