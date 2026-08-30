-- Minimal Neovim setup for the test suite.
--
-- It loads this config's own lua/ directory and plenary, and nothing else.
-- No plugin manager runs, so nothing reaches the network and no Claude CLI
-- ever starts. Tests that need claudecode.nvim install a stub instead; see
-- tests/helpers.lua.

local this_file = debug.getinfo(1, "S").source:sub(2)
local tests = vim.fn.fnamemodify(this_file, ":p:h")
local config = vim.fn.fnamemodify(tests, ":h")

vim.opt.rtp:prepend(config)
vim.opt.rtp:prepend(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
vim.opt.rtp:prepend(tests)

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.more = false
vim.g.mapleader = " "

-- Plenary spawns a child Neovim per spec file. It must use this same file,
-- or the child loads the real config and its plugin manager.
vim.g.plenary_test_minimal_init = this_file

require("plenary.busted")
