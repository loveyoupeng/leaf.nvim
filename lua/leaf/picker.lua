---Picker: Markdown under the project root with a leaf-rendered preview pane;
---selection opens the Viewer. Backend is whichever picker plugin the user
---actually has: telescope if available, fzf-lua otherwise. Both are loaded
---lazily, here only — the Viewer itself needs neither.

local config = require("leaf.config")

local M = {}

---@return "telescope"|"fzf"?
local function backend()
  if pcall(require, "telescope") then
    return "telescope"
  end
  if pcall(require, "fzf-lua") then
    return "fzf"
  end
  return nil
end

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
local function telescope_open(binary)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values

  local cwd = root()
  pickers
    .new({}, {
      prompt_title = "Markdown files (leaf)",
      cwd = cwd,
      finder = finders.new_oneshot_job(find_cmd(cwd), { cwd = cwd }),
      sorter = conf.file_sorter({}),
      previewer = previewers.new_termopen_previewer({
        title = "leaf",
        get_command = function(entry)
          return { binary, "--inline", "ansi", entry.path }
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and entry.path then
            require("leaf").open_path(entry.path)
          end
        end)
        return true
      end,
    })
    :find()
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
  local which = backend()
  if not which then
    return vim.notify(
      "leaf.nvim: the Picker needs nvim-telescope/telescope.nvim or ibhagwan/fzf-lua"
        .. " (or pass a file instead: :Leaf path.md)",
      vim.log.levels.ERROR
    )
  end
  local binary = checked_binary()
  if not binary then
    return
  end
  if which == "telescope" then
    telescope_open(binary)
  else
    fzf_open(binary)
  end
end

return M
