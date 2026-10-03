---Telescope extension registration: `:Telescope leaf`.
return require("telescope").register_extension({
  exports = {
    leaf = function()
      require("leaf.picker").open()
    end,
  },
})
