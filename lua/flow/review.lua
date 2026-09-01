local M = {}

local store = require("flow.store")
local worktree = require("flow.worktree")

local state = {
  tab = nil,
  plan_id = nil,
  buffers = {},
  protected = {},
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Flow review" })
end

local function present(value)
  return value ~= nil and value ~= vim.NIL and value ~= ""
end

local function current_plan()
  return require("flow").current()
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

function M.ready(meta)
  if not meta or not present(meta.worktree) or not present(meta.verified_head) then
    return false, "The implementation is not verified yet."
  end
  local modified = changed_buffer(meta.worktree)
  if modified then
    return false, "Save or discard the unsaved worktree buffer first: " .. modified
  end
  local clean, clean_err = worktree.is_clean(meta.worktree)
  if not clean then
    return false, clean_err or "The implementation worktree is not clean."
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

local function name_status(meta)
  local result = worktree.git(meta.worktree, {
    "diff", "--name-status", "--find-renames", meta.base_head .. ".." .. meta.verified_head,
  })
  if not result.ok then
    return nil, result.err ~= "" and result.err or result.out
  end
  local changes = {}
  for line in (result.out .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local fields = vim.split(line, "\t", { plain = true })
      local code = fields[1] or "M"
      if code:sub(1, 1) == "R" or code:sub(1, 1) == "C" then
        table.insert(changes, { status = code:sub(1, 1), old_file = fields[2], file = fields[3] })
      else
        table.insert(changes, { status = code:sub(1, 1), old_file = fields[2], file = fields[2] })
      end
    end
  end
  return changes, nil
end

local function file_hunks(meta, change)
  local result = worktree.git(meta.worktree, {
    "diff", "--no-color", "--unified=0", meta.base_head .. ".." .. meta.verified_head, "--", change.file,
  })
  if not result.ok then
    return nil, result.err ~= "" and result.err or result.out
  end
  local hunks = {}
  local binary = result.out:find("Binary files", 1, true) ~= nil or result.out:find("GIT binary patch", 1, true) ~= nil
  for line in (result.out .. "\n"):gmatch("([^\n]*)\n") do
    local old_start, new_start, label = line:match("^@@ %-(%d+)[^ ]* %+(%d+)[^ ]* @@%s*(.*)$")
    if old_start then
      table.insert(hunks, {
        file = change.file,
        old_file = change.old_file,
        status = change.status,
        old_start = tonumber(old_start),
        new_start = tonumber(new_start),
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
      new_start = 1,
      label = change.status == "D" and "Deleted file" or "Changed file",
      binary = binary,
    })
  end
  return hunks, nil
end

function M.hunks(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  local ok, err = M.ready(meta)
  if not ok then
    return nil, err
  end
  local changes, changes_err = name_status(meta)
  if not changes then
    return nil, changes_err
  end
  local hunks = {}
  for _, change in ipairs(changes) do
    local found, hunk_err = file_hunks(meta, change)
    if not found then
      return nil, hunk_err
    end
    vim.list_extend(hunks, found)
  end
  return hunks, nil
end

function M.context(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  local hunks = plan_id and M.hunks(plan_id)
  if not meta or not hunks or #hunks == 0 then
    return ""
  end
  local index = math.max(1, math.min(tonumber(meta.review_cursor) or 1, #hunks))
  local hunk = hunks[index]
  local result = worktree.git(meta.worktree, {
    "diff", "--no-color", "--unified=8", meta.base_head .. ".." .. meta.verified_head, "--", hunk.file,
  })
  local diff = result.ok and result.out or ""
  return table.concat({
    string.format("Reviewed hunk %d of %d in %s.", index, #hunks, hunk.file),
    diff,
  }, "\n")
end

local function scratch(name, lines, filetype)
  local old = vim.fn.bufnr(name)
  if old ~= -1 and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype or ""
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  table.insert(state.buffers, buf)
  return buf
end

local function base_lines(meta, hunk)
  if hunk.binary then
    return { "Binary file: " .. tostring(hunk.old_file or hunk.file) }
  end
  if hunk.status == "A" then
    return { "" }
  end
  local file = hunk.old_file or hunk.file
  local result = worktree.git(meta.source_root, { "show", meta.base_head .. ":" .. file })
  if not result.ok then
    return { "" }
  end
  local lines = vim.split(result.out:gsub("\n$", ""), "\n", { plain = true })
  return #lines > 0 and lines or { "" }
end

local function filetype(path)
  return vim.filetype.match({ filename = path }) or ""
end

local function protect(buf)
  if state.protected[buf] then
    return
  end
  state.protected[buf] = {
    modifiable = vim.bo[buf].modifiable,
    readonly = vim.bo[buf].readonly,
  }
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

local function map(buf, lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

local function review_maps(buf, plan_id)
  map(buf, "<CR>", function()
    M.next(plan_id)
  end, "Flow: next reviewed hunk")
  map(buf, "]f", function()
    M.next(plan_id)
  end, "Flow: next reviewed hunk")
  map(buf, "[f", function()
    M.prev(plan_id)
  end, "Flow: previous reviewed hunk")
  map(buf, "r", function()
    M.feedback(plan_id)
  end, "Flow: send review feedback")
  map(buf, "u", function()
    M.restore(plan_id)
  end, "Flow: restore before feedback")
  map(buf, "m", function()
    require("flow.merge").squash(plan_id)
  end, "Flow: squash implementation")
  map(buf, "q", M.close, "Flow: close review")
end

local function narrative(meta, hunk)
  local result = worktree.git(meta.worktree, {
    "log", "-1", "--format=%s", meta.base_head .. ".." .. meta.verified_head, "--", hunk.file,
  })
  return result.ok and vim.trim(result.out) or ""
end

function M.close()
  for buf, opts in pairs(state.protected) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = opts.modifiable
      vim.bo[buf].readonly = opts.readonly
    end
  end
  state.protected = {}
  if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
    local current = vim.api.nvim_get_current_tabpage()
    if #vim.api.nvim_list_tabpages() > 1 then
      if current ~= state.tab then
        pcall(vim.api.nvim_set_current_tabpage, state.tab)
      end
      pcall(vim.cmd, "tabclose")
      if current ~= state.tab and vim.api.nvim_tabpage_is_valid(current) then
        pcall(vim.api.nvim_set_current_tabpage, current)
      end
    end
  end
  for _, buf in ipairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state = { tab = nil, plan_id = nil, buffers = {}, protected = {} }
end

function M.open(plan_id, index)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  local hunks, err = M.hunks(plan_id)
  if not hunks then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  if #hunks == 0 then
    notify("The verified implementation has no diff.", vim.log.levels.WARN)
    return false
  end
  index = math.max(1, math.min(tonumber(index) or tonumber(meta.review_cursor) or 1, #hunks))
  local hunk = hunks[index]

  M.close()
  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()
  state.plan_id = plan_id

  local ft = filetype(hunk.file)
  local left_name = string.format("flow://review/%s/base/%s", plan_id, hunk.old_file or hunk.file)
  local left = scratch(left_name, base_lines(meta, hunk), ft)
  vim.api.nvim_win_set_buf(0, left)
  local left_win = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  local right
  local target = meta.worktree .. "/" .. hunk.file
  if hunk.binary then
    right = scratch(string.format("flow://review/%s/result/%s", plan_id, hunk.file), {
      "Binary file: " .. hunk.file,
    }, ft)
    vim.api.nvim_win_set_buf(0, right)
  elseif hunk.status ~= "D" and vim.fn.filereadable(target) == 1 then
    right = vim.fn.bufadd(target)
    vim.fn.bufload(right)
    protect(right)
    vim.api.nvim_win_set_buf(0, right)
  else
    right = scratch(string.format("flow://review/%s/result/%s", plan_id, hunk.file), { "" }, ft)
    vim.api.nvim_win_set_buf(0, right)
  end
  local right_win = vim.api.nvim_get_current_win()

  vim.wo[left_win].diff = true
  vim.wo[right_win].diff = true
  vim.wo[left_win].wrap = false
  vim.wo[right_win].wrap = false
  local line = hunk.status == "D" and hunk.old_start or hunk.new_start
  local target_win = hunk.status == "D" and left_win or right_win
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(target_win))
  vim.api.nvim_win_set_cursor(target_win, { math.max(1, math.min(line, count)), 0 })
  vim.api.nvim_set_current_win(target_win)
  vim.cmd("normal! zz")

  review_maps(left, plan_id)
  review_maps(right, plan_id)
  store.set_meta(plan_id, { status = "reviewing", review_cursor = index }, meta.cwd)

  local reason = narrative(meta, hunk)
  local title = string.format("%d/%d  %s", index, #hunks, hunk.file)
  local detail = reason ~= "" and "\n" .. reason or ""
  notify(title .. detail .. "\n<CR> next · r feedback · u restore · m squash · q close")
  return true
end

function M.next(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return false
  end
  local hunks, err = M.hunks(plan_id)
  if not hunks then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  local index = tonumber(meta.review_cursor) or 1
  if state.plan_id == plan_id then
    index = index + 1
  end
  if index > #hunks then
    M.close()
    store.set_meta(plan_id, { status = "merge_ready", review_cursor = #hunks }, meta.cwd)
    notify("Review complete. Press <leader>dm to squash and commit, or r to send more feedback.")
    return true
  end
  return M.open(plan_id, index)
end

function M.prev(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return false
  end
  return M.open(plan_id, math.max(1, (tonumber(meta.review_cursor) or 1) - 1))
end

function M.feedback(plan_id, text)
  plan_id = plan_id or current_plan()
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
  plan_id = plan_id or current_plan()
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
  store.set_meta(plan_id, {
    status = "review_ready",
    verified_head = head,
    verified_at = os.time(),
    review_cursor = feedback.review_cursor or 1,
  }, meta.cwd)
  notify("Restored the verified checkpoint from before that feedback.")
  return M.open(plan_id, feedback.review_cursor or 1)
end

return M
