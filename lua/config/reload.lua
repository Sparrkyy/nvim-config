-- Reload the configuration without leaving Neovim.
--
-- It drops every `config.*`, `claude.*`, `flow.*`, and `ghostty.*` module from the Lua
-- cache, then re-runs them in the order init.lua uses. Three modules are never
-- dropped:
--   config.lazy    lazy.setup() must run once per session
--   config.reload  this file is running
--   claude.tmux    the persistent session backend owns live processes
--
-- Plugin options do not reload. lazy.nvim hands `opts` to a plugin's setup()
-- once, when the plugin loads. Change a plugin spec and you must restart.

local M = {}

local PATTERNS = { "^config%.", "^claude%.", "^ghostty$", "^ghostty%.", "^flow$", "^flow%." }
local KEEP = {
  ["config.lazy"] = true,
  ["config.reload"] = true,
  ["claude.tmux"] = true,
}

-- The modules init.lua requires, in its order.
local PLAIN = { "config.options", "config.keymaps", "config.autocmds" }
local WITH_SETUP = {
  "config.bufstack",
  "config.session",
  "config.newfile",
  "claude.follow",
  "config.update",
  "config.git_ui",
  "flow",
}

local function reloadable(name)
  if KEEP[name] then
    return false
  end
  for _, pattern in ipairs(PATTERNS) do
    if name:match(pattern) then
      return true
    end
  end
  return false
end

--- Let the modules that hold on to the editor let go, before they disappear.
--- An extmark or a buffer-local keymap outlives its module otherwise.
local function release_state()
  local session_snapshot
  local sessions_ok, sessions = pcall(require, "claude.sessions")
  if sessions_ok and type(sessions.release_for_reload) == "function" then
    local released, snapshot = pcall(sessions.release_for_reload)
    if released then
      session_snapshot = snapshot
    end
  end

  local follow_ok, follow = pcall(require, "claude.follow")
  if follow_ok then
    pcall(follow.clear_queue)
    pcall(follow.clear_marks)
    pcall(follow.unregister)
  end

  local flow_ok, flow_ui = pcall(require, "flow.ui")
  if flow_ok then
    pcall(flow_ui.clear)
  end
  local stack_ok, stack = pcall(require, "flow.stack")
  if stack_ok then
    pcall(stack.reset)
  end
  local review_ok, review = pcall(require, "flow.review")
  if review_ok then
    pcall(review.close)
  end
  local git_ui_ok, git_ui = pcall(require, "config.git_ui")
  if git_ui_ok then
    pcall(git_ui.close)
  end
  return session_snapshot
end

--- Drop and re-run the configuration.
---@return table names the modules that were reloaded, sorted
---@return table failures { module, error } for anything that would not load
function M.reload()
  local session_snapshot = release_state()

  local cleared = {}
  for name in pairs(package.loaded) do
    if reloadable(name) then
      table.insert(cleared, name)
    end
  end
  for _, name in ipairs(cleared) do
    package.loaded[name] = nil
  end

  local failures = {}
  local function load(name, call_setup)
    local ok, result = pcall(require, name)
    if not ok then
      table.insert(failures, { module = name, err = tostring(result) })
      return
    end
    if call_setup and type(result) == "table" and type(result.setup) == "function" then
      local setup_ok, err = pcall(result.setup)
      if not setup_ok then
        table.insert(failures, { module = name .. ".setup", err = tostring(err) })
      end
    end
  end

  for _, name in ipairs(PLAIN) do
    load(name, false)
  end

  local sessions_ok, sessions = pcall(require, "claude.sessions")
  if not sessions_ok then
    table.insert(failures, { module = "claude.sessions", err = tostring(sessions) })
  else
    if session_snapshot and type(sessions.restore_after_reload) == "function" then
      local restored, err = pcall(sessions.restore_after_reload, session_snapshot)
      if not restored then
        table.insert(failures, { module = "claude.sessions.restore_after_reload", err = tostring(err) })
      end
    end
    if type(sessions.setup) == "function" then
      local setup_ok, err = pcall(sessions.setup)
      if not setup_ok then
        table.insert(failures, { module = "claude.sessions.setup", err = tostring(err) })
      end
    end
  end

  -- The colourscheme is a module too, so a colour edit shows up here.
  local hl_ok, hl_err = pcall(vim.cmd.colorscheme, "ghostty")
  if not hl_ok then
    table.insert(failures, { module = "colors.ghostty", err = tostring(hl_err) })
  end
  for _, name in ipairs(WITH_SETUP) do
    load(name, true)
  end

  table.sort(cleared)
  return cleared, failures
end

--- Reload and report.
function M.run()
  local cleared, failures = M.reload()

  if #failures > 0 then
    local lines = { string.format("Reloaded %d modules, %d failed:", #cleared, #failures) }
    for _, f in ipairs(failures) do
      table.insert(lines, "  " .. f.module .. ": " .. f.err:gsub("\n.*", ""))
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.ERROR, { title = "Reload" })
    return
  end

  vim.notify(
    string.format("Reloaded %d modules. Plugin options need a restart.", #cleared),
    vim.log.levels.INFO,
    { title = "Reload" }
  )
end

function M.setup()
  vim.api.nvim_create_user_command("Reload", M.run, {
    desc = "Reload the config modules, without the plugin options",
  })
  vim.keymap.set("n", "<leader>R", M.run, { desc = "Reload config" })
end

return M
