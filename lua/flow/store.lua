-- Everything Flow keeps on disk.
--
-- One directory per project, one directory per plan inside it:
--
--   <state>/flow/<cwd-slug>_<sha8>/<plan-id>/
--     meta.json          id, title, status, which revision is current
--     revisions/001.json the design doc, one file per revision
--     comments.json      your notes on the doc, never deleted
--     review-comments.json anchored notes on implementation lines
--     feedback.json      review instructions and their commit checkpoints
--     steps.json         the ordered change stack
--     diffs/<step>.json  the edits for one step
--     applied.json       the undo journal, with a file pre-image per entry
--
-- Nothing here is fatal. A missing or broken file reads back as nil, the same
-- way config.session treats a session file.

local M = {}

M.root = vim.fn.stdpath("state") .. "/flow"

--- Paths ---------------------------------------------------------------------

--- The directory for one working directory. The slug stays readable, and the
--- hash keeps two directories with the same tail apart.
function M.project_dir(cwd)
  cwd = vim.fn.resolve(vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"))
  local slug = cwd:gsub("[^%w]+", "_"):gsub("^_", ""):gsub("_$", "")
  return M.root .. "/" .. slug:sub(-60) .. "_" .. vim.fn.sha256(cwd):sub(1, 8)
end

--- The directory for one plan.
function M.plan_dir(plan_id, cwd)
  return M.project_dir(cwd) .. "/" .. plan_id
end

--- A plan id that sorts by time and never collides.
function M.new_id()
  return os.date("%Y%m%d-%H%M%S") .. "-" .. string.format("%04x", math.random(0, 0xffff))
end

--- JSON ----------------------------------------------------------------------

--- Read a JSON file. Returns nil for anything missing or broken.
function M.read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines[1] then
    return nil
  end
  local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(data) ~= "table" then
    return nil
  end
  return data
end

--- Write a JSON file, creating the directory. Returns true on success.
function M.write_json(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, json = pcall(vim.json.encode, data)
  if not ok then
    return false
  end
  return (pcall(vim.fn.writefile, { json }, path))
end

--- Plans ---------------------------------------------------------------------

--- Start a new plan on disk.
---@param opts table { title: string|nil, prompt: string|nil, cwd: string|nil }
---@return string|nil plan_id
function M.create(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  local id = M.new_id()
  local meta = {
    id = id,
    title = opts.title or "Untitled plan",
    prompt = opts.prompt or "",
    cwd = vim.fn.resolve(vim.fn.fnamemodify(cwd, ":p")),
    created = os.time(),
    status = "planning",
    current_revision = 0,
    step_cursor = 0,
  }
  if not M.write_json(M.plan_dir(id, cwd) .. "/meta.json", meta) then
    return nil
  end
  return id
end

--- Find a plan wherever it was planned. A plan id is unique across projects,
--- so `:cd` somewhere else never hides a plan you are part way through.
---@return string|nil dir
function M.locate(plan_id)
  if type(plan_id) ~= "string" or plan_id == "" then
    return nil
  end
  local here = M.plan_dir(plan_id)
  if vim.fn.filereadable(here .. "/meta.json") == 1 then
    return here
  end
  if vim.fn.isdirectory(M.root) ~= 1 then
    return nil
  end
  for name, kind in vim.fs.dir(M.root) do
    if kind == "directory" then
      local dir = M.root .. "/" .. name .. "/" .. plan_id
      if vim.fn.filereadable(dir .. "/meta.json") == 1 then
        return dir
      end
    end
  end
  return nil
end

--- A plan's meta. Without a `cwd`, it looks the plan up wherever it lives.
function M.meta(plan_id, cwd)
  if cwd then
    return M.read_json(M.plan_dir(plan_id, cwd) .. "/meta.json")
  end
  local dir = M.locate(plan_id)
  return dir and M.read_json(dir .. "/meta.json") or nil
end

--- Merge `patch` into the plan's meta. Returns the new meta, or nil.
function M.set_meta(plan_id, patch, cwd)
  local meta = M.meta(plan_id, cwd)
  if not meta then
    return nil
  end
  meta = vim.tbl_extend("force", meta, patch or {})
  if not M.write_json(M.plan_dir(plan_id, cwd) .. "/meta.json", meta) then
    return nil
  end
  return meta
end

local function plans_in(dir)
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}
  end
  local out = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "directory" then
      local meta = M.read_json(dir .. "/" .. name .. "/meta.json")
      if meta then
        table.insert(out, meta)
      end
    end
  end
  return out
end

local function newest_first(plans)
  table.sort(plans, function(a, b)
    return (a.created or 0) > (b.created or 0)
  end)
  return plans
end

--- Every plan for `cwd`, newest first.
function M.plans(cwd)
  return newest_first(plans_in(M.project_dir(cwd)))
end

--- Every plan across all working directories, newest first.
function M.all_plans()
  if vim.fn.isdirectory(M.root) ~= 1 then
    return {}
  end
  local out = {}
  for name, kind in vim.fs.dir(M.root) do
    if kind == "directory" then
      vim.list_extend(out, plans_in(M.root .. "/" .. name))
    end
  end
  return newest_first(out)
end

--- Revisions -----------------------------------------------------------------

local function revision_path(plan_id, n, cwd)
  return M.plan_dir(plan_id, cwd) .. string.format("/revisions/%03d.json", n)
end

--- Append a revision. Returns its number.
---@param rev table { plan_md, prompt, session_id, cost, addressed_comments }
function M.add_revision(plan_id, rev, cwd)
  local meta = M.meta(plan_id, cwd)
  if not meta then
    return nil
  end
  local n = (meta.current_revision or 0) + 1
  rev = vim.tbl_extend("force", { n = n, created = os.time() }, rev or {})
  if not M.write_json(revision_path(plan_id, n, cwd), rev) then
    return nil
  end
  M.set_meta(plan_id, { current_revision = n }, cwd)
  return n
end

--- One revision. `n` defaults to the current one.
function M.revision(plan_id, n, cwd)
  if not n then
    local meta = M.meta(plan_id, cwd)
    n = meta and meta.current_revision
  end
  if not n or n < 1 then
    return nil
  end
  return M.read_json(revision_path(plan_id, n, cwd))
end

--- Comments ------------------------------------------------------------------

local function comments_path(plan_id, cwd)
  return M.plan_dir(plan_id, cwd) .. "/comments.json"
end

function M.comments(plan_id, cwd)
  local data = M.read_json(comments_path(plan_id, cwd))
  if type(data) ~= "table" or not vim.islist(data) then
    return {}
  end
  return data
end

--- Add a comment. Returns its id.
---@param comment table { anchor, quote, body, revision }
function M.add_comment(plan_id, comment, cwd)
  local list = M.comments(plan_id, cwd)
  local entry = vim.tbl_extend("force", {
    id = string.format("c%d-%04x", os.time(), math.random(0, 0xffff)),
    created = os.time(),
    addressed_in = vim.NIL,
  }, comment or {})
  table.insert(list, entry)
  if not M.write_json(comments_path(plan_id, cwd), list) then
    return nil
  end
  return entry.id
end

--- Remove one comment. Returns true when it was there.
function M.remove_comment(plan_id, comment_id, cwd)
  local list = M.comments(plan_id, cwd)
  local kept, found = {}, false
  for _, c in ipairs(list) do
    if c.id == comment_id then
      found = true
    else
      table.insert(kept, c)
    end
  end
  if not found then
    return false
  end
  M.write_json(comments_path(plan_id, cwd), kept)
  return true
end

--- The comments a replan still has to answer.
function M.open_comments(plan_id, cwd)
  local out = {}
  for _, c in ipairs(M.comments(plan_id, cwd)) do
    local done = c.addressed_in
    if done == nil or done == vim.NIL then
      table.insert(out, c)
    end
  end
  return out
end

--- Stamp comments as answered by revision `n`. They stay on disk.
function M.address_comments(plan_id, ids, n, cwd)
  local wanted = {}
  for _, id in ipairs(ids or {}) do
    wanted[id] = true
  end
  local list = M.comments(plan_id, cwd)
  for _, c in ipairs(list) do
    if wanted[c.id] then
      c.addressed_in = n
    end
  end
  return M.write_json(comments_path(plan_id, cwd), list)
end

--- Implementation review comments ------------------------------------------

local function review_comments_path(plan_id, cwd)
  return M.plan_dir(plan_id, cwd) .. "/review-comments.json"
end

function M.review_comments(plan_id, cwd)
  local data = M.read_json(review_comments_path(plan_id, cwd))
  if type(data) ~= "table" or not vim.islist(data) then
    return {}
  end
  return data
end

function M.open_review_comments(plan_id, cwd)
  local out = {}
  for _, comment in ipairs(M.review_comments(plan_id, cwd)) do
    if comment.status == nil or comment.status == vim.NIL or comment.status == "open" then
      table.insert(out, comment)
    end
  end
  return out
end

function M.add_review_comment(plan_id, comment, cwd)
  local list = M.review_comments(plan_id, cwd)
  local entry = vim.tbl_extend("force", {
    id = string.format("r%d-%04x", os.time(), math.random(0, 0xffff)),
    created = os.time(),
    status = "open",
  }, comment or {})
  table.insert(list, entry)
  if not M.write_json(review_comments_path(plan_id, cwd), list) then
    return nil
  end
  return entry.id
end

function M.update_review_comment(plan_id, comment_id, patch, cwd)
  local list = M.review_comments(plan_id, cwd)
  local updated = nil
  for _, comment in ipairs(list) do
    if comment.id == comment_id then
      for key, value in pairs(patch or {}) do
        comment[key] = value
      end
      updated = comment
      break
    end
  end
  if not updated or not M.write_json(review_comments_path(plan_id, cwd), list) then
    return nil
  end
  return updated
end

function M.remove_review_comment(plan_id, comment_id, cwd)
  local list = M.review_comments(plan_id, cwd)
  local kept, found = {}, false
  for _, comment in ipairs(list) do
    if comment.id == comment_id then
      found = true
    else
      table.insert(kept, comment)
    end
  end
  if not found then
    return false
  end
  return M.write_json(review_comments_path(plan_id, cwd), kept)
end

function M.set_review_comment_status(plan_id, ids, status, head, cwd)
  local wanted = {}
  for _, id in ipairs(ids or {}) do
    wanted[id] = true
  end
  local list = M.review_comments(plan_id, cwd)
  for _, comment in ipairs(list) do
    if wanted[comment.id] then
      comment.status = status
      comment.head = head or vim.NIL
    end
  end
  return M.write_json(review_comments_path(plan_id, cwd), list)
end

--- Review feedback ----------------------------------------------------------

local function feedback_path(plan_id, cwd)
  return M.plan_dir(plan_id, cwd) .. "/feedback.json"
end

function M.feedback(plan_id, cwd)
  local data = M.read_json(feedback_path(plan_id, cwd))
  if type(data) ~= "table" or not vim.islist(data) then
    return {}
  end
  return data
end

function M.push_feedback(plan_id, entry, cwd)
  local list = M.feedback(plan_id, cwd)
  local item = vim.tbl_extend("force", {
    id = string.format("f%d-%04x", os.time(), math.random(0, 0xffff)),
    created = os.time(),
    status = "running",
  }, entry or {})
  table.insert(list, item)
  if not M.write_json(feedback_path(plan_id, cwd), list) then
    return nil
  end
  return item.id
end

function M.update_feedback(plan_id, feedback_id, patch, cwd)
  local list = M.feedback(plan_id, cwd)
  local updated = nil
  for _, item in ipairs(list) do
    if item.id == feedback_id then
      for key, value in pairs(patch or {}) do
        item[key] = value
      end
      updated = item
      break
    end
  end
  if not updated or not M.write_json(feedback_path(plan_id, cwd), list) then
    return nil
  end
  return updated
end

function M.last_feedback(plan_id, cwd)
  local list = M.feedback(plan_id, cwd)
  return list[#list]
end

--- Steps ---------------------------------------------------------------------

function M.set_steps(plan_id, steps, cwd)
  return M.write_json(M.plan_dir(plan_id, cwd) .. "/steps.json", steps or {})
end

function M.steps(plan_id, cwd)
  local data = M.read_json(M.plan_dir(plan_id, cwd) .. "/steps.json")
  if type(data) ~= "table" or not vim.islist(data) then
    return {}
  end
  return data
end

--- Diffs ---------------------------------------------------------------------

-- A step id reaches the filesystem, so keep it to safe characters.
local function diff_path(plan_id, step_id, cwd)
  local safe = tostring(step_id):gsub("[^%w%-_]", "_")
  return M.plan_dir(plan_id, cwd) .. "/diffs/" .. safe .. ".json"
end

function M.set_diff(plan_id, step_id, diff, cwd)
  return M.write_json(diff_path(plan_id, step_id, cwd), diff)
end

function M.diff(plan_id, step_id, cwd)
  return M.read_json(diff_path(plan_id, step_id, cwd))
end

function M.clear_diffs(plan_id, cwd)
  pcall(vim.fn.delete, M.plan_dir(plan_id, cwd) .. "/diffs", "rf")
end

--- The undo journal ----------------------------------------------------------

local function applied_path(plan_id, cwd)
  return M.plan_dir(plan_id, cwd) .. "/applied.json"
end

function M.applied(plan_id, cwd)
  local data = M.read_json(applied_path(plan_id, cwd))
  if type(data) ~= "table" or not vim.islist(data) then
    return {}
  end
  return data
end

--- Record an applied step, with the file exactly as it was before.
---@param entry table { step_id, file, before: string[], existed: boolean }
function M.push_applied(plan_id, entry, cwd)
  local list = M.applied(plan_id, cwd)
  table.insert(list, vim.tbl_extend("force", { at = os.time() }, entry or {}))
  return M.write_json(applied_path(plan_id, cwd), list)
end

--- Take the newest journal entry off. Returns it, or nil when empty.
function M.pop_applied(plan_id, cwd)
  local list = M.applied(plan_id, cwd)
  local entry = table.remove(list)
  if not entry then
    return nil
  end
  M.write_json(applied_path(plan_id, cwd), list)
  return entry
end

return M
