-- The review server, seen from Neovim.
--
-- It runs lua/flow/web/server.js under node, on a port the kernel picks. The
-- server prints one line, `FLOW_READY <port> <token>`, and this reads it. One
-- server serves every plan in the state directory, so it starts once.
--
-- The server holds a pipe to our stdin. Neovim exiting closes that pipe, and
-- node stops. M.stop() on VimLeavePre is the tidy path; the pipe is the net.

local M = {}

local store = require("flow.store")

M.opts = {
  command = "node",
  ready_timeout_ms = 5000,
}

local state = { proc = nil, port = nil, token = nil, starting = false, waiting = {} }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Flow" })
end

--- Where server.js lives, next to this file.
function M.script()
  local here = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(here, ":p:h") .. "/web/server.js"
end

--- The one call that reaches the outside world. The tests replace it.
function M.spawn(cmd, opts, on_exit)
  return vim.system(cmd, opts, on_exit)
end

function M.is_running()
  return state.port ~= nil
end

function M.url(plan_id)
  if not state.port then
    return nil
  end
  return string.format("http://127.0.0.1:%d/plan/%s?token=%s", state.port, plan_id, state.token)
end

--- Everyone who asked for the server while it was starting.
local function settle(ok)
  local waiting = state.waiting
  state.waiting = {}
  state.starting = false
  for _, fn in ipairs(waiting) do
    pcall(fn, ok)
  end
end

--- Start the server if it is not up. `done` is called with a boolean.
function M.start(done)
  if state.port then
    if done then
      done(true)
    end
    return
  end
  if done then
    table.insert(state.waiting, done)
  end
  if state.starting then
    return
  end
  state.starting = true

  if vim.fn.executable(M.opts.command) ~= 1 then
    notify("Flow needs node on the PATH to show a plan.", vim.log.levels.ERROR)
    return settle(false)
  end

  local script = M.script()
  if vim.fn.filereadable(script) ~= 1 then
    notify("Flow cannot find " .. script, vim.log.levels.ERROR)
    return settle(false)
  end

  local env = vim.tbl_extend("force", {}, (vim.uv or vim.loop).os_environ())
  env.FLOW_NVIM_SERVER = vim.v.servername

  local buffer = ""
  local stderr = {}

  local ok, proc = pcall(M.spawn, {
    M.opts.command,
    script,
    "--root",
    store.root,
    "--port",
    "0",
    -- The pipe below is how node learns that Neovim is gone.
    "--watch-stdin",
  }, {
    -- The pipe stays open for the life of Neovim. node exits when it closes.
    stdin = true,
    text = true,
    env = env,
    stdout = function(err, chunk)
      if err or not chunk or state.port then
        return
      end
      buffer = buffer .. chunk
      local port, token = buffer:match("FLOW_READY (%d+) (%x+)")
      if port then
        vim.schedule(function()
          state.port, state.token = tonumber(port), token
          settle(true)
        end)
      end
    end,
    stderr = function(err, chunk)
      if not err and chunk then
        table.insert(stderr, chunk)
      end
    end,
  }, function(out)
    vim.schedule(function()
      state.proc, state.port, state.token = nil, nil, nil
      if out.code ~= 0 and out.code ~= 143 then
        local detail = table.concat(stderr, ""):gsub("%s+$", "")
        notify(
          "The review server stopped: " .. (detail ~= "" and detail or ("exit " .. out.code)),
          vim.log.levels.ERROR
        )
      end
      settle(false)
    end)
  end)

  if not ok then
    notify("Flow could not start the review server: " .. tostring(proc), vim.log.levels.ERROR)
    return settle(false)
  end
  state.proc = proc

  -- A server that never prints its port is a server that is not coming.
  vim.defer_fn(function()
    if state.starting and not state.port then
      notify("The review server did not start in time.", vim.log.levels.ERROR)
      M.stop()
      settle(false)
    end
  end, M.opts.ready_timeout_ms)
end

--- Open one plan in the browser, starting the server first if it is down.
function M.open(plan_id)
  M.start(function(ok)
    if not ok then
      return
    end
    local url = M.url(plan_id)
    if not url then
      return
    end
    local opened = pcall(vim.ui.open, url)
    if opened then
      notify("Plan open in the browser.")
    else
      notify("Open this: " .. url)
    end
  end)
end

function M.stop()
  local proc = state.proc
  state.proc, state.port, state.token = nil, nil, nil
  if proc then
    pcall(function()
      proc:kill("sigterm")
    end)
  end
end

--- The port and token, for the tests.
function M.address()
  return state.port, state.token
end

return M
