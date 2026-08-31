-- :checkhealth flow

local M = {}

local store = require("flow.store")

function M.check()
  local start = vim.health.start or vim.health.report_start
  local ok = vim.health.ok or vim.health.report_ok
  local warn = vim.health.warn or vim.health.report_warn
  local err = vim.health.error or vim.health.report_error

  start("flow")

  if vim.fn.executable("claude") == 1 then
    ok("claude is on the PATH")
  else
    err("claude is not on the PATH", { "Install Claude Code, then open a new shell." })
  end

  if vim.fn.executable("node") == 1 then
    ok("node is on the PATH")
  else
    err("node is not on the PATH", { "The plan review page needs node. Install it." })
  end

  local server = require("flow.server")
  if vim.fn.filereadable(server.script()) == 1 then
    ok("the review server is at " .. server.script())
  else
    err("the review server is missing: " .. server.script())
  end

  if vim.v.servername ~= "" then
    ok("this Neovim answers at " .. vim.v.servername)
  else
    err("this Neovim has no server address", { "The browser cannot call Replan or Accept." })
  end

  if vim.fn.isdirectory(store.root) == 1 or vim.fn.mkdir(store.root, "p") == 1 then
    local plans = store.plans()
    ok(string.format("state is at %s (%d plans here)", store.root, #plans))
  else
    err("Flow cannot write to " .. store.root)
  end

  local port = select(1, server.address())
  if port then
    ok("the review server runs on port " .. port)
  else
    warn("the review server is not running", { "It starts when you open a plan." })
  end
end

return M
