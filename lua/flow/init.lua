-- Flow: approve a plan, let Claude implement and verify it in a worktree,
-- review the finished diff, then squash it into the source branch.
--
--   <leader>dn  new plan
--   <leader>dp  open the current plan in the browser
--   <leader>dj  review the next finished hunk
--   <leader>dk  review the previous hunk
--   <leader>dr  send review feedback to Claude
--   <leader>dc  comment on the current review line or selection
--   <leader>dS  submit review edits and comments
--   <leader>da  approve a clean verified review
--   <leader>dR  review the current branch against master
--   <leader>du  restore the checkpoint before the last feedback
--   <leader>ds  toggle the implementation session
--   <leader>dm  squash and commit the verified implementation
--   <leader>dl  list every plan
--
-- The stages live in flow.planner, flow.implementation, flow.review, and
-- flow.merge. This file is the wiring.

local M = {}

local store = require("flow.store")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Flow" })
end

--- Colours ------------------------------------------------------------------

local function define_highlights()
  local groups = {
    FlowAdd = { link = "DiffAdd" },
    FlowDel = { link = "DiffDelete" },
    FlowHint = { link = "Comment" },
    FlowDone = { link = "DiagnosticOk" },
    FlowCurrent = { link = "DiagnosticInfo" },
    FlowPending = { link = "Comment" },
    FlowStale = { link = "DiagnosticWarn" },
    FlowSkipped = { link = "NonText" },
    FlowBorder = { link = "FloatBorder" },
    FlowTitle = { link = "Title" },
    FlowReviewComment = { link = "DiagnosticInfo" },
    FlowReviewCommentText = { link = "DiagnosticInfo" },
    FlowReviewCommentRange = { link = "CursorLine" },
    FlowReviewAdd = { link = "DiffAdd" },
    FlowReviewAddMarker = { link = "DiagnosticOk" },
    FlowReviewAddText = { link = "GitSignsAddInline" },
    FlowReviewDelete = { link = "DiffDelete" },
    FlowReviewDeleteMarker = { link = "DiagnosticError" },
    FlowReviewDeleteText = { link = "GitSignsDeleteInline" },
    FlowReviewDeletedFile = { link = "DiagnosticError" },
    FlowReviewDeletedFileName = { link = "ErrorMsg" },
    FlowReviewHunkHeader = { link = "DiagnosticInfo" },
    FlowReviewBinary = { link = "DiagnosticWarn" },
    FlowReviewSection = { link = "Title" },
    FlowReviewAI = { link = "NormalFloat" },
    FlowReviewAIReason = { link = "Comment" },
    FlowReviewAIRiskHIGH = { link = "DiagnosticError" },
    FlowReviewAIRiskMEDIUM = { link = "DiagnosticWarn" },
    FlowReviewAIRiskLOW = { link = "DiagnosticInfo" },
    FlowReviewAICovered = { link = "DiagnosticOk" },
    FlowReviewAIMissing = { link = "DiagnosticError" },
  }
  for name, spec in pairs(groups) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

--- Which plan is in play -----------------------------------------------------

-- The plan the keymaps act on, per working directory. It survives a :Reload
-- because it is recomputed from disk whenever it is missing.
local selected = {}

local DONE = { done = true, merged = true, abandoned = true }

--- The plan the keymaps act on. The newest unfinished plan, unless you picked
--- another one with :FlowPlans.
---@return string|nil plan_id
function M.current(cwd)
  cwd = cwd or vim.fn.getcwd()
  local chosen = selected[cwd]
  local chosen_meta = chosen and store.meta(chosen, cwd)
  if chosen_meta and not DONE[chosen_meta.status] then
    return chosen
  elseif chosen then
    selected[cwd] = nil
  end
  for _, meta in ipairs(store.plans(cwd)) do
    if not DONE[meta.status] then
      selected[cwd] = meta.id
      return meta.id
    end
  end
  return nil
end

--- Act on this plan from now on.
function M.select(plan_id, cwd)
  selected[cwd or vim.fn.getcwd()] = plan_id
end

--- Commands -----------------------------------------------------------------

--- Ask for planning context, then start a plan.
function M.plan(context)
  if context and vim.trim(context) ~= "" then
    local id = require("flow.planner").start(context)
    if id then
      M.select(id)
    end
    return
  end

  require("claude.input").open({ title = "Flow — what should I plan?" }, function(text)
    if not text then
      return
    end
    local id = require("flow.planner").start(text)
    if id then
      M.select(id)
    end
  end)
end

--- Open the current plan in the browser.
function M.open(plan_id)
  plan_id = plan_id or M.current()
  if not plan_id then
    notify("No plan yet. Press <leader>dn to start one.", vim.log.levels.WARN)
    return
  end
  require("flow.server").open(plan_id)
end

--- Show the current plan in a scratch buffer, for a quick look without the
--- browser.
function M.show(plan_id)
  plan_id = plan_id or M.current()
  local revision = plan_id and store.revision(plan_id)
  if not revision or not revision.plan_md then
    notify("That plan has no document yet.", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(revision.plan_md, "\n", { plain = true }))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.cmd("vertical botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = true
  vim.wo.linebreak = true
end

--- Abandon the current plan. Nothing on disk is deleted.
function M.abandon(plan_id)
  plan_id = plan_id or M.current()
  if not plan_id then
    return
  end
  local meta = store.meta(plan_id)
  if meta and meta.worktree and meta.worktree ~= vim.NIL and vim.fn.isdirectory(meta.worktree) == 1 then
    notify("This plan owns an implementation worktree. Merge it before abandoning the plan.", vim.log.levels.WARN)
    return
  end
  store.set_meta(plan_id, { status = "abandoned" })
  selected[vim.fn.getcwd()] = nil
  notify("Plan abandoned. It stays on disk.")
end

--- Setup --------------------------------------------------------------------

local function commands()
  local function cmd(name, fn, opts)
    vim.api.nvim_create_user_command(name, fn, opts)
  end

  cmd("FlowPlan", function(a)
    M.plan(a.args)
  end, { nargs = "?", desc = "Plan a change with Claude" })

  cmd("FlowOpen", function()
    M.open()
  end, { desc = "Open the current plan in the browser" })

  cmd("FlowShow", function()
    M.show()
  end, { desc = "Show the current plan in a split" })

  cmd("FlowAbandon", function()
    M.abandon()
  end, { desc = "Abandon the current plan" })

  cmd("FlowNext", function()
    require("flow.review").next()
  end, { desc = "Review the next finished hunk" })

  cmd("FlowPrev", function()
    require("flow.review").prev()
  end, { desc = "Review the previous finished hunk" })

  cmd("FlowStack", function()
    require("flow.implementation").toggle()
  end, { desc = "Toggle the implementation session" })

  cmd("FlowSession", function()
    require("flow.implementation").open()
  end, { desc = "Open the implementation session" })

  cmd("FlowReview", function(a)
    require("flow.review").open_diff(a.args ~= "" and a.args or "master")
  end, { nargs = "?", desc = "Review the current branch and worktree against a base" })

  cmd("FlowPlanReview", function()
    require("flow.review").open()
  end, { desc = "Review the verified Flow implementation" })

  cmd("FlowFeedback", function(a)
    require("flow.review").feedback(nil, a.args)
  end, { nargs = "?", desc = "Send implementation-review feedback" })

  cmd("FlowComment", function(a)
    require("flow.review").comment(nil, a.args ~= "" and a.args or nil)
  end, { nargs = "?", desc = "Comment on the current implementation line" })

  cmd("FlowSubmit", function()
    require("flow.review").submit()
  end, { desc = "Submit review edits and comments" })

  cmd("FlowApprove", function()
    require("flow.review").approve()
  end, { desc = "Approve a clean verified implementation" })

  cmd("FlowRestore", function()
    require("flow.review").restore()
  end, { desc = "Restore the checkpoint before the last feedback" })

  cmd("FlowMerge", function()
    require("flow.review").merge()
  end, { desc = "Squash and commit the verified implementation" })

  cmd("FlowInterrupt", function()
    require("flow.implementation").interrupt()
  end, { desc = "Interrupt the implementation session" })

  cmd("FlowPlans", function()
    require("flow.picker").plans()
  end, { desc = "List plans across every repository" })
end

local function keymaps()
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { desc = desc })
  end

  map("<leader>dn", function()
    M.plan()
  end, "Flow: new plan")
  map("<leader>dp", function()
    M.open()
  end, "Flow: open plan in browser")
  map("<leader>dv", function()
    M.show()
  end, "Flow: view plan in a split")
  map("<leader>dl", function()
    require("flow.picker").plans()
  end, "Flow: list plans")
  map("<leader>dj", function()
    require("flow.review").next()
  end, "Flow: review next hunk")
  map("<leader>dk", function()
    require("flow.review").prev()
  end, "Flow: review previous hunk")
  map("<leader>dr", function()
    require("flow.review").feedback()
  end, "Flow: send review feedback")
  map("<leader>dc", function()
    require("flow.review").comment()
  end, "Flow: comment on review line")
  map("<leader>dS", function()
    require("flow.review").submit()
  end, "Flow: submit review changes")
  map("<leader>da", function()
    require("flow.review").approve()
  end, "Flow: approve review")
  map("<leader>dR", function()
    require("flow.review").open_diff("master")
  end, "Flow: review branch against master")
  map("<leader>du", function()
    require("flow.review").restore()
  end, "Flow: restore before feedback")
  map("<leader>ds", function()
    require("flow.implementation").toggle()
  end, "Flow: toggle implementation session")
  map("<leader>dm", function()
    require("flow.review").merge()
  end, "Flow: squash and commit")
  map("]f", function()
    require("flow.review").next()
  end, "Flow: review next hunk")
  map("[f", function()
    require("flow.review").prev()
  end, "Flow: review previous hunk")
end

function M.setup()
  math.randomseed(os.time() + vim.fn.getpid())
  define_highlights()
  commands()
  keymaps()

  local group = vim.api.nvim_create_augroup("EthanFlow", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })

  -- A finished plan opens itself. This is the only place that decides so.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FlowPlanReady",
    callback = function(ev)
      local plan_id = ev.data and ev.data.plan_id
      if plan_id then
        pcall(M.open, plan_id)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FlowReviewReady",
    callback = function(ev)
      local plan_id = ev.data and ev.data.plan_id
      if plan_id then
        vim.schedule(function()
          pcall(require("flow.review").open, plan_id)
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FlowPlanFailed",
    callback = function(ev)
      local plan_id = ev.data and ev.data.plan_id
      local meta = plan_id and store.meta(plan_id)
      notify("The plan failed: " .. tostring(meta and meta.error or "unknown"), vim.log.levels.ERROR)
    end,
  })

  -- A `claude -p` run and the node server both outlive Neovim otherwise.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      pcall(function()
        require("flow.job").stop_all()
      end)
      pcall(function()
        require("flow.server").stop()
      end)
    end,
  })

  require("flow.implementation").recover()
end

--- The statusline fragment. Empty unless an implementation is in play.
function M.statusline()
  local ok, implementation = pcall(require, "flow.implementation")
  if not ok then
    return ""
  end
  return implementation.statusline()
end

return M
