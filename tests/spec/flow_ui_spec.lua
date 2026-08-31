-- What a change looks like before it lands, and the stack panel.

local H = require("helpers")

describe("flow.ui", function()
  local ui, dir

  before_each(function()
    H.reset_buffers()
    ui = H.reload("flow.ui")
    ui.clear()
    ui.close_panel()
    dir = H.tmpdir()
  end)

  after_each(function()
    ui.clear()
    ui.close_panel()
  end)

  local FILE = { "local M = {}", "", "function M.go()", "  return 1", "end", "", "return M" }

  local function file()
    return H.write_file(dir, "sample.lua", FILE)
  end

  --- Finding the place -----------------------------------------------------

  it("finds a single line", function()
    assert.equals(3, ui.find(FILE, { "  return 1" }))
  end)

  it("finds a run of lines", function()
    assert.equals(2, ui.find(FILE, { "function M.go()", "  return 1" }))
  end)

  it("returns nil when the text is not there", function()
    assert.is_nil(ui.find(FILE, { "  return 2" }))
    assert.is_nil(ui.find(FILE, {}))
  end)

  it("searches past a hint, so a repeated line still lands in order", function()
    local lines = { "a", "x", "b", "x", "c" }
    assert.equals(1, ui.find(lines, { "x" }))
    assert.equals(3, ui.find(lines, { "x" }, 2))
  end)

  it("locates every edit of a step, in order", function()
    local hits = ui.locate(FILE, {
      { old_string = "local M = {}", new_string = "local M = {} -- one" },
      { old_string = "return M", new_string = "return M -- two" },
    })
    assert.equals(2, #hits)
    assert.equals(0, hits[1].start)
    assert.equals(6, hits[2].start)
    assert.is_true(hits[1].ok and hits[2].ok)
  end)

  it("marks an edit that no longer fits, instead of guessing", function()
    local hits = ui.locate(FILE, { { old_string = "  return 99", new_string = "x" } })
    assert.is_false(hits[1].ok)
    assert.is_nil(hits[1].start)
  end)

  it("treats an empty old string as the whole of a new file", function()
    local hits = ui.locate({}, { { old_string = "", new_string = "line one\nline two" } })
    assert.is_true(hits[1].ok)
    assert.is_true(hits[1].whole)
    assert.same({ "line one", "line two" }, hits[1].new)
  end)

  it("treats a buffer holding one empty line as a new file too", function()
    -- A file that does not exist yet opens as one empty line, not as no lines.
    local hits = ui.locate({ "" }, { { old_string = "", new_string = "hello" } })
    assert.is_true(hits[1].ok)
    assert.is_true(hits[1].whole)
  end)

  it("refuses an empty old string on a file that has content", function()
    -- This is the bug that spliced a second copy of a type in at line 1.
    local hits = ui.locate(FILE, { { old_string = "", new_string = "local M = {}" } })
    assert.is_false(hits[1].ok)
    assert.equals("empty", hits[1].reason)
    assert.is_nil(hits[1].start)
  end)

  it("splits a deletion into no new lines", function()
    assert.same({}, ui.split(""))
    assert.same({}, ui.split(nil))
  end)

  it("treats a trailing newline as the end of a line, not the start of one", function()
    -- A model ends a code block with a newline. Splitting naively made a
    -- phantom empty line that could never match at the end of a file.
    assert.same({ "a", "b" }, ui.split("a\nb\n"))
    assert.same({ "a", "b" }, ui.split("a\nb"))
    assert.same({ "a", "" }, ui.split("a\n\n"))
    assert.same({ "" }, ui.split("\n"))
  end)

  it("matches an edit anchored on the last lines of the file", function()
    -- The exact shape that failed: the whole final block, newline-terminated.
    local last = table.concat({ "function M.go()", "  return 1", "end", "", "return M" }, "\n") .. "\n"
    local hits = ui.locate(FILE, { { old_string = last, new_string = last .. "\n-- done\n" } })
    assert.is_true(hits[1].ok)
    assert.equals(2, hits[1].start)
  end)

  it("does not add a blank line when the new text ends with a newline", function()
    local hits = ui.locate(FILE, { { old_string = "return M\n", new_string = "return M\n" } })
    assert.same({ "return M" }, hits[1].new)
  end)

  --- The preview ------------------------------------------------------------

  local function preview(edits, extra)
    return ui.preview(vim.tbl_extend("force", {
      file = file(),
      edits = edits,
      rationale = "Return two instead of one.",
      title = "Return two",
      index = 1,
      total = 3,
    }, extra or {}))
  end

  it("opens the file the change belongs to", function()
    H.capture_notify(function()
      assert.is_true(preview({ { old_string = "  return 1", new_string = "  return 2" } }))
    end)
    assert.equals(H.resolve(dir .. "/sample.lua"), H.current_file())
  end)

  it("puts the cursor on the line that changes", function()
    H.capture_notify(function()
      preview({ { old_string = "  return 1", new_string = "  return 2" } })
    end)
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("shows the new lines and the reason, without writing anything", function()
    H.capture_notify(function()
      preview({ { old_string = "  return 1", new_string = "  return 2" } })
    end)
    local shown = table.concat(ui.preview_lines(), "\n")
    assert.is_truthy(shown:match("%+   return 2"))
    assert.is_truthy(shown:match("Return two instead of one"))
    -- The file on disk is untouched.
    assert.same(FILE, vim.fn.readfile(dir .. "/sample.lua"))
  end)

  it("leaves the buffer exactly as it was", function()
    H.capture_notify(function()
      preview({ { old_string = "  return 1", new_string = "  return 2" } })
    end)
    assert.same(FILE, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.bo.modified)
  end)

  it("names the duplicate as the reason, not a stale file", function()
    H.capture_notify(function()
      preview({ { old_string = "", new_string = "local M = {}" } })
    end)
    local shown = table.concat(ui.preview_lines(), "\n")
    assert.is_truthy(shown:match("second copy"))
    assert.same(FILE, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it("says so when the change no longer fits the file", function()
    H.capture_notify(function()
      preview({ { old_string = "  return 99", new_string = "  return 2" } })
    end)
    assert.is_truthy(table.concat(ui.preview_lines(), "\n"):match("This file moved on"))
  end)

  it("applies only when you press enter", function()
    local applied = 0
    H.capture_notify(function()
      preview({ { old_string = "  return 1", new_string = "  return 2" } }, {
        on_apply = function()
          applied = applied + 1
        end,
      })
    end)
    assert.equals(0, applied)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.equals(1, applied)
  end)

  it("takes itself down and calls nothing when you dismiss it", function()
    local applied = false
    H.capture_notify(function()
      preview({ { old_string = "  return 1", new_string = "  return 2" } }, {
        on_apply = function()
          applied = true
        end,
      })
    end)
    assert.is_true(ui.is_open())
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(ui.is_open())
    assert.is_false(applied)
  end)

  it("gives the buffer its keys back when it closes", function()
    H.capture_notify(function()
      preview({ { old_string = "  return 1", new_string = "  return 2" } })
    end)
    local buf = vim.api.nvim_get_current_buf()
    ui.clear()
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      assert.is_not.equal("q", m.lhs)
      assert.is_not.equal("r", m.lhs)
    end
  end)

  it("clears the marks of the last preview before it draws the next", function()
    H.capture_notify(function()
      preview({ { old_string = "  return 1", new_string = "  return 2" } })
      preview({ { old_string = "return M", new_string = "return M -- done" } })
    end)
    local shown = table.concat(ui.preview_lines(), "\n")
    assert.is_falsy(shown:match("return 2"))
    assert.is_truthy(shown:match("return M %-%- done"))
  end)

  it("says a step with no edits is already in the file", function()
    H.capture_notify(function()
      preview({})
    end)
    assert.is_truthy(table.concat(ui.preview_lines(), "\n"):match("already in the file"))
  end)

  it("refuses a spec with no file", function()
    assert.is_false(ui.preview({ edits = {} }))
    assert.is_false(ui.preview(nil))
  end)

  it("can be cleared twice without throwing", function()
    assert.has_no.errors(function()
      ui.clear()
      ui.clear()
    end)
  end)

  --- The panel --------------------------------------------------------------

  local function stack(steps, cursor)
    return {
      title = "Add a flag",
      steps = steps,
      cursor = cursor or 1,
      status_of = function(step, i)
        if step.status == "done" then
          return "done"
        end
        return i == (cursor or 1) and "current" or "ready"
      end,
    }
  end

  it("lists every step with its file", function()
    local lines = ui.panel_lines(stack({
      { title = "Add the flag", file = "src/cli.lua" },
      { title = "Read the flag", file = "src/main.lua" },
    }))
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:match("Add the flag"))
    assert.is_truthy(text:match("src/cli%.lua"))
    assert.is_truthy(text:match("Read the flag"))
  end)

  it("counts what is applied", function()
    local lines = ui.panel_lines(stack({
      { title = "one", file = "a", status = "done" },
      { title = "two", file = "b" },
    }, 2))
    assert.is_truthy(table.concat(lines, "\n"):match("1 of 2 applied"))
  end)

  it("marks the step you are on", function()
    local lines = ui.panel_lines(stack({
      { title = "one", file = "a", status = "done" },
      { title = "two", file = "b" },
    }, 2))
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:match("✔  1  one"))
    assert.is_truthy(text:match("▸  2  two"))
  end)

  it("opens on the right without taking focus", function()
    local before = vim.api.nvim_get_current_win()
    ui.toggle_panel(stack({ { title = "one", file = "a" } }))
    assert.is_true(ui.panel_is_open())
    assert.equals(before, vim.api.nvim_get_current_win())
  end)

  it("closes when you toggle it again", function()
    ui.toggle_panel(stack({ { title = "one", file = "a" } }))
    ui.toggle_panel()
    assert.is_false(ui.panel_is_open())
  end)

  it("reuses its buffer instead of making a second one", function()
    ui.toggle_panel(stack({ { title = "one", file = "a" } }))
    local first = vim.fn.bufnr("flow://stack")
    ui.toggle_panel()
    ui.toggle_panel(stack({ { title = "one", file = "a" } }))
    assert.equals(first, vim.fn.bufnr("flow://stack"))
  end)

  it("redraws when the stack changes", function()
    ui.toggle_panel(stack({ { title = "one", file = "a" } }))
    ui.render_panel(stack({ { title = "one", file = "a", status = "done" } }))
    assert.is_truthy(table.concat(ui.panel_text(), "\n"):match("1 of 1 applied"))
  end)

  it("says nothing when there is no stack", function()
    assert.same({}, ui.panel_text())
  end)
end)
