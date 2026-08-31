-- The headless Claude engine Flow runs its background work on.
--
-- claude.oneshot does the same thing for a one-off edit: it lets Claude change
-- the file and then reloads the buffer. Flow never wants that. A Flow job
-- reads the repository and hands back text, and Flow decides what to do with
-- it. So the stream parsing is shared in spirit, not in code.
--
-- Progress shows in the window in the top right, the same one oneshot uses.

local M = {}

local uv = vim.uv or vim.loop
local hud = require("claude.hud")

M.opts = {
  command = "claude", -- the tests replace M.spawn instead
  model = "opus",
  timeout_ms = 900000, -- planning a real change takes a while
  max_concurrent = 4,
}

-- Every job in flight, keyed by its window job id.
M.jobs = {}

function M.count()
  return vim.tbl_count(M.jobs)
end

function M.is_running()
  return M.count() > 0
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Flow" })
end

--- Streaming -----------------------------------------------------------------

--- A one-line description of a tool call, for the window.
local function tool_detail(input)
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
--- The shapes differ between CLI versions. Read defensively and ignore
--- anything unknown. A stream we cannot parse must never break the run.
local function on_event(job_id, event)
  if type(event) ~= "table" then
    return
  end

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
        hud.tool(job_id, block.name, tool_detail(block.input))
      end
    end
    return
  end

  if event.type == "assistant" and type(event.message) == "table" then
    for _, block in ipairs(event.message.content or {}) do
      if type(block) == "table" and block.type == "tool_use" then
        hud.tool(job_id, block.name, tool_detail(block.input))
      end
    end
    return
  end

  local job = M.jobs[job_id]
  if event.type == "system" and event.subtype == "init" and job then
    job.session_id = event.session_id
    return
  end

  if event.type == "result" and job then
    job.result = event.result
    job.session_id = event.session_id or job.session_id
    job.cost = event.total_cost_usd
    job.is_error = event.is_error
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

--- Result text ---------------------------------------------------------------

--- Take the JSON out of a reply, whether or not it came in a fence.
--- Claude often wraps structured output in ```json even when asked not to.
---@return table|nil
function M.decode_result(text)
  if type(text) ~= "string" then
    return nil
  end
  local body = text:match("```json%s*\n(.-)\n?```") or text:match("```%s*\n(.-)\n?```") or text
  local ok, data = pcall(vim.json.decode, vim.trim(body))
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

--- Take the markdown document out of a reply.
--- The contract asks for bare markdown, but a fence is a common slip.
---@return string
function M.decode_markdown(text)
  if type(text) ~= "string" then
    return ""
  end
  local fenced = text:match("^%s*```%a*%s*\n(.*)\n?```%s*$")
  return vim.trim(fenced or text)
end

--- Running -------------------------------------------------------------------

--- The one call that reaches the outside world. The tests replace it.
---@param cmd string[]
---@param opts table for vim.system
---@param on_exit function
function M.spawn(cmd, opts, on_exit)
  return vim.system(cmd, opts, on_exit)
end

--- Build the argument list for one job.
function M.command(spec)
  local cmd = {
    M.opts.command,
    "-p",
    spec.prompt,
    "--output-format",
    "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--model",
    spec.model or M.opts.model,
    "--permission-mode",
    spec.permission_mode or "plan",
    "--tools",
    spec.tools or "Read,Grep,Glob",
    -- A background job has nobody to answer a question, so take the tool away.
    "--disallowedTools",
    "AskUserQuestion",
    "--no-session-persistence",
  }
  if spec.max_turns then
    vim.list_extend(cmd, { "--max-turns", tostring(spec.max_turns) })
  end
  if spec.append_system_prompt then
    vim.list_extend(cmd, { "--append-system-prompt", spec.append_system_prompt })
  end
  if spec.json_schema then
    local ok, encoded = pcall(vim.json.encode, spec.json_schema)
    if ok then
      vim.list_extend(cmd, { "--json-schema", encoded })
    end
  end
  return cmd
end

--- Run one background session.
---@param spec table {
---   prompt: string,
---   title: string|nil,           shown in the window
---   model, tools, permission_mode, max_turns, append_system_prompt,
---   json_schema: table|nil,      ask for structured output
---   cwd: string|nil,
---   on_done: function|nil,       (ok, result_text, info)
--- }
---@return number|nil job_id
function M.run(spec)
  if type(spec) ~= "table" or type(spec.prompt) ~= "string" or vim.trim(spec.prompt) == "" then
    notify("Nothing to ask.", vim.log.levels.WARN)
    return nil
  end
  if M.count() >= M.opts.max_concurrent then
    notify(
      string.format("%d jobs already running. Wait for one to finish.", M.opts.max_concurrent),
      vim.log.levels.WARN
    )
    return nil
  end

  local env = vim.tbl_extend("force", {}, uv.os_environ())
  -- This session must not drive the editor. The follow hook checks this.
  env.CLAUDE_NVIM_FOLLOW_DISABLE = "1"

  local job_id = hud.start(spec.title or "Flow")
  M.jobs[job_id] = { title = spec.title, started = uv.now() }
  pcall(vim.cmd, "redrawstatus")

  local buffer = ""
  local stderr = {}

  local function finish(ok, text, detail)
    local job = M.jobs[job_id] or {}
    M.jobs[job_id] = nil
    pcall(vim.cmd, "redrawstatus")

    if ok then
      hud.finish(job_id, true, text)
    else
      hud.finish(job_id, false, tostring(detail):sub(1, 300))
      notify("The job failed: " .. tostring(detail):sub(1, 200), vim.log.levels.ERROR)
    end
    if spec.on_done then
      pcall(spec.on_done, ok, text, {
        session_id = job.session_id,
        cost = job.cost,
        detail = detail,
      })
    end
  end

  local proc = M.spawn(M.command(spec), {
    cwd = spec.cwd or vim.fn.getcwd(),
    env = env,
    text = true,
    timeout = spec.timeout_ms or M.opts.timeout_ms,
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
      -- Anything left with no trailing newline.
      if vim.trim(buffer) ~= "" then
        local ok, decoded = pcall(vim.json.decode, vim.trim(buffer))
        if ok then
          on_event(job_id, decoded)
        end
      end

      local job = M.jobs[job_id] or {}
      if out.code ~= 0 then
        local detail = table.concat(stderr, ""):gsub("%s+$", "")
        if detail == "" then
          detail = "exit " .. tostring(out.code)
        end
        return finish(false, nil, detail)
      end
      if job.is_error or not job.result or vim.trim(job.result) == "" then
        return finish(false, nil, job.result or "the session returned nothing")
      end
      finish(true, job.result, nil)
    end)
  end)

  -- Held so VimLeavePre can stop it. A `claude -p` run outlives its parent
  -- otherwise, and keeps spending after you quit.
  if M.jobs[job_id] then
    M.jobs[job_id].proc = proc
  end

  return job_id
end

--- Stop every job in flight. Neovim leaving calls this.
function M.stop_all()
  for id, job in pairs(M.jobs) do
    if job.proc then
      pcall(function()
        job.proc:kill("sigterm")
      end)
    end
    M.jobs[id] = nil
  end
end

return M
