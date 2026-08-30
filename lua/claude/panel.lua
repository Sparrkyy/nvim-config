-- Two scratch buffers that mirror what Claude is doing.
--   Plan  : Claude's task list, ticking off as it works.
--   Notes : Claude's prose, so reasoning is a buffer you can search and yank.

local M = {}

local panels = {
  plan = { buf = nil, name = "Claude Plan", ft = "markdown" },
  notes = { buf = nil, name = "Claude Notes", ft = "markdown" },
}

M.tasks = {}
local notes = { current_id = nil, chunks = {} }

--- Find a buffer already named `name`. Neovim stores the name as a full path.
local function buf_named(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
      and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == name then
      return b
    end
  end
  return nil
end

local function ensure_buf(key)
  local p = panels[key]
  if p.buf and vim.api.nvim_buf_is_valid(p.buf) then
    return p.buf
  end
  -- A buffer with this name can already exist: the module was reloaded, or an
  -- old panel buffer outlived its handle. Reuse it. nvim_buf_set_name throws
  -- E95 on a duplicate name, which would break every panel update.
  local existing = buf_named(p.name)
  if existing then
    p.buf = existing
    vim.bo[existing].modifiable = false
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, p.name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = p.ft
  vim.bo[buf].modifiable = false
  p.buf = buf
  return buf
end

local function write(key, lines)
  local buf = ensure_buf(key)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Keep any window showing this buffer scrolled to the end.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, #lines), 0 })
    end
  end
end

--- Open a panel in a split on the right, without leaving the current window.
local function open(key, width)
  local buf = ensure_buf(key)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_close(win, false) -- already open: toggle it shut
      return
    end
  end
  local current = vim.api.nvim_get_current_win()
  vim.cmd("vertical botright " .. (width or 50) .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true
  vim.wo[win].winfixwidth = true
  vim.api.nvim_set_current_win(current)
end

--- Plan -------------------------------------------------------------------

local MARK = { completed = "[x]", in_progress = "[~]", pending = "[ ]" }

local function render_plan()
  if vim.tbl_isempty(M.tasks) then
    write("plan", { "# Claude Plan", "", "No tasks yet." })
    return
  end
  local lines = { "# Claude Plan", "" }
  local done = 0
  local ordered = {}
  for _, t in pairs(M.tasks) do
    table.insert(ordered, t)
  end
  table.sort(ordered, function(a, b)
    return (a.seq or 0) < (b.seq or 0)
  end)
  for _, t in ipairs(ordered) do
    if t.status == "completed" then
      done = done + 1
    end
    table.insert(lines, string.format("%s %s", MARK[t.status] or MARK.pending, t.text))
  end
  table.insert(lines, 2, string.format("%d of %d done", done, #ordered))
  write("plan", lines)
end

local seq = 0

--- Record or update one task.
function M.task(id, text, status)
  if not id or id == "" then
    id = text
  end
  if not id then
    return
  end
  local existing = M.tasks[id]
  if existing then
    existing.text = text or existing.text
    existing.status = status or existing.status
  else
    seq = seq + 1
    M.tasks[id] = { text = text or id, status = status or "pending", seq = seq }
  end
  render_plan()
end

function M.clear_tasks()
  M.tasks = {}
  seq = 0
  render_plan()
end

function M.plan_summary()
  local total, done = 0, 0
  for _, t in pairs(M.tasks) do
    total = total + 1
    if t.status == "completed" then
      done = done + 1
    end
  end
  if total == 0 then
    return ""
  end
  return string.format("%d/%d", done, total)
end

--- Notes ------------------------------------------------------------------

local function render_notes()
  local lines = { "# Claude Notes", "" }
  -- Join every chunk first, then split on newlines. A streamed delta can end
  -- mid-word, so a chunk is not a line of its own.
  for _, l in ipairs(vim.split(table.concat(notes.chunks), "\n", { plain = true })) do
    table.insert(lines, l)
  end
  write("notes", lines)
end

--- Append one streamed chunk of Claude's prose.
function M.message(message_id, delta, final)
  if type(delta) ~= "string" or delta == "" then
    return
  end
  if message_id and message_id ~= notes.current_id then
    notes.current_id = message_id
    if #notes.chunks > 0 then
      table.insert(notes.chunks, "\n---\n")
    end
  end
  table.insert(notes.chunks, delta)
  if final == false then
    return -- still streaming; redraw on the final chunk
  end
  -- Keep the buffer from growing without bound.
  while #notes.chunks > 400 do
    table.remove(notes.chunks, 1)
  end
  render_notes()
end

function M.clear_notes()
  notes.chunks = {}
  notes.current_id = nil
  render_notes()
end

--- Commands ---------------------------------------------------------------

function M.toggle_plan()
  render_plan()
  open("plan", 46)
end

function M.toggle_notes()
  render_notes()
  open("notes", 60)
end

return M
