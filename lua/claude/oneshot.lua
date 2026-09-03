-- One-shot Claude sessions.
--
-- A short headless `claude -p` run, separate from the Claude in your split.
-- It streams its progress into the window in the bottom right, edits the file,
-- and exits. Your main conversation never sees it.
--
-- claude.fixit and claude.ask both drive this.

local M = {}

local uv = vim.uv or vim.loop
local hud = require("claude.hud")
local sessions = require("claude.sessions")

M.opts = {
  command = "claude", -- overridden in the tests by a mock
  max_turns = 12,
  timeout_ms = 180000,
  tools = "Read,Edit,Grep,Glob",
  max_concurrent = 4, -- several one-offs may run at once, but not unbounded
}

-- Every session in flight, keyed by its window job id.
M.jobs = {}
M.last_result = nil

--- How many sessions are running.
function M.count()
  return vim.tbl_count(M.jobs)
end

--- True while at least one session runs. Kept for the statusline and callers
--- that only care whether anything is in flight.
function M.is_running()
  return M.count() > 0
end

--- Statusline fragment. Empty unless a session is in flight.
function M.statusline()
  local n = M.count()
  if n == 0 then
    return ""
  end
  return n == 1 and "󰁨 claude" or string.format("󰁨 claude ×%d", n)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Claude" })
end

--- Streaming -----------------------------------------------------------------

--- A one-line description of a tool call, for the window.
local function tool_detail(name, input)
  if type(input) ~= "table" then
    return nil
  end
  if input.file_path then
    return vim.fn.fnamemodify(input.file_path, ":t")
  end
  if input.pattern then
    return input.pattern
  end
  if input.command then
    return tostring(input.command):sub(1, 40)
  end
  return nil
end

--- Handle one decoded stream-json event.
--- The shapes differ between CLI versions, so read defensively and ignore
--- anything unknown. A stream we cannot parse must never break the run.
local function on_event(job_id, event)
  if type(event) ~= "table" then
    return
  end

  -- Partial deltas, when --include-partial-messages is on.
  if event.type == "stream_event" and type(event.event) == "table" then
    local inner = event.event
    local delta = inner.delta
    if inner.type == "content_block_delta" and type(delta) == "table" then
      if delta.type == "thinking_delta" and delta.thinking then
        hud.append(job_id, delta.thinking)
      elseif delta.text then
        hud.append(job_id, delta.text)
      end
    elseif inner.type == "content_block_start" and type(inner.content_block) == "table" then
      local block = inner.content_block
      if block.type == "tool_use" then
        hud.tool(job_id, block.name, tool_detail(block.name, block.input))
      end
    end
    return
  end

  -- Whole assistant messages.
  if event.type == "assistant" and type(event.message) == "table" then
    for _, block in ipairs(event.message.content or {}) do
      if type(block) == "table" then
        if block.type == "tool_use" then
          hud.tool(job_id, block.name, tool_detail(block.name, block.input))
        elseif block.type == "thinking" and block.thinking then
          hud.append(job_id, block.thinking)
        end
      end
    end
    return
  end

  if event.type == "system" and event.subtype == "init" then
    local job = M.jobs[job_id]
    if job and event.session_id then
      job.session_id = event.session_id
      hud.update(job_id, { session_id = event.session_id })
    end
    return
  end

  if event.type == "result" then
    local job = M.jobs[job_id]
    if job then
      job.result = event.result
      job.session_id = event.session_id or job.session_id
      hud.update(job_id, { session_id = job.session_id })
      if job.proc and job.proc.write then
        pcall(job.proc.write, job.proc, nil)
      else
        job.close_input = true
      end
    end
    M.last_result = event.result
  end
end

--- Split a stdout chunk into whole NDJSON lines. Returns the leftover.
local function consume(job_id, buffer, chunk)
  buffer = buffer .. chunk
  local last_break = buffer:find("\n[^\n]*$")
  if not last_break then
    return buffer
  end
  local whole = buffer:sub(1, last_break - 1)
  for _, line in ipairs(vim.split(whole, "\n", { plain = true })) do
    if vim.trim(line) ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok then
        on_event(job_id, decoded)
      end
    end
  end
  return buffer:sub(last_break + 1)
end

--- Running -------------------------------------------------------------------

--- Run a one-shot session.
---@param spec table {
---   prompt: string,
---   title: string|nil,      shown in the window
---   bufnr: number|nil,      the buffer to reload and highlight when it ends
---   tools: string|nil,      overrides M.opts.tools
---   on_done: function|nil,  called with (ok, summary)
--- }
function M.run(spec)
  if type(spec) ~= "table" or type(spec.prompt) ~= "string" or spec.prompt == "" then
    notify("Nothing to ask.", vim.log.levels.WARN)
    return nil
  end
  if M.count() >= M.opts.max_concurrent then
    notify(string.format("%d sessions already running. Wait for one to finish.",
      M.opts.max_concurrent), vim.log.levels.WARN)
    return nil
  end

  local bufnr = spec.bufnr
  local before = nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    -- Claude reads the file from disk, so unsaved edits must land first.
    if vim.bo[bufnr].modified and vim.bo[bufnr].buftype == "" then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent write")
      end)
    end
    before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local session_id = spec.session_id or sessions.uuid(spec.title or spec.prompt:sub(1, 40))
  local cwd = spec.cwd or vim.fn.getcwd()
  local tools = spec.tools or M.opts.tools
  local cmd = {
    M.opts.command,
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--permission-mode", "acceptEdits",
    "--allowedTools", tools,
    "--max-turns", tostring(M.opts.max_turns),
    "--session-id", session_id,
    "--name", spec.title or "Claude one-shot",
  }

  local env = vim.tbl_extend("force", {}, uv.os_environ())
  -- This session must not drive the editor. The follow hook checks this.
  env.CLAUDE_NVIM_FOLLOW_DISABLE = "1"

  local job_id = hud.start(spec.title or "Claude", {
    kind = spec.kind or "one-shot",
    prompt = spec.prompt,
    cwd = cwd,
    session_id = session_id,
    resume_args = { "--permission-mode", "acceptEdits", "--allowedTools", tools },
  })
  M.jobs[job_id] = {
    title = spec.title,
    bufnr = bufnr,
    before = before,
    started = (uv.now()),
    session_id = session_id,
  }
  pcall(vim.cmd, "redrawstatus")

  local buffer = ""
  local stderr = {}

  local proc = vim.system(cmd, {
    cwd = cwd,
    env = env,
    text = true,
    stdin = true,
    timeout = M.opts.timeout_ms,
    stdout = function(err, chunk)
      if err or not chunk then
        return
      end
      vim.schedule(function()
        buffer = consume(job_id, buffer, chunk)
      end)
    end,
    stderr = function(err, chunk)
      if not err and chunk then
        table.insert(stderr, chunk)
      end
    end,
  }, function(out)
    vim.schedule(function()
      if vim.trim(buffer) ~= "" then
        local decoded_ok, decoded = pcall(vim.json.decode, vim.trim(buffer))
        if decoded_ok then
          on_event(job_id, decoded)
        end
      end

      local job = M.jobs[job_id]
      local summary = job and job.result or nil
      M.jobs[job_id] = nil
      pcall(vim.cmd, "redrawstatus")

      if out.code ~= 0 then
        local detail = table.concat(stderr, ""):gsub("%s+$", "")
        if detail == "" then
          detail = "exit " .. tostring(out.code)
        end
        M.last_result = detail
        hud.finish(job_id, false, detail:sub(1, 300))
        notify("The session failed: " .. detail:sub(1, 200), vim.log.levels.ERROR)
        if spec.on_done then
          spec.on_done(false, detail)
        end
        return
      end

      M.last_result = summary
      M.apply(bufnr, before, spec.title)
      hud.finish(job_id, true, summary)
      if spec.on_done then
        spec.on_done(true, summary)
      end
    end)
  end)

  if M.jobs[job_id] then
    M.jobs[job_id].proc = proc
    if M.jobs[job_id].close_input and proc and proc.write then
      pcall(proc.write, proc, nil)
    else
      M.write(proc, spec.prompt)
      hud.update(job_id, {
        send = function(text)
          local running = M.jobs[job_id]
          return running ~= nil and M.write(running.proc, text)
        end,
      })
    end
  end

  return job_id
end

function M.write(proc, prompt)
  if not proc or not proc.write or type(prompt) ~= "string" or vim.trim(prompt) == "" then
    return false
  end
  local ok, encoded = pcall(vim.json.encode, {
    type = "user",
    message = {
      role = "user",
      content = { { type = "text", text = prompt } },
    },
  })
  if not ok then
    return false
  end
  return pcall(proc.write, proc, encoded .. "\n")
end

--- Which lines differ between two versions of a file.
--- Returns the first and last changed line in `after`, or nil when equal.
function M.changed_range(before, after)
  local top = 1
  while top <= #before and top <= #after and before[top] == after[top] do
    top = top + 1
  end
  if top > #before and top > #after then
    return nil
  end

  local b, a = #before, #after
  while b >= top and a >= top and before[b] == after[a] do
    b, a = b - 1, a - 1
  end
  return top, math.max(top, a)
end

--- Reload the buffer and highlight what changed.
function M.apply(bufnr, before, label)
  if not (bufnr and before and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent! checktime")
    vim.cmd("silent! edit")
  end)

  local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first, last = M.changed_range(before, after)
  if not first then
    notify((label and (label .. ": ") or "") .. "Claude changed nothing.", vim.log.levels.WARN)
    return
  end

  -- Reuse follow mode's change marks, so this looks like any other edit.
  local ok, follow = pcall(require, "claude.follow")
  if ok and follow.mark then
    follow.mark(vim.api.nvim_buf_get_name(bufnr), {
      table.concat(vim.list_slice(after, first, last), "\n"),
    })
  end

  vim.schedule(function()
    local left = #vim.diagnostic.get(bufnr, { severity = { min = vim.diagnostic.severity.WARN } })
    notify(string.format("%sChanged line %d. %d diagnostics left in this file.",
      label and (label .. ": ") or "", first, left))
  end)
end

return M
