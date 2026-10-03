---Plugin configuration: defaults, merge, validation, leaf binary resolution.

local M = {}

---@class leaf.Config
---@field leaf_path? string Path/executable name of the leaf binary; nil = search $PATH
---@field interactive boolean Default Mode: interactive TUI instead of static render
---@field position "auto"|"split"|"float" Viewer placement
---@field theme? string Leaf theme passed via --theme
---@field border string Float border style
---@field width_ratio number Float width as a ratio of the editor
---@field height_ratio number Float height as a ratio of the editor
---@field split_ratio number Split width as a ratio of the source window
---@field markdown_filetypes string[] Filetypes treated as Markdown
---@field markdown_extensions string[] File extensions treated as Markdown

---@class leaf.SetupOpts
---@field leaf_path? string
---@field interactive? boolean
---@field position? "auto"|"split"|"float"
---@field theme? string
---@field border? string
---@field width_ratio? number
---@field height_ratio? number
---@field split_ratio? number
---@field markdown_filetypes? string[]
---@field markdown_extensions? string[]

---@type leaf.Config
M.defaults = {
  leaf_path = nil,
  interactive = false,
  position = "auto",
  theme = nil,
  border = "rounded",
  width_ratio = 0.7,
  height_ratio = 0.7,
  split_ratio = 0.5,
  markdown_filetypes = {
    "markdown",
    "markdown.pandoc",
    "markdown.gfm",
    "vimwiki",
    "telekasten",
  },
  markdown_extensions = {
    "md",
    "markdown",
    "mkd",
    "mkdn",
    "mdwn",
    "mdown",
    "mdtxt",
    "mdtext",
    "rmd",
    "wiki",
  },
}

---@type leaf.Config
M.options = vim.deepcopy(M.defaults)

---Valid placements; anything else falls back to "auto" with a warning.
local positions = { auto = true, split = true, float = true }

---@param opts? leaf.SetupOpts
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if not positions[M.options.position] then
    vim.notify(
      string.format("leaf.nvim: invalid position %q, falling back to 'auto'", M.options.position),
      vim.log.levels.WARN
    )
    M.options.position = "auto"
  end
end

---Resolve the leaf binary: explicit option first, then $PATH.
---@return string? path Executable path, or nil when not runnable
function M.executable()
  local path = M.options.leaf_path
  if path and path ~= "" then
    return vim.fn.executable(path) == 1 and path or nil
  end
  local found = vim.fn.exepath("leaf")
  return found ~= "" and found or nil
end

---@param ft string
---@return boolean
function M.is_markdown_ft(ft)
  return vim.tbl_contains(M.options.markdown_filetypes, ft)
end

---@param path string
---@return boolean
function M.is_markdown_ext(path)
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  return vim.tbl_contains(M.options.markdown_extensions, ext)
end

return M
