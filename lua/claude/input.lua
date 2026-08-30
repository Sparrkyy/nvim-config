-- A small composer window for a Claude instruction.
--
-- vim.ui.input gives you one line that grows sideways until it runs off the
-- screen. An instruction to Claude is often a sentence or three, so this wraps
-- instead, and the window grows downward as you type.
--
--   <CR>          send
--   <S-CR>, <C-j> a new line
--   <Esc>, <C-c>  cancel

local M = {}

M.opts = {
  width = 0.6, -- a fraction of the screen, or an absolute column count
  max_width = 84,
  min_width = 40,
  max_height = 12,
  row = 0.25, -- a fraction of the screen height
  icon = "󰭹",
}

local state = { win = nil, buf = nil, done = nil }

local function target_width()
  local w = M.opts.width
  if w <= 1 then
    w = math.floor(vim.o.columns * w)
  end
  return math.max(M.opts.min_width, math.min(w, M.opts.max_width, vim.o.columns - 6))
end

--- How many screen rows the text needs, once it is wrapped.
local function text_height(win, buf, width)
  local ok, result = pcall(vim.api.nvim_win_text_height, win, {})
  if ok and type(result) == "table" and result.all then
    return result.all
  end
  local rows = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  return math.max(1, rows)
end

local function resize()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  local width = target_width()
  local height = math.max(1, math.min(M.opts.max_height, text_height(state.win, state.buf, width)))
  pcall(vim.api.nvim_win_set_config, state.win, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor(vim.o.lines * M.opts.row),
    col = math.floor((vim.o.columns - width) / 2),
  })
end

--- Finish, exactly once. `text` is nil when you cancel.
local function close(text)
  local callback = state.done
  state.done = nil

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf = nil, nil

  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
  if callback then
    callback(text)
  end
end

--- The text in the window, or nil when it is empty.
local function current_text()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return nil
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  if vim.trim(text) == "" then
    return nil
  end
  return text
end

--- Ask for an instruction.
---@param opts table { title: string|nil, default: string|nil }
---@param on_done function called with the text, or with nil when you cancel
function M.open(opts, on_done)
  opts = opts or {}
  if state.win then
    close(nil) -- never leave two composers up
  end

  state.done = on_done
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "claude-input"

  if opts.default and opts.default ~= "" then
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(opts.default, "\n", { plain = true }))
  end

  vim.api.nvim_set_hl(0, "ClaudeInputBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "ClaudeInputTitle", { link = "Title", default = true })

  local width = target_width()
  local ok, win = pcall(vim.api.nvim_open_win, state.buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = math.floor(vim.o.lines * M.opts.row),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. M.opts.icon .. " " .. (opts.title or "Claude") .. " ",
    title_pos = "center",
    zindex = 70,
  })
  if not ok then
    state.buf = nil
    state.done = nil
    if on_done then
      on_done(nil)
    end
    return
  end

  state.win = win
  -- The whole point: wrap, and break on a word boundary.
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight =
    "Normal:NormalFloat,FloatBorder:ClaudeInputBorder,FloatTitle:ClaudeInputTitle"

  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = state.buf, nowait = true, silent = true })
  end

  map({ "n", "i" }, "<CR>", function()
    close(current_text())
  end)
  map({ "n", "i" }, "<C-j>", function()
    vim.api.nvim_put({ "", "" }, "c", false, true)
  end)
  map({ "n", "i" }, "<S-CR>", function()
    vim.api.nvim_put({ "", "" }, "c", false, true)
  end)
  map({ "n", "i" }, "<C-c>", function()
    close(nil)
  end)
  map("n", "<Esc>", function()
    close(nil)
  end)
  map("n", "q", function()
    close(nil)
  end)

  local group = vim.api.nvim_create_augroup("ClaudeInput", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = state.buf,
    callback = resize,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = state.buf,
    callback = function()
      close(nil)
    end,
  })

  resize()
  vim.cmd("startinsert!")
end

--- Close the composer if one is open. For the tests and for a cleanup.
function M.close()
  if state.win then
    close(nil)
  end
end

--- True while a composer is open.
function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- The window and buffer, for the tests.
function M.handles()
  return state.win, state.buf
end

return M
