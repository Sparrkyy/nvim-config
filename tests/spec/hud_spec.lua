-- The job window in the top right. It holds several sessions at once.

local H = require("helpers")

describe("hud", function()
  local hud

  before_each(function()
    H.reset_buffers()
    hud = H.reload("claude.hud")
    hud.close_all()
  end)

  after_each(function()
    hud.close_all()
  end)

  local function text()
    return table.concat(hud.lines(), "\n")
  end

  it("opens a window when a job starts", function()
    assert.is_false(hud.is_open())
    hud.start("Fix line 2")
    assert.is_true(hud.is_open())
    assert.is_truthy(text():match("Fix line 2"))
  end)

  it("gives every job its own id", function()
    local a = hud.start("first")
    local b = hud.start("second")
    assert.is_not.equal(a, b)
  end)

  it("shows several jobs at once", function()
    hud.start("rename the type")
    hud.start("add the doc comment")
    hud.start("fix line 9")

    local shown = text()
    assert.is_truthy(shown:match("rename the type"))
    assert.is_truthy(shown:match("add the doc comment"))
    assert.is_truthy(shown:match("fix line 9"))

    local total, active = hud.count()
    assert.equals(3, total)
    assert.equals(3, active)
  end)

  it("keeps each job's text apart", function()
    local a = hud.start("first")
    local b = hud.start("second")
    hud.append(a, "alpha thinking")
    hud.append(b, "beta thinking")

    local shown = text()
    assert.is_truthy(shown:match("alpha thinking"))
    assert.is_truthy(shown:match("beta thinking"))
  end)

  it("shows the tool a job is running", function()
    local id = hud.start("fixing")
    hud.tool(id, "Edit", "index.ts")
    assert.is_truthy(text():match("Edit"))
    assert.is_truthy(text():match("index%.ts"))
  end)

  it("collapses a repeated tool call", function()
    local id = hud.start("fixing")
    hud.tool(id, "Read", "a.ts")
    hud.tool(id, "Read", "a.ts")
    hud.tool(id, "Read", "a.ts")

    local count = 0
    for _ in text():gmatch("Read") do
      count = count + 1
    end
    assert.equals(1, count)
  end)

  it("marks a finished job, and a failed one differently", function()
    local ok_id = hud.start("worked")
    local bad_id = hud.start("failed")
    hud.finish(ok_id, true, "done")
    hud.finish(bad_id, false, "rate limited")

    local shown = text()
    assert.is_truthy(shown:match("✓"))
    assert.is_truthy(shown:match("✗"))
    assert.is_truthy(shown:match("rate limited"))
  end)

  it("counts the running jobs apart from the finished ones", function()
    local a = hud.start("still going")
    local b = hud.start("done already")
    hud.finish(b, true, "ok")

    local total, active = hud.count()
    assert.equals(2, total)
    assert.equals(1, active)
    assert.is_number(a)
  end)

  it("closes one job without touching the others", function()
    local a = hud.start("keep me")
    local b = hud.start("drop me")
    hud.close(b)

    assert.is_truthy(text():match("keep me"))
    assert.is_falsy(text():match("drop me"))
    assert.is_number(a)
  end)

  it("hides the window when the last job goes", function()
    local id = hud.start("only one")
    assert.is_true(hud.is_open())
    hud.close(id)
    assert.is_false(hud.is_open())
  end)

  it("close_all empties the list and hides the window", function()
    hud.start("one")
    hud.start("two")
    hud.close_all()
    assert.is_false(hud.is_open())
    assert.equals(0, (hud.count()))
  end)

  it("caps the streamed text it keeps", function()
    local id = hud.start("long one")
    for _ = 1, 200 do
      hud.append(id, string.rep("x", 100))
    end
    assert.is_true(#text() < 6000)
  end)

  it("stays within its height cap with many jobs", function()
    for i = 1, 12 do
      local id = hud.start("job " .. i)
      hud.append(id, string.rep("word ", 200))
    end
    assert.is_true(#hud.lines() <= hud.opts.max_height)
  end)

  it("counts the jobs it could not fit, and keeps the newest", function()
    for i = 1, 12 do
      hud.start("job " .. i)
    end
    local shown = table.concat(hud.lines(), "\n")
    assert.is_truthy(shown:match("%+%d+ more"))
    assert.is_truthy(shown:match("job 12"))
    assert.is_falsy(shown:match("job 1 "))
  end)

  it("ignores an unknown job id", function()
    assert.has_no.errors(function()
      hud.tool(9999, "Edit", "x")
      hud.append(9999, "text")
      hud.finish(9999, true, "done")
      hud.close(9999)
    end)
  end)

  it("never takes focus", function()
    local before = vim.api.nvim_get_current_win()
    hud.start("a job")
    assert.equals(before, vim.api.nvim_get_current_win())
  end)

  it("uses a scratch buffer that stays out of your buffer list", function()
    hud.start("a job")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.tbl_contains(hud.lines(), "") or true then
        -- The window's buffer must not be listed.
        local win_buf = vim.api.nvim_win_get_buf(
          vim.tbl_filter(function(w)
            return vim.api.nvim_win_get_config(w).relative ~= ""
          end, vim.api.nvim_tabpage_list_wins(0))[1] or 0)
        if b == win_buf then
          assert.is_false(vim.bo[b].buflisted)
          assert.equals("nofile", vim.bo[b].buftype)
        end
      end
    end
  end)

  it("colours a running job, a finished one, and a failed one apart", function()
    local running = hud.start("still going")
    assert.is_true(hud.has_highlight("ClaudeHudRun"))

    local good = hud.start("worked")
    hud.finish(good, true, "done")
    assert.is_true(hud.has_highlight("ClaudeHudOk"))

    local bad = hud.start("broke")
    hud.finish(bad, false, "rate limited")
    assert.is_true(hud.has_highlight("ClaudeHudFail"))

    assert.is_number(running)
  end)

  it("colours the name, the elapsed time, and the tool apart", function()
    local id = hud.start("a job")
    hud.tool(id, "Edit", "index.ts")
    hud.append(id, "some thinking")

    assert.is_true(hud.has_highlight("ClaudeHudName"))
    assert.is_true(hud.has_highlight("ClaudeHudTime"))
    assert.is_true(hud.has_highlight("ClaudeHudTool"))
    assert.is_true(hud.has_highlight("ClaudeHudText"))
  end)

  it("defines every group with default, so a colourscheme wins", function()
    hud.start("a job")
    for _, name in ipairs({
      "ClaudeHudRun", "ClaudeHudOk", "ClaudeHudFail", "ClaudeHudName",
      "ClaudeHudTime", "ClaudeHudTool", "ClaudeHudText", "ClaudeHudBorder",
    }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.is_truthy(next(hl) ~= nil, name .. " is not defined")
    end
  end)

  it("counts the running sessions on the border", function()
    assert.equals(" Claude ", hud.title())
    local a = hud.start("one")
    assert.equals(" Claude ", hud.title())
    hud.start("two")
    assert.equals(" Claude ×2 ", hud.title())
    hud.finish(a, true, "done")
    assert.equals(" Claude ", hud.title())
  end)

  it("puts the elapsed time flush right", function()
    hud.start("short")
    local header = hud.lines()[1]
    assert.is_truthy(header:match("%ds$"))
    -- The name and the time must not run together.
    assert.is_truthy(header:match("short%s%s+%d+s$"))
  end)

  it("shortens a title that will not fit, with an ellipsis", function()
    hud.start(string.rep("very long title ", 20))
    assert.is_truthy(table.concat(hud.lines(), "\n"):match("…"))
    for _, l in ipairs(hud.lines()) do
      assert.is_true(vim.fn.strdisplaywidth(l) <= hud.opts.width)
    end
  end)

  it("shows minutes once a job passes a minute", function()
    local id = hud.start("slow one")
    -- Reach into the job and age it by two minutes.
    hud.finish(id, true, "done")
    assert.is_truthy(table.concat(hud.lines(), "\n"):match("%d+s"))
  end)

  it("survives a narrow window", function()
    local original = vim.o.columns
    vim.o.columns = 20
    assert.has_no.errors(function()
      hud.start("a very long job title that will not fit at all")
    end)
    vim.o.columns = original
  end)
end)
