-- One-off requests: type an instruction, and Claude carries it out on the file
-- in front of you. The `claude` binary is a mock.

local H = require("helpers")

local MOCK = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  .. "/hook/mock/claude"

describe("ask", function()
  local ask, oneshot, hud, dir

  local function settle()
    vim.wait(10000, function()
      return oneshot.count() == 0
    end)
    vim.wait(200, function()
      return false
    end)
  end

  --- Answer the prompt with `instruction`, run, and return the notifications.
  local function ask_with(instruction, fn)
    local seen = {}
    local original_notify = vim.notify
    local input = require("claude.input")
    local original_open = input.open
    local asked
    vim.notify = function(msg, level)
      table.insert(seen, { msg = msg, level = level })
    end
    input.open = function(opts, cb)
      asked = opts.title
      cb(instruction)
    end
    fn()
    settle()
    input.open = original_open
    vim.notify = original_notify
    return seen, asked
  end

  before_each(function()
    H.reset_buffers()
    hud = H.reload("claude.hud")
    hud.close_all()
    oneshot = H.reload("claude.oneshot")
    oneshot.opts.command = MOCK
    ask = H.reload("claude.ask")
    dir = H.tmpdir()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    for _, key in ipairs({ "MOCK_CLAUDE_LOG", "MOCK_CLAUDE_FILE", "MOCK_CLAUDE_LINE",
      "MOCK_CLAUDE_TEXT", "MOCK_CLAUDE_DELAY" }) do
      vim.env[key] = nil
    end
  end)

  after_each(function()
    hud.close_all()
  end)

  it("sends the file and the cursor line as context", function()
    local path = H.write_file(dir, "a.ts", { "one", "two", "three", "four" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log

    ask_with("add a doc comment", function()
      ask.ask()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("add a doc comment"))
    assert.is_truthy(text:match("File: a%.ts"))
    assert.is_truthy(text:match("cursor is on line 3"))
    assert.is_truthy(text:match(">%s+3 | three"))
  end)

  it("names the file in the title it shows you", function()
    local path = H.write_file(dir, "b.ts", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))

    local _, asked = ask_with("do a thing", function()
      ask.ask()
    end)
    assert.is_truthy(asked:match("b%.ts"))
  end)

  it("uses the instruction as the job title", function()
    local path = H.write_file(dir, "c.ts", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.env.MOCK_CLAUDE_DELAY = "0.2"

    local input = require("claude.input")
    local original_open = input.open
    local original_notify = vim.notify
    vim.notify = function() end
    input.open = function(_, cb)
      cb("rename the type to Bean")
    end
    ask.ask()
    vim.wait(2000, function()
      return oneshot.count() > 0
    end)

    assert.is_truthy(table.concat(hud.lines(), "\n"):match("rename the type"))

    settle()
    input.open = original_open
    vim.notify = original_notify
  end)

  it("carries the change into the buffer", function()
    local path = H.write_file(dir, "d.ts", { "before", "keep" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    vim.env.MOCK_CLAUDE_FILE = path
    vim.env.MOCK_CLAUDE_LINE = "1"
    vim.env.MOCK_CLAUDE_TEXT = "after"

    ask_with("change the first line", function()
      ask.ask()
    end)

    assert.equals("after", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("sends nothing when you cancel", function()
    local path = H.write_file(dir, "e.ts", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log

    ask_with(nil, function()
      ask.ask()
    end)
    assert.equals(0, vim.fn.filereadable(log))
  end)

  it("sends nothing for a blank instruction", function()
    local path = H.write_file(dir, "f.ts", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log

    ask_with("   ", function()
      ask.ask()
    end)
    assert.equals(0, vim.fn.filereadable(log))
  end)

  it("refuses a scratch buffer", function()
    vim.cmd("enew")
    local seen = ask_with("do a thing", function()
      ask.ask()
    end)
    local warned = false
    for _, n in ipairs(seen) do
      if type(n.msg) == "string" and n.msg:match("not a file buffer") then
        warned = true
      end
    end
    assert.is_true(warned)
  end)

  it("sends the selected lines when you ask about a selection", function()
    local path = H.write_file(dir, "g.ts", { "one", "two", "three", "four" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    -- Mark lines 2 to 3 as the last visual selection.
    vim.fn.setpos("'<", { 0, 2, 1, 0 })
    vim.fn.setpos("'>", { 0, 3, 1, 0 })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log

    ask_with("extract this", function()
      ask.ask_selection()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("selected lines are 2 to 3"))
    assert.is_truthy(text:match("two"))
    assert.is_truthy(text:match("three"))
    assert.is_falsy(text:match("|%s+four"))
  end)

  it("names the selected range in the title it shows you", function()
    local path = H.write_file(dir, "h.ts", { "one", "two", "three" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 2, 1, 0 })

    local _, asked = ask_with("do a thing", function()
      ask.ask_selection()
    end)
    assert.is_truthy(asked:match("h%.ts:1%-2"))
  end)

  it("handles a selection made from the bottom up", function()
    local path = H.write_file(dir, "i.ts", { "one", "two", "three" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.fn.setpos("'<", { 0, 3, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log

    ask_with("do a thing", function()
      ask.ask_selection()
    end)
    assert.is_truthy(table.concat(vim.fn.readfile(log), "\n"):match("lines are 1 to 3"))
  end)

  it("caps how much of a long file it quotes", function()
    local lines = {}
    for i = 1, 400 do
      lines[i] = "line " .. i
    end
    local path = H.write_file(dir, "j.ts", lines)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 200, 0 })

    local log = dir .. "/claude.log"
    vim.env.MOCK_CLAUDE_LOG = log

    ask_with("do a thing", function()
      ask.ask()
    end)

    local text = table.concat(vim.fn.readfile(log), "\n")
    assert.is_truthy(text:match("line 200"))
    assert.is_falsy(text:match("line 1\n"))
    assert.is_falsy(text:match("line 400"))
  end)
end)
