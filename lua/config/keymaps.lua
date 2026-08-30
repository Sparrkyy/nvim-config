local map = vim.keymap.set

-- Escape shortcuts (kept from the previous init.vim).
map("i", "jk", "<Esc>")
map("i", "kj", "<Esc>")

-- Alternate buffer (kept from the previous init.vim).
map("n", "<leader>b", "<cmd>b#<cr>", { desc = "Alternate buffer" })

-- Clear search highlight.
map("n", "<Esc>", "<cmd>nohlsearch<cr>", { desc = "Clear highlight" })

-- Window navigation.
map("n", "<C-h>", "<C-w>h", { desc = "Window left" })
map("n", "<C-j>", "<C-w>j", { desc = "Window down" })
map("n", "<C-k>", "<C-w>k", { desc = "Window up" })
map("n", "<C-l>", "<C-w>l", { desc = "Window right" })

-- Leave terminal insert mode.
map("t", "<C-x>", [[<C-\><C-n>]], { desc = "Terminal normal mode" })

-- Move the selected lines.
map("v", "J", ":m '>+1<cr>gv=gv", { desc = "Move selection down" })
map("v", "K", ":m '<-2<cr>gv=gv", { desc = "Move selection up" })

-- Keep the cursor centred.
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")
map("n", "n", "nzzzv")
map("n", "N", "Nzzzv")

-- Paste over a selection without losing the register.
map("x", "<leader>p", [["_dP]], { desc = "Paste (keep register)" })

-- Save and quit.
map("n", "<leader>w", "<cmd>write<cr>", { desc = "Write file" })
map("n", "<leader>q", "<cmd>quit<cr>", { desc = "Quit window" })

-- Diagnostics.
map("n", "[g", function() vim.diagnostic.jump({ count = -1, float = true }) end, { desc = "Previous diagnostic" })
map("n", "]g", function() vim.diagnostic.jump({ count = 1, float = true }) end, { desc = "Next diagnostic" })
map("n", "<leader>e", vim.diagnostic.open_float, { desc = "Show diagnostic" })

-- gu = "go to uses". Use the LSP if it can find references. Otherwise grep the tree.
local function goto_uses()
  local clients = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/references" })
  if #clients > 0 then
    require("telescope.builtin").lsp_references({
      include_declaration = false,
      show_line = false,
    })
  else
    require("telescope.builtin").grep_string({ word_match = "-w" })
  end
end

map("n", "gu", goto_uses, { desc = "Go to uses (references)" })

-- Join lines. The buffer stack takes J. See lua/config/bufstack.lua.
map("n", "<leader>J", "J", { desc = "Join lines" })
