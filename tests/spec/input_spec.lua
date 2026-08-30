-- The instruction composer. It wraps and grows downward, instead of running
-- off the side of the screen.

local H = require("helpers")

describe("input", function()
  local input

  before_each(function()
    H.reset_buffers()
    input = H.reload("claude.input")
    input.close()
  end)

  after_each(function()
    input.close()
  end)

  --- Press one key in the composer, from normal mode. Insert mode would make
  --- <Esc> mean "leave insert", not "cancel".
  local function press(key)
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
  end

  local function type_text(text)
    local _, buf = input.handles()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  end

  local function height()
    local win = input.handles()
    return vim.api.nvim_win_get_height(win)
  end

  local function window_width()
    local win = input.handles()
    return vim.api.nvim_win_get_width(win)
  end

  it("opens a window and takes focus, so you can type", function()
    input.open({ title = "Claude, index.ts" }, function() end)
    assert.is_true(input.is_open())
    local win = input.handles()
    assert.equals(win, vim.api.nvim_get_current_win())
  end)

  it("wraps rather than growing sideways", function()
    input.open({ title = "test" }, function() end)
    local win, buf = input.handles()
    assert.is_true(vim.wo[win].wrap)
    assert.is_true(vim.wo[win].linebreak)
    assert.is_number(buf)
  end)

  it("never grows wider than its cap, whatever you type", function()
    input.open({ title = "test" }, function() end)
    local before = window_width()
    type_text(string.rep("scaffold out endpoints for CRUD ", 40))
    assert.equals(before, window_width())
    assert.is_true(window_width() <= input.opts.max_width)
  end)

  it("grows downward as the text wraps", function()
    input.open({ title = "test" }, function() end)
    assert.equals(1, height())
    type_text(string.rep("word ", 200))
    assert.is_true(height() > 1)
  end)

  it("stops growing at its height cap", function()
    input.open({ title = "test" }, function() end)
    type_text(string.rep("word ", 4000))
    assert.is_true(height() <= input.opts.max_height)
  end)

  it("grows for a hard line break too", function()
    input.open({ title = "test" }, function() end)
    type_text("one\ntwo\nthree\nfour")
    assert.is_true(height() >= 4)
  end)

  it("passes the text back on submit", function()
    local got
    input.open({ title = "test" }, function(text)
      got = text
    end)
    type_text("scaffold the CRUD endpoints")
    press("<CR>")
    assert.equals("scaffold the CRUD endpoints", got)
    assert.is_false(input.is_open())
  end)

  it("keeps a hard line break in the text it returns", function()
    local got
    input.open({ title = "test" }, function(text)
      got = text
    end)
    type_text("first line\nsecond line")
    press("<CR>")
    assert.equals("first line\nsecond line", got)
  end)

  it("returns nil when you cancel", function()
    local called, got = false, "unset"
    input.open({ title = "test" }, function(text)
      called = true
      got = text
    end)
    type_text("something I changed my mind about")
    press("<Esc>")
    assert.is_true(called)
    assert.is_nil(got)
  end)

  it("returns nil for an empty submit", function()
    local got = "unset"
    input.open({ title = "test" }, function(text)
      got = text
    end)
    press("<CR>")
    assert.is_nil(got)
  end)

  it("returns nil for whitespace only", function()
    local got = "unset"
    input.open({ title = "test" }, function(text)
      got = text
    end)
    type_text("    \n  ")
    press("<CR>")
    assert.is_nil(got)
  end)

  it("calls back exactly once", function()
    local calls = 0
    input.open({ title = "test" }, function()
      calls = calls + 1
    end)
    type_text("a thing")
    press("<CR>")
    input.close()
    assert.equals(1, calls)
  end)

  it("pre-fills a default", function()
    input.open({ title = "test", default = "start with this" }, function() end)
    local _, buf = input.handles()
    assert.same({ "start with this" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("shows the title on the border", function()
    input.open({ title = "Claude, index.ts" }, function() end)
    local win = input.handles()
    local config = vim.api.nvim_win_get_config(win)
    local title = type(config.title) == "table" and config.title[1][1] or tostring(config.title)
    assert.is_truthy(title:match("index%.ts"))
  end)

  it("replaces an open composer instead of stacking two", function()
    local first_cancelled = false
    input.open({ title = "first" }, function(text)
      first_cancelled = text == nil
    end)
    input.open({ title = "second" }, function() end)
    assert.is_true(first_cancelled)
    assert.is_true(input.is_open())
  end)

  it("uses a scratch buffer that never joins your buffer list", function()
    input.open({ title = "test" }, function() end)
    local _, buf = input.handles()
    assert.is_false(vim.bo[buf].buflisted)
    assert.equals("nofile", vim.bo[buf].buftype)
  end)

  it("fits a narrow screen", function()
    local original = vim.o.columns
    vim.o.columns = 50
    input.open({ title = "test" }, function() end)
    assert.is_true(window_width() <= 50)
    input.close()
    vim.o.columns = original
  end)

  it("close is safe with nothing open", function()
    assert.has_no.errors(function()
      input.close()
      input.close()
    end)
  end)
end)
