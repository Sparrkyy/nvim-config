-- Sending a prompt to Claude. The claudecode.nvim terminal is stubbed, so no
-- Claude process starts and no prompt costs a token.

local H = require("helpers")

describe("follow.prompt", function()
  local follow, stub, dir

  before_each(function()
    H.reset_buffers()
    dir = H.tmpdir()
    follow = H.reload("claude.follow")
  end)

  after_each(function()
    H.unmock_claudecode()
  end)

  it("sends at once when Claude is already running", function()
    stub = H.mock_claudecode({ running = true })
    H.stub_input("fix the bug", function()
      follow.prompt()
    end)
    H.settle(60)

    assert.equals(1, #stub.sends)
    assert.equals("fix the bug", stub.sends[1].text)
    assert.is_true(stub.sends[1].opts.submit)
    assert.equals("working", follow.status)
  end)

  it("waits for the prompt box before it sends on a cold start", function()
    stub = H.mock_claudecode({ running = false })

    H.stub_input("start something", function()
      follow.prompt()
    end)

    -- Claude has not drawn its box yet, so nothing may be sent.
    H.settle(120)
    assert.equals(0, #stub.sends)
    assert.equals(1, stub.visible_calls)

    -- Now Claude finishes booting.
    H.render_claude_prompt(stub.bufnr)
    vim.wait(1500, function()
      return #stub.sends > 0
    end)

    assert.equals(1, #stub.sends)
    assert.equals("start something", stub.sends[1].text)
  end)

  it("sends nothing when you cancel the input", function()
    stub = H.mock_claudecode({ running = true })
    H.stub_input(nil, function()
      follow.prompt()
    end)
    H.settle(60)
    assert.equals(0, #stub.sends)
  end)

  it("sends nothing for a blank prompt", function()
    stub = H.mock_claudecode({ running = true })
    H.stub_input("    ", function()
      follow.prompt()
    end)
    H.settle(60)
    assert.equals(0, #stub.sends)
  end)

  it("prefixes the file and line when asked for context", function()
    stub = H.mock_claudecode({ running = true })
    local path = H.write_file(dir, "ctx.lua", { "one", "two", "three" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local prefix
    local original = vim.ui.input
    vim.ui.input = function(opts, cb)
      prefix = opts.default
      cb(opts.default .. "explain this")
    end
    follow.prompt({ context = true })
    vim.ui.input = original
    H.settle(60)

    assert.is_truthy(prefix:match("ctx%.lua"))
    assert.is_truthy(prefix:match("line 2"))
    assert.is_truthy(stub.sends[1].text:match("explain this$"))
  end)

  it("adds no context prefix from a scratch buffer", function()
    stub = H.mock_claudecode({ running = true })
    vim.cmd("enew")
    local prefix
    local original = vim.ui.input
    vim.ui.input = function(opts, cb)
      prefix = opts.default
      cb("hello")
    end
    follow.prompt({ context = true })
    vim.ui.input = original
    H.settle(60)
    assert.equals("", prefix)
  end)

  it("warns instead of throwing when claudecode.nvim is missing", function()
    -- Make require fail, the way it fails when the plugin is not installed.
    package.loaded["claudecode.terminal"] = nil
    package.preload["claudecode.terminal"] = function()
      error("module 'claudecode.terminal' not found")
    end

    local seen = H.capture_notify(function()
      follow.prompt()
    end)

    package.preload["claudecode.terminal"] = nil
    assert.equals(1, #seen)
    assert.is_truthy(seen[1].msg:match("not loaded"))
  end)

  it("warns instead of throwing when the module is not a table", function()
    package.loaded["claudecode.terminal"] = false
    local seen = H.capture_notify(function()
      follow.prompt()
    end)
    assert.equals(1, #seen)
    assert.is_truthy(seen[1].msg:match("not loaded"))
  end)

  it("interrupt warns when Claude is not running", function()
    stub = H.mock_claudecode({ running = false })
    local seen = H.capture_notify(function()
      follow.interrupt()
    end)
    assert.is_truthy(seen[1].msg:match("not running"))
  end)
end)
