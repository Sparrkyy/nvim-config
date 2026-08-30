local aug = vim.api.nvim_create_augroup("EthanConfig", { clear = true })

-- Highlight on yank.
vim.api.nvim_create_autocmd("TextYankPost", {
  group = aug,
  callback = function()
    local hl = vim.hl or vim.highlight
    hl.on_yank({ timeout = 150 })
  end,
})

-- Reload buffers that Claude Code changed on disk.
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "TermClose", "TermLeave" }, {
  group = aug,
  callback = function()
    if vim.bo.buftype == "" and vim.fn.mode() ~= "c" then
      vim.cmd("checktime")
    end
  end,
})

vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = aug,
  callback = function()
    vim.notify("File changed on disk. Buffer reloaded.", vim.log.levels.INFO)
  end,
})

-- Terminal buffers: no numbers, start in insert mode.
vim.api.nvim_create_autocmd("TermOpen", {
  group = aug,
  callback = function()
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.signcolumn = "no"
  end,
})

-- Two-space indent for web and config filetypes.
vim.api.nvim_create_autocmd("FileType", {
  group = aug,
  pattern = {
    "javascript", "javascriptreact", "typescript", "typescriptreact",
    "json", "jsonc", "yaml", "html", "css", "scss", "lua", "markdown", "sql",
  },
  callback = function()
    vim.opt_local.tabstop = 2
    vim.opt_local.softtabstop = 2
    vim.opt_local.shiftwidth = 2
  end,
})
