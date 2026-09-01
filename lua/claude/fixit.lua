-- One-shot fixes for diagnostics. Put the cursor on an error, press the key,
-- and a short headless Claude session repairs that one thing.
--
-- claude.oneshot runs the session and streams it into the window in the top
-- right. This file only decides what to ask.

local M = {}

local oneshot = require("claude.oneshot")

-- The command, the model, and the timeouts live in one place.
M.opts = oneshot.opts

M.opts.context_lines = M.opts.context_lines or 6

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Claude fix" })
end

--- Kept for the statusline and for anything that asks whether a fix is up.
function M.statusline()
  return oneshot.statusline()
end

--- Choosing the diagnostic -------------------------------------------------

local SEVERITY = { "ERROR", "WARN", "INFO", "HINT" }

--- The diagnostic to fix: the one under the cursor, else the nearest to it.
local function diagnostic_at_cursor(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1

  local here = vim.diagnostic.get(bufnr, { lnum = lnum })
  if #here > 0 then
    table.sort(here, function(a, b)
      return (a.severity or 4) < (b.severity or 4)
    end)
    return here[1]
  end

  local all = vim.diagnostic.get(bufnr)
  if #all == 0 then
    return nil
  end
  table.sort(all, function(a, b)
    return math.abs(a.lnum - lnum) < math.abs(b.lnum - lnum)
  end)
  return all[1]
end

--- Describe one diagnostic the way a prompt wants it.
local function describe(d)
  local parts = {
    string.format("Line %d, column %d", d.lnum + 1, (d.col or 0) + 1),
    string.format("Severity: %s", SEVERITY[d.severity] or "ERROR"),
  }
  if d.source and d.source ~= "" then
    table.insert(parts, "Source: " .. d.source)
  end
  if d.code and tostring(d.code) ~= "" then
    table.insert(parts, "Code: " .. tostring(d.code))
  end
  table.insert(parts, "Message: " .. (d.message or ""):gsub("%s+", " "))
  return table.concat(parts, "\n")
end

--- The code around an error, with the failing line marked.
local function code_window(bufnr, lnum)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local first = math.max(1, lnum + 1 - M.opts.context_lines)
  local last = math.min(total, lnum + 1 + M.opts.context_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)

  local out = {}
  for i, text in ipairs(lines) do
    local n = first + i - 1
    table.insert(out, string.format("%s %4d | %s", n == lnum + 1 and ">" or " ", n, text))
  end
  return table.concat(out, "\n")
end

--- The prompt ---------------------------------------------------------------

local RULES = table.concat({
  "Resolve this diagnostic completely. Inspect the surrounding project and",
  "dependency manifests before choosing a fix. Use Bash when local project",
  "state or a command is needed to diagnose or verify it. If a missing",
  "dependency or type package is the correct fix, install it with the",
  "project's existing package manager. Keep the change focused on this",
  "diagnostic, but update related manifests and lockfiles when required.",
  "Do not fix unrelated issues. Verify the fix when practical. Reply with",
  "one short line saying what you changed.",
}, "\n")

local function build_prompt(relpath, diagnostics, snippet)
  return table.concat({
    "Fix this diagnostic in " .. relpath .. ".",
    "",
    diagnostics,
    "",
    "The code around it:",
    "",
    snippet,
    "",
    RULES,
  }, "\n")
end

--- Running ------------------------------------------------------------------

--- Fix the diagnostic under the cursor.
---@param opts table|nil { all = boolean } all: fix every diagnostic in the file
function M.fix(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or path == "" then
    return notify("This is not a file buffer.", vim.log.levels.WARN)
  end

  local items = vim.diagnostic.get(bufnr, { severity = { min = vim.diagnostic.severity.WARN } })
  if #items == 0 then
    return notify("No diagnostics in this file.")
  end

  local described, target_line, title
  if opts.all then
    local parts = {}
    for i, d in ipairs(items) do
      if i > 10 then
        table.insert(parts, string.format("... and %d more", #items - 10))
        break
      end
      table.insert(parts, describe(d))
    end
    described = table.concat(parts, "\n\n")
    target_line = items[1].lnum
    title = string.format("Fix %d diagnostics", #items)
  else
    local d = diagnostic_at_cursor(bufnr)
    if not d then
      return notify("No diagnostic here.")
    end
    described = describe(d)
    target_line = d.lnum
    title = "Fix line " .. (d.lnum + 1)
  end

  local relpath = vim.fn.fnamemodify(path, ":.")
  oneshot.run({
    prompt = build_prompt(relpath, described, code_window(bufnr, target_line)),
    title = title,
    bufnr = bufnr,
    tools = "Read,Edit,Grep,Glob,Bash",
  })
end

--- Fix every diagnostic in the file, in one session.
function M.fix_all()
  M.fix({ all = true })
end

--- How many sessions run right now. Several fixes may be in flight at once.
function M.count()
  return oneshot.count()
end

--- The last summary Claude returned, whichever session produced it.
setmetatable(M, {
  __index = function(_, key)
    if key == "last_result" then
      return oneshot.last_result
    end
    if key == "running" then
      return oneshot.is_running()
    end
    return nil
  end,
})

return M
