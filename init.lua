-- Entry point. Order matters: leader keys must be set before lazy.nvim loads.
require("config.options")
-- The colourscheme is local, so it loads before any plugin draws.
vim.cmd.colorscheme("ghostty")
require("config.lazy")
require("config.keymaps")
require("config.autocmds")
require("config.bufstack").setup()
require("config.session").setup()
require("config.newfile").setup()
require("claude.follow").setup()
require("config.reload").setup()
