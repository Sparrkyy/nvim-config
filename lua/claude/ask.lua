-- One-off requests. Type an instruction, and a short headless Claude session
-- carries it out on the file in front of you. Not tied to any diagnostic.
--
-- Use it for the small jobs: rename this, extract that, add the types, write
-- the doc comment. The work streams into the window in the top right.

local M = {}

local oneshot = require("claude.oneshot")

M.opts = {
  context_lines = 40, -- how much of a long file to quote around the cursor
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Claude" })
end

local RULES = table.concat({
  "Edit the files directly. Make the smallest change that does the job.",
  "Do not run commands. Do not explain at length. Reply with one short line",
  "saying what you changed.",
}, "\n")

--- The visual selection, or nil when there is none.
local function selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil
  end
  local first, last = start_pos[2], end_pos[2]
  if first > last then
    first, last = last, first
  end
  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  if #lines == 0 then
    return nil
  end
  return { first = first, last = last, text = table.concat(lines, "\n") }
end

--- Quote a window of the buffer around the cursor, with line numbers.
local function around_cursor(bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local first = math.max(1, cursor - M.opts.context_lines)
  local last = math.min(total, cursor + M.opts.context_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)

  local out = {}
  for i, text in ipairs(lines) do
    local n = first + i - 1
    table.insert(out, string.format("%s %4d | %s", n == cursor and ">" or " ", n, text))
  end
  return table.concat(out, "\n"), cursor
end

--- Build the prompt for one request.
local function build_prompt(relpath, instruction, region)
  local parts = { instruction, "", "File: " .. relpath }

  if region.kind == "selection" then
    table.insert(parts, string.format("The selected lines are %d to %d:", region.first, region.last))
    table.insert(parts, "")
    table.insert(parts, region.text)
  else
    table.insert(parts, string.format("The cursor is on line %d. The code around it:", region.cursor))
    table.insert(parts, "")
    table.insert(parts, region.text)
  end

  table.insert(parts, "")
  table.insert(parts, RULES)
  return table.concat(parts, "\n")
end

--- Ask for an instruction, then carry it out.
---@param opts table|nil { selection = boolean }
function M.ask(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or path == "" then
    return notify("This is not a file buffer.", vim.log.levels.WARN)
  end

  local region
  if opts.selection then
    local sel = selection()
    if not sel then
      return notify("No selection.", vim.log.levels.WARN)
    end
    region = { kind = "selection", first = sel.first, last = sel.last, text = sel.text }
  else
    local text, cursor = around_cursor(bufnr)
    region = { kind = "cursor", cursor = cursor, text = text }
  end

  local relpath = vim.fn.fnamemodify(path, ":.")
  local label = opts.selection
    and string.format("%s:%d-%d", vim.fn.fnamemodify(path, ":t"), region.first, region.last)
    or vim.fn.fnamemodify(path, ":t")

  require("claude.input").open({ title = "Claude, " .. label }, function(instruction)
    if not instruction or vim.trim(instruction) == "" then
      return
    end
    oneshot.run({
      prompt = build_prompt(relpath, instruction, region),
      title = vim.trim(instruction):sub(1, 34),
      bufnr = bufnr,
    })
  end)
end

--- Carry out a request on the visual selection.
function M.ask_selection()
  M.ask({ selection = true })
end

return M
