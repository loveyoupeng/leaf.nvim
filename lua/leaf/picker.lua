---Picker: Markdown under the project root with a leaf-rendered preview pane;
---selection opens the Viewer. fzf-lua only, loaded lazily here — the Viewer
---itself needs no picker plugin.

local config = require("leaf.config")

local M = {}

---Project root: LazyVim's root when available, else cwd.
---@return string
local function root()
  local ok, lazyvim_root = pcall(function()
    return require("lazyvim.util").root.get()
  end)
  if ok and type(lazyvim_root) == "string" and lazyvim_root ~= "" then
    return lazyvim_root
  end
  return vim.uv.cwd()
end

---ripgrep invocation over the configured Markdown extensions; absolute paths.
---@param dir string
---@return string[]
local function find_cmd(dir)
  local cmd = { "rg", "--files", "--color", "never", dir }
  for _, ext in ipairs(config.options.markdown_extensions) do
    table.insert(cmd, "--glob")
    table.insert(cmd, "*." .. ext)
  end
  return cmd
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
  fzf.fzf_exec(find_cmd(cwd), {
    prompt = "Markdown (leaf)> ",
    cwd = cwd,
    preview = binary .. " --inline ansi {1}",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] and selected[1] ~= "" then
          require("leaf").open_path(selected[1])
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
