-- The job window in the bottom right.
--
-- It shows every one-shot Claude session that is running: what each one is
-- doing, the tool it just ran, and the text it is writing. Several can run at
-- once, so this is a list, not a single card.
--
-- Waiting on a silent 30-second job is a bad flow. Watching the work is a good
-- one. The window never takes focus and never joins your buffer list.

local M = {}

local uv = vim.uv or vim.loop
local sessions = require("claude.sessions")

M.opts = {
  width = 58,
  max_height = 22,
  linger_ms = 5000, -- how long a finished job stays on the list
  text_lines = 3, -- lines of streamed text, when there is room
}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local jobs = {} -- ordered, oldest first
local by_id = {}
local next_id = 0

local win, buf, timer
local ns = vim.api.nvim_create_namespace("claude_hud")

--- Geometry -----------------------------------------------------------------

local function width()
  return math.max(30, math.min(M.opts.width, vim.o.columns - 4))
end

local function active_count()
  local n = 0
  for _, job in ipairs(jobs) do
    if not job.done then
      n = n + 1
    end
  end
  return n
end

--- Colours ------------------------------------------------------------------

-- Every group links to something a colourscheme already defines, so the window
-- looks at home in any theme. Override any of them to taste.
local function define_highlights()
  local hl = {
    ClaudeHudRun = { link = "DiagnosticInfo" },
    ClaudeHudOk = { link = "DiagnosticOk" },
    ClaudeHudFail = { link = "DiagnosticError" },
    ClaudeHudName = { link = "Normal" },
    ClaudeHudTime = { link = "Comment" },
    ClaudeHudTool = { link = "Function" },
    ClaudeHudDetail = { link = "Comment" },
    ClaudeHudText = { link = "Comment" },
    ClaudeHudMore = { link = "Comment" },
    ClaudeHudBorder = { link = "FloatBorder" },
    ClaudeHudTitle = { link = "Title" },
  }
  for name, spec in pairs(hl) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

--- Content ------------------------------------------------------------------

local function elapsed_of(job)
  local finish = job.finished_at or uv.now()
  local seconds = math.floor((finish - job.started) / 1000)
  if seconds < 60 then
    return seconds .. "s"
  end
  return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
end

--- Cut a string to a display width, with an ellipsis when it does not fit.
local function fit(text, budget)
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if budget <= 1 or vim.fn.strdisplaywidth(text) <= budget then
    return text
  end
  return vim.fn.strcharpart(text, 0, budget - 1) .. "…"
end

--- Keep the tail of a long stream, so you see the newest words.
local function tail(text, budget)
  local flat = text:gsub("%s+", " "):gsub("^%s+", "")
  if budget <= 0 or #flat <= budget then
    return flat
  end
  return "…" .. flat:sub(#flat - budget + 4)
end

--- Wrap one long line to a width.
local function wrap(text, w)
  local out = {}
  while vim.fn.strdisplaywidth(text) > w do
    local cut = text:sub(1, w):match(".*()%s") or w
    table.insert(out, text:sub(1, cut - 1))
    text = text:sub(cut + 1)
  end
  if text ~= "" then
    table.insert(out, text)
  end
  return out
end

--- Build one line as coloured segments.
local function segments()
  local L = { text = "", segs = {} }
  function L.add(str, hl)
    local from = #L.text
    L.text = L.text .. str
    if hl then
      table.insert(L.segs, { from = from, to = #L.text, hl = hl })
    end
    return L
  end
  return L
end

local function render()
  local w = width()

  -- With several jobs at once each gets less room, so the list stays readable.
  local many = #jobs > 2
  local budget_lines = many and 1 or M.opts.text_lines

  --- One job as a list of coloured lines.
  local function block(job)
    local out = {}

    local icon, accent
    if job.done then
      icon = job.failed and "✗" or "✓"
      accent = job.failed and "ClaudeHudFail" or "ClaudeHudOk"
    else
      icon = SPINNER[job.frame]
      accent = "ClaudeHudRun"
    end

    -- Header: icon, name, and the elapsed time flush right.
    local time = elapsed_of(job)
    local name = fit(job.title, w - 5 - vim.fn.strdisplaywidth(time))
    local pad = w - 4 - vim.fn.strdisplaywidth(name) - vim.fn.strdisplaywidth(time)

    local head = segments()
    head.add(" ", nil)
    head.add(icon, accent)
    head.add(" ", nil)
    head.add(name, "ClaudeHudName")
    head.add(string.rep(" ", math.max(1, pad)), nil)
    head.add(time, "ClaudeHudTime")
    table.insert(out, head)

    --- Continuation lines hang off a bar in the job's own colour.
    local function bar()
      local line = segments()
      line.add(" ", nil)
      line.add("│", accent)
      line.add(" ", nil)
      return line
    end

    local recent = job.activity[#job.activity]
    if recent then
      local tool, detail = recent:match("^(%S+)%s%s(.+)$")
      local line = bar()
      if tool then
        line.add(tool, "ClaudeHudTool")
        line.add(" · ", "ClaudeHudDetail")
        line.add(fit(detail, w - 8 - vim.fn.strdisplaywidth(tool)), "ClaudeHudDetail")
      else
        line.add(fit(recent, w - 4), "ClaudeHudTool")
      end
      table.insert(out, line)
    end

    local body = job.done and (job.result or job.text) or job.text
    if body and body ~= "" and budget_lines > 0 then
      local hl = job.done and "ClaudeHudName" or "ClaudeHudText"
      for _, l in ipairs(wrap(tail(body, budget_lines * (w - 4)), w - 4)) do
        local line = bar()
        line.add(l, hl)
        table.insert(out, line)
      end
    end

    return out
  end

  -- Fill from the newest job backwards, so the busiest work is always on
  -- screen. Anything that will not fit becomes a count at the top.
  local blocks = {}
  local used, shown = 0, 0
  for i = #jobs, 1, -1 do
    local b = block(jobs[i])
    local cost = #b + (shown > 0 and 1 or 0)
    if used + cost > M.opts.max_height - 1 and shown > 0 then
      break
    end
    table.insert(blocks, 1, b)
    used = used + cost
    shown = shown + 1
  end

  local lines, marks = {}, {}
  local function emit(line)
    table.insert(lines, line.text)
    for _, seg in ipairs(line.segs) do
      table.insert(marks, { line = #lines - 1, from = seg.from, to = seg.to, hl = seg.hl })
    end
  end

  local hidden = #jobs - shown
  if hidden > 0 then
    local line = segments()
    line.add(string.format(" +%d more", hidden), "ClaudeHudMore")
    emit(line)
  end

  for i, b in ipairs(blocks) do
    if i > 1 then
      emit(segments())
    end
    for _, line in ipairs(b) do
      emit(line)
    end
  end

  if #lines == 0 then
    local line = segments()
    line.add(" No sessions running.", "ClaudeHudMore")
    emit(line)
  end

  return lines, marks
end

--- Window -------------------------------------------------------------------

--- The text on the border. It names how many sessions are up.
local function border_title()
  local total, active = #jobs, active_count()
  if active > 1 then
    return string.format(" Claude ×%d ", active)
  end
  if active == 1 then
    return " Claude "
  end
  return total > 0 and " Claude " or " Claude "
end

local function window_config()
  return {
    relative = "editor",
    anchor = "SE",
    row = math.max(1, vim.o.lines - 2),
    col = math.max(1, vim.o.columns - 2),
    width = width(),
    height = 3,
    style = "minimal",
    border = "rounded",
    title = border_title(),
    title_pos = "center",
    focusable = false,
    noautocmd = true,
    zindex = 60,
  }
end

local function ensure_window()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
  end
  if win and vim.api.nvim_win_is_valid(win) then
    return true
  end

  define_highlights()

  local ok, handle = pcall(vim.api.nvim_open_win, buf, false, window_config())
  if not ok then
    win = nil
    return false
  end
  win = handle
  vim.wo[win].wrap = false
  vim.wo[win].winblend = 0
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight =
    "Normal:NormalFloat,FloatBorder:ClaudeHudBorder,FloatTitle:ClaudeHudTitle"
  return true
end

local function draw()
  if #jobs == 0 then
    return M.close_window()
  end
  if not ensure_window() then
    return
  end

  local lines, marks = render()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.line, m.from, {
      end_col = m.to,
      hl_group = m.hl,
    })
  end

  local config = window_config()
  config.height = math.max(1, math.min(M.opts.max_height, #lines))
  config.noautocmd = nil -- not allowed when a window already exists
  pcall(vim.api.nvim_win_set_config, win, config)
end

--- Timing -------------------------------------------------------------------

--- Drop the finished jobs whose linger time is up.
local function reap()
  local now = uv.now()
  local kept = {}
  for _, job in ipairs(jobs) do
    if job.done and job.finished_at and now - job.finished_at > M.opts.linger_ms then
      by_id[job.id] = nil
    else
      table.insert(kept, job)
    end
  end
  jobs = kept
end

local function stop_timer()
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timer = nil
  end
end

local function ensure_timer()
  if timer then
    return
  end
  timer = uv.new_timer()
  if not timer then
    return
  end
  timer:start(0, 100, vim.schedule_wrap(function()
    for _, job in ipairs(jobs) do
      if not job.done then
        job.frame = job.frame % #SPINNER + 1
      end
    end
    reap()
    draw()
    if #jobs == 0 then
      stop_timer()
    end
  end))
end

--- Public -------------------------------------------------------------------

--- Add a job to the list. Returns its id.
---@param title string
---@param spec table|nil
---@return number id
function M.start(title, spec)
  spec = vim.tbl_extend("force", spec or {}, { title = title or "Claude" })
  local id = sessions.start(spec)
  next_id = math.max(next_id, id)
  local job = {
    id = id,
    title = title or "Claude",
    started = uv.now(),
    frame = 1,
    activity = {},
    text = "",
    done = false,
    failed = false,
  }
  table.insert(jobs, job)
  by_id[job.id] = job
  ensure_timer()
  draw()
  return job.id
end

--- Note a tool one job started.
function M.tool(id, name, detail)
  local job = by_id[id]
  if not job or not name or name == "" then
    return
  end
  local line = name
  if detail and detail ~= "" then
    line = line .. "  " .. detail
  end
  if job.activity[#job.activity] ~= line then
    table.insert(job.activity, line)
  end
  if #job.activity > 20 then
    table.remove(job.activity, 1)
  end
  sessions.tool(id, name, detail)
  draw()
end

--- Append streamed text or thinking to one job.
function M.append(id, chunk)
  local job = by_id[id]
  if not job or type(chunk) ~= "string" or chunk == "" then
    return
  end
  job.text = job.text .. chunk
  if #job.text > 4000 then
    job.text = job.text:sub(-4000)
  end
  sessions.append(id, chunk)
  draw()
end

function M.update(id, values)
  sessions.update(id, values)
end

--- Mark one job finished. It lingers, then leaves the list.
function M.finish(id, ok, summary)
  local job = by_id[id]
  if not job then
    return
  end
  job.done = true
  job.failed = not ok
  job.result = summary
  job.finished_at = uv.now()
  sessions.finish(id, ok, summary)
  draw()
end

--- Remove one job now.
function M.close(id)
  local job = by_id[id]
  if not job then
    return
  end
  by_id[id] = nil
  for i, j in ipairs(jobs) do
    if j.id == id then
      table.remove(jobs, i)
      break
    end
  end
  draw()
end

--- Drop every job and hide the window.
function M.close_all()
  jobs = {}
  by_id = {}
  stop_timer()
  M.close_window()
end

--- Hide the window, keeping the job list.
function M.close_window()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
end

--- True while the window is on screen.
function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- How many jobs the list holds, and how many still run.
function M.count()
  return #jobs, active_count()
end

--- The colours the window applies, as { line, col, hl }. For the tests.
function M.highlights()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return {}
  end
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    table.insert(out, { line = m[2], col = m[3], hl = m[4].hl_group })
  end
  return out
end

--- True when any line carries this highlight group.
function M.has_highlight(group)
  for _, h in ipairs(M.highlights()) do
    if h.hl == group then
      return true
    end
  end
  return false
end

--- The text on the window border. For the tests.
function M.title()
  return border_title()
end

--- What the window shows. The tests read this.
function M.lines()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

return M
