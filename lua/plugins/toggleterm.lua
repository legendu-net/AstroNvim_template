-- Use fish for the interactive terminal (`<Leader>t*`) while `vim.opt.shell` is
-- kept off fish for plugin and `:!` shell-outs (see `astrocore.lua`).
-- Leaving `shell` unset when fish is missing lets toggleterm apply its own
-- `vim.o.shell` default, which it resolves after astrocore has set options.

---@type LazySpec
return {
  "akinsho/toggleterm.nvim",
  opts = { shell = vim.fn.executable "fish" == 1 and "fish" or nil },
}
