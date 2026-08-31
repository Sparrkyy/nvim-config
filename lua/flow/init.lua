-- Flow: plan a change, review it in a browser, then apply it one idea at a
-- time without leaving Neovim.
--
--   <leader>dn  new plan
--   <leader>dp  open the current plan in the browser
--   <leader>dj  apply the next change
--   <leader>dk  view the previous change
--   <leader>dr  revise this change
--   <leader>dR  revise the whole plan
--   <leader>du  undo the last applied change
--   <leader>ds  toggle the stack panel
--   <leader>dl  list every plan
--
-- The stages live in flow.planner (write the doc), flow.server (review it),
-- and flow.stack (apply it). This file is the wiring.

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

local DONE = { done = true, abandoned = true }

--- The plan the keymaps act on. The newest unfinished plan, unless you picked
--- another one with :FlowPlans.
---@return string|nil plan_id
function M.current(cwd)
  cwd = cwd or vim.fn.getcwd()
  local chosen = selected[cwd]
  if chosen and store.meta(chosen, cwd) then
    return chosen
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
    require("flow.stack").next()
  end, { desc = "Apply the next change" })

  cmd("FlowPrev", function()
    require("flow.stack").prev()
  end, { desc = "View the previous change" })

  cmd("FlowStack", function()
    require("flow.stack").toggle_panel()
  end, { desc = "Toggle the change stack panel" })

  cmd("FlowPlans", function()
    require("flow.picker").plans()
  end, { desc = "List every plan in this directory" })
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
    require("flow.stack").next()
  end, "Flow: apply next change")
  map("<leader>dk", function()
    require("flow.stack").prev()
  end, "Flow: view previous change")
  map("<leader>dr", function()
    require("flow.stack").revise_step()
  end, "Flow: revise this change")
  map("<leader>dR", function()
    require("flow.stack").revise_plan()
  end, "Flow: revise the plan")
  map("<leader>du", function()
    require("flow.stack").undo()
  end, "Flow: undo last change")
  map("<leader>ds", function()
    require("flow.stack").toggle_panel()
  end, "Flow: toggle stack panel")
  map("]f", function()
    require("flow.stack").next()
  end, "Flow: apply next change")
  map("[f", function()
    require("flow.stack").prev()
  end, "Flow: view previous change")
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
end

--- The statusline fragment. Empty unless a stack is in play.
function M.statusline()
  local ok, stack = pcall(require, "flow.stack")
  if not ok then
    return ""
  end
  return stack.statusline()
end

return M
