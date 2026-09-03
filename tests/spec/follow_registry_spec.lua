-- The registry lets the hook script find this Neovim over RPC. It also covers
-- the in-editor permission prompt and the statusline. No real hook runs.

local H = require("helpers")

describe("follow registry", function()
  local follow

  before_each(function()
    follow = H.reload("claude.follow")
  end)

  it("writes one file per Neovim instance, keyed by cwd", function()
    follow.register()
    local key = vim.fn.sha256(vim.uv.cwd())
    local dir = vim.fn.stdpath("cache") .. "/claude-follow/" .. key
    local entries = vim.fn.glob(dir .. "/*.server", false, true)

    if vim.v.servername == "" then
      -- Headless Neovim may have no server. Nothing to register.
      assert.equals(0, #entries)
      return
    end

    assert.is_true(#entries >= 1)
    local mine = dir .. "/" .. tostring(vim.uv.os_getpid()) .. ".server"
    assert.equals(1, vim.fn.filereadable(mine))
    assert.equals(vim.v.servername, vim.fn.readfile(mine)[1])
  end)

  it("removes only its own entry", function()
    follow.register()
    local key = vim.fn.sha256(vim.uv.cwd())
    local dir = vim.fn.stdpath("cache") .. "/claude-follow/" .. key
    local other = dir .. "/999999.server"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "/tmp/other.sock" }, other)

    follow.unregister()

    assert.equals(1, vim.fn.filereadable(other))
    vim.fn.delete(other)
  end)

  it("unregister is safe to call twice", function()
    assert.has_no.errors(function()
      follow.unregister()
      follow.unregister()
    end)
  end)

  it("registers and removes a Flow worktree alias", function()
    local worktree = H.tmpdir()
    follow.register(worktree)
    local key = vim.fn.sha256(worktree)
    local path = vim.fn.stdpath("cache") .. "/claude-follow/" .. key .. "/" .. tostring(vim.uv.os_getpid()) .. ".server"
    if vim.v.servername ~= "" then
      assert.equals(1, vim.fn.filereadable(path))
    end
    follow.unregister(worktree)
    assert.equals(0, vim.fn.filereadable(path))
  end)
end)

describe("follow permission", function()
  local follow

  before_each(function()
    follow = H.reload("claude.follow")
    follow.permission_enabled = true
  end)

  local function with_confirm(choice, fn)
    local original = vim.fn.confirm
    local prompt
    vim.fn.confirm = function(msg)
      prompt = msg
      return choice
    end
    local result = fn()
    vim.fn.confirm = original
    return result, prompt
  end

  it("returns allow when you choose Allow", function()
    local result = with_confirm(1, function()
      return follow.permission(H.encode({ tool = "Bash", detail = "ls -la" }))
    end)
    assert.equals("allow", result)
  end)

  it("returns deny when you choose Deny", function()
    local result = with_confirm(2, function()
      return follow.permission(H.encode({ tool = "Bash", detail = "rm -rf /" }))
    end)
    assert.equals("deny", result)
  end)

  it("falls back to the terminal for any other choice", function()
    local result = with_confirm(3, function()
      return follow.permission(H.encode({ tool = "Edit", detail = "x" }))
    end)
    assert.equals("ask", result)
  end)

  it("shows the tool and the detail in the prompt", function()
    local _, prompt = with_confirm(1, function()
      return follow.permission(H.encode({ tool = "Write", detail = "/etc/hosts" }))
    end)
    assert.is_truthy(prompt:match("Write"))
    assert.is_truthy(prompt:match("/etc/hosts"))
  end)

  it("truncates a very long detail", function()
    local long = string.rep("x", 900)
    local _, prompt = with_confirm(1, function()
      return follow.permission(H.encode({ tool = "Bash", detail = long }))
    end)
    assert.is_true(#prompt < 500)
    assert.is_truthy(prompt:match("%.%.%."))
  end)

  it("asks the terminal when in-editor permissions are off", function()
    follow.permission_enabled = false
    local called = false
    local original = vim.fn.confirm
    vim.fn.confirm = function()
      called = true
      return 1
    end
    local result = follow.permission(H.encode({ tool = "Bash", detail = "ls" }))
    vim.fn.confirm = original

    assert.equals("ask", result)
    assert.is_false(called)
  end)

  it("asks the terminal on malformed input, and never throws", function()
    assert.equals("ask", follow.permission("not base64"))
  end)
end)

describe("follow statusline", function()
  local follow, panel

  before_each(function()
    follow = H.reload("claude.follow")
    panel = H.reload("claude.panel")
    panel.clear_tasks()
    follow.agents = {}
    follow.status = "idle"
    follow.clear_queue()
  end)

  it("is empty when Claude is idle and has nothing to show", function()
    assert.equals("", follow.statusline())
  end)

  it("names the running subagents, sorted", function()
    follow.agents = { a = "Explore", b = "Plan" }
    local line = follow.statusline()
    assert.is_truthy(line:match("Explore%+Plan"))
  end)

  it("shows the current tool while Claude works", function()
    follow.status = "working"
    follow.last_tool = "Edit"
    assert.is_truthy(follow.statusline():match("Edit"))
  end)

  it("falls back to 'working' when no tool is known", function()
    follow.status = "working"
    follow.last_tool = nil
    assert.is_truthy(follow.statusline():match("working"))
  end)

  it("shows the plan progress", function()
    panel.task("t1", "one", "completed")
    panel.task("t2", "two", "pending")
    assert.is_truthy(follow.statusline():match("1/2"))
  end)

  it("shows the pending jump count", function()
    follow.enabled = true
    follow.pace_ms = 5000
    local dir = H.tmpdir()
    for i = 1, 3 do
      follow.open(H.write_file(dir, "s" .. i .. ".lua", { "x" }), 1)
    end
    assert.is_truthy(follow.statusline():match("3"))
    follow.clear_queue()
  end)
end)
