-- claude.context builds the editor-state block that a UserPromptSubmit hook
-- injects. The hook is never run here; the tests call gather() directly.

local H = require("helpers")

describe("context.gather", function()
  local context, dir

  before_each(function()
    H.reset_buffers()
    context = H.reload("claude.context")
    dir = H.tmpdir()
  end)

  it("returns plain text with a leading explanation", function()
    local path = H.write_file(dir, "a.lua", { "one", "two" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local text = context.gather()
    assert.is_truthy(text:match("^The user is working in Neovim"))
  end)

  it("reports the file and line the cursor is on", function()
    local path = H.write_file(dir, "b.lua", { "one", "two", "three" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    assert.is_truthy(context.gather():match("Cursor: .*b%.lua line 3"))
  end)

  it("reports the lines on screen", function()
    local path = H.write_file(dir, "c.lua", { "one", "two" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    assert.is_truthy(context.gather():match("On screen: .*c%.lua lines %d+%-%d+"))
  end)

  it("lists the open buffers", function()
    local a = H.write_file(dir, "d1.lua", { "x" })
    local b = H.write_file(dir, "d2.lua", { "y" })
    vim.cmd("edit " .. vim.fn.fnameescape(a))
    vim.cmd("edit " .. vim.fn.fnameescape(b))
    local text = context.gather()
    assert.is_truthy(text:match("Open buffers:"))
    assert.is_truthy(text:match("d1%.lua"))
    assert.is_truthy(text:match("d2%.lua"))
  end)

  it("names the buffers with unsaved changes", function()
    local path = H.write_file(dir, "e.lua", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
    assert.is_truthy(context.gather():match("Unsaved changes in: .*e%.lua"))
  end)

  it("caps the buffer list and says how many it hid", function()
    for i = 1, 16 do
      vim.cmd("edit " .. vim.fn.fnameescape(H.write_file(dir, "f" .. i .. ".lua", { "x" })))
    end
    assert.is_truthy(context.gather():match("%(%+%d+ more%)"))
  end)

  it("skips a special buffer and falls back to the last real file", function()
    local path = H.write_file(dir, "g.lua", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    -- Open a scratch split, as the Claude terminal would be.
    vim.cmd("split")
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = "nofile"
    vim.api.nvim_win_set_buf(0, scratch)

    assert.is_truthy(context.gather():match("g%.lua"))
  end)

  it("returns text, never an error, from an empty scratch buffer", function()
    vim.cmd("enew")
    assert.has_no.errors(function()
      local text = context.gather()
      assert.is_string(text)
    end)
  end)

  it("lists the diagnostics in the current file", function()
    local path = H.write_file(dir, "h.lua", { "one", "two", "three" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace("context_test")
    vim.diagnostic.set(ns, buf, {
      { lnum = 1, col = 0, message = "undefined variable", severity = vim.diagnostic.severity.ERROR },
    })

    local text = context.gather()
    assert.is_truthy(text:match("Diagnostics in the current file %(1%)"))
    assert.is_truthy(text:match("line 2 ERROR: undefined variable"))

    vim.diagnostic.reset(ns, buf)
  end)

  it("ignores hints and information, and keeps warnings", function()
    local path = H.write_file(dir, "i.lua", { "one", "two" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace("context_test_2")
    vim.diagnostic.set(ns, buf, {
      { lnum = 0, col = 0, message = "just a hint", severity = vim.diagnostic.severity.HINT },
      { lnum = 1, col = 0, message = "a real warning", severity = vim.diagnostic.severity.WARN },
    })

    local text = context.gather()
    assert.is_falsy(text:match("just a hint"))
    assert.is_truthy(text:match("a real warning"))

    vim.diagnostic.reset(ns, buf)
  end)

  it("caps the diagnostic list and says how many it hid", function()
    local lines = {}
    for i = 1, 30 do
      lines[i] = "line " .. i
    end
    local path = H.write_file(dir, "j.lua", lines)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace("context_test_3")
    local items = {}
    for i = 1, 25 do
      items[i] = { lnum = i - 1, col = 0, message = "problem " .. i, severity = vim.diagnostic.severity.ERROR }
    end
    vim.diagnostic.set(ns, buf, items)

    assert.is_truthy(context.gather():match("%.%.%. and %d+ more"))
    vim.diagnostic.reset(ns, buf)
  end)

  it("collapses a multi-line diagnostic message onto one line", function()
    local path = H.write_file(dir, "k.lua", { "one", "two" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace("context_test_4")
    vim.diagnostic.set(ns, buf, {
      { lnum = 0, col = 0, message = "first part\nsecond part", severity = vim.diagnostic.severity.ERROR },
    })
    assert.is_truthy(context.gather():match("first part second part"))
    vim.diagnostic.reset(ns, buf)
  end)

  it("gather_encoded round-trips through base64", function()
    local path = H.write_file(dir, "l.lua", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local decoded = vim.base64.decode(context.gather_encoded())
    assert.equals(context.gather(), decoded)
  end)

  it("never throws, so a broken context never blocks your prompt", function()
    local original = vim.api.nvim_win_get_cursor
    vim.api.nvim_win_get_cursor = function()
      error("simulated failure")
    end
    local text
    assert.has_no.errors(function()
      text = context.gather()
    end)
    vim.api.nvim_win_get_cursor = original
    assert.is_string(text)
  end)
end)
