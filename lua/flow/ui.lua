-- What a change looks like before it lands.
--
-- Flow does not open a diff window. It opens the real file, puts the cursor on
-- the real line, and draws the change around it with extmarks. The lines that
-- go away turn red where they sit. The lines that arrive appear under them in
-- green. Nothing is written until you press <CR>.
--
--   <CR>  apply     r  revise     s  skip     q / <Esc>  dismiss
--
-- The stack panel on the right lists every step and where you are in it.

local M = {}

M.ns = vim.api.nvim_create_namespace("flow_preview")

M.opts = {
  glyphs = {
    done = "✔",
    current = "▸",
    ready = "○",
    generating = "◌",
    stale = "⚠",
    waiting = "⋯",
    skipped = "⨯",
    failed = "✗",
  },
  panel_width = 44,
}

local preview = { buf = nil, marks = {}, spec = nil, rendered = {} }
local panel = { buf = nil }

--- Text helpers -------------------------------------------------------------

function M.split(text)
  if text == nil or text == "" then
    return {}
  end
  local lines = vim.split(tostring(text), "\n", { plain = true })
  -- A trailing newline ends the last line. It does not start another one.
  -- A model writes "}\n" and means one line; a plain split makes two, and that
  -- phantom empty line can never match at the end of a file, so every edit
  -- anchored on the last lines of a file would be refused.
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Where `needle` sits inside `haystack`. Both are line lists.
--- Returns a 0-based start line, or nil. `from` is a 0-based hint.
function M.find(haystack, needle, from)
  if #needle == 0 then
    return nil
  end
  local last = #haystack - #needle
  for offset = (from or 0), last do
    local hit = true
    for i = 1, #needle do
      if haystack[offset + i] ~= needle[i] then
        hit = false
        break
      end
    end
    if hit then
      return offset
    end
  end
  return nil
end

--- True when a buffer holds nothing. A file that does not exist yet opens as
--- one empty line, not as no lines at all.
local function is_empty(lines)
  return #lines == 0 or (#lines == 1 and lines[1] == "")
end

--- Locate every edit of a step in a buffer's lines.
--- Returns a list of { start, old, new, ok, whole, reason } in the order they
--- were given. Later edits search past the earlier ones, so a repeated snippet
--- still lands in the right place.
function M.locate(lines, edits)
  local out = {}
  local from = 0
  for _, edit in ipairs(edits or {}) do
    local old = M.split(edit.old_string)
    local new = M.split(edit.new_string)
    if #old == 0 then
      -- An empty old_string means "this is the whole file". That is only ever
      -- right for a file with nothing in it. On a file that has content it
      -- would splice a second copy in at the top, so refuse it.
      if is_empty(lines) then
        table.insert(out, { start = 0, old = {}, new = new, ok = true, whole = true })
      else
        table.insert(out, { start = nil, old = {}, new = new, ok = false, reason = "empty" })
      end
    else
      local at = M.find(lines, old, from)
      if at then
        from = at + #old
        table.insert(out, { start = at, old = old, new = new, ok = true })
      else
        table.insert(out, { start = nil, old = old, new = new, ok = false })
      end
    end
  end
  return out
end

--- Drawing -----------------------------------------------------------------

local function virt_line(text, group)
  return { { text, group } }
end

--- Draw one located edit. Returns the virtual lines it added, for the tests.
local function draw(buf, hit, rationale, first)
  local shown = {}
  local at = hit.start or 0
  local count = vim.api.nvim_buf_line_count(buf)
  local anchor = math.min(at, math.max(count - 1, 0))

  local above = {}
  if first and rationale and vim.trim(rationale) ~= "" then
    for _, line in ipairs(M.split(rationale)) do
      table.insert(above, virt_line("  " .. line, "FlowHint"))
      table.insert(shown, "  " .. line)
    end
  end
  if not hit.ok then
    local warn = hit.reason == "empty" and "  ! This change would add a second copy of code the file already has."
      or "  ! This file moved on. Flow will build this change again."
    table.insert(above, virt_line(warn, "FlowStale"))
    table.insert(shown, warn)
  end

  if #above > 0 then
    vim.api.nvim_buf_set_extmark(buf, M.ns, anchor, 0, {
      virt_lines = above,
      virt_lines_above = true,
    })
  end

  -- The lines that go away, marked where they sit.
  if hit.ok and #hit.old > 0 then
    for i = 0, #hit.old - 1 do
      if at + i < count then
        vim.api.nvim_buf_set_extmark(buf, M.ns, at + i, 0, {
          line_hl_group = "FlowDel",
        })
      end
    end
  end

  -- The lines that arrive, under them.
  local below = {}
  for _, line in ipairs(hit.new) do
    table.insert(below, virt_line("+ " .. line, "FlowAdd"))
    table.insert(shown, "+ " .. line)
  end
  if #below > 0 then
    local tail = hit.ok and math.max(0, at + math.max(#hit.old, 1) - 1) or anchor
    vim.api.nvim_buf_set_extmark(buf, M.ns, math.min(tail, math.max(count - 1, 0)), 0, {
      virt_lines = below,
    })
  end

  return shown
end

--- Show a step's change in its file, without writing anything.
---@param spec table {
---   file, edits, rationale, title, index, total,
---   on_apply, on_revise, on_skip: function|nil
--- }
---@return boolean opened
function M.preview(spec)
  M.clear()
  if type(spec) ~= "table" or type(spec.file) ~= "string" then
    return false
  end

  local ok = pcall(vim.cmd.edit, vim.fn.fnameescape(spec.file))
  if not ok then
    return false
  end
  local buf = vim.api.nvim_get_current_buf()
  preview.buf = buf
  preview.spec = spec
  preview.rendered = {}

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local hits = M.locate(lines, spec.edits)
  preview.hits = hits

  for i, hit in ipairs(hits) do
    vim.list_extend(preview.rendered, draw(buf, hit, i == 1 and spec.rationale or nil, i == 1))
  end

  -- Land the cursor on the first change, with room above it.
  local first = hits[1]
  if first and first.start then
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(first.start + 1, #lines), 0 })
    pcall(vim.cmd, "normal! zz")
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Flow" })
    table.insert(preview.marks, lhs)
  end

  map("<CR>", function()
    local on_apply = spec.on_apply
    M.clear()
    if on_apply then
      on_apply()
    end
  end)
  map("r", function()
    local on_revise = spec.on_revise
    M.clear()
    if on_revise then
      on_revise()
    end
  end)
  map("s", function()
    local on_skip = spec.on_skip
    M.clear()
    if on_skip then
      on_skip()
    end
  end)
  map("q", M.clear)
  map("<Esc>", M.clear)

  if #hits == 0 then
    local note = "  This change is already in the file. Press <CR> to mark it done."
    local at = math.max(0, vim.api.nvim_buf_line_count(buf) - 1)
    vim.api.nvim_buf_set_extmark(buf, M.ns, at, 0, {
      virt_lines = { virt_line(note, "FlowHint") },
      virt_lines_above = true,
    })
    table.insert(preview.rendered, note)
  end

  local hint = string.format("%d/%d  %s", spec.index or 1, spec.total or 1, spec.title or "")
  vim.notify(
    hint .. "\n<CR> apply and go on · r revise · s skip · q dismiss",
    vim.log.levels.INFO,
    { title = "Flow" }
  )
  return true
end

--- Take the preview down. Safe to call at any time.
function M.clear()
  local buf = preview.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
    for _, lhs in ipairs(preview.marks) do
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  preview = { buf = nil, marks = {}, spec = nil, rendered = {} }
end

function M.is_open()
  return preview.buf ~= nil and vim.api.nvim_buf_is_valid(preview.buf)
end

--- The virtual lines on screen. The tests read this.
function M.preview_lines()
  return vim.deepcopy(preview.rendered)
end

--- Where each edit landed. The tests read this.
function M.hits()
  return preview.hits or {}
end

--- The panel ----------------------------------------------------------------

local PANEL_NAME = "flow://stack"

--- Find a buffer already named `name`. Neovim stores the name as a full path.
local function named_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match(vim.pesc(name) .. "$") then
      return b
    end
  end
  return nil
end

local function ensure_panel_buf()
  if panel.buf and vim.api.nvim_buf_is_valid(panel.buf) then
    return panel.buf
  end
  local existing = named_buf(PANEL_NAME)
  if existing then
    panel.buf = existing
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, PANEL_NAME)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "flow-stack"
  vim.bo[buf].modifiable = false
  panel.buf = buf
  return buf
end

--- Build the panel text from a stack. Returns lines and their highlights.
---@param stack table { title, steps, cursor, status_of: function }
function M.panel_lines(stack)
  local lines = { stack.title or "Flow", "" }
  local highlights = { { 0, "FlowTitle" } }
  local done = 0

  for i, step in ipairs(stack.steps or {}) do
    local status = stack.status_of(step, i)
    local group = ({
      done = "FlowDone",
      current = "FlowCurrent",
      ready = "FlowPending",
      generating = "FlowPending",
      stale = "FlowStale",
      waiting = "FlowPending",
      skipped = "FlowSkipped",
      failed = "FlowStale",
    })[status] or "FlowPending"
    if status == "done" then
      done = done + 1
    end
    local glyph = M.opts.glyphs[status] or "○"
    table.insert(lines, string.format("%s %2d  %s", glyph, i, step.title or "?"))
    table.insert(highlights, { #lines - 1, group })
    table.insert(lines, string.format("      %s", vim.fn.fnamemodify(step.file or "", ":.")))
    table.insert(highlights, { #lines - 1, "FlowHint" })
  end

  table.insert(lines, 2, string.format("%d of %d applied", done, #(stack.steps or {})))
  for _, h in ipairs(highlights) do
    if h[1] >= 2 then
      h[1] = h[1] + 1
    end
  end
  return lines, highlights
end

--- Redraw the panel if it is on screen.
function M.render_panel(stack)
  local buf = panel.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines, highlights = M.panel_lines(stack)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, h[1], 0, { line_hl_group = h[2] })
  end
end

function M.panel_is_open()
  return panel.buf ~= nil and vim.fn.bufwinid(panel.buf) ~= -1
end

--- Open or close the panel. It never takes focus.
function M.toggle_panel(stack)
  if M.panel_is_open() then
    local win = vim.fn.bufwinid(panel.buf)
    pcall(vim.api.nvim_win_close, win, true)
    return false
  end

  local buf = ensure_panel_buf()
  local from = vim.api.nvim_get_current_win()
  vim.cmd(string.format("vertical botright %dvsplit", M.opts.panel_width))
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.wrap = false
  vim.wo.winfixwidth = true
  if stack then
    M.render_panel(stack)
  end
  pcall(vim.api.nvim_set_current_win, from)
  return true
end

--- What the panel shows. The tests read this.
function M.panel_text()
  if not (panel.buf and vim.api.nvim_buf_is_valid(panel.buf)) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
end

function M.close_panel()
  if panel.buf and vim.api.nvim_buf_is_valid(panel.buf) then
    local win = vim.fn.bufwinid(panel.buf)
    if win ~= -1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(vim.api.nvim_buf_delete, panel.buf, { force = true })
  end
  panel.buf = nil
end

return M
