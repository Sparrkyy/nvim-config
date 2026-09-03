-- M.handle is the entry point the hook script calls over RPC. It takes
-- base64 JSON. Every payload here is a fake; no hook and no Claude CLI runs.

local H = require("helpers")

describe("follow.handle", function()
  local follow, panel, dir

  before_each(function()
    H.reset_buffers()
    follow = H.reload("claude.follow")
    follow.enabled = true
    panel = H.reload("claude.panel")
    follow.pace_ms = 0
    follow.highlight_changes = true
    follow.clear_queue()
    dir = H.tmpdir()
  end)

  it("unregisters on exit without treating the autocmd event as a directory", function()
    follow.setup()
    local argument = "not called"
    follow.unregister = function(value)
      argument = value
    end
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "ClaudeFollow" })
    assert.is_nil(argument)
  end)

  it("opens the file an edit touches", function()
    local path = H.write_file(dir, "a.lua", { "one", "two", "three" })
    local result = follow.handle(H.encode({
      kind = "open", tool = "Edit", path = path, line = 3,
    }))
    assert.equals("ok", result)
    assert.equals(path, H.current_file())
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("ignores file events while follow mode is off", function()
    local path = H.write_file(dir, "off.lua", { "before" })
    follow.enabled = false
    local result = follow.handle(H.encode({
      kind = "open", event = "PreToolUse", tool = "Edit", path = path, line = 1,
    }))
    H.write_file(dir, "off.lua", { "after" })
    follow.handle(H.encode({
      kind = "open", event = "PostToolUse", tool = "Edit", path = path, line = 1,
    }))
    H.settle()
    assert.equals("disabled", result)
    assert.equals(0, follow.queue_length())
    assert.is_false(path == H.current_file())
  end)

  it("finds the line from the old_string when no offset is given", function()
    local path = H.write_file(dir, "b.lua", { "alpha", "beta", "gamma" })
    follow.handle(H.encode({
      kind = "open", tool = "Edit", path = path, line = vim.NIL, needle = "gamma",
    }))
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("treats a JSON null line as absent, not as line zero", function()
    local path = H.write_file(dir, "c.lua", { "one", "two" })
    assert.has_no.errors(function()
      follow.handle(H.encode({ kind = "open", tool = "Read", path = path, line = vim.NIL }))
    end)
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("marks the added lines a PostToolUse payload reports", function()
    local path = H.write_file(dir, "d.lua", { "keep", "added one", "added two" })
    follow.handle(H.encode({
      kind = "open", event = "PostToolUse", tool = "Edit", path = path,
      added = { "added one\nadded two" },
    }))
    H.settle(80)

    local ns = vim.api.nvim_get_namespaces()["claude_changes"]
    local marks = vim.api.nvim_buf_get_extmarks(vim.fn.bufnr(path), ns, 0, -1, { details = true })
    local hl = 0
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == "ClaudeAdded" then
        hl = hl + 1
      end
    end
    assert.equals(2, hl)
  end)

  it("does not mark on a PreToolUse payload, because nothing is written yet", function()
    local path = H.write_file(dir, "e.lua", { "one", "two" })
    follow.handle(H.encode({
      kind = "open", event = "PreToolUse", tool = "Edit", path = path, added = {},
    }))
    H.settle(60)
    local ns = vim.api.nvim_get_namespaces()["claude_changes"]
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(vim.fn.bufnr(path), ns, 0, -1, {}))
  end)

  it("reloads an edit and keeps removed code visible in red virtual lines", function()
    local path = H.write_file(dir, "animated.lua", { "keep", "remove me", "tail" })
    follow.handle(H.encode({
      kind = "open", event = "PreToolUse", tool = "Edit", write = true,
      path = path, needle = "remove me",
    }))
    H.write_file(dir, "animated.lua", { "keep", "added here", "tail" })

    follow.handle(H.encode({
      kind = "open", event = "PostToolUse", tool = "Edit", write = true,
      path = path, added = { "added here" },
    }))

    local bufnr = vim.fn.bufnr(path)
    assert.same({ "keep", "added here", "tail" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local ns = vim.api.nvim_get_namespaces()["claude_changes"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local added = 0
    local removed
    for _, mark in ipairs(marks) do
      if mark[4].line_hl_group == "ClaudeAdded" then
        added = added + 1
      elseif mark[4].virt_lines then
        removed = mark[4].virt_lines[1][1][1]
      end
    end
    assert.equals(1, added)
    assert.equals("remove me", removed)
  end)

  it("queues each changed hunk as its own replay step", function()
    follow.pace_ms = 5000
    local path = H.write_file(dir, "hunks.lua", {
      "head", "old one", "keep a", "keep b", "keep c", "old two", "tail",
    })
    follow.handle(H.encode({
      kind = "open", event = "PreToolUse", tool = "Edit", write = true,
      path = path, needle = "old one",
    }))
    H.write_file(dir, "hunks.lua", {
      "head", "new one", "keep a", "keep b", "keep c", "new two", "tail",
    })

    follow.handle(H.encode({
      kind = "open", event = "PostToolUse", tool = "Edit", write = true,
      path = path, added = { "new one", "new two" },
    }))

    assert.equals(3, follow.queue_length())
    follow.clear_queue()
  end)

  it("lingers, fades, and then clears animated changes", function()
    follow.change_linger_ms = 30
    follow.change_fade_ms = 90
    local path = H.write_file(dir, "fade.lua", { "old" })
    follow.handle(H.encode({
      kind = "open", event = "PreToolUse", tool = "Edit", write = true,
      path = path, needle = "old",
    }))
    H.write_file(dir, "fade.lua", { "new" })
    follow.handle(H.encode({
      kind = "open", event = "PostToolUse", tool = "Edit", write = true,
      path = path, added = { "new" },
    }))

    local bufnr = vim.fn.bufnr(path)
    local ns = vim.api.nvim_get_namespaces()["claude_changes"]
    H.settle(60)
    local fading = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local saw_fade = false
    for _, mark in ipairs(fading) do
      local details = mark[4]
      if details.line_hl_group and details.line_hl_group:match("^ClaudeAddedFade") then
        saw_fade = true
      end
    end
    assert.is_true(saw_fade)

    H.settle(90)
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
  end)

  it("records a tool failure in the quickfix list", function()
    vim.fn.setqflist({}, "r")
    local path = H.write_file(dir, "f.lua", { "one" })
    local seen = H.capture_notify(function()
      follow.handle(H.encode({
        kind = "quickfix", path = path, line = 1, text = "Edit: file not found",
      }))
    end)
    local items = vim.fn.getqflist()
    assert.equals(1, #items)
    assert.equals("Edit: file not found", vim.trim(items[1].text))
    assert.equals(1, #seen)
  end)

  it("tracks subagents as they start and stop", function()
    follow.handle(H.encode({ kind = "agent", event = "start", id = "a1", agent_type = "Explore" }))
    assert.equals("Explore", follow.agents["a1"])
    assert.is_truthy(follow.statusline():match("Explore"))

    follow.handle(H.encode({ kind = "agent", event = "stop", id = "a1" }))
    assert.is_nil(follow.agents["a1"])
  end)

  it("passes a task through to the plan panel", function()
    panel.clear_tasks()
    follow.handle(H.encode({
      kind = "task", id = "t1", text = "Write the tests", task_status = "in_progress",
    }))
    assert.equals("Write the tests", panel.tasks["t1"].text)
    assert.equals("in_progress", panel.tasks["t1"].status)
  end)

  it("passes a message through to the notes panel", function()
    panel.clear_notes()
    follow.handle(H.encode({
      kind = "message", id = "m1", delta = "Here is the plan.", final = true,
    }))
    local buf = vim.fn.bufnr("Claude Notes")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:match("Here is the plan"))
  end)

  it("updates the status and notifies", function()
    local seen = H.capture_notify(function()
      follow.handle(H.encode({
        kind = "status", status = "working", level = "WARN", message = "Checks failed.",
      }))
    end)
    assert.equals("working", follow.status)
    assert.equals("Checks failed.", seen[1].msg)
  end)

  it("does not notify on a status with no message", function()
    local seen = H.capture_notify(function()
      follow.handle(H.encode({ kind = "status", status = "idle", message = "" }))
    end)
    assert.equals("idle", follow.status)
    assert.equals(0, #seen)
  end)

  it("returns unknown for a kind it does not handle", function()
    assert.equals("unknown", follow.handle(H.encode({ kind = "nonsense" })))
  end)

  it("returns an error string instead of throwing on bad input", function()
    local result = follow.handle("this is not base64 json")
    assert.is_truthy(result:match("^error:"))
  end)

  it("never throws, whatever the hook sends", function()
    local payloads = {
      {}, { kind = "open" }, { kind = "open", path = 42 },
      { kind = "task" }, { kind = "message" }, { kind = "agent" },
      { kind = "quickfix" }, { kind = "status" },
    }
    for _, p in ipairs(payloads) do
      assert.has_no.errors(function()
        follow.handle(H.encode(p))
      end)
    end
  end)
end)
