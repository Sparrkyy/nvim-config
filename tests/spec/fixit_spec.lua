-- One-shot fixes. The `claude` binary is a mock, so no session starts and no
-- token is spent. See tests/hook/mock/claude.

local H = require("helpers")

local MOCK = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  .. "/hook/mock/claude"

describe("fixit", function()
  local fixit, dir, ns

  --- Put a diagnostic on a buffer, the way an LSP would.
  local function diagnose(bufnr, items)
    vim.diagnostic.set(ns, bufnr, items)
  end

  local function open(path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end

  --- Run a fix and wait for the async job to finish.
  local function run_fix(fn)
    local seen = {}
    local original = vim.notify
    vim.notify = function(msg, level)
      table.insert(seen, { msg = msg, level = level })
    end
    fn()
    vim.wait(8000, function()
      return require("claude.oneshot").count() == 0
    end)
    -- The result lands in a scheduled callback.
    vim.wait(300, function()
      return false
    end)
    vim.notify = original
    return seen
  end

  local function notified(seen, pattern)
    for _, n in ipairs(seen) do
      if type(n.msg) == "string" and n.msg:match(pattern) then
        return true
      end
    end
    return false
  end

  before_each(function()
    H.reset_buffers()
    H.reload("claude.hud").close_all()
    H.reload("claude.oneshot")
    fixit = H.reload("claude.fixit")
    fixit.opts.command = MOCK
    dir = H.tmpdir()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    ns = vim.api.nvim_create_namespace("fixit_test")
    for _, key in ipairs({
      "MOCK_CLAUDE_LOG", "MOCK_CLAUDE_FILE", "MOCK_CLAUDE_LINE",
      "MOCK_CLAUDE_TEXT", "MOCK_CLAUDE_RESULT", "MOCK_CLAUDE_EXIT",
      "MOCK_CLAUDE_STDERR",
    }) do
      vim.env[key] = nil
    end
  end)

  it("edits the file and reloads the buffer", function()
    local path = H.write_file(dir, "a.ts", {
      'import { Bag } from "./types.js";',
      "const bags: Bag[] = [];",
    })
    local buf = open(path)
    diagnose(buf, {
      { lnum = 0, col = 9, message = "'Bag' is a type", severity = vim.diagnostic.severity.ERROR },
    })

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = 'import type { Bag } from "./types.js";'

    run_fix(function()
      fixit.fix()
    end)

    assert.equals('import type { Bag } from "./types.js";',
      vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("reports which line it fixed", function()
    local path = H.write_file(dir, "b.ts", { "bad line", "good line" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = "fixed line"

    local seen = run_fix(function()
      fixit.fix()
    end)
    assert.is_true(notified(seen, "Changed line 1"))
  end)

  it("highlights the line it changed", function()
    local path = H.write_file(dir, "c.ts", { "bad", "untouched" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = "good"

    run_fix(function()
      fixit.fix()
    end)

    local mark_ns = vim.api.nvim_get_namespaces()["claude_changes"]
    local marks = vim.api.nvim_buf_get_extmarks(vim.fn.bufnr(path), mark_ns, 0, -1, { details = true })
    local hl = 0
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == "ClaudeAdded" then
        hl = hl + 1
      end
    end
    assert.is_true(hl >= 1)
  end)

  it("sends the file, the line, and the message in the prompt", function()
    local path = H.write_file(dir, "d.ts", { "one", "two", "three" })
    local buf = open(path)
    diagnose(buf, {
      { lnum = 1, col = 4, message = "verbatimModuleSyntax complaint", severity = 1, source = "ts", code = "1484" },
    })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    run_fix(function()
      fixit.fix()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("d%.ts"))
    assert.is_truthy(text:match("Line 2, column 5"))
    assert.is_truthy(text:match("verbatimModuleSyntax complaint"))
    assert.is_truthy(text:match("Source: ts"))
    assert.is_truthy(text:match("Code: 1484"))
  end)

  it("shows the failing line marked in the code window", function()
    local path = H.write_file(dir, "e.ts", { "one", "two", "three", "four" })
    local buf = open(path)
    diagnose(buf, { { lnum = 2, col = 0, message = "problem", severity = 1 } })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    run_fix(function()
      fixit.fix()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match(">%s+3 | three"))
  end)

  it("runs with a restricted tool list and accepts its own edits", function()
    local path = H.write_file(dir, "f.ts", { "one" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    run_fix(function()
      fixit.fix()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("%-%-allowedTools"))
    assert.is_truthy(text:match("Read,Edit"))
    assert.is_truthy(text:match("acceptEdits"))
    assert.is_truthy(text:match("%-%-no%-session%-persistence"))
  end)

  it("tells the follow hook to stay out of the way", function()
    local path = H.write_file(dir, "g.ts", { "one" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    run_fix(function()
      fixit.fix()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("CLAUDE_NVIM_FOLLOW_DISABLE=1"))
  end)

  it("picks the nearest diagnostic when the cursor is not on one", function()
    local path = H.write_file(dir, "h.ts", { "one", "two", "three", "four", "five" })
    local buf = open(path)
    diagnose(buf, { { lnum = 4, col = 0, message = "far away problem", severity = 1 } })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    run_fix(function()
      fixit.fix()
    end)

    assert.is_truthy(table.concat(vim.fn.readfile(log), "\n"):match("far away problem"))
  end)

  it("prefers the most severe diagnostic on the cursor line", function()
    local path = H.write_file(dir, "i.ts", { "one", "two" })
    local buf = open(path)
    diagnose(buf, {
      { lnum = 0, col = 0, message = "only a warning", severity = vim.diagnostic.severity.WARN },
      { lnum = 0, col = 5, message = "a real error", severity = vim.diagnostic.severity.ERROR },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    run_fix(function()
      fixit.fix()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("a real error"))
    assert.is_falsy(text:match("only a warning"))
  end)

  it("fix_all sends every diagnostic in one session", function()
    local path = H.write_file(dir, "j.ts", { "one", "two", "three" })
    local buf = open(path)
    diagnose(buf, {
      { lnum = 0, col = 0, message = "first problem", severity = 1 },
      { lnum = 1, col = 0, message = "second problem", severity = 1 },
      { lnum = 2, col = 0, message = "third problem", severity = 1 },
    })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log
    run_fix(function()
      fixit.fix_all()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("first problem"))
    assert.is_truthy(text:match("second problem"))
    assert.is_truthy(text:match("third problem"))
    -- One session only.
    local runs = select(2, text:gsub("%-%-%- invocation %-%-%-", ""))
    assert.equals(1, runs)
  end)

  it("says so when the file has no diagnostics", function()
    local path = H.write_file(dir, "k.ts", { "all good" })
    open(path)
    local seen = run_fix(function()
      fixit.fix()
    end)
    assert.is_true(notified(seen, "No diagnostics"))
  end)

  it("refuses to run on a scratch buffer", function()
    vim.cmd("enew")
    local seen = run_fix(function()
      fixit.fix()
    end)
    assert.is_true(notified(seen, "not a file buffer"))
  end)

  it("reports a failure instead of throwing", function()
    local path = H.write_file(dir, "l.ts", { "one" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    vim.env.MOCK_CLAUDE_EXIT = "1"
    vim.env.MOCK_CLAUDE_STDERR = "rate limited"

    local seen = run_fix(function()
      fixit.fix()
    end)
    assert.is_true(notified(seen, "The session failed"))
    assert.is_true(notified(seen, "rate limited"))
  end)

  it("warns when Claude changes nothing", function()
    local path = H.write_file(dir, "m.ts", { "one" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })
    -- No MOCK_CLAUDE_FILE, so the mock edits nothing.

    local seen = run_fix(function()
      fixit.fix()
    end)
    assert.is_true(notified(seen, "changed nothing"))
  end)

  it("caps how many sessions run at once", function()
    local oneshot = require("claude.oneshot")
    local path = H.write_file(dir, "cap.ts", { "one" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    -- Fill every slot with a pretend session.
    for i = 1, oneshot.opts.max_concurrent do
      oneshot.jobs[1000 + i] = { title = "busy" }
    end

    local seen = run_fix(function()
      fixit.fix()
    end)
    assert.is_true(notified(seen, "already running"))

    for i = 1, oneshot.opts.max_concurrent do
      oneshot.jobs[1000 + i] = nil
    end
  end)

  it("allows a second fix while one runs", function()
    local oneshot = require("claude.oneshot")
    oneshot.jobs[2001] = { title = "busy" }

    local path = H.write_file(dir, "second.ts", { "one" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = "two"

    run_fix(function()
      fixit.fix()
    end)

    oneshot.jobs[2001] = nil
    assert.same({ "two" }, vim.fn.readfile(path))
  end)

  it("writes an unsaved buffer first, so Claude reads your current text", function()
    local path = H.write_file(dir, "n.ts", { "original" })
    local buf = open(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited but unsaved" })
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    run_fix(function()
      fixit.fix()
    end)

    assert.same({ "edited but unsaved" }, vim.fn.readfile(path))
    assert.is_false(vim.bo[buf].modified)
  end)

  it("shows a statusline fragment only while a session runs", function()
    local oneshot = require("claude.oneshot")
    assert.equals("", fixit.statusline())

    oneshot.jobs[3001] = { title = "busy" }
    assert.is_truthy(fixit.statusline():match("claude"))

    oneshot.jobs[3002] = { title = "busy too" }
    assert.is_truthy(fixit.statusline():match("2"))

    oneshot.jobs[3001] = nil
    oneshot.jobs[3002] = nil
    assert.equals("", fixit.statusline())
  end)

  it("keeps the result summary Claude returned", function()
    local path = H.write_file(dir, "o.ts", { "one" })
    local buf = open(path)
    diagnose(buf, { { lnum = 0, col = 0, message = "problem", severity = 1 } })

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = "two"
    vim.env.MOCK_CLAUDE_RESULT = "Made it a type-only import."

    run_fix(function()
      fixit.fix()
    end)
    assert.equals("Made it a type-only import.", fixit.last_result)
  end)
end)
