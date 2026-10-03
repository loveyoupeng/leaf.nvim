---:checkhealth leaf

local config = require("leaf.config")

local M = {}

function M.check()
  vim.health.start("leaf.nvim")

  local binary = config.executable()
  if binary then
    vim.health.ok("leaf binary: " .. binary)
    local version = vim.fn.system({ binary, "--version" }):gsub("%s+$", "")
    if vim.v.shell_error == 0 and version ~= "" then
      vim.health.info("version: " .. version)
    end
  else
    vim.health.error(
      "leaf binary not found (looked in `leaf_path` and $PATH)",
      { "Install from https://github.com/RivoLink/leaf", "Or set `leaf_path` in setup()" }
    )
  end

  local has_telescope = pcall(require, "telescope")
  local has_fzf = pcall(require, "fzf-lua")
  if has_telescope or has_fzf then
    vim.health.ok("picker backend: " .. (has_telescope and "telescope.nvim" or "fzf-lua") .. " — Picker enabled")
  else
    vim.health.warn("no picker backend found: Picker disabled", {
      "Install nvim-telescope/telescope.nvim or ibhagwan/fzf-lua for the Picker and the non-Markdown :Leaf fallback",
    })
  end
end

return M
