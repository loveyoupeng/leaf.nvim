-- Test harness bootstrap: repo + plenary on the runtimepath.
local repo = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand("<sfile>:p")), ":h:h")
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
