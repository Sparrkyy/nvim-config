local M = {}

local store = require("flow.store")
local worktree = require("flow.worktree")

M.analysis = require("flow.review_ai")

M.ns = vim.api.nvim_create_namespace("flow_review_comments")
M.diff_ns = vim.api.nvim_create_namespace("flow_review_inline_diff")
M.overview_ns = vim.api.nvim_create_namespace("flow_review_overview")

local state = {
  tab = nil,
  win = nil,
  plan_id = nil,
  review_id = nil,
  mode = nil,
  meta = nil,
  buffers = {},
  marks = {},
  comment_count = 0,
  dirty = false,
  closing = false,
  previous_ui = nil,
  previous_tab = nil,
  location = nil,
  files = {},
  file_by_path = {},
  file_index = nil,
  overview = nil,
  analysis_status = "off",
  analysis_result = nil,
  analysis_token = nil,
  active_hunk_render_scheduled = false,
  inline_render_scheduled = {},
}

local current_location
local reset_state
local write_review_buffers
local open_file
local render_active_hunk
local schedule_active_hunk_render
local schedule_inline_render
local start_ai_analysis
local update_windows

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Flow review" })
end

local function present(value)
  return value ~= nil and value ~= vim.NIL and value ~= ""
end

local function current_plan()
  return require("flow").current()
end

local function active_meta()
  if state.mode == "flow" and state.plan_id then
    return store.meta(state.plan_id) or state.meta
  end
  return state.meta
end

local function active_review_id()
  return state.review_id or state.plan_id
end

local function review_context(plan_id)
  if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) and (plan_id == nil or plan_id == state.plan_id) then
    return state.plan_id, active_meta(), active_review_id()
  end
  local resolved = plan_id or current_plan()
  return resolved, resolved and store.meta(resolved) or nil, resolved
end

local function open_comments(meta)
  local review_id = active_review_id()
  return review_id and meta and store.open_review_comments(review_id, meta.cwd) or {}
end

local function changed_buffer(root)
  local prefix = vim.fn.resolve(root):gsub("/+$", "") .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local name = vim.fn.resolve(vim.api.nvim_buf_get_name(buf))
      if vim.startswith(name, prefix) then
        return name
      end
    end
  end
  return nil
end

local function same_head(meta)
  if not meta or not present(meta.worktree) or not present(meta.verified_head) then
    return false, "The implementation is not verified yet."
  end
  local head, head_err = worktree.head(meta.worktree)
  if not head then
    return false, head_err
  end
  if head ~= meta.verified_head then
    return false, "The implementation changed after its last verification."
  end
  return true, nil
end

function M.reviewable(meta)
  return same_head(meta)
end

function M.ready(meta)
  local ok, err = same_head(meta)
  if not ok then
    return false, err
  end
  local modified = changed_buffer(meta.worktree)
  if modified then
    return false, "Save or discard the unsaved worktree buffer first: " .. modified
  end
  local clean, clean_err = worktree.is_clean(meta.worktree)
  if not clean then
    return false, clean_err or "The implementation worktree is not clean."
  end
  return true, nil
end

local function name_status(meta)
  local result = worktree.git(meta.worktree, {
    "diff", "--name-status", "--find-renames", "--ignore-all-space", meta.base_head,
  })
  if not result.ok then
    return nil, result.err ~= "" and result.err or result.out
  end
  local candidates = {}
  for line in (result.out .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local fields = vim.split(line, "\t", { plain = true })
      local code = fields[1] or "M"
      if code:sub(1, 1) == "R" or code:sub(1, 1) == "C" then
        table.insert(candidates, { status = code:sub(1, 1), old_file = fields[2], file = fields[3] })
      else
        table.insert(candidates, { status = code:sub(1, 1), old_file = fields[2], file = fields[2] })
      end
    end
  end
  local changes = {}
  local seen = {}
  for _, change in ipairs(candidates) do
    local args = { "diff", "--no-color", "--ignore-all-space", meta.base_head, "--" }
    if change.old_file and change.old_file ~= change.file then
      table.insert(args, change.old_file)
    end
    table.insert(args, change.file)
    local patch = worktree.git(meta.worktree, args)
    if not patch.ok then
      return nil, patch.err ~= "" and patch.err or patch.out
    end
    if patch.out ~= "" then
      table.insert(changes, change)
      seen[change.file] = true
    end
  end
  local untracked = worktree.git(meta.worktree, { "ls-files", "--others", "--exclude-standard" })
  if not untracked.ok then
    return nil, untracked.err ~= "" and untracked.err or untracked.out
  end
  for file in (untracked.out .. "\n"):gmatch("([^\n]*)\n") do
    if file ~= "" and not seen[file] then
      table.insert(changes, { status = "A", old_file = file, file = file })
    end
  end
  return changes, nil
end

local function file_hunks(meta, change)
  local result = worktree.git(meta.worktree, {
    "diff", "--no-color", "--unified=0", "--ignore-all-space", meta.base_head, "--", change.file,
  })
  if not result.ok then
    return nil, result.err ~= "" and result.err or result.out
  end
  local hunks = {}
  local binary = result.out:find("Binary files", 1, true) ~= nil or result.out:find("GIT binary patch", 1, true) ~= nil
  for line in (result.out .. "\n"):gmatch("([^\n]*)\n") do
    local old_start, old_count, new_start, new_count, label = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@%s*(.*)$")
    if old_start then
      table.insert(hunks, {
        file = change.file,
        old_file = change.old_file,
        status = change.status,
        old_start = tonumber(old_start),
        old_count = old_count == "" and 1 or tonumber(old_count),
        new_start = tonumber(new_start),
        new_count = new_count == "" and 1 or tonumber(new_count),
        label = label,
        binary = binary,
      })
    end
  end
  if #hunks == 0 then
    table.insert(hunks, {
      file = change.file,
      old_file = change.old_file,
      status = change.status,
      old_start = 1,
      old_count = change.status == "A" and 0 or 1,
      new_start = 1,
      new_count = change.status == "D" and 0 or 1,
      label = change.status == "D" and "Deleted file" or "Changed file",
      binary = binary,
    })
  end
  return hunks, nil
end

local function text_lines(text)
  text = tostring(text or ""):gsub("\r\n", "\n")
  text = text:gsub("\n$", "")
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

local function disk_text(path)
  if vim.fn.filereadable(path) ~= 1 then
    return ""
  end
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if not ok then
    return ""
  end
  return table.concat(lines, "\n")
end

local function buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    return ""
  end
  return table.concat(lines, "\n")
end

local function base_text(meta, change)
  if change.status == "A" then
    return "", false
  end
  local path = change.old_file or change.file
  local result = worktree.git(meta.worktree, { "show", meta.base_head .. ":" .. path })
  if not result.ok then
    return "", false
  end
  return result.out, result.out:find("\0", 1, true) ~= nil
end

local function inline_hunks(base, current, binary)
  if binary or base:find("\0", 1, true) or current:find("\0", 1, true) then
    return { {
      old_start = 1,
      old_count = 1,
      new_start = 1,
      new_count = 1,
      deleted_lines = {},
      binary = true,
    } }
  end
  local ok, indices = pcall(vim.diff, base, current, {
    result_type = "indices",
    algorithm = "histogram",
    ignore_whitespace = true,
  })
  if not ok then
    return {}
  end
  local old_lines = text_lines(base)
  local hunks = {}
  for _, item in ipairs(indices) do
    local deleted = {}
    for line = item[1], item[1] + item[2] - 1 do
      table.insert(deleted, old_lines[line] or "")
    end
    table.insert(hunks, {
      old_start = item[1],
      old_count = item[2],
      new_start = item[3],
      new_count = item[4],
      deleted_lines = deleted,
      binary = false,
    })
  end
  return hunks
end

local function file_kind(file)
  local lower = tostring(file):lower()
  local name = vim.fn.fnamemodify(lower, ":t")
  if lower:match("^tests?/")
    or lower:match("^spec/")
    or lower:find("/test/", 1, true)
    or lower:find("/tests/", 1, true)
    or lower:find("/spec/", 1, true)
    or name:find("_test.", 1, true)
    or name:find("_spec.", 1, true)
    or name:find(".test.", 1, true)
    or name:find(".spec.", 1, true) then
    return "TESTS", 2
  end
  if lower:match("^docs?/")
    or lower:match("^config/")
    or lower:find("/docs/", 1, true)
    or lower:find("/config/", 1, true)
    or name == "readme.md"
    or name:match("%.md$")
    or name:match("%.lock$") then
    return "SUPPORTING", 3
  end
  return "CORE", 1
end

local function hunk_totals(hunks)
  local added, deleted = 0, 0
  for _, hunk in ipairs(hunks) do
    if not hunk.binary then
      added = added + hunk.new_count
      deleted = deleted + hunk.old_count
    end
  end
  return added, deleted
end

local function prepare_files(meta, changes)
  local files = {}
  for _, change in ipairs(changes) do
    local before, binary = base_text(meta, change)
    local current = disk_text(meta.worktree .. "/" .. change.file)
    local hunks = inline_hunks(before, current, binary)
    if #hunks == 0 then
      local git_hunks = file_hunks(meta, change)
      if git_hunks and git_hunks[1] and git_hunks[1].binary then
        hunks = inline_hunks("\0", "", true)
      elseif git_hunks and #git_hunks > 0 then
        hunks = { {
          old_start = git_hunks[1].old_start,
          old_count = git_hunks[1].old_count,
          new_start = git_hunks[1].new_start,
          new_count = git_hunks[1].new_count,
          deleted_lines = {},
          binary = false,
          label = git_hunks[1].label,
        } }
      end
    end
    local kind, rank = file_kind(change.file)
    local added, deleted = hunk_totals(hunks)
    table.insert(files, {
      change = change,
      file = change.file,
      status = change.status,
      kind = kind,
      rank = rank,
      base_text = before,
      current_text = current,
      binary = binary,
      hunks = hunks,
      added = added,
      deleted = deleted,
    })
  end
  table.sort(files, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    local a_size = a.added + a.deleted
    local b_size = b.added + b.deleted
    if a_size ~= b_size then
      return a_size > b_size
    end
    return a.file < b.file
  end)
  local total = 0
  for index, entry in ipairs(files) do
    entry.index = index
    for hunk_index, hunk in ipairs(entry.hunks) do
      total = total + 1
      hunk.index = hunk_index
      hunk.global_index = total
      hunk.file = entry.file
      hunk.old_file = entry.change.old_file
      hunk.status = entry.status
    end
  end
  return files
end

function M.hunks(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  local ok, err = M.reviewable(meta)
  if not ok then
    return nil, err
  end
  local changes, changes_err = name_status(meta)
  if not changes then
    return nil, changes_err
  end
  local hunks = {}
  for _, entry in ipairs(prepare_files(meta, changes)) do
    for _, hunk in ipairs(entry.hunks) do
      table.insert(hunks, hunk)
    end
  end
  return hunks, nil
end

function M.context(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return ""
  end
  local location = state.plan_id == plan_id and current_location(meta) or nil
  local file = location and location.file or (present(meta.review_file) and meta.review_file or nil)
  if not file then
    local hunks = M.hunks(plan_id)
    file = hunks and hunks[1] and hunks[1].file or nil
  end
  if not file then
    return ""
  end
  local result = worktree.git(meta.worktree, {
    "diff", "--no-color", "--unified=8", "--ignore-all-space", meta.base_head, "--", file,
  })
  local diff = result.ok and result.out or ""
  return table.concat({
    string.format("Reviewed %s near line %d.", file, location and location.line or tonumber(meta.review_line) or 1),
    diff,
  }, "\n")
end

local REVIEW_MAPS = {
  { "n", "J" }, { "n", "K" }, { "n", "]c" }, { "n", "[c" },
  { "n", "]f" }, { "n", "[f" },
  { "n", "]r" }, { "n", "[r" }, { "n", "gc" }, { "x", "gc" },
  { "n", "gC" }, { "n", "s" }, { "n", "a" }, { "n", "m" },
  { "n", "u" }, { "n", "gA" }, { "n", "<leader>o" }, { "n", "q" }, { "n", "?" },
}

local function root_prefix(meta)
  return vim.fn.resolve(meta.worktree):gsub("/+$", "") .. "/"
end

local function relative_file(meta, buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local resolved = vim.fn.resolve(name)
  local prefix = root_prefix(meta)
  if not vim.startswith(resolved, prefix) then
    return nil
  end
  return resolved:sub(#prefix + 1)
end

local function escape_statusline(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

current_location = function(meta)
  if vim.api.nvim_get_current_tabpage() ~= state.tab then
    return state.location
  end
  local buf = vim.api.nvim_get_current_buf()
  local file = relative_file(meta, buf)
  if file then
    local cursor = vim.api.nvim_win_get_cursor(0)
    state.location = { file = file, line = cursor[1], col = cursor[2] }
  end
  return state.location
end

local function comment_lines(comment)
  local out = {}
  for index, line in ipairs(vim.split(tostring(comment.body or ""), "\n", { plain = true })) do
    local prefix = index == 1 and "  ● " or "    "
    table.insert(out, { { prefix .. line, "FlowReviewCommentText" } })
  end
  return #out > 0 and out or { { { "  ● Review comment", "FlowReviewCommentText" } } }
end

function M.render_comments(buf)
  local meta = active_meta()
  local file = meta and relative_file(meta, buf)
  if not file or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for id, mark in pairs(state.marks) do
    if mark.buf == buf then
      state.marks[id] = nil
    end
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for _, comment in ipairs(open_comments(meta)) do
    if comment.file == file then
      local first = math.max(1, math.min(tonumber(comment.start_line) or 1, count))
      local last = math.max(first, math.min(tonumber(comment.end_line) or first, count))
      local mark = vim.api.nvim_buf_set_extmark(buf, M.ns, first - 1, 0, {
        end_row = last,
        end_col = 0,
        hl_group = "FlowReviewCommentRange",
        priority = 120,
        sign_text = "●",
        sign_hl_group = "FlowReviewComment",
        virt_lines = comment_lines(comment),
      })
      state.marks[comment.id] = { buf = buf, mark = mark }
    end
  end
end

local function reindex_files()
  local total = 0
  for file_index, entry in ipairs(state.files) do
    entry.index = file_index
    entry.added, entry.deleted = hunk_totals(entry.hunks)
    for hunk_index, hunk in ipairs(entry.hunks) do
      total = total + 1
      hunk.index = hunk_index
      hunk.global_index = total
      hunk.file = entry.file
      hunk.old_file = entry.change.old_file
      hunk.status = entry.status
    end
  end
  state.hunk_count = total
end

local function fallback_sort_files()
  table.sort(state.files, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    local a_size = a.added + a.deleted
    local b_size = b.added + b.deleted
    if a_size ~= b_size then
      return a_size > b_size
    end
    return a.file < b.file
  end)
  reindex_files()
end

local function attach_hunk_insights(entry)
  local insights = state.analysis_result
    and state.analysis_result.hunk_insights
    and state.analysis_result.hunk_insights[entry.file]
    or {}
  for index, hunk in ipairs(entry.hunks) do
    hunk.ai = insights[index]
  end
end

local function refresh_open_overview()
  local open = state.overview and state.overview.win and vim.api.nvim_win_is_valid(state.overview.win)
  if open and M.overview then
    M.overview()
    M.overview()
  end
end

local function apply_ai_analysis(analysis)
  local current_file = state.location and state.location.file
  local ordered = {}
  local included = {}
  for _, path in ipairs(analysis.order or {}) do
    local entry = state.file_by_path[path]
    if entry and not included[path] then
      table.insert(ordered, entry)
      included[path] = true
    end
  end
  for _, entry in ipairs(state.files) do
    if not included[entry.file] then
      table.insert(ordered, entry)
    end
  end
  state.files = ordered
  state.analysis_result = analysis
  state.analysis_status = "ready"
  for _, entry in ipairs(state.files) do
    entry.ai_group = analysis.group_by_file[entry.file]
    entry.ai = analysis.file_insights[entry.file]
    attach_hunk_insights(entry)
  end
  reindex_files()
  if current_file and state.file_by_path[current_file] then
    state.file_index = state.file_by_path[current_file].index
  end
  refresh_open_overview()
  render_active_hunk()
  update_windows()
end

local function review_intent(meta)
  if state.plan_id then
    local revision = store.revision(state.plan_id, nil, meta.cwd)
    if revision and present(revision.plan_md) then
      return revision.plan_md
    end
  end
  local history = worktree.git(meta.worktree, {
    "log", "--format=%s%n%b", meta.base_head .. "..HEAD",
  })
  if history.ok and present(history.out) then
    return history.out
  end
  return meta.title
end

start_ai_analysis = function()
  if not M.analysis.enabled() then
    state.analysis_status = "off"
    return false
  end
  local meta = active_meta()
  if not meta or #state.files == 0 then
    return false
  end
  local refresh_loading = state.analysis_status ~= "loading" or state.analysis_result ~= nil
  local token = {}
  state.analysis_token = token
  state.analysis_status = "loading"
  state.analysis_result = nil
  for _, entry in ipairs(state.files) do
    entry.ai = nil
    entry.ai_group = nil
    for _, hunk in ipairs(entry.hunks) do
      hunk.ai = nil
    end
  end
  for buf in pairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      M.render_inline(buf)
    end
  end
  fallback_sort_files()
  if refresh_loading then
    refresh_open_overview()
  end
  update_windows()
  local started = M.analysis.start(meta, state.files, {
    intent = review_intent(meta),
    on_done = function(analysis)
      if state.analysis_token ~= token or not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
        return
      end
      apply_ai_analysis(analysis)
      notify("AI review map ready.")
    end,
    on_error = function()
      if state.analysis_token ~= token then
        return
      end
      state.analysis_status = "unavailable"
      refresh_open_overview()
      update_windows()
    end,
  })
  if not started and state.analysis_token == token and state.analysis_status == "loading" then
    state.analysis_status = "unavailable"
    refresh_open_overview()
    update_windows()
  end
  return started
end

function M.refresh_analysis()
  if not M.analysis.enabled() then
    notify("AI review maps are disabled. Set vim.g.flow_review_ai to true to enable them.", vim.log.levels.INFO)
    return false
  end
  return start_ai_analysis()
end

local function hunk_anchor(hunk, line_count)
  if hunk.new_count > 0 then
    return math.max(0, math.min(hunk.new_start - 1, line_count - 1)), true
  end
  if hunk.new_start < line_count then
    return math.max(0, hunk.new_start), true
  end
  return math.max(0, line_count - 1), false
end

local function hunk_target(hunk, line_count)
  if hunk.new_count > 0 then
    return math.max(1, math.min(hunk.new_start, line_count))
  end
  return math.max(1, math.min(hunk.new_start + 1, line_count))
end

local function hunk_header(hunk, index, count)
  local old_last = hunk.old_count > 0 and hunk.old_start + hunk.old_count - 1 or hunk.old_start
  local old_range = hunk.old_count > 1 and string.format("%d–%d", hunk.old_start, old_last) or tostring(hunk.old_start)
  local label = hunk.label and hunk.label ~= "" and " · " .. hunk.label or ""
  local totals
  if hunk.binary then
    totals = "binary"
  elseif hunk.old_count > 0 and hunk.new_count > 0 then
    totals = string.format("+%d −%d", hunk.new_count, hunk.old_count)
  elseif hunk.old_count > 0 then
    totals = string.format("−%d", hunk.old_count)
  else
    totals = string.format("+%d", hunk.new_count)
  end
  return { {
    string.format("  ── CHANGE %d/%d · %s · base %s%s ", index, count, totals, old_range, label),
    "FlowReviewHunkHeader",
  } }
end

local function deleted_display_lines(hunk)
  local lines = vim.deepcopy(hunk.deleted_lines or {})
  if lines[1] then
    lines[1] = lines[1]:gsub("^\239\187\191", "")
  end
  return lines
end

local function selected_hunk(buf, entry)
  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  for _, hunk in ipairs(entry.hunks) do
    if hunk.mark then
      local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.diff_ns, hunk.mark, {})
      if #mark > 0 then
        local first = mark[1] + 1
        local last = hunk.new_count > 0 and first + hunk.new_count - 1 or first
        if cursor_line >= first and cursor_line <= last then
          return hunk, first
        end
      end
    end
  end
  return nil
end

local function word_tokens(line)
  local tokens = {}
  local byte = 1
  while byte <= #line do
    local remainder = line:sub(byte)
    local text = remainder:match("^%s+") or remainder:match("^[%w_]+") or remainder:match("^[^%w_%s]+")
    if not text or text == "" then
      text = remainder:sub(1, 1)
    end
    table.insert(tokens, { text = text, first = byte - 1, last = byte - 1 + #text })
    byte = byte + #text
  end
  return tokens
end

local function matching_tokens(old_tokens, new_tokens)
  local old_matches = {}
  local new_matches = {}
  if #old_tokens * #new_tokens > 40000 then
    local first = 1
    while first <= #old_tokens and first <= #new_tokens and old_tokens[first].text == new_tokens[first].text do
      old_matches[first] = true
      new_matches[first] = true
      first = first + 1
    end
    local old_last = #old_tokens
    local new_last = #new_tokens
    while old_last >= first and new_last >= first and old_tokens[old_last].text == new_tokens[new_last].text do
      old_matches[old_last] = true
      new_matches[new_last] = true
      old_last = old_last - 1
      new_last = new_last - 1
    end
    return old_matches, new_matches
  end
  local lengths = {}
  lengths[0] = { [0] = 0 }
  for new_index = 1, #new_tokens do
    lengths[0][new_index] = 0
  end
  for old_index = 1, #old_tokens do
    lengths[old_index] = { [0] = 0 }
    for new_index = 1, #new_tokens do
      if old_tokens[old_index].text == new_tokens[new_index].text then
        lengths[old_index][new_index] = lengths[old_index - 1][new_index - 1] + 1
      else
        lengths[old_index][new_index] = math.max(lengths[old_index - 1][new_index], lengths[old_index][new_index - 1])
      end
    end
  end
  local old_index = #old_tokens
  local new_index = #new_tokens
  while old_index > 0 and new_index > 0 do
    if old_tokens[old_index].text == new_tokens[new_index].text then
      old_matches[old_index] = true
      new_matches[new_index] = true
      old_index = old_index - 1
      new_index = new_index - 1
    elseif lengths[old_index - 1][new_index] >= lengths[old_index][new_index - 1] then
      old_index = old_index - 1
    else
      new_index = new_index - 1
    end
  end
  return old_matches, new_matches
end

local function enhanced_line_diff(old_line, new_line)
  local old_tokens = word_tokens(old_line)
  local new_tokens = new_line == nil and {} or word_tokens(new_line)
  local old_matches, new_matches = matching_tokens(old_tokens, new_tokens)
  local old_chunks = {}
  for index, token in ipairs(old_tokens) do
    local group = old_matches[index] and "FlowReviewDelete" or "FlowReviewDeleteText"
    local previous = old_chunks[#old_chunks]
    if previous and previous[2] == group then
      previous[1] = previous[1] .. token.text
    else
      table.insert(old_chunks, { token.text, group })
    end
  end
  if #old_chunks == 0 then
    old_chunks = { { " ", "FlowReviewDeleteText" } }
  end
  local new_ranges = {}
  for index, token in ipairs(new_tokens) do
    if not new_matches[index] then
      local previous = new_ranges[#new_ranges]
      if previous and previous[2] == token.first then
        previous[2] = token.last
      else
        table.insert(new_ranges, { token.first, token.last })
      end
    end
  end
  return old_chunks, new_ranges
end

local function enhance_hunk(buf, hunk, line_count)
  hunk.deleted_virtual_lines = {}
  if hunk.binary then
    return
  end
  local first = math.max(0, hunk.new_start - 1)
  local available = math.max(0, math.min(hunk.new_count, line_count - first))
  local current_lines = available > 0 and vim.api.nvim_buf_get_lines(buf, first, first + available, false) or {}
  for index, old_line in ipairs(deleted_display_lines(hunk)) do
    local old_chunks, new_ranges = enhanced_line_diff(old_line, current_lines[index])
    table.insert(hunk.deleted_virtual_lines, old_chunks)
    if current_lines[index] ~= nil then
      local row = first + index - 1
      for _, range in ipairs(new_ranges) do
        if range[2] > range[1] then
          vim.api.nvim_buf_set_extmark(buf, M.diff_ns, row, range[1], {
            end_row = row,
            end_col = range[2],
            hl_group = "FlowReviewAddText",
            hl_mode = "combine",
            priority = 100,
          })
        end
      end
    end
  end
end

local function set_hunk_virtual_lines(buf, entry, selected)
  for index, hunk in ipairs(entry.hunks) do
    if hunk.mark then
      local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.diff_ns, hunk.mark, {})
      if #mark > 0 then
        local virtual = { hunk_header(hunk, index, #entry.hunks) }
        if hunk.binary then
          table.insert(virtual, { { "  ◆ Binary file changed", "FlowReviewBinary" } })
        elseif hunk == selected then
          if state.analysis_status == "ready" and hunk.ai then
            local risk = entry.ai_group and entry.ai_group.risk or "MEDIUM"
            table.insert(virtual, {
              { "  ◆ " .. risk .. " · ", "FlowReviewAIRisk" .. risk },
              { hunk.ai.briefing, "FlowReviewAI" },
            })
            for _, check in ipairs(hunk.ai.checks or {}) do
              table.insert(virtual, { { "      Check · " .. check, "FlowReviewAIReason" } })
            end
          end
          for _, line in ipairs(hunk.deleted_virtual_lines or {}) do
            table.insert(virtual, line)
          end
        end
        vim.api.nvim_buf_set_extmark(buf, M.diff_ns, mark[1], mark[2], {
          id = hunk.mark,
          virt_lines = virtual,
          virt_lines_above = hunk.above,
          priority = 90,
        })
      end
    end
  end
end

local function render_deleted_file_notice(buf, entry, current)
  if entry.status ~= "D" or current ~= "" then
    return
  end
  local name = vim.fn.fnamemodify(entry.file, ":t")
  vim.api.nvim_buf_set_extmark(buf, M.diff_ns, 0, 0, {
    virt_text = {
      { "  󰆴 ", "FlowReviewDeletedFile" },
      { name, "FlowReviewDeletedFileName" },
      { " was deleted", "FlowReviewDeletedFile" },
    },
    virt_text_pos = "eol",
    priority = 120,
  })
end

render_active_hunk = function()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  local meta = active_meta()
  local buf = vim.api.nvim_win_get_buf(state.win)
  local file = meta and relative_file(meta, buf)
  local entry = file and state.file_by_path[file] or nil
  if not entry then
    return
  end
  local selected = not state.overview and selected_hunk(buf, entry) or nil
  set_hunk_virtual_lines(buf, entry, selected)
end

schedule_active_hunk_render = function()
  if state.active_hunk_render_scheduled then
    return
  end
  state.active_hunk_render_scheduled = true
  vim.schedule(function()
    state.active_hunk_render_scheduled = false
    render_active_hunk()
  end)
end

function M.render_inline(buf)
  local meta = active_meta()
  local file = meta and relative_file(meta, buf)
  local entry = file and state.file_by_path[file] or nil
  if not entry or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.diff_ns, 0, -1)
  local current = buffer_text(buf)
  entry.current_text = current
  entry.hunks = inline_hunks(entry.base_text, current, entry.binary)
  if #entry.hunks == 0 then
    local git_hunks = file_hunks(meta, entry.change)
    if git_hunks and git_hunks[1] and git_hunks[1].binary then
      entry.hunks = inline_hunks("\0", "", true)
    end
  end
  attach_hunk_insights(entry)
  reindex_files()
  local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
  for index, hunk in ipairs(entry.hunks) do
    local anchor, above = hunk_anchor(hunk, line_count)
    hunk.above = above
    local virtual = { hunk_header(hunk, index, #entry.hunks) }
    if hunk.binary then
      table.insert(virtual, { { "  ◆ Binary file changed", "FlowReviewBinary" } })
    end
    hunk.mark = vim.api.nvim_buf_set_extmark(buf, M.diff_ns, anchor, 0, {
      virt_lines = virtual,
      virt_lines_above = above,
      priority = 90,
    })
    hunk.target = hunk_target(hunk, line_count)
    if hunk.new_count > 0 and not hunk.binary then
      local first = math.max(0, hunk.new_start - 1)
      local last = math.min(line_count - 1, first + hunk.new_count - 1)
      for row = first, last do
        vim.api.nvim_buf_set_extmark(buf, M.diff_ns, row, 0, {
          line_hl_group = "FlowReviewAdd",
          number_hl_group = "FlowReviewAddMarker",
          sign_text = "▎",
          sign_hl_group = "FlowReviewAddMarker",
          priority = 80,
        })
      end
    end
    enhance_hunk(buf, hunk, line_count)
  end
  render_deleted_file_notice(buf, entry, current)
  schedule_active_hunk_render()
end

local function sync_comment_marks()
  local meta = active_meta()
  local review_id = active_review_id()
  if not meta or not review_id then
    return
  end
  for comment_id, item in pairs(state.marks) do
    if vim.api.nvim_buf_is_valid(item.buf) then
      local found = vim.api.nvim_buf_get_extmark_by_id(item.buf, M.ns, item.mark, { details = true })
      if #found > 0 then
        local first = found[1] + 1
        local details = found[3] or {}
        local last = math.max(first, tonumber(details.end_row) or first)
        local lines = vim.api.nvim_buf_get_lines(item.buf, first - 1, last, false)
        store.update_review_comment(review_id, comment_id, {
          start_line = first,
          end_line = last,
          quote = table.concat(lines, "\n"),
        }, meta.cwd)
      end
    end
  end
end

local function set_location(plan_id)
  local meta = plan_id and store.meta(plan_id)
  local location = meta and current_location(meta)
  if location then
    store.set_meta(plan_id, {
      review_file = location.file,
      review_line = location.line,
      review_col = location.col,
    }, meta.cwd)
  end
end

function M.statusline()
  local meta = active_meta()
  if not meta or vim.api.nvim_get_current_tabpage() ~= state.tab then
    return ""
  end
  local location = current_location(meta) or {}
  local entry = location.file and state.file_by_path[location.file] or nil
  local pending = state.comment_count
  local status, group
  if state.mode == "diff" and state.dirty then
    status, group = "EDITED", "FlowStale"
  elseif state.mode == "diff" then
    status, group = "LIVE DIFF", "FlowCurrent"
  elseif state.dirty or pending > 0 then
    status, group = "CHANGES PENDING", "FlowStale"
  elseif meta.status == "merge_ready" then
    status, group = "APPROVED", "FlowDone"
  else
    status, group = "VERIFIED", "FlowDone"
  end
  local comments = pending > 0 and string.format(" · %d %s", pending, state.mode == "diff" and (pending == 1 and "note" or "notes") or (pending == 1 and "comment" or "comments")) or ""
  local progress = entry and string.format(" · %d/%d files · %d changes", entry.index, #state.files, state.hunk_count or 0) or ""
  local ai_status = ({
    loading = " · AI mapping",
    ready = " · AI map",
    stale = " · AI stale",
    unavailable = " · AI unavailable",
  })[state.analysis_status] or ""
  local actions
  if vim.o.columns < 120 then
    actions = "  ? help "
  elseif state.mode == "diff" then
    actions = "  K next · J previous · <leader>o overview · gc note · s save · ? help "
  else
    actions = "  K next · J previous · <leader>o overview · gc comment · s submit · m merge · ? help "
  end
  return table.concat({
    "%#FlowTitle# 󰐅 FLOW REVIEW ",
    "%#FlowHint# ", escape_statusline(meta.title),
    escape_statusline(progress .. ai_status),
    "%<",
    "%=",
    "%#", group, "# ", status, comments, " ",
    "%#FlowHint#", actions,
  })
end

update_windows = function()
  local meta = active_meta()
  if not meta or not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
    return
  end
  local function set_winbar(win, value)
    pcall(function()
      vim.wo[win].winbar = value
    end)
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local file = relative_file(meta, buf)
    local config = vim.api.nvim_win_get_config(win)
    if config.relative == "" and file then
      local entry = state.file_by_path[file]
      vim.wo[win].wrap = false
      vim.wo[win].cursorline = true
      vim.wo[win].diff = false
      vim.wo[win].number = true
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "yes:1"
      local status
      if state.mode == "diff" then
        status = state.dirty and "%#FlowStale# EDITED" or "%#FlowCurrent# EDITABLE"
      else
        status = state.dirty and "%#FlowStale# EDITED" or "%#FlowDone# VERIFIED"
      end
      local section = entry and entry.kind or "CONTEXT"
      if entry and state.analysis_status == "ready" and entry.ai_group then
        section = entry.ai_group.risk .. " · " .. entry.ai_group.title
      end
      local position = entry and string.format(" %02d/%02d · %s ", entry.index, #state.files, section) or " CONTEXT "
      local totals = entry and string.format(" +%d −%d · %d changes ", entry.added, entry.deleted, #entry.hunks) or ""
      set_winbar(win, "%#FlowTitle#" .. position .. "%#FlowHint# " .. escape_statusline(file) .. escape_statusline(totals) .. "%=" .. status .. "%#FlowHint# · <leader>o overview ")
    end
  end
  vim.cmd("redrawstatus")
end

schedule_inline_render = function(buf)
  if state.inline_render_scheduled[buf] then
    return
  end
  state.inline_render_scheduled[buf] = true
  vim.schedule(function()
    state.inline_render_scheduled[buf] = nil
    if state.tab and vim.api.nvim_buf_is_valid(buf) then
      M.render_inline(buf)
      update_windows()
    end
  end)
end

local function mark_dirty(buf)
  if state.analysis_status == "loading" or state.analysis_status == "ready" then
    state.analysis_token = nil
    state.analysis_status = "stale"
    refresh_open_overview()
    render_active_hunk()
  end
  if state.dirty then
    return
  end
  local meta = active_meta()
  if meta and relative_file(meta, buf) then
    state.dirty = true
    if state.mode ~= "diff" and meta.status ~= "review_dirty" then
      store.set_meta(state.plan_id, { status = "review_dirty" }, meta.cwd)
    end
    current_location(meta)
    update_windows()
  end
end

local function map(buf, mode, lhs, fn, desc)
  vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

local function range_at_cursor()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local first = vim.fn.line("v")
    local last = vim.fn.line(".")
    return math.min(first, last), math.max(first, last)
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return line, line
end

local function review_maps(buf, plan_id)
  map(buf, "n", "K", function() M.next(plan_id) end, "Flow: next changed hunk")
  map(buf, "n", "J", function() M.prev(plan_id) end, "Flow: previous changed hunk")
  map(buf, "n", "]c", function() M.next(plan_id) end, "Flow: next changed hunk")
  map(buf, "n", "[c", function() M.prev(plan_id) end, "Flow: previous changed hunk")
  map(buf, "n", "]f", function() M.next_file(1) end, "Flow: next changed file")
  map(buf, "n", "[f", function() M.next_file(-1) end, "Flow: previous changed file")
  map(buf, "n", "]r", function() M.next_comment(1) end, "Flow: next review comment")
  map(buf, "n", "[r", function() M.next_comment(-1) end, "Flow: previous review comment")
  map(buf, { "n", "x" }, "gc", function()
    local first, last = range_at_cursor()
    M.comment(plan_id, nil, { buf = buf, start_line = first, end_line = last })
  end, "Flow: add review comment")
  map(buf, "n", "gC", function() M.remove_comment(plan_id) end, "Flow: remove review comment")
  map(buf, "n", "gA", M.refresh_analysis, "Flow: refresh AI review map")
  map(buf, "n", "<leader>o", M.overview, "Flow: toggle review overview")
  if state.mode == "diff" then
    map(buf, "n", "s", function() M.submit() end, "Flow: save review edits and notes")
  else
    map(buf, "n", "s", function() M.submit(plan_id) end, "Flow: submit review changes")
    map(buf, "n", "a", function() M.approve(plan_id) end, "Flow: approve review")
    map(buf, "n", "m", function() M.merge(plan_id) end, "Flow: squash and commit")
    map(buf, "n", "u", function() M.restore(plan_id) end, "Flow: restore before feedback")
  end
  map(buf, "n", "q", M.close, "Flow: close review")
  map(buf, "n", "?", M.help, "Flow: review help")
end

local function attach_buffer(buf)
  if state.buffers[buf] or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local meta = active_meta()
  if not meta or not relative_file(meta, buf) then
    return
  end
  state.buffers[buf] = true
  review_maps(buf, state.plan_id)
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  M.render_inline(buf)
  M.render_comments(buf)
end

local function attach_tab()
  if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    attach_buffer(vim.api.nvim_win_get_buf(win))
  end
  update_windows()
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("EthanFlowReview", { clear = true })
  state.group = group
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function(ev)
      if not state.tab or vim.api.nvim_get_current_tabpage() ~= state.tab then
        return
      end
      attach_buffer(ev.buf)
      local win = vim.api.nvim_get_current_win()
      local meta = active_meta()
      if vim.api.nvim_win_get_config(win).relative == "" and meta and relative_file(meta, ev.buf) then
        state.win = win
      end
      update_windows()
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(ev)
      if state.tab then
        mark_dirty(ev.buf)
        schedule_inline_render(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if state.tab then
        mark_dirty(ev.buf)
        M.render_inline(ev.buf)
        M.render_comments(ev.buf)
        update_windows()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function()
      if state.plan_id then
        set_location(state.plan_id)
      else
        local meta = active_meta()
        if meta then
          current_location(meta)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if state.tab and vim.api.nvim_get_current_tabpage() == state.tab then
        schedule_active_hunk_render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      vim.schedule(function()
        if state.tab and not vim.api.nvim_tabpage_is_valid(state.tab) then
          reset_state()
        end
      end)
    end,
  })
end

local function clear_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.diff_ns, 0, -1)
  for _, entry in ipairs(REVIEW_MAPS) do
    pcall(vim.keymap.del, entry[1], entry[2], { buffer = buf })
  end
end

reset_state = function()
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
  end
  for buf in pairs(state.buffers) do
    clear_buffer(buf)
  end
  if state.previous_ui then
    vim.o.laststatus = state.previous_ui.laststatus
    vim.o.statusline = state.previous_ui.statusline
  end
  state = {
    tab = nil,
    win = nil,
    plan_id = nil,
    review_id = nil,
    mode = nil,
    meta = nil,
    buffers = {},
    marks = {},
    comment_count = 0,
    dirty = false,
    closing = false,
    previous_ui = nil,
    previous_tab = nil,
    location = nil,
    files = {},
    file_by_path = {},
    file_index = nil,
    overview = nil,
    analysis_status = "off",
    analysis_result = nil,
    analysis_token = nil,
    active_hunk_render_scheduled = false,
    inline_render_scheduled = {},
  }
end

function M.close()
  if not state.tab or state.closing then
    return
  end
  local meta = active_meta()
  if meta and write_review_buffers then
    local written, write_err = write_review_buffers(meta)
    if not written then
      notify("Flow could not save the review edits: " .. tostring(write_err), vim.log.levels.ERROR)
      return false
    end
  end
  state.closing = true
  if state.plan_id then
    set_location(state.plan_id)
  elseif meta then
    current_location(meta)
  end
  sync_comment_marks()
  local tab = state.tab
  local previous = state.previous_tab
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    if vim.api.nvim_get_current_tabpage() ~= tab then
      pcall(vim.api.nvim_set_current_tabpage, tab)
    end
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose")
    end
  end
  if previous and vim.api.nvim_tabpage_is_valid(previous) then
    pcall(vim.api.nvim_set_current_tabpage, previous)
  end
  reset_state()
  return true
end

local function close_overview()
  if not state.overview then
    return
  end
  local win = state.overview.win
  state.overview = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  schedule_active_hunk_render()
end

function M.overview()
  if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
    return false
  end
  if state.overview and state.overview.win and vim.api.nvim_win_is_valid(state.overview.win) then
    close_overview()
    return true
  end
  schedule_active_hunk_render()
  local meta = active_meta()
  local lines = { tostring(meta.title or "Code review") }
  local file_rows = {}
  local highlights = { [1] = "FlowTitle" }
  local function add(line, group)
    table.insert(lines, line)
    if group then
      highlights[#lines] = group
    end
    return #lines
  end
  local status_text = ({
    loading = "AI is building a review journey · deterministic order is ready now",
    ready = "AI-guided review journey · risk and ordering reasons are advisory",
    stale = "AI review map is stale after an edit · press gA to refresh",
    unavailable = "AI review map unavailable · deterministic order is active",
    off = "Deterministic review order · AI review maps are disabled",
  })[state.analysis_status] or "Deterministic review order"
  add(string.format("%d files · %d changes · %s", #state.files, state.hunk_count or 0, status_text), "FlowHint")
  if state.analysis_result and (state.analysis_status == "ready" or state.analysis_status == "stale") then
    if state.analysis_result.summary ~= "" then
      add("  " .. state.analysis_result.summary, "FlowReviewAI")
    end
    add("")
    for _, group in ipairs(state.analysis_result.groups or {}) do
      add(string.format("◆ %-6s  %s", group.risk, group.title), "FlowReviewAIRisk" .. group.risk)
      if group.intent ~= "" then
        add("  " .. group.intent, "FlowReviewAI")
      end
      if group.reason ~= "" then
        add("  Why here · " .. group.reason, "FlowReviewAIReason")
      end
      for _, file in ipairs(group.files or {}) do
        local entry = state.file_by_path[file.path]
        if entry then
          local marker = entry.index == state.file_index and "›" or " "
          local summary = file.summary ~= "" and " · " .. file.summary or ""
          local row = add(string.format(
            " %s %02d  %-2s  %s  +%d −%d%s",
            marker,
            entry.index,
            entry.status,
            entry.file,
            entry.added,
            entry.deleted,
            summary
          ))
          file_rows[row] = entry.index
        end
      end
      add("")
    end
    if #state.analysis_result.test_map > 0 then
      add("VERIFICATION", "FlowReviewSection")
      for _, item in ipairs(state.analysis_result.test_map) do
        local icon = item.status == "COVERED" and "✓" or item.status == "MISSING" and "!" or "~"
        local group = item.status == "COVERED" and "FlowReviewAICovered" or item.status == "MISSING" and "FlowReviewAIMissing" or "FlowReviewAIReason"
        local evidence = item.evidence ~= "" and " · " .. item.evidence or ""
        add(string.format("  %s %-7s %s%s", icon, item.status, item.behavior, evidence), group)
      end
      add("")
    end
  else
    add("")
    for _, kind in ipairs({ "CORE", "TESTS", "SUPPORTING" }) do
      local section = false
      for _, entry in ipairs(state.files) do
        if entry.kind == kind then
          if not section then
            add(kind, "FlowReviewSection")
            section = true
          end
          local marker = entry.index == state.file_index and "›" or " "
          local row = add(string.format(" %s %02d  %-2s  %s  +%d −%d  %d %s", marker, entry.index, entry.status, entry.file, entry.added, entry.deleted, #entry.hunks, #entry.hunks == 1 and "change" or "changes"))
          file_rows[row] = entry.index
        end
      end
      if section then
        add("")
      end
    end
  end
  add("<CR> open file   K/J review journey   gA refresh AI   <leader>o/q close", "FlowHint")
  local longest = 0
  for _, line in ipairs(lines) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line))
  end
  local max_width = math.max(1, vim.o.columns - 6)
  local min_width = math.min(58, max_width)
  local width = math.max(min_width, math.min(longest + 4, max_width))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "flowreview"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(2, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Flow review overview ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FlowBorder,CursorLine:Visual"
  for row, group in pairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, M.overview_ns, group, row - 1, 0, -1)
  end
  for row, index in pairs(file_rows) do
    if index == state.file_index then
      vim.api.nvim_buf_add_highlight(buf, M.overview_ns, "FlowCurrent", row - 1, 0, -1)
    end
  end
  state.overview = { buf = buf, win = win, file_rows = file_rows }
  local function dismiss()
    close_overview()
  end
  map(buf, "n", "q", dismiss, "Flow: close review overview")
  map(buf, "n", "<Esc>", dismiss, "Flow: close review overview")
  map(buf, "n", "<leader>o", dismiss, "Flow: close review overview")
  map(buf, "n", "gA", M.refresh_analysis, "Flow: refresh AI review map")
  map(buf, "n", "<CR>", function()
    local target = file_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if target then
      close_overview()
      open_file(target)
    end
  end, "Flow: open review file")
  for row in pairs(file_rows) do
    if file_rows[row] == state.file_index then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      break
    end
  end
  return true
end

local function normal_review_window()
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_get_current_tabpage() == state.tab and vim.api.nvim_win_get_config(current).relative == "" then
    return current
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return state.win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

open_file = function(index, line, col)
  local entry = state.files[index]
  local meta = active_meta()
  if not entry or not meta or not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
    return false
  end
  close_overview()
  vim.api.nvim_set_current_tabpage(state.tab)
  local win = normal_review_window()
  if not win then
    return false
  end
  local path = meta.worktree .. "/" .. entry.file
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, buf)
  state.win = win
  state.file_index = index
  state.location = { file = entry.file, line = line or 1, col = col or 0 }
  attach_buffer(buf)
  M.render_inline(buf)
  M.render_comments(buf)
  local count = math.max(1, vim.api.nvim_buf_line_count(buf))
  local target = math.max(1, math.min(tonumber(line) or (entry.hunks[1] and entry.hunks[1].target) or 1, count))
  vim.api.nvim_win_set_cursor(win, { target, math.max(0, tonumber(col) or 0) })
  vim.cmd("normal! zz")
  current_location(meta)
  update_windows()
  return true
end

local function restore_location(meta)
  if not present(meta.review_file) then
    return false
  end
  local entry = state.file_by_path[meta.review_file]
  if not entry then
    return false
  end
  return open_file(entry.index, tonumber(meta.review_line) or 1, tonumber(meta.review_col) or 0)
end

local function open_view(meta, opts)
  local changes, changes_err = name_status(meta)
  if not changes then
    notify(changes_err, vim.log.levels.ERROR)
    return false
  end
  if #changes == 0 then
    notify(opts.empty_message, vim.log.levels.WARN)
    return false
  end
  if state.mode == opts.mode and active_review_id() == opts.review_id and state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
    vim.api.nvim_set_current_tabpage(state.tab)
    return true
  end

  if state.tab and not M.close() then
    return false
  end
  local before = vim.api.nvim_get_current_tabpage()
  local files = prepare_files(meta, changes)
  local opened, open_err = pcall(vim.cmd, "tabnew")
  if not opened then
    notify("Flow could not open the review tab: " .. tostring(open_err), vim.log.levels.ERROR)
    return false
  end
  local tab = vim.api.nvim_get_current_tabpage()
  if tab == before then
    notify("Flow did not open the implementation review.", vim.log.levels.ERROR)
    return false
  end

  state.tab = tab
  state.win = vim.api.nvim_get_current_win()
  state.plan_id = opts.plan_id
  state.review_id = opts.review_id
  state.mode = opts.mode
  state.meta = meta
  state.buffers = {}
  state.marks = {}
  state.files = files
  state.file_by_path = {}
  state.analysis_status = M.analysis.enabled() and "loading" or "off"
  state.analysis_result = nil
  state.analysis_token = nil
  for _, entry in ipairs(files) do
    state.file_by_path[entry.file] = entry
  end
  reindex_files()
  state.comment_count = #store.open_review_comments(opts.review_id, meta.cwd)
  state.location = opts.mode == "flow" and present(meta.review_file) and {
    file = meta.review_file,
    line = tonumber(meta.review_line) or 1,
    col = tonumber(meta.review_col) or 0,
  } or nil
  state.previous_ui = { laststatus = vim.o.laststatus, statusline = vim.o.statusline }
  state.previous_tab = before
  vim.o.laststatus = 3
  vim.o.statusline = "%!v:lua.require'flow.review'.statusline()"
  local clean = worktree.is_clean(meta.worktree)
  state.dirty = clean == false
  pcall(vim.cmd, "tcd " .. vim.fn.fnameescape(meta.worktree))
  setup_autocmds()
  local restored = opts.mode == "flow" and restore_location(meta)
  if not restored then
    open_file(1)
  end
  if opts.mode == "flow" then
    if meta.status ~= "merge_ready" then
      store.set_meta(opts.plan_id, { status = state.dirty and "review_dirty" or "reviewing" }, meta.cwd)
    end
  end
  if #files > 1 then
    M.overview()
  end
  notify(opts.open_message)
  start_ai_analysis()
  return true
end

function M.open(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  local ok, err = M.reviewable(meta)
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  return open_view(meta, {
    mode = "flow",
    plan_id = plan_id,
    review_id = plan_id,
    empty_message = "The implementation has no changes to review.",
    open_message = "Inline implementation review opened. Current code is fully editable. Press ? for every review command.",
  })
end

local function review_root(cwd)
  if cwd and cwd ~= "" then
    return worktree.repository(cwd)
  end

  local starts = {}
  local active = active_meta()
  if state.mode == "flow" and active and present(active.source_root) then
    table.insert(starts, active.source_root)
  end
  table.insert(starts, vim.fn.getcwd())
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    table.insert(starts, vim.fn.fnamemodify(name, ":h"))
  end

  local seen = {}
  local last_err
  for _, start in ipairs(starts) do
    local resolved = vim.fn.resolve(vim.fn.fnamemodify(start, ":p"))
    if not seen[resolved] then
      seen[resolved] = true
      local root, err = worktree.repository(resolved)
      if root then
        return root
      end
      last_err = err or last_err
    end
  end
  return nil, last_err or "This directory is not a Git repository."
end

local function resolve_base(root, requested)
  local candidates = { requested }
  if requested == "master" then
    table.insert(candidates, "origin/master")
    table.insert(candidates, "main")
    table.insert(candidates, "origin/main")
  end
  for _, candidate in ipairs(candidates) do
    local result = worktree.git(root, { "rev-parse", "--verify", candidate .. "^{commit}" })
    if result.ok then
      return candidate, vim.trim(result.out), nil
    end
  end
  return nil, nil, "Git could not resolve the review base " .. requested .. "."
end

function M.open_diff(base, cwd)
  local root, root_err = review_root(cwd)
  if not root then
    notify(root_err, vim.log.levels.ERROR)
    return false
  end
  local requested = present(base) and vim.trim(base) or "master"
  local base_ref, _, base_err = resolve_base(root, requested)
  if not base_ref then
    notify(base_err, vim.log.levels.ERROR)
    return false
  end
  local head, head_err = worktree.head(root)
  if not head then
    notify(head_err, vim.log.levels.ERROR)
    return false
  end
  local merge_base = worktree.git(root, { "merge-base", base_ref, head })
  if not merge_base.ok or vim.trim(merge_base.out) == "" then
    notify(merge_base.err ~= "" and merge_base.err or "Git could not find a merge base for " .. base_ref .. ".", vim.log.levels.ERROR)
    return false
  end
  local branch = worktree.branch(root) or "HEAD"
  local base_head = vim.trim(merge_base.out)
  local review_id = "diff-" .. vim.fn.sha256(branch .. "\0" .. base_ref):sub(1, 16)
  local meta = {
    cwd = root,
    worktree = root,
    base_head = base_head,
    base_ref = base_ref,
    source_branch = branch,
    verified_head = head,
    title = branch .. " → " .. base_ref,
    status = "diff_review",
  }
  return open_view(meta, {
    mode = "diff",
    review_id = review_id,
    empty_message = "There are no changes between " .. branch .. " and " .. base_ref .. ".",
    open_message = "Inline branch review opened against " .. base_ref .. ". Comments are saved locally. Press ? for every review command.",
  })
end

function M.next_file(direction)
  if #state.files == 0 then
    return false
  end
  local current = state.file_index or 1
  local target = ((current - 1 + direction) % #state.files) + 1
  return open_file(target)
end

local function live_hunk_line(entry, hunk)
  local buf = vim.fn.bufnr(active_meta().worktree .. "/" .. entry.file)
  if buf > 0 and hunk.mark then
    local found = vim.api.nvim_buf_get_extmark_by_id(buf, M.diff_ns, hunk.mark, {})
    if #found > 0 then
      return found[1] + 1
    end
  end
  return hunk.target or math.max(1, hunk.new_start)
end

local function go_to_hunk(file_index, hunk_index)
  local entry = state.files[file_index]
  local hunk = entry and entry.hunks[hunk_index]
  if not hunk then
    return false
  end
  if not open_file(file_index) then
    return false
  end
  hunk = entry.hunks[hunk_index]
  local line = hunk and live_hunk_line(entry, hunk) or 1
  local count = vim.api.nvim_buf_line_count(0)
  line = math.max(1, math.min(line, count))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zz")
  state.location.line = line
  return true
end

local function move_hunk(direction, plan_id)
  local active = state.tab and vim.api.nvim_tabpage_is_valid(state.tab) and (plan_id == nil or state.plan_id == plan_id)
  if not active then
    local resolved = plan_id or current_plan()
    return M.open(resolved)
  end
  close_overview()
  local meta = active_meta()
  local location = current_location(meta) or {}
  local entry = location.file and state.file_by_path[location.file] or state.files[state.file_index or 1]
  if not entry then
    return false
  end
  local line = location.line or vim.api.nvim_win_get_cursor(0)[1]
  if direction > 0 then
    for index, hunk in ipairs(entry.hunks) do
      if live_hunk_line(entry, hunk) > line then
        return go_to_hunk(entry.index, index)
      end
    end
  else
    for index = #entry.hunks, 1, -1 do
      if live_hunk_line(entry, entry.hunks[index]) < line then
        return go_to_hunk(entry.index, index)
      end
    end
  end
  for offset = 1, #state.files do
    local file_index = ((entry.index - 1 + direction * offset) % #state.files) + 1
    local target = state.files[file_index]
    if #target.hunks > 0 then
      return go_to_hunk(file_index, direction > 0 and 1 or #target.hunks)
    end
  end
  return false
end

function M.next(plan_id)
  return move_hunk(1, plan_id)
end

function M.prev(plan_id)
  return move_hunk(-1, plan_id)
end

local function save_comment(plan_id, text, range)
  local resolved, meta, review_id = review_context(plan_id)
  meta = range.review_meta or meta
  review_id = range.review_id or review_id
  local buf = range and range.buf or vim.api.nvim_get_current_buf()
  local file = meta and relative_file(meta, buf)
  if not file then
    notify("Move to the editable worktree pane before adding a comment.", vim.log.levels.WARN)
    return false
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local first = math.max(1, math.min(tonumber(range.start_line) or 1, count))
  local last = math.max(first, math.min(tonumber(range.end_line) or first, count))
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local id = store.add_review_comment(review_id, {
    file = file,
    start_line = first,
    end_line = last,
    quote = table.concat(lines, "\n"),
    body = vim.trim(text),
    checkpoint = meta.verified_head,
  }, meta.cwd)
  if not id then
    notify("Flow could not save that review comment.", vim.log.levels.ERROR)
    return false
  end
  M.render_comments(buf)
  if active_review_id() == review_id then
    state.comment_count = #store.open_review_comments(review_id, meta.cwd)
  end
  update_windows()
  notify(string.format("Comment added to %s:%d.", file, first))
  return true
end

function M.comment(plan_id, text, range)
  range = range or {}
  range.buf = range.buf or vim.api.nvim_get_current_buf()
  local resolved, meta, review_id = review_context(plan_id)
  if not meta or not relative_file(meta, range.buf) then
    notify("Move to the editable worktree pane before adding a comment.", vim.log.levels.WARN)
    return false
  end
  range.start_line = range.start_line or vim.api.nvim_win_get_cursor(0)[1]
  range.end_line = range.end_line or range.start_line
  range.review_meta = meta
  range.review_id = review_id
  if type(text) == "string" and vim.trim(text) ~= "" then
    return save_comment(resolved, text, range)
  end
  require("claude.input").open({ title = "Flow review — comment on these lines" }, function(answer)
    if answer then
      save_comment(resolved, answer, range)
    end
  end)
  return true
end

function M.remove_comment(plan_id)
  sync_comment_marks()
  local _, meta, review_id = review_context(plan_id)
  local buf = vim.api.nvim_get_current_buf()
  local file = meta and relative_file(meta, buf)
  if not file then
    notify("Move to a worktree comment before removing it.", vim.log.levels.WARN)
    return false
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, comment in ipairs(store.open_review_comments(review_id, meta.cwd)) do
    local first = tonumber(comment.start_line) or 1
    local last = tonumber(comment.end_line) or first
    if comment.file == file and line >= first and line <= last then
      store.remove_review_comment(review_id, comment.id, meta.cwd)
      state.marks[comment.id] = nil
      M.render_comments(buf)
      state.comment_count = #store.open_review_comments(review_id, meta.cwd)
      update_windows()
      notify("Review comment removed.")
      return true
    end
  end
  notify("There is no review comment on this line.", vim.log.levels.WARN)
  return false
end

local function comment_target(comments, direction, file, line)
  table.sort(comments, function(a, b)
    if a.file == b.file then
      return (tonumber(a.start_line) or 1) < (tonumber(b.start_line) or 1)
    end
    return tostring(a.file) < tostring(b.file)
  end)
  if direction > 0 then
    for _, comment in ipairs(comments) do
      if tostring(comment.file) > tostring(file or "")
        or (comment.file == file and (tonumber(comment.start_line) or 1) > (line or 0)) then
        return comment
      end
    end
    return comments[1]
  end
  for index = #comments, 1, -1 do
    local comment = comments[index]
    if tostring(comment.file) < tostring(file or "")
      or (comment.file == file and (tonumber(comment.start_line) or 1) < (line or math.huge)) then
      return comment
    end
  end
  return comments[#comments]
end

local function focus_comment(meta, comment)
  local entry = state.file_by_path[comment.file]
  if entry then
    open_file(entry.index, tonumber(comment.start_line) or 1, 0)
    notify(comment.body)
    return
  end
  notify("That comment belongs to a file outside the current diff.", vim.log.levels.WARN)
end

function M.next_comment(direction)
  sync_comment_marks()
  local _, meta, review_id = review_context()
  local comments = meta and store.open_review_comments(review_id, meta.cwd) or {}
  if #comments == 0 then
    notify("There are no open review comments.", vim.log.levels.INFO)
    return false
  end
  local location = current_location(meta) or {}
  local target = comment_target(comments, direction, location.file, location.line)
  focus_comment(meta, target)
  return true
end

write_review_buffers = function(meta)
  for buf in pairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(buf) and relative_file(meta, buf) and vim.bo[buf].modified then
      local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent write")
      end)
      if not ok then
        return false, err
      end
    end
  end
  return true, nil
end

local function feedback_text(comments, has_edits)
  local parts = {}
  if has_edits then
    table.insert(parts, "Preserve the reviewer's direct worktree edits. Inspect them, complete anything they require, and verify them.")
  end
  if #comments > 0 then
    table.insert(parts, "Address every anchored review comment below.")
    for index, comment in ipairs(comments) do
      vim.list_extend(parts, {
        "",
        string.format("%d. %s:%d-%d", index, comment.file, comment.start_line, comment.end_line),
        "> " .. tostring(comment.quote or ""):gsub("\n", "\n> "),
        tostring(comment.body or ""),
      })
    end
  end
  return table.concat(parts, "\n")
end

function M.submit(plan_id)
  local resolved, meta, review_id = review_context(plan_id)
  if not meta then
    return false
  end
  local written, write_err = write_review_buffers(meta)
  if not written then
    notify("Flow could not save the review edits: " .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end
  sync_comment_marks()
  if resolved then
    set_location(resolved)
  else
    current_location(meta)
  end
  local comments = store.open_review_comments(review_id, meta.cwd)
  if state.mode == "diff" and active_review_id() == review_id then
    notify(string.format("Review saved with %d anchored note%s.", #comments, #comments == 1 and "" or "s"))
    update_windows()
    return true
  end
  local clean = worktree.is_clean(meta.worktree)
  local has_edits = clean == false
  if not has_edits and #comments == 0 then
    notify("There are no edits or comments to submit.", vim.log.levels.INFO)
    return false
  end
  local ids = {}
  for _, comment in ipairs(comments) do
    table.insert(ids, comment.id)
  end
  return require("flow.implementation").submit_review(resolved, {
    text = feedback_text(comments, has_edits),
    comment_ids = ids,
    direct_edits = has_edits,
  })
end

function M.approve(plan_id)
  local resolved, meta = review_context(plan_id)
  if not meta then
    return false
  end
  if state.mode == "diff" and not resolved then
    notify("Branch reviews do not have a Flow approval step.", vim.log.levels.INFO)
    return false
  end
  local written, write_err = write_review_buffers(meta)
  if not written then
    notify("Flow could not save the review edits: " .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end
  sync_comment_marks()
  if #store.open_review_comments(resolved, meta.cwd) > 0 then
    notify("Submit or remove every review comment before approval.", vim.log.levels.WARN)
    return false
  end
  local ready, ready_err = M.ready(meta)
  if not ready then
    notify(ready_err .. " Press s to submit edits for verification.", vim.log.levels.WARN)
    return false
  end
  store.set_meta(resolved, { status = "merge_ready" }, meta.cwd)
  state.dirty = false
  update_windows()
  notify("Review approved. Press m to squash and commit it.")
  return true
end

function M.merge(plan_id)
  local resolved, meta = review_context(plan_id)
  if not meta then
    return false
  end
  if state.mode == "diff" and not resolved then
    notify("Branch reviews do not squash or merge a Flow implementation.", vim.log.levels.INFO)
    return false
  end
  if meta.status ~= "merge_ready" and not M.approve(resolved) then
    return false
  end
  return require("flow.merge").squash(resolved)
end

function M.help()
  local lines = {
    "K / J      next / previous hunk",
    "]c / [c   next / previous hunk (alternate)",
    "]f / [f   next / previous file",
    "<leader>o  toggle the ordered file overview",
    "gA         refresh the AI review map",
    "gc         add an anchored note on the line or selection",
    "]r / [r   next / previous note",
    "gC         remove the note under the cursor",
  }
  if state.mode == "diff" then
    vim.list_extend(lines, {
      "s          save edits and anchored notes",
      "q          close review",
      "",
      "This is the current branch and worktree diff against " .. tostring(active_meta() and active_meta().base_ref or "master") .. ".",
    })
  else
    vim.list_extend(lines, {
      "s          submit edits and comments for verification",
      "a          approve a clean verified review",
      "m          approve, squash, and commit",
      "u          restore the checkpoint before the last feedback",
      "q          close review",
      "",
      "This is the verified Flow implementation review.",
    })
  end
  table.insert(lines, "Current lines are a normal editable Neovim buffer. AI guidance and deleted base lines are virtual.")
  notify(table.concat(lines, "\n"))
end

function M.feedback(plan_id, text)
  local resolved = select(1, review_context(plan_id))
  if state.mode == "diff" and not resolved then
    notify("Use gc for an anchored branch-review note, or edit the worktree directly.", vim.log.levels.INFO)
    return false
  end
  plan_id = resolved
  if text and vim.trim(text) ~= "" then
    return require("flow.implementation").feedback(plan_id, text)
  end
  require("claude.input").open({ title = "Flow review — what should Claude change?" }, function(answer)
    if answer then
      require("flow.implementation").feedback(plan_id, answer)
    end
  end)
  return true
end

function M.restore(plan_id)
  local resolved = select(1, review_context(plan_id))
  if state.mode == "diff" and not resolved then
    notify("Branch reviews do not have Flow feedback checkpoints.", vim.log.levels.INFO)
    return false
  end
  plan_id = resolved
  local meta = plan_id and store.meta(plan_id)
  local feedback = meta and store.last_feedback(plan_id, meta.cwd)
  if not feedback or not feedback.checkpoint then
    notify("There is no review feedback to restore.", vim.log.levels.WARN)
    return false
  end
  if feedback.status == "restored" then
    notify("The last review feedback is already restored.", vim.log.levels.INFO)
    return false
  end
  if feedback.status == "running" then
    notify("Wait for Claude to finish and commit this feedback before restoring it.", vim.log.levels.WARN)
    return false
  end
  local ready, ready_err = M.ready(meta)
  if not ready then
    notify(ready_err, vim.log.levels.ERROR)
    return false
  end

  M.close()
  local current_tree = worktree.git(meta.worktree, { "rev-parse", meta.verified_head .. "^{tree}" })
  local checkpoint_tree = worktree.git(meta.worktree, { "rev-parse", feedback.checkpoint .. "^{tree}" })
  if not current_tree.ok or not checkpoint_tree.ok then
    notify("Git could not read the review checkpoints.", vim.log.levels.ERROR)
    return false
  end

  if current_tree.out ~= checkpoint_tree.out then
    local patch = worktree.git(meta.worktree, { "diff", "--binary", meta.verified_head, feedback.checkpoint })
    if not patch.ok then
      notify(patch.err ~= "" and patch.err or patch.out, vim.log.levels.ERROR)
      return false
    end
    local applied = worktree.git(meta.worktree, { "apply", "--index", "--whitespace=nowarn" }, { stdin = patch.out })
    if not applied.ok then
      notify(applied.err ~= "" and applied.err or applied.out, vim.log.levels.ERROR)
      return false
    end
    local committed = worktree.git(meta.worktree, {
      "commit", "-m", "Restore review checkpoint before: " .. tostring(feedback.body):gsub("[\r\n]+", " "):sub(1, 60),
    })
    if not committed.ok then
      notify(committed.err ~= "" and committed.err or committed.out, vim.log.levels.ERROR)
      return false
    end
  end

  local head, head_err = worktree.head(meta.worktree)
  if not head then
    notify(head_err, vim.log.levels.ERROR)
    return false
  end
  store.update_feedback(plan_id, feedback.id, { status = "restored", restored_head = head }, meta.cwd)
  if #(feedback.comment_ids or {}) > 0 then
    store.set_review_comment_status(plan_id, feedback.comment_ids, "open", head, meta.cwd)
  end
  store.set_meta(plan_id, {
    status = "review_ready",
    verified_head = head,
    verified_at = os.time(),
    review_cursor = feedback.review_cursor or 1,
    review_file = feedback.review_file,
    review_line = feedback.review_line,
    review_col = feedback.review_col,
  }, meta.cwd)
  notify("Restored the verified checkpoint from before that feedback.")
  return M.open(plan_id, feedback.review_cursor or 1)
end

return M
