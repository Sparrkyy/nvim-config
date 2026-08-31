-- What the review server calls when you press a button in the browser.
--
-- The server runs:
--   nvim --server <addr> --remote-expr "v:lua.require'flow.bridge'.handle('<b64>')"
--
-- That is the same transport ~/.claude/hooks/nvim-follow.sh uses. Base64 keeps
-- the JSON away from the shell and away from Vim's expression parser.
--
-- This must never raise. An error here surfaces as a failed HTTP request in
-- the browser, with no useful message.

local M = {}

local store = require("flow.store")

--- Handle one message. Returns a short string, because --remote-expr needs an
--- expression to print.
---@param encoded string base64 of { action = "replan"|"accept", plan_id = string }
---@return string
function M.handle(encoded)
  local ok, result = pcall(function()
    local decoded = vim.base64.decode(encoded)
    local msg = vim.json.decode(decoded)
    if type(msg) ~= "table" or type(msg.plan_id) ~= "string" then
      return "bad message"
    end
    return M.dispatch(msg.action, msg.plan_id)
  end)
  if not ok then
    return "error: " .. tostring(result):gsub("\n.*", "")
  end
  return result
end

--- Act on one browser button.
function M.dispatch(action, plan_id)
  local meta = store.meta(plan_id)
  if not meta then
    return "no such plan"
  end

  if action == "replan" then
    local started = require("flow.planner").replan(plan_id, { cwd = meta.cwd })
    return started and "replanning" or "nothing to replan"
  end

  if action == "accept" then
    require("flow").select(plan_id, meta.cwd)
    require("flow.stack").begin(plan_id)
    return "accepted"
  end

  return "unknown action"
end

return M
