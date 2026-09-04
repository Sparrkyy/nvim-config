-- :checkhealth flow. The check looks at the PATH, the state directory, and
-- the review server. These tests stub each of those, record every report
-- line, and read the verdicts back.

local H = require("helpers")

describe("flow.health", function()
  local health, store, server_stub, report

  --- Run the check with recorders in place of vim.health.
  local function run_check()
    report = { start = {}, ok = {}, warn = {}, error = {} }
    local saved = {}
    for _, kind in ipairs({ "start", "ok", "warn", "error" }) do
      saved[kind] = vim.health[kind]
      vim.health[kind] = function(msg, advice)
        table.insert(report[kind], { msg = msg, advice = advice })
      end
    end
    local ok, err = pcall(health.check)
    for kind, fn in pairs(saved) do
      vim.health[kind] = fn
    end
    assert(ok, err)
  end

  local function messages(kind)
    return table.concat(vim.tbl_map(function(entry)
      return entry.msg
    end, report[kind]), "\n")
  end

  --- Answer vim.fn.executable without touching the real PATH.
  local function stub_executable(missing)
    missing = missing or {}
    vim.fn.executable = function(name)
      return missing[name] and 0 or 1
    end
  end

  before_each(function()
    store = H.reload("flow.store")
    H.flow_root(store)
    server_stub = {
      script = function()
        return H.write_file(H.tmpdir(), "server.js", { "// stub" })
      end,
      address = function()
        return nil
      end,
    }
    package.loaded["flow.server"] = server_stub
    stub_executable()
    health = H.reload("flow.health")
  end)

  after_each(function()
    vim.fn.executable = nil
    package.loaded["flow.server"] = nil
  end)

  it("reports a healthy setup with no errors", function()
    run_check()
    assert.equals("flow", report.start[1].msg)
    assert.equals(0, #report.error)
    local seen = messages("ok")
    assert.is_truthy(seen:match("claude is on the PATH"))
    assert.is_truthy(seen:match("node is on the PATH"))
    assert.is_truthy(seen:match("git is on the PATH"))
    assert.is_truthy(seen:match("this Neovim answers at"))
    assert.is_truthy(seen:match("0 plans here"))
  end)

  it("says where the state lives and counts the plans there", function()
    -- The check counts the plans for the directory Neovim is in.
    store.create({ title = "One plan", cwd = vim.fn.getcwd() })
    run_check()
    local expected = "state is at " .. store.root .. " (1 plans here)"
    assert.is_truthy(messages("ok"):find(expected, 1, true))
  end)

  it("names each missing binary and says what to do", function()
    stub_executable({ claude = true, node = true, git = true })
    run_check()
    local seen = messages("error")
    assert.is_truthy(seen:match("claude is not on the PATH"))
    assert.is_truthy(seen:match("node is not on the PATH"))
    assert.is_truthy(seen:match("git is not on the PATH"))
    for _, entry in ipairs(report.error) do
      assert.is_table(entry.advice)
    end
  end)

  it("points at the review server script when it is gone", function()
    server_stub.script = function()
      return "/nowhere/flow/web/server.js"
    end
    run_check()
    assert.is_truthy(messages("error"):match("/nowhere/flow/web/server%.js"))
  end)

  it("warns, not errors, when the review server is down", function()
    run_check()
    assert.is_truthy(messages("warn"):match("the review server is not running"))
    assert.equals(0, #report.error)
  end)

  it("reports the port of a running review server", function()
    server_stub.address = function()
      return 8080, "abc123"
    end
    run_check()
    assert.is_truthy(messages("ok"):match("the review server runs on port 8080"))
    assert.equals(0, #report.warn)
  end)
end)
