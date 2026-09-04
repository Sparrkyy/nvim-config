local M = {}

local uv = vim.uv or vim.loop
local tmux = require("claude.tmux")

M.opts = {
  archive_ms = 60 * 60 * 1000,
  panel_width = 54,
  command = "claude",
  state_path = vim.fn.stdpath("state") .. "/claude/sessions.json",
}
M.tmux = tmux

local records = {}
local by_id = {}
local by_buf = {}
local next_id = 0
local manager = { picker = nil, prompt_bufnr = nil, preview_win = nil, refresh_pending = false }
local timer = nil
local managed_terminal_environment
local restoring = false
local hydrated = false

local function now()
  return os.time() * 1000
end

local function present(value)
  return value ~= nil and value ~= vim.NIL and value ~= ""
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Claude sessions" })
end

local function elapsed(milliseconds)
  local seconds = math.max(0, math.floor(milliseconds / 1000))
  if seconds < 60 then
    return seconds .. "s"
  end
  if seconds < 3600 then
    return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
  end
  return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

local function short_cwd(cwd)
  if not present(cwd) then
    return ""
  end
  return vim.fn.fnamemodify(cwd, ":~")
end

local function fit(text, width)
  text = tostring(text or ""):gsub("%s+", " ")
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

local function status_of(record)
  if record.status == "failed" then
    return "✗", "failed"
  end
  if record.status == "finished" then
    return "✓", "finished"
  end
  if record.status == "saved" then
    return "○", "saved"
  end
  if record.detached then
    return "◌", "detached"
  end
  return "●", "running"
end

local persisted_fields = {
  "id",
  "key",
  "title",
  "kind",
  "prompt",
  "prompts",
  "cwd",
  "session_id",
  "resume_args",
  "started",
  "status",
  "finished_at",
  "activity",
  "result",
  "persistent",
  "pinned",
  "tmux_name",
  "auto_title",
  "env_overrides",
}

local function persistent_record(record)
  return record.persistent == true or record.pinned == true
end

local function flow_record(record)
  return type(record.kind) == "string" and record.kind:match("^Flow ") ~= nil
end

local function serializable_record(record)
  local saved = {}
  for _, field in ipairs(persisted_fields) do
    if record[field] ~= nil then
      saved[field] = record[field]
    end
  end
  return saved
end

function M.save_state()
  if restoring or not present(M.opts.state_path) then
    return false
  end
  local saved = {}
  for _, record in ipairs(records) do
    if persistent_record(record) then
      table.insert(saved, serializable_record(record))
    end
  end
  local path = M.opts.state_path
  if #saved == 0 then
    if vim.fn.filereadable(path) == 1 then
      pcall(vim.fn.delete, path)
    end
    return true
  end
  local directory = vim.fn.fnamemodify(path, ":h")
  if vim.fn.mkdir(directory, "p") == 0 and vim.fn.isdirectory(directory) ~= 1 then
    return false
  end
  local temporary = path .. ".tmp." .. tostring(vim.fn.getpid())
  local ok, result = pcall(vim.fn.writefile, { vim.json.encode({ version = 1, next_id = next_id, records = saved }) }, temporary, "b")
  if not ok or result == -1 then
    return false
  end
  local renamed = uv.fs_rename(temporary, path)
  if not renamed then
    pcall(vim.fn.delete, temporary)
    return false
  end
  return true
end

local function stop_timer()
  if not timer then
    return
  end
  pcall(function()
    timer:stop()
    timer:close()
  end)
  timer = nil
end

local function remove(id)
  local record = by_id[id]
  if not record then
    return
  end
  if record.buf then
    by_buf[record.buf] = nil
  end
  by_id[id] = nil
  for index, item in ipairs(records) do
    if item.id == id then
      table.remove(records, index)
      break
    end
  end
  M.save_state()
end

function M.reap(at)
  at = at or now()
  local expired = {}
  for _, record in ipairs(records) do
    if not record.pinned and record.finished_at and at - record.finished_at >= M.opts.archive_ms then
      table.insert(expired, record.id)
    end
  end
  for _, id in ipairs(expired) do
    remove(id)
  end
  return #expired
end

local function ensure_timer()
  if timer then
    return
  end
  timer = uv.new_timer()
  if not timer then
    return
  end
  timer:start(30000, 30000, vim.schedule_wrap(function()
    M.reap()
    M.render()
    if #records == 0 then
      stop_timer()
    end
  end))
end

function M.panel_lines()
  M.reap()
  local lines = { "Claude sessions", "" }
  local ids = { false, false }
  local running = 0
  local pinned = 0
  for _, record in ipairs(records) do
    if record.status == "running" then
      running = running + 1
    end
    if record.pinned then
      pinned = pinned + 1
    end
  end
  lines[2] = string.format("%d running · %d pinned · %d recent", running, pinned, #records - running)

  for index = #records, 1, -1 do
    local record = records[index]
    local icon, status = status_of(record)
    local stamp = record.finished_at or now()
    local duration = elapsed(stamp - record.started)
    local pin = record.pinned and "◆" or " "
    table.insert(lines, string.format("%s%s %3d  %s", icon, pin, record.id, fit(record.title, M.opts.panel_width - 11)))
    table.insert(ids, record.id)
    local detail_text = string.format("      %s · %s", status, duration)
    if present(record.kind) then
      detail_text = detail_text .. " · " .. record.kind
    end
    table.insert(lines, fit(detail_text, M.opts.panel_width))
    table.insert(ids, record.id)
    if present(record.cwd) then
      table.insert(lines, fit("      " .. short_cwd(record.cwd), M.opts.panel_width))
      table.insert(ids, record.id)
    end
    table.insert(lines, "")
    table.insert(ids, record.id)
  end

  if #records == 0 then
    table.insert(lines, "No active or recent sessions.")
    table.insert(ids, false)
    table.insert(lines, "")
    table.insert(ids, false)
  end
  table.insert(lines, "<CR> open · v inspect · i steer · d forget · q close")
  table.insert(ids, false)
  return lines, ids
end

function M.detail_lines(record)
  if type(record) == "number" then
    record = by_id[record]
  end
  if not record then
    return { "No session selected." }
  end
  local icon, status = status_of(record)
  local stamp = record.finished_at or now()
  local duration = elapsed(stamp - record.started)
  local lines = {
    "# " .. record.title,
    "",
    string.format("**%s %s** · `%s` · %s", icon, status:gsub("^%l", string.upper), record.kind or "Claude", duration),
  }
  if record.pinned then
    table.insert(lines, "Retention: `Pinned`")
  elseif record.persistent then
    table.insert(lines, "Retention: `Scratch`")
  end
  if present(record.cwd) then
    table.insert(lines, "Directory: `" .. short_cwd(record.cwd) .. "`")
  end
  if present(record.session_id) then
    table.insert(lines, "Session: `" .. record.session_id .. "`")
  end
  if present(record.tmux_name) then
    table.insert(lines, "Runtime: `tmux -L " .. M.tmux.socket .. " · " .. record.tmux_name .. "`")
  end
  if record.ide_reconnect == "pending" then
    table.insert(lines, "IDE: **Reconnecting…**")
  elseif record.ide_reconnect then
    table.insert(lines, "IDE: **Reconnect required** · press `R`")
  end
  if #(record.activity or {}) > 0 then
    table.insert(lines, "")
    table.insert(lines, "### Recent activity")
    table.insert(lines, "")
    local first = math.max(1, #record.activity - 4)
    for index = first, #record.activity do
      table.insert(lines, "- " .. record.activity[index])
    end
  end
  local prompts = record.prompts or {}
  local latest_prompt = prompts[#prompts]
  if present(latest_prompt) then
    local summary = vim.trim(latest_prompt):match("[^\r\n]+") or ""
    summary = fit(summary, 110)
    if #latest_prompt > #summary then
      summary = summary .. string.format(" · %s chars", tostring(#latest_prompt))
    end
    table.insert(lines, "")
    table.insert(lines, "### Current request")
    table.insert(lines, "")
    table.insert(lines, summary)
  end
  table.insert(lines, "")
  if record.status == "running" and (record.send or record.channel) then
    table.insert(lines, "Type below and press `<CR>` to guide this agent.")
  elseif present(record.session_id) then
    table.insert(lines, "Type below and press `<CR>` to resume this session.")
  end
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "## Claude · latest response")
  table.insert(lines, "")
  local output = record.result or record.transcript
  if not present(output) then
    output = "_Waiting for Claude…_"
  end
  vim.list_extend(lines, vim.split(tostring(output), "\n", { plain = true }))
  return lines
end

function M.preview_lines(record)
  if type(record) == "number" then
    record = by_id[record]
  end
  if not record then
    return { "No agent selected." }
  end
  if record.channel and record.buf and vim.api.nvim_buf_is_valid(record.buf) then
    local count = vim.api.nvim_buf_line_count(record.buf)
    local lines = vim.api.nvim_buf_get_lines(record.buf, math.max(0, count - 500), -1, false)
    if #lines > 1 or (#lines == 1 and lines[1] ~= "") then
      return lines
    end
    return { "Claude terminal is starting." }
  end
  return M.detail_lines(record)
end

function M.focus_latest(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    return false
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return false
  end
  local last = math.max(1, vim.api.nvim_buf_line_count(buf))
  if not pcall(vim.api.nvim_win_set_cursor, win, { last, 0 }) then
    return false
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zb")
  end)
  return true
end

function M.manager_records()
  M.reap()
  local ordered = {}
  for index = #records, 1, -1 do
    local record = records[index]
    local terminal = record.channel and record.buf and vim.api.nvim_buf_is_valid(record.buf)
    local persistent_tui = persistent_record(record) and present(record.tmux_name)
    local resumable_tui = record.status ~= "running" and present(record.session_id)
    if terminal or persistent_tui or resumable_tui then
      table.insert(ordered, record)
    end
  end
  table.sort(ordered, function(left, right)
    local left_running = left.status == "running"
    local right_running = right.status == "running"
    if left_running ~= right_running then
      return left_running
    end
    if left.pinned ~= right.pinned then
      return left.pinned == true
    end
    local left_stamp = left.finished_at or left.started
    local right_stamp = right.finished_at or right.started
    if left_stamp ~= right_stamp then
      return left_stamp > right_stamp
    end
    return left.id > right.id
  end)
  return ordered
end

function M.search_text(record)
  local function excerpt(value, limit)
    value = tostring(value or "")
    if #value <= limit then
      return value
    end
    local half = math.floor(limit / 2)
    return value:sub(1, half) .. " " .. value:sub(-half)
  end
  local prompts = {}
  for _, prompt in ipairs(record.prompts or {}) do
    table.insert(prompts, excerpt(prompt, 2000))
  end
  local candidates = {
    record.title,
    record.kind,
    record.cwd,
    record.status,
    excerpt(table.concat(prompts, " "), 6000),
    excerpt(table.concat(record.activity or {}, " "), 2000),
    excerpt(record.result, 4000),
    excerpt(record.transcript, 4000),
  }
  local values = {}
  for index = 1, 8 do
    if present(candidates[index]) then
      table.insert(values, candidates[index])
    end
  end
  return table.concat(values, " ")
end

local function manager_is_open()
  return manager.prompt_bufnr ~= nil and vim.api.nvim_buf_is_valid(manager.prompt_bufnr)
end

local function manager_finder(finders)
  return finders.new_table({
    results = M.manager_records(),
    entry_maker = function(record)
      local icon = status_of(record)
      local pin = record.pinned and "◆" or " "
      local stamp = record.finished_at or now()
      local duration = elapsed(stamp - record.started)
      return {
        value = record,
        ordinal = M.search_text(record),
        display = function()
          return string.format(
            "%s%s #%-3d  %-9s  %-16s  %s",
            icon,
            pin,
            record.id,
            duration,
            fit(record.kind or "Claude", 16),
            record.title
          )
        end,
      }
    end,
  })
end

local function refresh_manager()
  if not manager_is_open() or not manager.picker then
    return
  end
  local ok_finders, finders = pcall(require, "telescope.finders")
  if ok_finders then
    manager.picker:refresh(manager_finder(finders), { reset_prompt = false })
  end
end

local function schedule_manager_refresh()
  if manager.refresh_pending or not manager_is_open() then
    return
  end
  manager.refresh_pending = true
  vim.schedule(function()
    manager.refresh_pending = false
    refresh_manager()
  end)
end

function M.render()
  schedule_manager_refresh()
end

function M.spawn_terminal(cmd, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].claude_session_registry_id = opts.id
  local channel
  vim.api.nvim_buf_call(buf, function()
    channel = vim.fn.termopen(cmd, {
      cwd = opts.cwd,
      env = opts.env,
      on_exit = function(_, code)
        vim.schedule(function()
          opts.on_exit(code)
        end)
      end,
    })
  end)
  if channel <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil
  end
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "claude-session"
  return { buf = buf, channel = channel }
end

local function tmux_metadata(record)
  return {
    key = record.key,
    title = record.title,
    kind = record.kind,
    cwd = record.cwd,
    session_id = record.session_id,
    resume_args = record.resume_args,
    started = record.started,
    pinned = record.pinned == true,
    auto_title = record.auto_title == true,
    env_overrides = record.env_overrides,
  }
end

local function terminal_environment(record, overrides)
  local env = managed_terminal_environment()
  for key, value in pairs(record.env_overrides or {}) do
    env[key] = value
  end
  for key, value in pairs(overrides or {}) do
    env[key] = value
  end
  return env
end

local function bind_terminal(record, terminal)
  record.buf = terminal.buf
  record.channel = terminal.channel
  record.status = "running"
  record.finished_at = nil
  record.detached = false
  by_buf[terminal.buf] = record.id
  vim.b[terminal.buf].claude_session_registry_id = record.id
end

function M.terminal_client_closed(id, buf, code)
  local record = by_id[id]
  if not record then
    return
  end
  if buf and record.buf ~= buf and by_buf[buf] ~= id then
    return
  end
  if buf then
    by_buf[buf] = nil
  end
  if record.buf == buf then
    record.buf = nil
    record.channel = nil
  end
  if record.stopping then
    record.stopping = nil
    M.save_state()
    return
  end
  if present(record.tmux_name) and M.tmux.has(record.tmux_name) then
    record.status = "running"
    record.detached = true
    record.ide_reconnect = true
    M.save_state()
    M.render()
    return
  end
  M.finish(id, code == 0, record.result)
end

function M.launch_terminal(record, claude_cmd, opts)
  opts = opts or {}
  local env = terminal_environment(record, opts.env)
  local launch_cmd = claude_cmd
  local used_tmux = record.persistent and M.tmux.available()
  local existing = false
  if used_tmux then
    record.tmux_name = record.tmux_name or M.tmux.name(record.key)
    existing = M.tmux.has(record.tmux_name)
    if existing then
      launch_cmd = M.tmux.attach_command(record.tmux_name)
    else
      if not claude_cmd then
        return nil
      end
      launch_cmd = M.tmux.create_command(record.tmux_name, record.cwd, env, claude_cmd)
    end
  elseif not launch_cmd then
    return nil
  end

  local terminal
  terminal = M.spawn_terminal(launch_cmd, {
    id = record.id,
    cwd = record.cwd,
    env = env,
    on_exit = function(code)
      M.terminal_client_closed(record.id, terminal and terminal.buf, code)
    end,
  })
  if not terminal then
    return nil
  end
  bind_terminal(record, terminal)
  if used_tmux then
    record.ide_reconnect = existing
    M.tmux.configure(record.tmux_name, tmux_metadata(record))
  else
    record.ide_reconnect = false
  end
  M.save_state()
  return terminal
end

function M.attach(id)
  local record = by_id[id]
  if not record or record.status ~= "running" or not present(record.tmux_name) then
    return false
  end
  if record.channel and record.buf and vim.api.nvim_buf_is_valid(record.buf) then
    return true
  end
  if not M.tmux.has(record.tmux_name) then
    record.status = present(record.session_id) and "saved" or "failed"
    record.finished_at = now()
    M.save_state()
    M.render()
    return false
  end
  return M.launch_terminal(record, nil) ~= nil
end

local function resume(record, prompt, opts)
  opts = opts or {}
  if not present(record.session_id) then
    return opts.show_manager == false or M.show_manager({ selected_id = record.id })
  end
  record.persistent = true
  record.tmux_name = record.tmux_name or M.tmux.name(record.key)
  local cmd = { M.opts.command, "--resume", record.session_id, "--name", record.title, "--ide" }
  vim.list_extend(cmd, record.resume_args or {})
  if present(prompt) then
    table.insert(cmd, prompt)
  end
  local terminal = M.launch_terminal(record, cmd)
  if not terminal then
    notify("Claude Code did not start.", vim.log.levels.ERROR)
    return false
  end
  table.insert(record.activity, "Resumed in Claude Code")
  if present(prompt) then
    table.insert(record.prompts, prompt)
  end
  M.save_state()
  M.render()
  if opts.show_manager ~= false then
    M.show_manager({ selected_id = record.id })
  end
  return true
end

function M.ensure_tui(id)
  local record = by_id[id]
  if not record then
    return false
  end
  if record.channel and record.buf and vim.api.nvim_buf_is_valid(record.buf) then
    return true
  end
  if record.status == "running" and present(record.tmux_name) and M.tmux.has(record.tmux_name) then
    return M.attach(id)
  end
  if record.status == "running" or not present(record.session_id) then
    return false
  end
  return resume(record, nil, { show_manager = false })
end

function M.open(id)
  M.upgrade_legacy_flow_records()
  local record = by_id[id]
  if not record then
    return false
  end
  if record.status ~= "running" and present(record.session_id) then
    return resume(record)
  end
  return M.show_manager({ selected_id = id })
end

function M.send_channel(channel, text)
  if not channel or channel <= 0 then
    return false
  end
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local payload = normalized
  if normalized:find("\n", 1, true) then
    payload = "\27[200~" .. normalized .. "\27[201~"
  end
  local pasted, written = pcall(vim.fn.chansend, channel, payload)
  if not pasted or written == 0 then
    return false
  end
  vim.defer_fn(function()
    pcall(vim.fn.chansend, channel, "\r")
  end, 100)
  return true
end

local function send_terminal(record, text)
  return M.send_channel(record.channel, text)
end

function M.send(id, text)
  local record = by_id[id]
  if not record or type(text) ~= "string" or vim.trim(text) == "" then
    return false
  end
  if record.status == "running" and not record.channel and present(record.tmux_name) then
    M.attach(id)
  end
  local ok = false
  if record.status == "running" and record.send then
    ok = record.send(text) == true
  elseif record.status == "running" and record.channel then
    ok = send_terminal(record, text)
  elseif present(record.session_id) then
    return resume(record, text)
  end
  if ok then
    table.insert(record.prompts, text)
    table.insert(record.activity, "You sent guidance")
    if record.auto_title then
      local title = vim.trim(text):match("[^\r\n]+") or record.title
      record.title = fit(title, 56)
      record.auto_title = false
      if present(record.tmux_name) then
        M.tmux.configure(record.tmux_name, tmux_metadata(record))
      end
    end
    M.save_state()
    M.render()
  end
  return ok
end

function M.steer(id)
  local record = by_id[id]
  if not record then
    return false
  end
  require("claude.input").open({ title = "Steer: " .. record.title }, function(text)
    if text and not M.send(id, text) then
      notify("This session cannot accept input.", vim.log.levels.WARN)
    end
  end)
  return true
end

function M.start(spec)
  if type(spec) == "string" then
    spec = { title = spec }
  end
  spec = spec or {}
  next_id = next_id + 1
  local record = {
    id = next_id,
    key = spec.key or M.uuid(spec.title),
    title = spec.title or "Claude",
    kind = spec.kind,
    prompt = spec.prompt,
    prompts = present(spec.prompt) and { spec.prompt } or {},
    cwd = spec.cwd or vim.fn.getcwd(),
    session_id = spec.session_id,
    resume_args = spec.resume_args or {},
    started = now(),
    status = spec.status or "running",
    activity = {},
    transcript = "",
    send = spec.send,
    buf = spec.buf,
    channel = spec.channel,
    persistent = spec.persistent == true,
    pinned = spec.pinned == true,
    tmux_name = spec.tmux_name,
    auto_title = spec.auto_title == true,
    ide_reconnect = spec.ide_reconnect == true,
    env_overrides = spec.env_overrides or {},
  }
  table.insert(records, record)
  by_id[record.id] = record
  if record.buf then
    by_buf[record.buf] = record.id
    vim.b[record.buf].claude_session_registry_id = record.id
  end
  ensure_timer()
  M.save_state()
  M.render()
  return record.id
end

managed_terminal_environment = function()
  local env = {
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
    CLAUDE_CODE_TMUX_TRUECOLOR = "1",
  }
  local ok, claudecode = pcall(require, "claudecode")
  if ok and claudecode.state then
    if not claudecode.state.server and type(claudecode.start) == "function" then
      pcall(claudecode.start, false)
    end
    if claudecode.state.port then
      env.CLAUDE_CODE_SSE_PORT = tostring(claudecode.state.port)
    end
    local configured = claudecode.state.config and claudecode.state.config.env or {}
    for key, value in pairs(configured) do
      env[key] = value
    end
  end
  local bypass = {}
  for _, value in ipairs({ os.getenv("no_proxy"), os.getenv("NO_PROXY"), env.no_proxy, env.NO_PROXY }) do
    if present(value) then
      table.insert(bypass, value)
    end
  end
  vim.list_extend(bypass, { "localhost", "127.0.0.1", "::1" })
  env.no_proxy = table.concat(bypass, ",")
  env.NO_PROXY = env.no_proxy
  return env
end

function M.selection_reference(line1, line2)
  line1 = line1 or vim.fn.line("v")
  line2 = line2 or vim.fn.line(".")
  line1, line2 = math.min(line1, line2), math.max(line1, line2)
  local file = vim.fn.expand("%:.")
  if file == "" then
    return string.format("Consider lines %d-%d: ", line1, line2)
  end
  return string.format("@%s (lines %d-%d) ", file, line1, line2)
end

function M.context_reference()
  local file = vim.fn.expand("%:.")
  if file == "" or vim.bo.buftype ~= "" then
    return ""
  end
  return string.format("@%s (line %d) ", file, vim.api.nvim_win_get_cursor(0)[1])
end

function M.new_terminal_session(spec)
  spec = spec or {}
  local cwd = spec.cwd or vim.fn.getcwd()
  local project = vim.fn.fnamemodify(cwd, ":t")
  local title = spec.title or (present(project) and "Claude Code · " .. project or "Claude Code")
  local session_id
  if not spec.omit_session_id then
    session_id = spec.session_id or M.uuid(title)
  end
  local key = spec.key or session_id or M.uuid(title)
  local permission_mode = spec.permission_mode or "auto"
  local id = M.start({
    key = key,
    title = title,
    kind = spec.kind or "terminal",
    prompt = spec.prompt,
    cwd = cwd,
    session_id = session_id,
    resume_args = spec.resume_args or { "--permission-mode", permission_mode },
    persistent = spec.persistent ~= false,
    pinned = spec.pinned == true,
    tmux_name = spec.tmux_name or M.tmux.name(key),
    auto_title = spec.title == nil,
    env_overrides = spec.env_overrides or {},
  })
  local cmd = spec.cmd or { M.opts.command }
  if not spec.cmd and session_id then
    vim.list_extend(cmd, { "--session-id", session_id, "--name", title })
  end
  vim.list_extend(cmd, spec.args or {})
  if not spec.cmd then
    vim.list_extend(cmd, { "--permission-mode", permission_mode, "--ide" })
  end
  local record = by_id[id]
  local terminal = M.launch_terminal(record, cmd, {
    env = spec.env,
  })
  if not terminal then
    remove(id)
    M.render()
    notify("Claude Code did not start.", vim.log.levels.ERROR)
    return nil
  end
  M.render()
  if not M.show_manager({ default_text = spec.default_text, selected_id = id }) then
    notify("Claude started, but the Telescope manager is unavailable.", vim.log.levels.ERROR)
  end
  return id
end

function M.resume_session()
  return M.new_terminal_session({
    title = "Claude Code · Resume",
    omit_session_id = true,
    args = { "--resume" },
  })
end

function M.continue_session()
  return M.new_terminal_session({
    title = "Claude Code · Continue",
    omit_session_id = true,
    args = { "--continue" },
  })
end

function M.plan_session()
  return M.new_terminal_session({
    title = "Claude Code · Plan",
    permission_mode = "plan",
    pinned = true,
  })
end

function M.interrupt(id)
  local record = id and by_id[id]
  if not record then
    for _, candidate in ipairs(M.manager_records()) do
      if candidate.status == "running" and candidate.channel then
        record = candidate
        break
      end
    end
  end
  if not record or not record.channel or record.channel <= 0 then
    notify("No managed Claude session is running.", vim.log.levels.WARN)
    return false
  end
  local ok = pcall(vim.fn.chansend, record.channel, "\27")
  if ok then
    table.insert(record.activity, "Interrupted by you")
    M.render()
  end
  return ok
end

function M.update(id, values)
  local record = by_id[id]
  if not record then
    return false
  end
  for key, value in pairs(values or {}) do
    record[key] = value
  end
  M.save_state()
  M.render()
  return true
end

function M.append(id, chunk)
  local record = by_id[id]
  if not record or type(chunk) ~= "string" or chunk == "" then
    return
  end
  record.transcript = record.transcript .. chunk
  if #record.transcript > 100000 then
    record.transcript = record.transcript:sub(-100000)
  end
  M.render()
end

function M.tool(id, name, detail_text)
  local record = by_id[id]
  if not record or not present(name) then
    return
  end
  local text = name
  if present(detail_text) then
    text = text .. " · " .. detail_text
  end
  if record.activity[#record.activity] ~= text then
    table.insert(record.activity, text)
  end
  while #record.activity > 50 do
    table.remove(record.activity, 1)
  end
  M.save_state()
  M.render()
end

function M.finish(id, ok, result)
  local record = by_id[id]
  if not record then
    return
  end
  record.status = ok and "finished" or "failed"
  record.result = result or record.result
  record.finished_at = now()
  record.send = nil
  record.detached = false
  record.ide_reconnect = false
  M.save_state()
  M.render()
end

function M.pin(id)
  local record = by_id[id]
  if not record then
    return false
  end
  record.pinned = not record.pinned
  record.persistent = record.persistent or record.pinned
  table.insert(record.activity, record.pinned and "Pinned for long-term work" or "Changed to scratch retention")
  if present(record.tmux_name) and M.tmux.has(record.tmux_name) then
    M.tmux.configure(record.tmux_name, tmux_metadata(record))
  end
  M.save_state()
  M.render()
  return record.pinned
end

function M.rename(id, title)
  local record = by_id[id]
  title = type(title) == "string" and vim.trim(title) or ""
  if not record or title == "" then
    return false
  end
  record.title = fit(title, 80)
  record.auto_title = false
  table.insert(record.activity, "Renamed to " .. record.title)
  if present(record.tmux_name) and M.tmux.has(record.tmux_name) then
    M.tmux.configure(record.tmux_name, tmux_metadata(record))
  end
  M.save_state()
  M.render()
  return true
end

function M.stop(id)
  local record = by_id[id]
  if not record or record.status ~= "running" then
    return false
  end
  record.stopping = true
  local stopped
  if present(record.tmux_name) then
    stopped = M.tmux.kill(record.tmux_name)
  elseif record.channel then
    local ok, result = pcall(vim.fn.jobstop, record.channel)
    stopped = ok and result ~= 0
  else
    stopped = false
  end
  if not stopped then
    record.stopping = nil
    notify("The Claude session could not be stopped.", vim.log.levels.ERROR)
    return false
  end
  if record.buf then
    by_buf[record.buf] = nil
  end
  record.buf = nil
  record.channel = nil
  record.status = present(record.session_id) and "saved" or "finished"
  record.finished_at = now()
  record.detached = false
  record.ide_reconnect = false
  table.insert(record.activity, "Stopped; conversation remains resumable")
  M.save_state()
  M.render()
  return true
end

function M.reconnect_ide(id)
  local record = by_id[id]
  if not record or record.status ~= "running" then
    return false
  end
  if not record.channel and not M.attach(id) then
    return false
  end
  if not M.send_channel(record.channel, "/ide") then
    return false
  end
  record.ide_reconnect = "pending"
  table.insert(record.activity, "Requested the current Neovim IDE connection")
  M.render()
  vim.defer_fn(function()
    local current = by_id[id]
    if not current or current.ide_reconnect ~= "pending" then
      return
    end
    local ok, claudecode = pcall(require, "claudecode")
    local connected = ok and type(claudecode.is_claude_connected) == "function" and claudecode.is_claude_connected()
    current.ide_reconnect = not connected
    table.insert(current.activity, connected and "Connected to Neovim" or "Select Neovim in Claude's /ide menu")
    M.render()
  end, 1500)
  return true
end

function M.archive(id)
  local record = by_id[id]
  if not record then
    return false
  end
  if record.status == "running" then
    notify("Stop this session with <C-x> before forgetting it.", vim.log.levels.WARN)
    return false
  end
  remove(id)
  M.render()
  return true
end

function M.get(id)
  return by_id[id]
end

function M.find_by_key(key)
  if not present(key) then
    return nil
  end
  for index = #records, 1, -1 do
    if records[index].key == key then
      return records[index]
    end
  end
  return nil
end

function M.list()
  M.reap()
  return vim.deepcopy(records)
end

function M.count()
  M.reap()
  local running = 0
  for _, record in ipairs(records) do
    if record.status == "running" then
      running = running + 1
    end
  end
  return #records, running
end

local function find_persistent(saved)
  for _, record in ipairs(records) do
    if present(saved.key) and record.key == saved.key then
      return record
    end
    if present(saved.tmux_name) and record.tmux_name == saved.tmux_name then
      return record
    end
    if present(saved.session_id) and record.session_id == saved.session_id then
      return record
    end
  end
  return nil
end

local function restore_record(saved)
  local record = {}
  for _, field in ipairs(persisted_fields) do
    if saved[field] ~= nil then
      record[field] = saved[field]
    end
  end
  record.id = tonumber(record.id)
  if not record.id or by_id[record.id] then
    next_id = next_id + 1
    record.id = next_id
  else
    next_id = math.max(next_id, record.id)
  end
  record.key = record.key or record.session_id or M.uuid(record.title)
  record.title = record.title or "Recovered Claude session"
  record.kind = record.kind or "terminal"
  record.cwd = record.cwd or vim.fn.getcwd()
  record.started = tonumber(record.started) or now()
  if record.started < 1000000000000 then
    record.started = now()
  end
  record.finished_at = tonumber(record.finished_at)
  if record.finished_at and record.finished_at < 1000000000000 then
    record.finished_at = now()
  end
  record.prompts = type(record.prompts) == "table" and record.prompts or {}
  record.activity = type(record.activity) == "table" and record.activity or {}
  record.resume_args = type(record.resume_args) == "table" and record.resume_args or {}
  record.env_overrides = type(record.env_overrides) == "table" and record.env_overrides or {}
  record.persistent = true
  record.pinned = record.pinned == true
  record.status = record.status or "saved"
  record.transcript = ""
  record.buf = nil
  record.channel = nil
  record.send = nil
  record.detached = record.status == "running"
  record.ide_reconnect = record.status == "running"
  records[#records + 1] = record
  by_id[record.id] = record
  return record
end

function M.load_state()
  if not present(M.opts.state_path) or vim.fn.filereadable(M.opts.state_path) ~= 1 then
    return 0
  end
  local ok_read, lines = pcall(vim.fn.readfile, M.opts.state_path, "b")
  if not ok_read then
    return 0
  end
  local ok_decode, state = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(state) ~= "table" or type(state.records) ~= "table" then
    return 0
  end
  next_id = math.max(next_id, tonumber(state.next_id) or 0)
  local loaded = 0
  restoring = true
  for _, saved in ipairs(state.records) do
    if type(saved) == "table" and not find_persistent(saved) then
      restore_record(saved)
      loaded = loaded + 1
    end
  end
  restoring = false
  if loaded > 0 then
    ensure_timer()
  end
  return loaded
end

function M.reconcile_tmux()
  if not M.tmux.available() then
    return 0
  end
  local live = {}
  local changed = 0
  for _, session in ipairs(M.tmux.list()) do
    live[session.name] = true
    local record = find_persistent({
      key = session.metadata and session.metadata.key,
      tmux_name = session.name,
      session_id = session.metadata and session.metadata.session_id,
    })
    if not record then
      local metadata = session.metadata or {}
      metadata.tmux_name = session.name
      metadata.status = "running"
      metadata.persistent = true
      record = restore_record(metadata)
      changed = changed + 1
    end
    if record.status ~= "running" or record.finished_at ~= nil then
      changed = changed + 1
    end
    record.tmux_name = session.name
    record.status = "running"
    record.finished_at = nil
    if not (record.buf and vim.api.nvim_buf_is_valid(record.buf)) then
      record.buf = nil
      record.channel = nil
      record.detached = true
      record.ide_reconnect = true
    end
  end
  for _, record in ipairs(records) do
    local attached = record.buf and vim.api.nvim_buf_is_valid(record.buf) and record.channel
    if present(record.tmux_name) and record.status == "running" and not attached and not live[record.tmux_name] then
      record.status = present(record.session_id) and "saved" or "failed"
      record.finished_at = now()
      record.buf = nil
      record.channel = nil
      record.detached = false
      record.ide_reconnect = false
      changed = changed + 1
    end
  end
  if changed > 0 then
    M.save_state()
    M.render()
  end
  return changed
end

function M.upgrade_legacy_flow_records()
  local changed = 0
  for _, record in ipairs(records) do
    if flow_record(record) and present(record.session_id) then
      local upgraded = false
      if not record.persistent then
        record.persistent = true
        upgraded = true
      end
      if not record.pinned then
        record.pinned = true
        upgraded = true
      end
      if not present(record.tmux_name) then
        record.tmux_name = M.tmux.name(record.key)
        upgraded = true
      end
      if upgraded then
        changed = changed + 1
      end
    end
  end
  if changed > 0 then
    M.save_state()
    M.render()
  end
  return changed
end

function M.hydrate()
  if not hydrated then
    hydrated = true
    M.load_state()
  end
  M.upgrade_legacy_flow_records()
  M.reconcile_tmux()
  M.reap()
end

function M.register_terminal(spec)
  spec = spec or {}
  local buf = spec.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local id = by_buf[buf] or vim.b[buf].claude_session_registry_id
  if not id and present(spec.session_id) then
    for index = #records, 1, -1 do
      if records[index].session_id == spec.session_id then
        id = records[index].id
        break
      end
    end
  end
  local record = id and by_id[id]
  if record then
    if present(spec.prompt) and record.prompts[#record.prompts] ~= spec.prompt then
      table.insert(record.prompts, spec.prompt)
    end
    M.update(id, {
      title = spec.title or record.title,
      kind = spec.kind or record.kind,
      prompt = spec.prompt or record.prompt,
      cwd = spec.cwd or record.cwd,
      session_id = spec.session_id or record.session_id,
      resume_args = spec.resume_args or record.resume_args,
      channel = spec.channel or record.channel,
      buf = buf,
      status = "running",
      persistent = spec.persistent == true or record.persistent,
      pinned = spec.pinned == true or record.pinned,
      tmux_name = spec.tmux_name or record.tmux_name,
      env_overrides = spec.env_overrides or record.env_overrides,
    })
    record.finished_at = nil
    by_buf[buf] = id
    vim.b[buf].claude_session_registry_id = id
    M.save_state()
    M.render()
    return id
  end
  return M.start(vim.tbl_extend("force", spec, { status = "running" }))
end

function M.terminal_closed(buf, code)
  local id = by_buf[buf] or vim.b[buf].claude_session_registry_id
  if id then
    M.terminal_client_closed(id, buf, code)
  end
end

function M.open_telescope(opts)
  opts = opts or {}
  M.hydrate()
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  if not ok_pickers then
    local ok_lazy, lazy = pcall(require, "lazy")
    if ok_lazy then
      pcall(lazy.load, { plugins = { "telescope.nvim" } })
      ok_pickers, pickers = pcall(require, "telescope.pickers")
    end
  end
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_previewers, previewers = pcall(require, "telescope.previewers")
  local ok_sorters, sorters = pcall(require, "telescope.sorters")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")
  if not (ok_pickers and ok_finders and ok_previewers and ok_sorters and ok_actions and ok_state) then
    return false
  end

  local visible_records = M.manager_records()
  local running = 0
  local pinned = 0
  for _, record in ipairs(visible_records) do
    if record.status == "running" then
      running = running + 1
    end
    if record.pinned then
      pinned = pinned + 1
    end
  end
  local default_selection_index
  if opts.selected_id then
    for index, record in ipairs(M.manager_records()) do
      if record.id == opts.selected_id then
        default_selection_index = index
        break
      end
    end
  end
  local picker
  picker = pickers.new({}, {
    prompt_title = "Message agent · <CR> send · <C-t> TUI",
    prompt_prefix = "󰭹  ",
    default_text = opts.default_text,
    default_selection_index = default_selection_index,
    results_title = string.format(
      "Agents · %d running · %d pinned",
      running,
      pinned
    ),
    preview_title = "Claude TUI",
    finder = manager_finder(finders),
    sorter = sorters.new({
      scoring_function = function()
        return 1
      end,
      highlighter = function()
        return {}
      end,
    }),
    previewer = previewers.new_buffer_previewer({
      title = "Claude TUI",
      define_preview = function(self, entry, status)
        local record = entry and entry.value
        if record then
          M.ensure_tui(record.id)
          record = by_id[record.id]
        end
        local buf = self.state.bufnr
        vim.bo[buf].filetype = record and record.channel and "claude-session" or "markdown"
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.preview_lines(record))
        local preview_win = status.preview_win
          or (status.layout and status.layout.preview and status.layout.preview.winid)
        if preview_win and vim.api.nvim_win_is_valid(preview_win) then
          manager.preview_win = preview_win
          local terminal = record and record.channel
          vim.wo[preview_win].wrap = not terminal
          vim.wo[preview_win].linebreak = not terminal
          vim.wo[preview_win].number = false
          vim.wo[preview_win].relativenumber = false
          vim.wo[preview_win].signcolumn = "no"
          vim.wo[preview_win].cursorline = false
          if terminal and record.buf and vim.api.nvim_buf_is_valid(record.buf) then
            local terminal_buf = record.buf
            vim.schedule(function()
              if manager_is_open() and vim.api.nvim_win_is_valid(preview_win)
                and vim.api.nvim_buf_is_valid(terminal_buf) then
                vim.api.nvim_win_set_buf(preview_win, terminal_buf)
                M.focus_latest(preview_win, terminal_buf)
              end
            end)
          else
            M.focus_latest(preview_win, buf)
          end
        end
      end,
    }),
    layout_strategy = "horizontal",
    layout_config = {
      width = 0.94,
      height = 0.86,
      prompt_position = "top",
      horizontal = {
        preview_width = 0.66,
        preview_cutoff = 80,
      },
    },
    sorting_strategy = "ascending",
    selection_strategy = "row",
    initial_mode = "insert",
    attach_mappings = function(bufnr, map)
      manager.prompt_bufnr = bufnr

      local function selected_id()
        local entry = action_state.get_selected_entry()
        return entry and entry.value and entry.value.id
      end

      local function send_selected()
        local id = selected_id()
        if not id then
          return
        end
        local text = action_state.get_current_line()
        if type(text) ~= "string" or vim.trim(text) == "" then
          return
        end
        local record = by_id[id]
        local running_input = record and record.status == "running" and (record.send or record.channel)
        local resumable = record and record.status ~= "running" and present(record.session_id)
        if not running_input and not resumable then
          notify("The selected agent is not accepting input.", vim.log.levels.WARN)
          return
        end
        if M.send(id, text) then
          picker:set_prompt("", true)
          refresh_manager()
        else
          notify("Claude did not accept that message.", vim.log.levels.WARN)
        end
      end

      local function archive_selected()
        local id = selected_id()
        if id and M.archive(id) then
          refresh_manager()
        end
      end

      local function stop_selected()
        local id = selected_id()
        if id and M.stop(id) then
          refresh_manager()
        end
      end

      local function pin_selected()
        local id = selected_id()
        if id then
          M.pin(id)
          refresh_manager()
        end
      end

      local function reconnect_selected()
        local id = selected_id()
        if id and not M.reconnect_ide(id) then
          notify("This session cannot reconnect to Neovim.", vim.log.levels.WARN)
        end
      end

      local function rename_selected()
        local id = selected_id()
        local record = id and by_id[id]
        if not record then
          return
        end
        vim.ui.input({ prompt = "Session name: ", default = record.title }, function(title)
          if M.rename(id, title) then
            refresh_manager()
          end
        end)
      end

      local function focus_terminal()
        local id = selected_id()
        local record = id and by_id[id]
        if record then
          M.ensure_tui(id)
          record = by_id[id]
        end
        if not record or not record.buf or not vim.api.nvim_buf_is_valid(record.buf) then
          notify("The selected session has no live terminal.", vim.log.levels.WARN)
          return
        end
        local win = manager.preview_win
        if not win or not vim.api.nvim_win_is_valid(win) then
          return
        end
        vim.api.nvim_win_set_buf(win, record.buf)
        vim.api.nvim_set_current_win(win)
        vim.cmd("startinsert")
      end

      local function interrupt_selected()
        local id = selected_id()
        if id then
          M.interrupt(id)
        end
      end

      actions.select_default:replace(send_selected)
      map("i", "<C-s>", send_selected)
      map("n", "<C-s>", send_selected)
      map("i", "<C-c>", interrupt_selected)
      map("n", "<C-c>", interrupt_selected)
      map("i", "<C-x>", stop_selected)
      map("n", "x", stop_selected)
      map("n", "d", archive_selected)
      map("n", "p", pin_selected)
      map("n", "r", rename_selected)
      map("n", "R", reconnect_selected)
      map("i", "<C-r>", reconnect_selected)
      map("n", "t", focus_terminal)
      map("i", "<C-t>", focus_terminal)

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        once = true,
        callback = function()
          if manager.prompt_bufnr == bufnr then
            manager = { picker = nil, prompt_bufnr = nil, preview_win = nil, refresh_pending = false }
          end
        end,
      })
      return true
    end,
  })
  manager.picker = picker
  picker:find()
  return true
end

function M.show_manager(opts)
  opts = opts or {}
  if manager_is_open() then
    refresh_manager()
    local win = vim.fn.bufwinid(manager.prompt_bufnr)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
    return true
  end
  return M.open_telescope(opts)
end

function M.toggle()
  if manager_is_open() then
    local ok, actions = pcall(require, "telescope.actions")
    if ok then
      actions.close(manager.prompt_bufnr)
    end
    manager = { picker = nil, prompt_bufnr = nil, preview_win = nil, refresh_pending = false }
    return false
  end
  if M.open_telescope() then
    return true
  end
  notify("Telescope is unavailable, so the agent manager could not open.", vim.log.levels.ERROR)
  return false
end

function M.is_open()
  return manager_is_open()
end

function M.uuid(seed)
  local hash = vim.fn.sha256(tostring(seed or "claude") .. ":" .. tostring(os.time()) .. ":" .. tostring(math.random()))
  return table.concat({
    hash:sub(1, 8),
    hash:sub(9, 12),
    "4" .. hash:sub(14, 16),
    "8" .. hash:sub(18, 20),
    hash:sub(21, 32),
  }, "-")
end

function M.setup()
  M.hydrate()
  vim.api.nvim_create_user_command("ClaudeSessions", M.toggle, {
    desc = "Manage persistent Claude sessions",
    force = true,
  })
  vim.api.nvim_set_hl(0, "ClaudeSessionRunning", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionFinished", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionFailed", { link = "DiagnosticError", default = true })
  local group = vim.api.nvim_create_augroup("ClaudeSessions", { clear = true })
  vim.api.nvim_create_autocmd("TermOpen", {
    group = group,
    callback = function(event)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(event.buf) or vim.b[event.buf].claude_session_registry_id then
          return
        end
        local name = vim.api.nvim_buf_get_name(event.buf):lower()
        if name:match("[:/]claude%s") or name:match("[:/]claude$") then
          M.register_terminal({
            title = "Claude Code",
            kind = "terminal",
            cwd = vim.fn.getcwd(),
            buf = event.buf,
            channel = vim.b[event.buf].terminal_job_id,
          })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("TermClose", {
    group = group,
    callback = function(event)
      M.terminal_closed(event.buf, vim.v.event.status or 0)
    end,
  })
end

function M.release_for_reload()
  M.upgrade_legacy_flow_records()
  if manager_is_open() then
    local ok, actions = pcall(require, "telescope.actions")
    if ok then
      pcall(actions.close, manager.prompt_bufnr)
    end
  end
  manager = { picker = nil, prompt_bufnr = nil, preview_win = nil, refresh_pending = false }
  stop_timer()
  return {
    records = records,
    next_id = next_id,
    opts = vim.deepcopy(M.opts),
    tmux = M.tmux,
  }
end

function M.restore_after_reload(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.records) ~= "table" then
    return false
  end
  records = snapshot.records
  by_id = {}
  by_buf = {}
  next_id = tonumber(snapshot.next_id) or 0
  M.opts = vim.tbl_extend("force", M.opts, snapshot.opts or {})
  M.tmux = snapshot.tmux or M.tmux
  for _, record in ipairs(records) do
    if record.id then
      by_id[record.id] = record
      next_id = math.max(next_id, tonumber(record.id) or 0)
    end
    if record.buf and vim.api.nvim_buf_is_valid(record.buf) then
      by_buf[record.buf] = record.id
      vim.b[record.buf].claude_session_registry_id = record.id
    else
      record.buf = nil
      record.channel = nil
    end
  end
  hydrated = true
  restoring = false
  M.upgrade_legacy_flow_records()
  M.reconcile_tmux()
  if #records > 0 then
    ensure_timer()
  end
  return true
end

function M.reset()
  records = {}
  by_id = {}
  by_buf = {}
  next_id = 0
  hydrated = false
  restoring = false
  stop_timer()
  if manager_is_open() then
    local ok, actions = pcall(require, "telescope.actions")
    if ok then
      pcall(actions.close, manager.prompt_bufnr)
    end
  end
  manager = { picker = nil, prompt_bufnr = nil, preview_win = nil, refresh_pending = false }
end

return M
