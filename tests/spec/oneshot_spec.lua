-- The shared one-shot engine. The `claude` binary is a mock, so no session
-- starts and no token is spent. See tests/hook/mock/claude.

local H = require("helpers")

local MOCK = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  .. "/hook/mock/claude"

describe("oneshot", function()
  local oneshot, hud, dir

  local function clear_env()
    for _, key in ipairs({
      "MOCK_CLAUDE_LOG", "MOCK_CLAUDE_FILE", "MOCK_CLAUDE_LINE",
      "MOCK_CLAUDE_TEXT", "MOCK_CLAUDE_RESULT", "MOCK_CLAUDE_EXIT",
      "MOCK_CLAUDE_STDERR", "MOCK_CLAUDE_THINK", "MOCK_CLAUDE_TOOL",
      "MOCK_CLAUDE_DELAY",
    }) do
      vim.env[key] = nil
    end
  end

  local function settle(seen_out)
    vim.wait(10000, function()
      return oneshot.count() == 0
    end)
    vim.wait(300, function()
      return false
    end)
    return seen_out
  end

  local function quiet(fn)
    local seen = {}
    local original = vim.notify
    vim.notify = function(msg, level)
      table.insert(seen, { msg = msg, level = level })
    end
    fn()
    settle()
    vim.notify = original
    return seen
  end

  before_each(function()
    H.reset_buffers()
    hud = H.reload("claude.hud")
    hud.close_all()
    oneshot = H.reload("claude.oneshot")
    oneshot.opts.command = MOCK
    dir = H.tmpdir()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    clear_env()
  end)

  after_each(function()
    hud.close_all()
  end)

  it("returns a job id", function()
    local id
    quiet(function()
      id = oneshot.run({ prompt = "do a thing", title = "thing" })
    end)
    assert.is_number(id)
  end)

  it("refuses an empty prompt", function()
    local seen = quiet(function()
      assert.is_nil(oneshot.run({ prompt = "" }))
      assert.is_nil(oneshot.run({}))
    end)
    assert.is_true(#seen >= 1)
  end)

  it("streams the thinking into the window", function()
    vim.env.MOCK_CLAUDE_THINK = "The import needs the type keyword."
    local id
    quiet(function()
      id = oneshot.run({ prompt = "fix it", title = "fixing" })
      -- Read the window before the job leaves the list.
      vim.wait(4000, function()
        return table.concat(hud.lines(), "\n"):match("type keyword") ~= nil
      end)
      assert.is_truthy(table.concat(hud.lines(), "\n"):match("type keyword"))
    end)
    assert.is_number(id)
  end)

  it("shows the tool Claude runs", function()
    vim.env.MOCK_CLAUDE_TOOL = "Edit"
    quiet(function()
      oneshot.run({ prompt = "fix it", title = "fixing" })
      vim.wait(4000, function()
        return table.concat(hud.lines(), "\n"):match("Edit") ~= nil
      end)
      assert.is_truthy(table.concat(hud.lines(), "\n"):match("Edit"))
    end)
  end)

  it("keeps the result the session returned", function()
    vim.env.MOCK_CLAUDE_RESULT = "Renamed the type."
    quiet(function()
      oneshot.run({ prompt = "rename it", title = "rename" })
    end)
    assert.equals("Renamed the type.", oneshot.last_result)
  end)

  it("runs two sessions at once", function()
    local a = H.write_file(dir, "a.ts", { "one" })
    local b = H.write_file(dir, "b.ts", { "two" })

    -- Slow the mock, so both are genuinely in flight together.
    vim.env.MOCK_CLAUDE_DELAY = "0.2"

    local seen = {}
    local original = vim.notify
    vim.notify = function(msg, level)
      table.insert(seen, { msg = msg, level = level })
    end

    local id_a = oneshot.run({ prompt = "fix a", title = "job a" })
    local id_b = oneshot.run({ prompt = "fix b", title = "job b" })

    vim.wait(2000, function()
      return oneshot.count() == 2
    end)
    assert.equals(2, oneshot.count())

    local shown = table.concat(hud.lines(), "\n")
    assert.is_truthy(shown:match("job a"))
    assert.is_truthy(shown:match("job b"))

    settle()
    vim.notify = original

    assert.is_not.equal(id_a, id_b)
    assert.equals(0, oneshot.count())
    assert.is_truthy(a)
    assert.is_truthy(b)
  end)

  it("refuses to start past the concurrency cap", function()
    for i = 1, oneshot.opts.max_concurrent do
      oneshot.jobs[500 + i] = { title = "busy" }
    end
    local seen = quiet(function()
      assert.is_nil(oneshot.run({ prompt = "one more", title = "extra" }))
    end)
    local warned = false
    for _, n in ipairs(seen) do
      if type(n.msg) == "string" and n.msg:match("already running") then
        warned = true
      end
    end
    assert.is_true(warned)
    for i = 1, oneshot.opts.max_concurrent do
      oneshot.jobs[500 + i] = nil
    end
  end)

  it("counts the sessions in flight", function()
    assert.equals(0, oneshot.count())
    assert.is_false(oneshot.is_running())
    oneshot.jobs[1] = { title = "busy" }
    assert.equals(1, oneshot.count())
    assert.is_true(oneshot.is_running())
    oneshot.jobs[1] = nil
  end)

  it("shows the session count in the statusline", function()
    assert.equals("", oneshot.statusline())
    oneshot.jobs[1] = { title = "a" }
    assert.is_truthy(oneshot.statusline():match("claude"))
    assert.is_falsy(oneshot.statusline():match("×"))
    oneshot.jobs[2] = { title = "b" }
    assert.is_truthy(oneshot.statusline():match("×2"))
    oneshot.jobs[1], oneshot.jobs[2] = nil, nil
  end)

  it("asks for a stream, and restricts the tools", function()
    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    quiet(function()
      oneshot.run({ prompt = "do it", title = "job", tools = "Read,Edit" })
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("stream%-json"))
    assert.is_truthy(text:match("%-%-include%-partial%-messages"))
    assert.is_falsy(text:match("%-%-model"))
    assert.is_truthy(text:match("Read,Edit"))
    assert.is_truthy(text:match("acceptEdits"))
    assert.is_truthy(text:match("%-%-input%-format"))
    assert.is_truthy(text:match("%-%-session%-id"))
    assert.is_falsy(text:match("%-%-no%-session%-persistence"))
  end)

  it("tells the follow hook to stay out of the way", function()
    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    quiet(function()
      oneshot.run({ prompt = "do it", title = "job" })
    end)
    assert.is_truthy(table.concat(vim.fn.readfile(log), "\n"):match("CLAUDE_NVIM_FOLLOW_DISABLE=1"))
  end)

  it("reloads the buffer and highlights the change", function()
    local path = H.write_file(dir, "c.ts", { "before", "keep" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = "after"

    quiet(function()
      oneshot.run({ prompt = "change it", title = "change", bufnr = buf })
    end)

    assert.equals("after", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    local mark_ns = vim.api.nvim_get_namespaces()["claude_changes"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, mark_ns, 0, -1, { details = true })
    local hl = 0
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == "ClaudeAdded" then
        hl = hl + 1
      end
    end
    assert.is_true(hl >= 1)
  end)

  it("writes an unsaved buffer first", function()
    local path = H.write_file(dir, "d.ts", { "original" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited but unsaved" })

    quiet(function()
      oneshot.run({ prompt = "look at it", title = "look", bufnr = buf })
    end)

    assert.same({ "edited but unsaved" }, vim.fn.readfile(path))
  end)

  it("names the job when it reports a change", function()
    local path = H.write_file(dir, "e.ts", { "before" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = "after"

    local seen = quiet(function()
      oneshot.run({ prompt = "change it", title = "rename the type", bufnr = buf })
    end)

    local named = false
    for _, n in ipairs(seen) do
      if type(n.msg) == "string" and n.msg:match("rename the type: Changed line 1") then
        named = true
      end
    end
    assert.is_true(named)
  end)

  it("warns when nothing changed", function()
    local path = H.write_file(dir, "f.ts", { "unchanged" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    local seen = quiet(function()
      oneshot.run({ prompt = "do nothing", title = "nothing", bufnr = buf })
    end)

    local warned = false
    for _, n in ipairs(seen) do
      if type(n.msg) == "string" and n.msg:match("changed nothing") then
        warned = true
      end
    end
    assert.is_true(warned)
  end)

  it("reports a failure and marks the job failed", function()
    vim.env.MOCK_CLAUDE_EXIT = "1"
    vim.env.MOCK_CLAUDE_STDERR = "rate limited"

    local seen = quiet(function()
      oneshot.run({ prompt = "do it", title = "doomed" })
    end)

    local failed = false
    for _, n in ipairs(seen) do
      if type(n.msg) == "string" and n.msg:match("The session failed") then
        failed = true
      end
    end
    assert.is_true(failed)
    assert.equals(0, oneshot.count())
  end)

  it("calls on_done with the outcome", function()
    local got
    quiet(function()
      oneshot.run({
        prompt = "do it",
        title = "job",
        on_done = function(ok, summary)
          got = { ok = ok, summary = summary }
        end,
      })
    end)
    assert.is_true(got.ok)
    assert.is_string(got.summary)
  end)

  it("survives a stream line that is not JSON", function()
    assert.has_no.errors(function()
      quiet(function()
        oneshot.run({ prompt = "do it", title = "job" })
      end)
    end)
  end)

  it("changed_range finds the edited lines", function()
    assert.is_nil(oneshot.changed_range({ "a", "b" }, { "a", "b" }))

    local first, last = oneshot.changed_range({ "a", "b", "c" }, { "a", "X", "c" })
    assert.equals(2, first)
    assert.equals(2, last)

    first, last = oneshot.changed_range({ "a", "b" }, { "a", "b", "c", "d" })
    assert.equals(3, first)
    assert.equals(4, last)
  end)
end)
