---Picker: Markdown under the project root with a leaf-rendered preview pane;
---selection opens the Viewer. fzf-lua only, loaded lazily here — the Viewer
---itself needs no picker plugin.

local config = require("leaf.config")

local M = {}

---Listing root: the current working directory, as the user sees it —
---project-root detection lists files relative to somewhere else, which
---reads as "my Markdown files are missing".
---@return string
local function root()
  return vim.fn.getcwd()
end

---All Markdown files under dir, relative paths. Pure Lua: ripgrep is an
---optional user tool, and "list my Markdown files" does not deserve a
---spawned shell + gitignore semantics.
---@param dir string
---@return string[]
local function find_files(dir)
  local exts = {}
  for _, ext in ipairs(config.options.markdown_extensions) do
    exts[ext:lower()] = true
  end
  local out = {}
  for name, ftype in vim.fs.dir(dir, { depth = math.huge }) do
    if ftype == "file" then
      local ext = name:match("%.([^.%/]+)$")
      if ext and exts[ext:lower()] then
        out[#out + 1] = name
      end
    end
  end
  table.sort(out)
  return out
end

---@return string? binary
local function checked_binary()
  local binary = config.executable()
  if not binary then
    vim.notify(
      "leaf.nvim: `leaf` binary not found. Install it from https://github.com/RivoLink/leaf",
      vim.log.levels.ERROR
    )
    return nil
  end
  return binary
end

---@param binary string
local function fzf_open(binary)
  local fzf = require("fzf-lua")
  local cwd = root()
  -- fzf_exec takes an entry table directly; entries are cwd-relative.
  fzf.fzf_exec(find_files(cwd), {
    prompt = "Markdown (leaf)> ",
    cwd = cwd,
    preview = binary .. " --inline ansi {1}",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] and selected[1] ~= "" then
          require("leaf").open_path(vim.fs.joinpath(cwd, selected[1]))
        end
      end,
    },
  })
end

function M.open()
  if not pcall(require, "fzf-lua") then
    return vim.notify(
      "leaf.nvim: the Picker needs ibhagwan/fzf-lua" .. " (or pass a file instead: :Leaf path.md)",
      vim.log.levels.ERROR
    )
  end
  local binary = checked_binary()
  if not binary then
    return
  end
  fzf_open(binary)
end

return M
