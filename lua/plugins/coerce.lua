return {
  "gregorias/coerce.nvim",
  dependencies = { "gregorias/coop.nvim" }, -- Required dependency
  event = "User AstroFile", -- Lazy load on file open
  config = function()
    require("coerce").setup {
      -- AstroNvim uses Which-Key; coerce.nvim integrates with it automatically
      -- to show you the available case transformations when you press 'cr'
      default_mode_mask = {
        normal_mode = true, -- Enables 'cr' (change result)
        visual_mode = true, -- Enables 'gcr' in visual mode
      },
    }
  end,
}
