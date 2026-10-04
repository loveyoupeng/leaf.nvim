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

  if pcall(require, "fzf-lua") then
    vim.health.ok("picker plugin: fzf-lua — Picker enabled")
  else
    vim.health.warn("fzf-lua not found: Picker disabled", {
      "Install ibhagwan/fzf-lua for the Picker and the :Leaf fallback when nothing is inferable",
    })
  end
end

return M
