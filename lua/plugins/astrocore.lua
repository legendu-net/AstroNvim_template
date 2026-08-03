-- if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE

-- AstroCore provides a central place to modify mappings, vim options, autocommands, and more!
-- Configuration documentation can be found with `:h astrocore`
-- NOTE: We highly recommend setting up the Lua Language Server (`:LspInstall lua_ls`)
--       as this provides autocomplete and documentation while editing

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    -- Configure core features of AstroNvim
    features = {
      large_buf = { size = 1024 * 256, lines = 10000 }, -- set global limits for large files for disabling features like treesitter
      autopairs = true, -- enable autopairs at start
      cmp = true, -- enable completion at start
      diagnostics = { virtual_text = true, virtual_lines = false }, -- diagnostic settings on startup
      highlighturl = true, -- highlight URLs at start
      notifications = true, -- enable notifications at start
    },
    -- Diagnostics configuration (for vim.diagnostics.config({...})) when diagnostics are on
    diagnostics = {
      virtual_text = true,
      underline = true,
    },
    -- passed to `vim.filetype.add`
    filetypes = {
      -- see `:h vim.filetype.add` for usage
      extension = {
        foo = "fooscript",
      },
      filename = {
        [".foorc"] = "fooscript",
      },
      pattern = {
        [".*/etc/foo/.*"] = "fooscript",
        -- the `blog` project is a MyST project, so scope MyST snippets to it
        [".*/archives/blog/docs/.*%.md"] = "markdown.myst",
      },
    },
    -- vim options can be configured here
    options = {
      opt = { -- vim.opt.<key>
        relativenumber = true, -- sets vim.opt.relativenumber
        number = true, -- sets vim.opt.number
        spell = false, -- sets vim.opt.spell
        signcolumn = "yes", -- sets vim.opt.signcolumn to yes
        wrap = false, -- sets vim.opt.wrap
        autowriteall = true, -- Auto save when switching buffers, losing focus, etc.
        -- Plugins and `:!` emit POSIX syntax that fish rejects, so fall back to
        -- bash only when `$SHELL` is fish; other shells are left alone. bash over
        -- `sh` because it is a POSIX superset and stays bash on distros where
        -- `/bin/sh` is dash. Read here at spec-parse time, `vim.o.shell` is still
        -- the `$SHELL`-derived default.
        shell = vim.fn.fnamemodify(vim.o.shell, ":t") == "fish" and (vim.fn.executable "bash" == 1 and "bash" or "sh")
          or nil,
      },
      g = { -- vim.g.<key>
        -- configure global vim variables (vim.g)
        -- NOTE: `mapleader` and `maplocalleader` must be set in the AstroNvim opts or before `lazy.setup`
        -- This can be found in the `lua/lazy_setup.lua` file
      },
    },
    -- user commands, see `:h nvim_create_user_command`
    commands = {
      -- `:!` and plugin shell-outs stay on `vim.o.shell`; `:F {cmd}` runs a single
      -- command through fish, for fish syntax and `~/.config/fish/functions`.
      -- NOTE: `fish -c` is neither login nor interactive, so `config.fish` (which
      -- is wrapped in `status is-interactive`) is skipped and abbreviations do not
      -- expand. `%`/`#`/`!` still expand, since the real `:!` does the expanding.
      F = {
        function(opts)
          if vim.fn.executable "fish" ~= 1 then
            return vim.notify("`:F` requires fish, which is not executable; use `:!`", vim.log.levels.ERROR)
          end
          -- `shellcmdflag` is derived from `$SHELL` at startup and never re-derived,
          -- so pin it too rather than inheriting a possibly non-POSIX flag
          local shell, cmdflag = vim.o.shell, vim.o.shellcmdflag
          vim.o.shell, vim.o.shellcmdflag = "fish", "-c"
          -- always restore, or a failed command would strand fish globally
          local ok, err = pcall(vim.cmd, "!" .. opts.args)
          vim.o.shell, vim.o.shellcmdflag = shell, cmdflag
          if not ok then vim.notify(err, vim.log.levels.ERROR) end
        end,
        desc = "Run a shell command through fish",
        nargs = "+",
        complete = "shellcmd",
      },
    },
    -- Mappings can be configured through AstroCore as well.
    -- NOTE: keycodes follow the casing in the vimdocs. For example, `<Leader>` must be capitalized
    mappings = {
      -- first key is the mode
      n = {
        -- second key is the lefthand side of the map

        -- navigate buffer tabs
        ["]b"] = { function() require("astrocore.buffer").nav(vim.v.count1) end, desc = "Next buffer" },
        ["[b"] = { function() require("astrocore.buffer").nav(-vim.v.count1) end, desc = "Previous buffer" },

        -- mappings seen under group name "Buffer"
        ["<Leader>bd"] = {
          function()
            require("astroui.status.heirline").buffer_picker(
              function(bufnr) require("astrocore.buffer").close(bufnr) end
            )
          end,
          desc = "Close buffer from tabline",
        },

        -- tables with just a `desc` key will be registered with which-key if it's installed
        -- this is useful for naming menus
        -- ["<Leader>b"] = { desc = "Buffers" },

        -- setting a mapping to false will disable it
        -- ["<C-S>"] = false,
      },
    },
  },
}
