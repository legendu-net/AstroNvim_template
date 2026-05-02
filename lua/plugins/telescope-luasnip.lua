return {
  {
    "benfowler/telescope-luasnip.nvim",
    dependencies = { "nvim-telescope/telescope.nvim" },
    config = function() require("telescope").load_extension "luasnip" end,
    -- Add a keybinding to open it
    keys = {
      { "<leader>fS", "<cmd>Telescope luasnip<cr>", desc = "Find snippets" },
    },
  },
}
