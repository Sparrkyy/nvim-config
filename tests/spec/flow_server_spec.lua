-- The review server, seen from Neovim. No test here starts node or opens a
-- port. `server.spawn` is the one call that reaches a process; these tests
-- replace it and feed the module the ready line the real server prints.

local H = require("helpers")

describe("flow.server", function()
  local server, store

  local function stub_spawn()
    local stub = { calls = {}, killed = {} }
    server.spawn = function(cmd, opts, on_exit)
      table.insert(stub.calls, { cmd = cmd, opts = opts })
      stub.stdout = opts.stdout
      stub.stderr = opts.stderr
      stub.on_exit = on_exit
      return {
        kill = function(_, signal)
          table.insert(stub.killed, signal)
        end,
      }
    end
    return stub
  end

  --- Print the ready line, then run the scheduled callbacks.
  local function ready(stub, port, token)
    stub.stdout(nil, string.format("FLOW_READY %d %s\n", port or 4321, token or "abc123"))
    H.settle(10)
  end

  local function flags(cmd)
    local out = {}
    for i, arg in ipairs(cmd) do
      out[arg] = cmd[i + 1]
    end
    return out
  end

  before_each(function()
    store = H.reload("flow.store")
    H.flow_root(store)
    server = H.reload("flow.server")
  end)

  after_each(function()
    server.stop()
  end)

  it("finds its script next to the module", function()
    assert.is_truthy(server.script():match("/lua/flow/web/server%.js$"))
    assert.equals(1, vim.fn.filereadable(server.script()))
  end)

  it("hands the exit callback to vim.system, so a crash is seen", function()
    local saved = vim.system
    local seen
    vim.system = function(cmd, opts, on_exit)
      seen = { cmd = cmd, opts = opts, on_exit = on_exit }
      return {}
    end
    local ok, err = pcall(function()
      local on_exit = function() end
      server.spawn({ "node", "--version" }, { text = true }, on_exit)
      assert.equals(on_exit, seen.on_exit)
    end)
    vim.system = saved
    assert(ok, err)
  end)

  it("starts one server and answers everyone who waited", function()
    local stub = stub_spawn()
    local results = {}
    server.start(function(ok)
      table.insert(results, ok)
    end)
    server.start(function(ok)
      table.insert(results, ok)
    end)
    assert.equals(1, #stub.calls)
    assert.same({}, results)
    ready(stub)
    assert.same({ true, true }, results)
    assert.is_true(server.is_running())
    local port, token = server.address()
    assert.equals(4321, port)
    assert.equals("abc123", token)
  end)

  it("reads a ready line that arrives in pieces", function()
    local stub = stub_spawn()
    local answered
    server.start(function(ok)
      answered = ok
    end)
    stub.stdout(nil, "FLOW_READY 43")
    stub.stdout(nil, "21 abc123\n")
    H.settle(10)
    assert.is_true(answered)
    assert.equals(4321, (server.address()))
  end)

  it("keeps the first port it read", function()
    local stub = stub_spawn()
    server.start()
    ready(stub)
    stub.stdout(nil, "FLOW_READY 9999 ffff\n")
    H.settle(10)
    assert.equals(4321, (server.address()))
  end)

  it("serves the state root and dies when Neovim closes stdin", function()
    local stub = stub_spawn()
    server.start()
    local call = stub.calls[1]
    assert.equals(server.opts.command, call.cmd[1])
    assert.equals(server.script(), call.cmd[2])
    local seen = flags(call.cmd)
    assert.equals(store.root, seen["--root"])
    assert.equals("0", seen["--port"])
    assert.is_true(vim.tbl_contains(call.cmd, "--watch-stdin"))
    assert.is_true(call.opts.stdin)
    assert.equals(vim.v.servername, call.opts.env.FLOW_NVIM_SERVER)
  end)

  it("builds a tokened URL for one plan", function()
    local stub = stub_spawn()
    server.start()
    ready(stub, 5000, "deadbeef")
    assert.equals("http://127.0.0.1:5000/plan/p1?token=deadbeef", server.url("p1"))
  end)

  it("has no URL while it is down", function()
    assert.is_nil(server.url("p1"))
  end)

  it("answers at once when it is already up", function()
    local stub = stub_spawn()
    server.start()
    ready(stub)
    local answered
    server.start(function(ok)
      answered = ok
    end)
    assert.is_true(answered)
    assert.equals(1, #stub.calls)
  end)

  it("refuses to start without node", function()
    server.opts.command = "flow-test-no-such-command"
    local answered
    local seen = H.capture_notify(function()
      server.start(function(ok)
        answered = ok
      end)
    end)
    assert.is_false(answered)
    assert.equals(vim.log.levels.ERROR, seen[1].level)
    assert.is_truthy(seen[1].msg:match("node on the PATH"))
    assert.is_false(server.is_running())
  end)

  it("refuses to start when the script is missing", function()
    server.script = function()
      return "/nowhere/flow/web/server.js"
    end
    local answered
    local seen = H.capture_notify(function()
      server.start(function(ok)
        answered = ok
      end)
    end)
    assert.is_false(answered)
    assert.is_truthy(seen[1].msg:match("/nowhere/flow/web/server%.js"))
  end)

  it("reports a spawn failure and settles everyone", function()
    server.spawn = function()
      error("boom")
    end
    local answered
    local seen = H.capture_notify(function()
      server.start(function(ok)
        answered = ok
      end)
    end)
    assert.is_false(answered)
    assert.is_truthy(seen[1].msg:match("could not start the review server"))
  end)

  it("reports a server that dies before it is ready", function()
    local stub = stub_spawn()
    local answered
    local seen = H.capture_notify(function()
      server.start(function(ok)
        answered = ok
      end)
      stub.stderr(nil, "Error: EADDRINUSE")
      stub.on_exit({ code = 1 })
      H.settle(10)
    end)
    assert.is_false(answered)
    assert.is_false(server.is_running())
    assert.equals(vim.log.levels.ERROR, seen[1].level)
    assert.is_truthy(seen[1].msg:match("EADDRINUSE"))
  end)

  it("falls back to the exit code when the server says nothing", function()
    local stub = stub_spawn()
    local seen = H.capture_notify(function()
      server.start()
      stub.on_exit({ code = 7 })
      H.settle(10)
    end)
    assert.is_truthy(seen[1].msg:match("exit 7"))
  end)

  it("stays quiet when Neovim's own exit takes the server down", function()
    local stub = stub_spawn()
    server.start()
    ready(stub)
    local seen = H.capture_notify(function()
      stub.on_exit({ code = 143 })
      H.settle(10)
    end)
    assert.equals(0, #seen)
    assert.is_false(server.is_running())
  end)

  it("gives up on a server that never answers", function()
    server.opts.ready_timeout_ms = 20
    local stub = stub_spawn()
    local answered
    local seen = H.capture_notify(function()
      server.start(function(ok)
        answered = ok
      end)
      H.settle(100)
    end)
    assert.is_false(answered)
    assert.is_truthy(seen[1].msg:match("did not start in time"))
    assert.same({ "sigterm" }, stub.killed)
  end)

  it("stops the process and forgets the address", function()
    local stub = stub_spawn()
    server.start()
    ready(stub)
    server.stop()
    assert.is_false(server.is_running())
    assert.is_nil(server.url("p1"))
    assert.same({ "sigterm" }, stub.killed)
  end)

  it("opens the plan in the browser once the server is up", function()
    local stub = stub_spawn()
    local saved = vim.ui.open
    local opened
    vim.ui.open = function(url)
      opened = url
    end
    local ok, err = pcall(function()
      local seen = H.capture_notify(function()
        server.open("p1")
        ready(stub)
      end)
      assert.equals("http://127.0.0.1:4321/plan/p1?token=abc123", opened)
      assert.is_truthy(seen[#seen].msg:match("browser"))
    end)
    vim.ui.open = saved
    assert(ok, err)
  end)

  it("does not open a browser when the server cannot start", function()
    server.spawn = function()
      error("boom")
    end
    local saved = vim.ui.open
    local opened
    vim.ui.open = function(url)
      opened = url
    end
    local ok, err = pcall(function()
      H.capture_notify(function()
        server.open("p1")
      end)
      assert.is_nil(opened)
    end)
    vim.ui.open = saved
    assert(ok, err)
  end)
end)
