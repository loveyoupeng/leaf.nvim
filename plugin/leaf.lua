if vim.g.loaded_leaf then
  return
end
vim.g.loaded_leaf = true

vim.api.nvim_create_user_command("Leaf", function(cmd)
  require("leaf").toggle({ fargs = cmd.fargs, bang = cmd.bang })
end, {
  nargs = "?",
  bang = true,
  complete = "file",
  desc = "Toggle the leaf Markdown viewer (:Leaf! for interactive mode)",
})
