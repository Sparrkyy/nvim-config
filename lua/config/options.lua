-- Leader must be set before any plugin defines a mapping.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local o = vim.opt

-- Indentation (kept from the previous init.vim)
o.expandtab = true
o.tabstop = 4
o.softtabstop = 4
o.shiftwidth = 4
o.smartindent = true

-- UI. The left side of the window stays empty: no numbers, no sign column,
-- and no tildes after the last line.
o.number = false
o.relativenumber = false
o.signcolumn = "no"
o.fillchars:append({ eob = " " })
o.cursorline = true
o.termguicolors = true
o.scrolloff = 8
o.splitright = true
o.splitbelow = true
o.wrap = false
o.showmode = false
-- No status line. The window shows the file and nothing else.
o.laststatus = 0

-- Search
o.ignorecase = true
o.smartcase = true
o.inccommand = "split"

-- Files. Claude Code edits files on disk, so autoread is important here.
o.autoread = true
o.backup = false
o.writebackup = false
o.swapfile = false
o.undofile = true
o.updatetime = 300
o.timeoutlen = 400

-- Clipboard and diffs
o.clipboard = "unnamedplus"
o.diffopt:append({ "linematch:60" })

-- Diagnostics
vim.diagnostic.config({
  virtual_text = { spacing = 2, prefix = "●" },
  severity_sort = true,
  float = { border = "rounded", source = true },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "",
      [vim.diagnostic.severity.WARN] = "",
      [vim.diagnostic.severity.INFO] = "",
      [vim.diagnostic.severity.HINT] = "",
    },
  },
})
