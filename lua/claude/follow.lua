-- Follow mode: lets Claude Code drive this Neovim instance.
--
-- Claude Code hooks call back into this module over Neovim's RPC socket.
-- The result: as Claude reads and edits files, the main window follows along.
-- Nothing here ever steals focus from you.

local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("claude_follow")
local mark_ns = vim.api.nvim_create_namespace("claude_changes")
local registry_dir = vim.fn.stdpath("cache") .. "/claude-follow"
local pending_changes = {}
local mark_epoch = 0
local enqueue_replay

M.enabled = false
M.highlight_changes = true
M.permission_enabled = true
M.status = "idle" -- idle | working
M.last_tool = nil
M.agents = {} -- running subagents, keyed by id
M.change_linger_ms = 1100
M.change_fade_ms = 900

--- Registry -----------------------------------------------------------------
-- Each Neovim instance writes its RPC address to a file keyed by its cwd.
-- The hook script looks the address up and calls back.

local registry_files = {}

-- One directory per cwd, one file per Neovim instance. Several editors can sit
-- in the same project without clobbering each other, and an instance only ever
-- removes its own entry.
local function registry_dir_for(dir)
  return registry_dir .. "/" .. vim.fn.sha256(dir)
end

local function normalized_dir(dir)
  local full = vim.fn.resolve(vim.fn.fnamemodify(dir or uv.cwd(), ":p"))
  return full:gsub("/+$", "")
end

function M.register(dir)
  local server = vim.v.servername
  if not server or server == "" then
    return
  end
  local cwd = normalized_dir(dir)
  local target = registry_dir_for(cwd)
  vim.fn.mkdir(target, "p")
  local path = target .. "/" .. tostring(uv.os_getpid()) .. ".server"
  local fd = io.open(path, "w")
  if fd then
    fd:write(server)
    fd:close()
    registry_files[cwd] = path
  end
end

function M.unregister(dir)
  if dir then
    local cwd = normalized_dir(dir)
    local path = registry_files[cwd]
    if path then
      os.remove(path)
      registry_files[cwd] = nil
    end
    return
  end
  for cwd, path in pairs(registry_files) do
    os.remove(path)
    registry_files[cwd] = nil
  end
end

--- Window selection ---------------------------------------------------------

local function is_editable_win(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false -- floating window
  end
  if vim.wo[win].diff then
    return false -- a review is in progress; leave it alone
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local bt = vim.bo[buf].buftype
  if bt == "terminal" or bt == "prompt" or bt == "quickfix" or bt == "nofile" then
    return false
  end
  local ft = vim.bo[buf].filetype
  if ft:match("^neo%-tree") or ft == "NvimTree" or ft == "snacks_picker_list" then
    return false
  end
  return true
end

local function target_win()
  local cur = vim.api.nvim_get_current_win()
  if is_editable_win(cur) then
    return cur
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editable_win(win) then
      return win
    end
  end
  return nil
end

local function a_diff_is_open()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      return true
    end
  end
  return false
end

--- Actions ------------------------------------------------------------------

local function full_path(path)
  return vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
end

local function read_file_lines(path)
  local ok, lines = pcall(vim.fn.readfile, full_path(path))
  if not ok then
    return nil
  end
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function refresh_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local disk_lines = read_file_lines(path)
  if not disk_lines then
    return false
  end
  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if vim.deep_equal(buffer_lines, disk_lines) then
    return false
  end
  if vim.bo[bufnr].modified then
    return false
  end

  vim.bo[bufnr].autoread = true
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent! checktime")
  end)

  buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not vim.deep_equal(buffer_lines, disk_lines) then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! noautocmd edit!")
    end)
  end
  return true
end

--- Show a file in the main window without taking focus.
--- This is the immediate jump. M.open queues it instead; see Pacing below.
---@param path string absolute or cwd-relative path
---@param line number|nil 1-indexed line to centre on
local function show(path, line)
  -- Never interrupt you mid-edit, and never disturb a diff under review.
  -- Terminal modes ("t", "nt") are fine: that is you talking to Claude, which
  -- is exactly when Claude works. Only a live edit in a file blocks the jump.
  local mode = vim.fn.mode()
  if not (mode:sub(1, 1) == "n" or mode:sub(1, 1) == "t") then
    return "busy"
  end
  if a_diff_is_open() then
    return "reviewing"
  end
  if vim.fn.filereadable(vim.fn.fnamemodify(path, ":p")) == 0 then
    return "unreadable"
  end

  local win = target_win()
  if not win then
    return "nowin"
  end

  local bufnr = vim.fn.bufadd(full_path(path))
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  refresh_buffer(bufnr)

  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    vim.api.nvim_win_set_buf(win, bufnr)
  end

  local target = math.max(1, math.min(tonumber(line) or 1, vim.api.nvim_buf_line_count(bufnr)))
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)

  local hl = vim.hl or vim.highlight
  pcall(hl.range, bufnr, ns, "Visual", { target - 1, 0 }, { target - 1, -1 }, { timeout = 500 })

  return "ok"
end

--- Change marks -------------------------------------------------------------
-- Claude tells us the exact text it wrote. Find that text in the file and give
-- it a background colour, so the new code stands out from the code you wrote.

local function blend_colour(source, target, weight)
  local function channel(value, shift)
    return math.floor(value / (2 ^ shift)) % 256
  end
  local function mixed(shift)
    return math.floor(channel(source, shift) * weight + channel(target, shift) * (1 - weight) + 0.5)
  end
  return mixed(16) * 65536 + mixed(8) * 256 + mixed(0)
end

local function highlight_background(name, fallback)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and value and value.bg then
    return value.bg
  end
  return fallback
end

local function define_highlights()
  local dark = vim.o.background == "dark"
  local normal = highlight_background("Normal", dark and 0x101418 or 0xf7f7f7)
  local added = highlight_background("DiffAdd", dark and 0x21452d or 0xcdebd5)
  local deleted = highlight_background("DiffDelete", dark and 0x552b32 or 0xf2cfd2)

  vim.api.nvim_set_hl(0, "ClaudeAdded", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "ClaudeAddedLabel", { link = "DiffChange", default = true })
  vim.api.nvim_set_hl(0, "ClaudeDeleted", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "ClaudeDeletedLabel", { link = "DiffDelete", default = true })

  for step, weight in ipairs({ 0.72, 0.46, 0.22 }) do
    vim.api.nvim_set_hl(0, "ClaudeAddedFade" .. step, {
      bg = blend_colour(added, normal, weight),
      default = true,
    })
    vim.api.nvim_set_hl(0, "ClaudeDeletedFade" .. step, {
      bg = blend_colour(deleted, normal, weight),
      default = true,
    })
  end
end

--- Locate a written chunk in a file.
---@return number|nil start 1-indexed first line
---@return number|nil count number of lines the chunk covers
local function chunk_range(path, chunk)
  if type(chunk) ~= "string" or vim.trim(chunk) == "" then
    return nil
  end
  local chunk_lines = vim.split(chunk:gsub("\r", ""), "\n", { plain = true })
  while #chunk_lines > 1 and vim.trim(chunk_lines[#chunk_lines]) == "" do
    table.remove(chunk_lines)
  end

  -- Anchor on the first line that has content, and remember its offset.
  local anchor_idx, anchor_text
  for i, l in ipairs(chunk_lines) do
    if vim.trim(l) ~= "" then
      anchor_idx, anchor_text = i, l
      break
    end
  end
  if not anchor_text then
    return nil
  end

  local ok, file_lines = pcall(vim.fn.readfile, vim.fn.fnamemodify(path, ":p"))
  if not ok then
    return nil
  end

  -- An exact line match is trustworthy. Fall back to a substring match.
  for _, exact in ipairs({ true, false }) do
    for i, l in ipairs(file_lines) do
      local hit = exact and l == anchor_text or (not exact and l:find(anchor_text, 1, true) ~= nil)
      if hit then
        return math.max(1, i - (anchor_idx - 1)), #chunk_lines
      end
    end
  end
  return nil
end

local function record_position(bufnr, id)
  local ok, position = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, mark_ns, id, {})
  if not ok or #position < 2 then
    return nil
  end
  return position
end

local function update_record(record, stage)
  if not vim.api.nvim_buf_is_valid(record.bufnr) then
    return
  end
  local position = record_position(record.bufnr, record.id)
  if not position then
    return
  end
  local group
  if stage == 0 then
    group = record.change == "added" and "ClaudeAdded" or "ClaudeDeleted"
  else
    local prefix = record.change == "added" and "ClaudeAddedFade" or "ClaudeDeletedFade"
    group = prefix .. stage
  end

  local opts = { id = record.id, priority = 210, strict = false }
  if record.kind == "line" then
    opts.line_hl_group = group
  elseif record.kind == "label" then
    opts.virt_text = { { "  claude", stage == 0 and "ClaudeAddedLabel" or group } }
    opts.virt_text_pos = "eol"
  else
    opts.virt_lines = {}
    for _, line in ipairs(record.lines) do
      table.insert(opts.virt_lines, { { line == "" and " " or line, group } })
    end
    opts.virt_lines_above = record.above
  end
  pcall(vim.api.nvim_buf_set_extmark, record.bufnr, mark_ns, position[1], position[2], opts)
end

local function animate_records(records)
  if #records == 0 then
    return
  end
  local epoch = mark_epoch
  local steps = 3
  for stage = 1, steps do
    local delay = M.change_linger_ms + math.floor(M.change_fade_ms * stage / (steps + 1))
    vim.defer_fn(function()
      if epoch ~= mark_epoch or not M.highlight_changes then
        return
      end
      for _, record in ipairs(records) do
        update_record(record, stage)
      end
      vim.cmd("redraw")
    end, delay)
  end
  vim.defer_fn(function()
    if epoch ~= mark_epoch then
      return
    end
    for _, record in ipairs(records) do
      if vim.api.nvim_buf_is_valid(record.bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, record.bufnr, mark_ns, record.id)
      end
    end
    vim.cmd("redraw")
  end, M.change_linger_ms + M.change_fade_ms)
end

local function add_line_records(bufnr, first, count, total, records)
  for line = first, math.min(first + count - 1, total) do
    local id = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, line - 1, 0, {
      line_hl_group = "ClaudeAdded",
      priority = 210,
    })
    table.insert(records, { bufnr = bufnr, id = id, kind = "line", change = "added" })
  end
  if count > 0 and first <= total then
    local id = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, first - 1, 0, {
      virt_text = { { "  claude", "ClaudeAddedLabel" } },
      virt_text_pos = "eol",
      priority = 210,
    })
    table.insert(records, { bufnr = bufnr, id = id, kind = "label", change = "added" })
  end
end

local function add_deleted_record(bufnr, lines, new_start, new_count, total, records)
  if #lines == 0 then
    return
  end
  local after_last_line = new_count == 0 and new_start > total
  local row = after_last_line and math.max(total - 1, 0) or math.max(0, math.min(new_start - 1, total - 1))
  local above = not after_last_line
  local virtual = {}
  for _, line in ipairs(lines) do
    table.insert(virtual, { { line == "" and " " or line, "ClaudeDeleted" } })
  end
  local id = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, row, 0, {
    virt_lines = virtual,
    virt_lines_above = above,
    priority = 210,
    strict = false,
  })
  table.insert(records, {
    bufnr = bufnr,
    id = id,
    kind = "deleted",
    change = "deleted",
    lines = lines,
    above = above,
  })
end

local function diff_hunks(before, after)
  if vim.deep_equal(before, after) then
    return {}
  end
  local ok, hunks = pcall(vim.diff, table.concat(before, "\n"), table.concat(after, "\n"), {
    result_type = "indices",
    algorithm = "histogram",
  })
  if ok and type(hunks) == "table" then
    return hunks
  end
  return { { 1, #before, 1, #after } }
end

local function draw_hunk(bufnr, before, hunk)
  local records = {}
  local total = vim.api.nvim_buf_line_count(bufnr)
  local old_start = math.max(tonumber(hunk[1]) or 1, 1)
  local old_count = math.max(tonumber(hunk[2]) or 0, 0)
  local new_start = math.max(tonumber(hunk[3]) or 1, 1)
  local new_count = math.max(tonumber(hunk[4]) or 0, 0)

  if old_count > 0 then
    local removed = {}
    for line = old_start, math.min(old_start + old_count - 1, #before) do
      table.insert(removed, before[line])
    end
    add_deleted_record(bufnr, removed, new_start, new_count, total, records)
  end
  if new_count > 0 then
    add_line_records(bufnr, new_start, new_count, total, records)
  end
  animate_records(records)
end

local function replay_diff(path, bufnr, before, after)
  local first_changed
  local queued = false
  local total = vim.api.nvim_buf_line_count(bufnr)
  for _, source_hunk in ipairs(diff_hunks(before, after)) do
    local hunk = { source_hunk[1], source_hunk[2], source_hunk[3], source_hunk[4] }
    local line = math.max(1, math.min(tonumber(hunk[3]) or 1, total))
    first_changed = first_changed or line
    local result = enqueue_replay(path, line, function()
      if M.highlight_changes and vim.api.nvim_buf_is_valid(bufnr) then
        draw_hunk(bufnr, before, hunk)
      end
    end)
    queued = queued or result == "queued" or result == "ok"
  end
  return first_changed, queued
end

local function replay_added_chunks(bufnr, path, chunks)
  local queued = false
  for _, chunk in ipairs(chunks) do
    local start, count = chunk_range(path, chunk)
    if start then
      local first = start
      local line_count = count
      local result = enqueue_replay(path, first, function()
        if not M.highlight_changes or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        local records = {}
        add_line_records(bufnr, first, line_count, vim.api.nvim_buf_line_count(bufnr), records)
        animate_records(records)
      end)
      queued = queued or result == "queued" or result == "ok"
    end
  end
  return queued
end

local function highlight_added_chunks(bufnr, path, chunks)
  local records = {}
  for _, chunk in ipairs(chunks) do
    local start, count = chunk_range(path, chunk)
    if start then
      add_line_records(bufnr, start, count, vim.api.nvim_buf_line_count(bufnr), records)
    end
  end
  animate_records(records)
end

--- Highlight the lines Claude just wrote in a file.
---@param path string
---@param chunks table list of written strings
function M.mark(path, chunks)
  if not M.highlight_changes or type(chunks) ~= "table" or #chunks == 0 then
    return
  end
  local full = full_path(path)
  if vim.fn.filereadable(full) == 0 then
    return
  end

  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)
  refresh_buffer(bufnr)

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if M.enabled then
      replay_added_chunks(bufnr, full, chunks)
    else
      highlight_added_chunks(bufnr, full, chunks)
    end
    vim.cmd("redraw")
  end)
end

local function prepare_change(path, line)
  local full = full_path(path)
  if vim.fn.filereadable(full) == 0 then
    return
  end
  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)
  refresh_buffer(bufnr)
  pending_changes[full] = {
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    line = line,
  }
end

local function finish_change(path, fallback_chunks)
  local full = full_path(path)
  if vim.fn.filereadable(full) == 0 then
    pending_changes[full] = nil
    return nil
  end

  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)
  local pending = pending_changes[full]
  local before = pending and pending.lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local after = read_file_lines(full)
  pending_changes[full] = nil
  if not after then
    return pending and pending.line or nil
  end
  if vim.bo[bufnr].modified then
    return pending and pending.line or nil
  end

  refresh_buffer(bufnr)
  local first_changed, replayed = replay_diff(full, bufnr, before, after)
  if not replayed and type(fallback_chunks) == "table" and #fallback_chunks > 0 then
    replayed = replay_added_chunks(bufnr, full, fallback_chunks)
  end
  vim.cmd("redraw")
  return first_changed or (pending and pending.line or nil), replayed
end

--- Remove the marks. Pass a buffer, or nothing to clear every buffer.
---@param bufnr number|nil
function M.clear_marks(bufnr)
  mark_epoch = mark_epoch + 1
  local targets = bufnr and { bufnr } or vim.api.nvim_list_bufs()
  for _, b in ipairs(targets) do
    if vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_clear_namespace(b, mark_ns, 0, -1)
    end
  end
end

--- Turn the marks on or off. Turning them off clears what is on screen.
function M.toggle_marks()
  M.highlight_changes = not M.highlight_changes
  if not M.highlight_changes then
    M.clear_marks()
  end
  vim.notify("Change highlights " .. (M.highlight_changes and "on" or "off"),
    vim.log.levels.INFO, { title = "Claude Code" })
end

--- Pacing -------------------------------------------------------------------
-- Claude edits faster than you can read. Queue the jumps and replay them one
-- at a time, so every change hunk and file transition gets a full beat.

M.pace_ms = 1000 -- gap between change hunks. Set to 0 to follow at full speed.

local queue = {}
local timer = nil
local last_replay_at = nil
local drain

local function now_ms()
  return uv.hrtime() / 1000000
end

local function schedule_drain(delay)
  if timer or #queue == 0 then
    return
  end
  if delay == nil then
    delay = 0
    if M.pace_ms > 0 and last_replay_at then
      delay = math.max(0, math.ceil(M.pace_ms - (now_ms() - last_replay_at)))
    end
  end
  timer = vim.defer_fn(drain, delay)
end

drain = function()
  timer = nil
  local item = queue[1]
  if not item then
    return
  end

  local result = show(item.path, item.line)
  local replayed = false

  -- "busy" means you are mid-edit. "reviewing" means a diff is open. Both are
  -- your turn, not Claude's, so hold the jump and try again shortly.
  if result == "busy" or result == "reviewing" then
    item.retries = (item.retries or 0) + 1
    if item.retries > 40 then
      table.remove(queue, 1)
    end
  else
    table.remove(queue, 1)
    if result == "ok" then
      replayed = true
      if item.on_show then
        pcall(item.on_show)
      end
      last_replay_at = now_ms()
    end
  end

  if #queue > 0 then
    if replayed then
      schedule_drain()
    else
      schedule_drain(100)
    end
  end
  pcall(vim.cmd, "redrawstatus")
end

enqueue_replay = function(path, line, on_show)
  if not M.enabled then
    return "disabled"
  end
  if type(path) ~= "string" or path == "" then
    return "nopath"
  end
  if M.pace_ms <= 0 then
    local result = show(path, line)
    if result == "ok" and on_show then
      pcall(on_show)
    end
    return result
  end

  local last = queue[#queue]
  if not on_show and last and not last.on_show and last.path == path and last.line == line then
    return "queued"
  end

  table.insert(queue, { path = path, line = line, on_show = on_show })
  schedule_drain()
  return "queued"
end

--- Queue a jump. The hook calls this, so it must return at once.
---@param path string
---@param line number|nil
function M.open(path, line)
  return enqueue_replay(path, line)
end

--- How many jumps are waiting. The statusline and the tests read this.
function M.queue_length()
  return #queue
end

--- Drop every pending jump and stop the replay.
function M.clear_queue()
  queue = {}
  last_replay_at = nil
  if timer then
    pcall(function() timer:stop() end)
    timer = nil
  end
end

--- Show the next queued jump at once, without waiting for the gap.
function M.next()
  if #queue == 0 then
    vim.notify("Nothing queued.", vim.log.levels.INFO, { title = "Claude Code" })
    return
  end
  if timer then
    pcall(function() timer:stop() end)
    timer = nil
  end
  drain()
end

--- Set the gap between jumps.
function M.set_pace(ms)
  if ms then
    M.pace_ms = math.max(0, tonumber(ms) or 0)
    vim.notify("Follow pace " .. M.pace_ms .. "ms", vim.log.levels.INFO, { title = "Claude Code" })
    return
  end
  vim.ui.input({ prompt = "Follow pace (ms, 0 = no pacing) ", default = tostring(M.pace_ms) },
    function(input)
      if input and vim.trim(input) ~= "" then
        M.set_pace(input)
      end
    end)
end

--- Find the line where a string occurs, so an edit centres on the right place.
local function find_line(path, needle)
  if type(needle) ~= "string" or needle == "" then
    return nil
  end
  local first = needle:gsub("\r", ""):match("^[^\n]*")
  if not first or vim.trim(first) == "" then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, vim.fn.fnamemodify(path, ":p"))
  if not ok then
    return nil
  end
  for i, l in ipairs(lines) do
    if l:find(first, 1, true) then
      return i
    end
  end
  return nil
end

local function writes_file(tool, explicit)
  if explicit == true then
    return true
  end
  return tool == "Edit"
    or tool == "Write"
    or tool == "MultiEdit"
    or tool == "NotebookEdit"
    or tool == "Bash"
end

--- Entry point for the hook script. Takes base64 JSON to avoid shell quoting.
---@param encoded string
function M.handle(encoded)
  local ok, result = pcall(function()
    local data = vim.json.decode(vim.base64.decode(encoded))
    local kind = data.kind

    if kind == "open" then
      if not M.enabled then
        return "disabled"
      end
      M.status = "working"
      M.last_tool = data.tool
      -- vim.json turns JSON null into vim.NIL, which is truthy in Lua.
      local function present(v)
        if v == nil or v == vim.NIL then
          return nil
        end
        return v
      end
      local line = present(data.line)
      local needle = present(data.needle)
      local path = present(data.path)
      if not line and needle then
        line = find_line(path, needle)
      end
      local event = present(data.event)
      local added = present(data.added)
      local is_write = writes_file(data.tool, present(data.write))
      local replayed = false
      if path and event == "PreToolUse" and is_write then
        prepare_change(path, line)
      elseif path and event == "PostToolUse" and is_write then
        local changed_line
        changed_line, replayed = finish_change(path, added)
        line = changed_line or line
      elseif path and type(added) == "table" and #added > 0 then
        M.mark(path, added)
      end
      if replayed then
        return M.pace_ms <= 0 and "ok" or "queued"
      end
      return M.open(path, line)
    elseif kind == "quickfix" then
      -- A failed tool call becomes a quickfix entry you can jump to.
      local items = vim.fn.getqflist()
      table.insert(items, {
        filename = data.path ~= vim.NIL and data.path or nil,
        lnum = tonumber(data.line) or 1,
        col = 1,
        type = "E",
        text = data.text or "Claude tool failure",
      })
      vim.fn.setqflist({}, "r", { title = "Claude failures", items = items })
      vim.notify(data.text or "Claude hit an error.", vim.log.levels.WARN,
        { title = "Claude Code" })
      return "ok"
    elseif kind == "agent" then
      if data.event == "start" then
        M.agents[data.id or "?"] = data.agent_type or "agent"
      else
        M.agents[data.id or "?"] = nil
      end
      return "ok"
    elseif kind == "task" then
      require("claude.panel").task(data.id, data.text, data.task_status)
      return "ok"
    elseif kind == "message" then
      require("claude.panel").message(data.id, data.delta, data.final)
      return "ok"
    elseif kind == "status" then
      M.status = data.status or "idle"
      if data.message and data.message ~= "" then
        vim.notify(data.message, vim.log.levels[data.level or "INFO"] or vim.log.levels.INFO,
          { title = "Claude Code" })
      end
      return "ok"
    end
    return "unknown"
  end)
  vim.cmd("redrawstatus")
  return ok and tostring(result) or ("error: " .. tostring(result))
end

--- Interaction --------------------------------------------------------------

local function claude_terminal()
  local ok, terminal = pcall(require, "claudecode.terminal")
  if not ok or type(terminal) ~= "table" then
    return nil, nil
  end
  local bufnr = terminal.get_active_terminal_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return terminal, nil
  end
  return terminal, bufnr
end

--- Interrupt Claude mid-task, the same as pressing Esc in its pane.
function M.interrupt()
  local _, bufnr = claude_terminal()
  if not bufnr then
    vim.notify("Claude is not running.", vim.log.levels.WARN, { title = "Claude Code" })
    return
  end
  local chan = vim.b[bufnr].terminal_job_id or vim.bo[bufnr].channel
  if not chan or chan <= 0 then
    vim.notify("No channel to Claude's terminal.", vim.log.levels.ERROR, { title = "Claude Code" })
    return
  end
  vim.fn.chansend(chan, "\27")
  M.status = "idle"
  vim.notify("Interrupted. Type a new instruction.", vim.log.levels.INFO, { title = "Claude Code" })
end

--- Send the visual selection to Claude as an at-mention.
---
--- The plugin's own :ClaudeCodeSend branches on the mode it observes when it
--- runs. Any path that drops out of visual mode first silently falls through to
--- its normal handler, which sends the whole file instead of the selection. So
--- read the range here, while visual mode is still current, and call the
--- selection module directly. No mode guessing, nothing scheduled.
---@return boolean sent
function M.send_selection()
  local mode = vim.fn.mode()
  local line1, line2

  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    line1, line2 = math.min(a, b), math.max(a, b)
    -- Leave visual mode now, so the marks settle before anything else runs.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  else
    line1, line2 = vim.fn.line("'<"), vim.fn.line("'>")
  end

  if not line1 or not line2 or line1 < 1 or line2 < 1 then
    vim.notify("No selection to send.", vim.log.levels.WARN, { title = "Claude Code" })
    return false
  end

  local ok_main, main = pcall(require, "claudecode")
  if not ok_main or not main.state or not main.state.server then
    vim.notify("Claude Code is not running. Press <leader>ac to start it.",
      vim.log.levels.WARN, { title = "Claude Code" })
    return false
  end

  local ok_sel, selection = pcall(require, "claudecode.selection")
  if not ok_sel then
    vim.notify("claudecode.selection failed to load.", vim.log.levels.ERROR, { title = "Claude Code" })
    return false
  end

  local ok, err = pcall(selection.send_at_mention_for_visual_selection, line1, line2)
  if not ok then
    vim.notify("Send failed: " .. tostring(err), vim.log.levels.ERROR, { title = "Claude Code" })
    return false
  end
  return true
end

--- Resolve a diff from anywhere. The plugin's own commands read the diff
--- context out of the current buffer, so they fail when the cursor sits in the
--- original file or in Claude's terminal. These wrappers find the proposed
--- buffer first, focus it, then act.
local function focus_proposed_buffer()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].claudecode_diff_tab_name then
        vim.api.nvim_set_current_win(win)
        return true
      end
    end
  end
  vim.notify("No diff is open.", vim.log.levels.WARN, { title = "Claude Code" })
  return false
end

function M.accept()
  if focus_proposed_buffer() then
    vim.cmd("ClaudeCodeDiffAccept")
  end
end

function M.reject()
  if focus_proposed_buffer() then
    vim.cmd("ClaudeCodeDiffDeny")
  end
end

function M.toggle()
  M.enabled = not M.enabled
  if not M.enabled then
    M.clear_queue()
    M.clear_marks()
    pending_changes = {}
  end
  vim.notify("Follow mode " .. (M.enabled and "on" or "off"), vim.log.levels.INFO, { title = "Claude Code" })
end

--- Statusline component. Shows what Claude is doing.
function M.statusline()
  local parts = {}

  local names = {}
  for _, agent_type in pairs(M.agents) do
    table.insert(names, agent_type)
  end
  if #names > 0 then
    table.sort(names)
    table.insert(parts, "󰬛 " .. table.concat(names, "+"))
  end

  local ok, panel = pcall(require, "claude.panel")
  if ok then
    local summary = panel.plan_summary()
    if summary ~= "" then
      table.insert(parts, "󰄬 " .. summary)
    end
  end

  if M.status == "working" then
    table.insert(parts, "󰚩 " .. (M.last_tool or "working"))
  end

  if #queue > 0 then
    table.insert(parts, " " .. #queue)
  end

  local one_ok, oneshot = pcall(require, "claude.oneshot")
  if one_ok and oneshot.statusline() ~= "" then
    table.insert(parts, oneshot.statusline())
  end

  return table.concat(parts, "  ")
end

--- Ask for a permission decision in the editor. The hook blocks on this call,
--- so it must return quickly and must never error. Anything other than a clear
--- yes or no falls through to Claude's own prompt in the terminal.
function M.permission(encoded)
  if not M.permission_enabled then
    return "ask"
  end
  local ok, decision = pcall(function()
    local data = vim.json.decode(vim.base64.decode(encoded))
    local detail = data.detail or ""
    if #detail > 300 then
      detail = detail:sub(1, 300) .. "..."
    end
    local message = string.format("Claude wants to run %s\n\n%s", data.tool or "a tool", detail)
    local choice = vim.fn.confirm(message, "&Allow\n&Deny\n&Terminal", 3, "Question")
    if choice == 1 then
      return "allow"
    elseif choice == 2 then
      return "deny"
    end
    return "ask"
  end)
  return ok and decision or "ask"
end

--- Setup --------------------------------------------------------------------

function M.setup()
  local aug = vim.api.nvim_create_augroup("ClaudeFollow", { clear = true })
  local primary_dir = normalized_dir(uv.cwd())
  vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
    group = aug,
    callback = function()
      M.unregister(primary_dir)
      primary_dir = normalized_dir(uv.cwd())
      M.register(primary_dir)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = aug,
    callback = function()
      M.unregister()
    end,
  })

  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = aug, callback = define_highlights })
end

return M
