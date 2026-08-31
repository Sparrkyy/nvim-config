-- Save a file buffer to disk when you leave it.
--
-- Claude Code reads files from disk, not from the Neovim buffer. An unsaved
-- buffer therefore hides your latest edit from Claude. This writes the
-- buffer on BufLeave, so what you left behind is what Claude reads.
--
-- The write is quiet and safe. It never prompts and it never fails loudly:
-- a buffer that cannot be written is left alone.

local M = {}

-- True when the buffer holds a real file with unsaved changes.
function M.should_save(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return false
  end
  local bo = vim.bo[buf]
  if bo.buftype ~= "" then return false end
  if not bo.modified or not bo.modifiable or bo.readonly then return false end
  return vim.api.nvim_buf_get_name(buf) ~= ""
end

-- Write the buffer. Returns true when the file reached the disk.
function M.save(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not M.should_save(buf) then return false end

  local ok = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent lockmarks write")
  end)
  return ok and not vim.bo[buf].modified
end

function M.setup(group)
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function(args)
      M.save(args.buf)
    end,
  })
end

return M
