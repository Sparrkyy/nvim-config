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

M.enabled = true
M.highlight_changes = true
M.permission_enabled = true
M.status = "idle" -- idle | working
M.last_tool = nil
M.agents = {} -- running subagents, keyed by id

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

  local bufnr = vim.fn.bufadd(vim.fn.fnamemodify(path, ":p"))
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true

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

--- Define the colours. Link to the diff groups, so a colourscheme can override.
local function define_highlights()
  vim.api.nvim_set_hl(0, "ClaudeAdded", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "ClaudeAddedLabel", { link = "DiffChange", default = true })
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

--- Highlight the lines Claude just wrote in a file.
---@param path string
---@param chunks table list of written strings
function M.mark(path, chunks)
  if not M.highlight_changes or type(chunks) ~= "table" or #chunks == 0 then
    return
  end
  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 0 then
    return
  end

  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)

  -- Claude wrote to disk. Reload first, or the reload wipes the marks we set.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent! checktime")
  end)

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local total = vim.api.nvim_buf_line_count(bufnr)
    for _, chunk in ipairs(chunks) do
      local start, count = chunk_range(full, chunk)
      if start then
        for l = start, math.min(start + count - 1, total) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, mark_ns, l - 1, 0, {
            line_hl_group = "ClaudeAdded",
          })
        end
        pcall(vim.api.nvim_buf_set_extmark, bufnr, mark_ns, start - 1, 0, {
          virt_text = { { "  claude", "ClaudeAddedLabel" } },
          virt_text_pos = "eol",
        })
      end
    end
  end)
end

--- Remove the marks. Pass a buffer, or nothing to clear every buffer.
---@param bufnr number|nil
function M.clear_marks(bufnr)
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
-- at a time, so each file stays on screen long enough to review.

M.pace_ms = 900 -- gap between jumps. Set to 0 to follow at full speed.

local queue = {}
local timer = nil
local MAX_QUEUE = 40

local function drain()
  timer = nil
  local item = queue[1]
  if not item then
    return
  end

  local result = show(item.path, item.line)

  -- "busy" means you are mid-edit. "reviewing" means a diff is open. Both are
  -- your turn, not Claude's, so hold the jump and try again shortly.
  if result == "busy" or result == "reviewing" then
    item.retries = (item.retries or 0) + 1
    if item.retries > 40 then
      table.remove(queue, 1)
    end
  else
    table.remove(queue, 1)
  end

  if #queue > 0 then
    timer = vim.defer_fn(drain, M.pace_ms > 0 and M.pace_ms or 100)
  end
  pcall(vim.cmd, "redrawstatus")
end

--- Queue a jump. The hook calls this, so it must return at once.
---@param path string
---@param line number|nil
function M.open(path, line)
  if not M.enabled then
    return "disabled"
  end
  if type(path) ~= "string" or path == "" then
    return "nopath"
  end
  if M.pace_ms <= 0 then
    return show(path, line)
  end

  -- Claude often touches the same place twice in a row. Show it once.
  local last = queue[#queue]
  if last and last.path == path and last.line == line then
    return "queued"
  end

  table.insert(queue, { path = path, line = line })
  if #queue > MAX_QUEUE then
    table.remove(queue, 1) -- drop the oldest, so you never fall far behind
  end
  if not timer then
    timer = vim.defer_fn(drain, 0)
  end
  return "queued"
end

--- How many jumps are waiting. The statusline and the tests read this.
function M.queue_length()
  return #queue
end

--- Drop every pending jump and stop the replay.
function M.clear_queue()
  queue = {}
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

--- Entry point for the hook script. Takes base64 JSON to avoid shell quoting.
---@param encoded string
function M.handle(encoded)
  local ok, result = pcall(function()
    local data = vim.json.decode(vim.base64.decode(encoded))
    local kind = data.kind

    if kind == "open" then
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
      -- The hook sends "added" only after the write, when the text is on disk.
      local added = present(data.added)
      if path and type(added) == "table" and #added > 0 then
        M.mark(path, added)
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

--- Claude's TUI needs a moment to boot. If we start it and write at once, the
--- bytes reach the PTY before Claude reads stdin: the text lands in the box but
--- the submit carriage return is lost. So wait until Claude draws its prompt.
local function terminal_is_ready(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    -- The top border of Claude's input box, or the caret drawn inside it.
    if line:find("\226\149\173", 1, true) or line:find("\226\148\130 >", 1, true) then
      return true
    end
  end
  return false
end

--- Call cb once Claude's prompt is up. Give up after about 10 seconds and call
--- cb anyway, so a slow start never swallows your prompt without a trace.
local function when_ready(cb)
  local attempts = 0
  local function poll()
    local _, bufnr = claude_terminal()
    if terminal_is_ready(bufnr) then
      -- One more beat so the first full paint finishes.
      vim.defer_fn(cb, 150)
      return
    end
    attempts = attempts + 1
    if attempts > 100 then
      cb()
      return
    end
    vim.defer_fn(poll, 100)
  end
  poll()
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

--- Send a prompt to Claude from anywhere, without leaving the buffer.
---@param opts table|nil { context = boolean, selection = boolean }
function M.prompt(opts)
  opts = opts or {}
  local terminal = claude_terminal()
  if not terminal then
    vim.notify("claudecode.nvim is not loaded.", vim.log.levels.ERROR)
    return
  end

  -- Capture the selection first. Reading the range must happen before the input
  -- box opens, because opening it ends visual mode.
  if opts.selection then
    M.send_selection()
  end

  local prefix = ""
  if opts.context and not opts.selection then
    local file = vim.fn.expand("%:.")
    if file ~= "" and vim.bo.buftype == "" then
      prefix = string.format("@%s (line %d) ", file, vim.api.nvim_win_get_cursor(0)[1])
    end
  end

  vim.ui.input({ prompt = "Claude ", default = prefix }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end

    local _, running = claude_terminal()
    terminal.ensure_visible()

    local function send()
      terminal.send_to_terminal(input, { submit = true })
      M.status = "working"
    end

    if running then
      vim.schedule(send)
    else
      when_ready(send)
    end
  end)
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
  vim.api.nvim_create_autocmd("VimLeavePre", { group = aug, callback = M.unregister })

  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = aug, callback = define_highlights })
end

return M
