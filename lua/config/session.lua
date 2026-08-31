-- Per-directory session. Start Neovim in a directory with no file argument,
-- and it reopens the buffer stack you left there, on the same line.
--
-- The stack lives in `config.bufstack`, so J and K work straight away.
-- Nothing here is fatal: a missing or broken session file just means an
-- empty start.

local M = {}

local bufstack = require("config.bufstack")

M.dir = vim.fn.stdpath("state") .. "/sessions"

-- Cursor positions waiting for their buffer to load, keyed by file path.
local pending = {}

-- A session file per working directory. The slug stays readable, and the
-- hash keeps two different directories from sharing one file.
function M.file(cwd)
  cwd = vim.fn.resolve(vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"))
  local slug = cwd:gsub("[^%w]+", "_"):gsub("^_", ""):gsub("_$", "")
  return M.dir .. "/" .. slug:sub(-60) .. "_" .. vim.fn.sha256(cwd):sub(1, 8) .. ".json"
end

-- Where the cursor sits in `buf`. The current buffer answers from its window,
-- because the `"` mark only updates when you leave a buffer.
local function cursor_of(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return nil end
  if buf == vim.api.nvim_get_current_buf() then
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
    return ok and pos or nil
  end
  local ok, mark = pcall(vim.api.nvim_buf_get_mark, buf, '"')
  if ok and mark[1] > 0 then return mark end
  return nil
end

--- Write the session for `cwd`.
function M.save(cwd)
  local state = bufstack.files()
  local cursors = {}
  for _, path in ipairs(state.files) do
    local buf = vim.fn.bufnr(path)
    if buf > 0 then
      local pos = cursor_of(buf)
      if pos then cursors[path] = { pos[1], pos[2] } end
    end
  end

  local path = M.file(cwd)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local data = { files = state.files, idx = state.idx, cursors = cursors }
  local ok, json = pcall(vim.json.encode, data)
  if not ok then return false end
  return pcall(vim.fn.writefile, { json }, path)
end

--- Read the session for `cwd`. Returns nil when there is none.
function M.load(cwd)
  local path = M.file(cwd)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines[1] then return nil end
  local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(data) ~= "table" or type(data.files) ~= "table" then
    return nil
  end
  return data
end

--- Reopen the saved stack for `cwd`. Returns true when a buffer opened.
function M.restore(cwd)
  local data = M.load(cwd)
  if not data then return false end

  pending = {}
  for path, pos in pairs(data.cursors or {}) do
    pending[vim.fn.resolve(path)] = pos
  end

  if not bufstack.restore(data.files, data.idx) then return false end
  M.place_cursor(vim.api.nvim_get_current_buf())
  return true
end

--- Move the cursor in `buf` to its saved line, once. A line past the end of
--- the file is clamped, because the file may have shrunk since the last run.
function M.place_cursor(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return end
  local pos = pending[vim.fn.resolve(name)]
  if not pos then return end
  pending[vim.fn.resolve(name)] = nil

  local win = vim.fn.bufwinid(buf)
  if win == -1 then return end
  local last = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(pos[1], last), pos[2] })
end

-- True when Neovim opened a file, a directory, or a pipe. Restoring then
-- would fight what you asked for.
local function started_empty()
  return vim.fn.argc() == 0 and not vim.g.session_stdin
end

function M.setup()
  local group = vim.api.nvim_create_augroup("EthanSession", { clear = true })

  vim.api.nvim_create_autocmd("StdinReadPre", {
    group = group,
    callback = function()
      vim.g.session_stdin = true
    end,
  })

  -- The restore runs after VimEnter returns. A buffer read inside an autocmd
  -- is a nested event, and Neovim then skips filetype detection, so the LSP
  -- and treesitter never start on the restored file.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      if not started_empty() then return end
      vim.schedule(function()
        pcall(M.restore)
      end)
    end,
  })

  -- A buffer you reach later with J or K loads here, not at startup.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      M.place_cursor(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      pcall(M.save)
    end,
  })
end

return M
