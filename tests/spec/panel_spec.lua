-- The plan and notes panels mirror what Claude is doing. Every task and
-- message here is a fake payload; nothing talks to Claude.

local H = require("helpers")

local function panel_lines(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == name then
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  return nil
end

local function panel_text(name)
  local lines = panel_lines(name)
  return lines and table.concat(lines, "\n") or ""
end

describe("panel plan", function()
  local panel

  before_each(function()
    panel = H.reload("claude.panel")
    panel.clear_tasks()
  end)

  it("says so when there are no tasks", function()
    assert.is_truthy(panel_text("Claude Plan"):match("No tasks yet"))
  end)

  it("records a task and renders it unchecked", function()
    panel.task("t1", "Write the tests", "pending")
    assert.is_truthy(panel_text("Claude Plan"):match("%[ %] Write the tests"))
  end)

  it("marks an in-progress task", function()
    panel.task("t1", "Write the tests", "in_progress")
    assert.is_truthy(panel_text("Claude Plan"):match("%[~%] Write the tests"))
  end)

  it("marks a completed task", function()
    panel.task("t1", "Write the tests", "completed")
    assert.is_truthy(panel_text("Claude Plan"):match("%[x%] Write the tests"))
  end)

  it("updates a task in place instead of adding a second one", function()
    panel.task("t1", "Write the tests", "pending")
    panel.task("t1", "Write the tests", "completed")

    local count = 0
    for _ in panel_text("Claude Plan"):gmatch("Write the tests") do
      count = count + 1
    end
    assert.equals(1, count)
    assert.equals("completed", panel.tasks["t1"].status)
  end)

  it("keeps the text when an update sends only a status", function()
    panel.task("t1", "Original text", "pending")
    panel.task("t1", nil, "completed")
    assert.equals("Original text", panel.tasks["t1"].text)
  end)

  it("keeps tasks in the order they arrived", function()
    panel.task("a", "first", "pending")
    panel.task("b", "second", "pending")
    panel.task("c", "third", "pending")

    local lines = panel_lines("Claude Plan")
    local order = {}
    for _, l in ipairs(lines) do
      local text = l:match("^%[.%] (.+)$")
      if text then
        table.insert(order, text)
      end
    end
    assert.same({ "first", "second", "third" }, order)
  end)

  it("counts the finished tasks in the header", function()
    panel.task("a", "one", "completed")
    panel.task("b", "two", "pending")
    panel.task("c", "three", "completed")
    assert.is_truthy(panel_text("Claude Plan"):match("2 of 3 done"))
  end)

  it("falls back to the text as the id when no id is sent", function()
    panel.task(nil, "No id task", "pending")
    assert.is_truthy(panel.tasks["No id task"])
  end)

  it("ignores a task with neither id nor text", function()
    assert.has_no.errors(function()
      panel.task(nil, nil, "pending")
    end)
  end)

  it("treats an unknown status as pending", function()
    panel.task("t1", "Odd status", "something_else")
    assert.is_truthy(panel_text("Claude Plan"):match("%[ %] Odd status"))
  end)

  it("plan_summary is empty with no tasks", function()
    assert.equals("", panel.plan_summary())
  end)

  it("plan_summary counts done over total", function()
    panel.task("a", "one", "completed")
    panel.task("b", "two", "pending")
    assert.equals("1/2", panel.plan_summary())
  end)

  it("clear_tasks empties the plan and resets the order", function()
    panel.task("a", "one", "completed")
    panel.clear_tasks()
    assert.same({}, panel.tasks)
    assert.is_truthy(panel_text("Claude Plan"):match("No tasks yet"))
  end)

  it("keeps the panel buffer read-only", function()
    panel.task("a", "one", "pending")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == "Claude Plan" then
        assert.is_false(vim.bo[b].modifiable)
        assert.equals("nofile", vim.bo[b].buftype)
      end
    end
  end)
end)

describe("panel notes", function()
  local panel

  before_each(function()
    panel = H.reload("claude.panel")
    panel.clear_notes()
  end)

  it("appends a message", function()
    panel.message("m1", "Claude says hello.", true)
    assert.is_truthy(panel_text("Claude Notes"):match("Claude says hello"))
  end)

  it("joins the chunks of one streamed message", function()
    panel.message("m1", "part one ", false)
    panel.message("m1", "part two", true)
    assert.is_truthy(panel_text("Claude Notes"):match("part one part two"))
  end)

  it("does not redraw until the final chunk arrives", function()
    panel.message("m1", "still streaming", false)
    assert.is_falsy(panel_text("Claude Notes"):match("still streaming"))
    panel.message("m1", "", true)
    -- An empty delta is ignored, so send real text to flush.
    panel.message("m1", " done", true)
    assert.is_truthy(panel_text("Claude Notes"):match("still streaming done"))
  end)

  it("separates two different messages with a rule", function()
    panel.message("m1", "first message", true)
    panel.message("m2", "second message", true)
    local text = panel_text("Claude Notes")
    assert.is_truthy(text:match("first message"))
    assert.is_truthy(text:match("%-%-%-"))
    assert.is_truthy(text:match("second message"))
  end)

  it("splits an embedded newline across lines", function()
    panel.message("m1", "line one\nline two", true)
    local lines = panel_lines("Claude Notes")
    local found_one, found_two = false, false
    for _, l in ipairs(lines) do
      if l == "line one" then found_one = true end
      if l == "line two" then found_two = true end
    end
    assert.is_true(found_one)
    assert.is_true(found_two)
  end)

  it("ignores an empty or non-string delta", function()
    panel.message("m1", "", true)
    panel.message("m1", nil, true)
    panel.message("m1", 42, true)
    assert.is_falsy(panel_text("Claude Notes"):match("42"))
  end)

  it("caps the buffer so a long session cannot grow without bound", function()
    for i = 1, 450 do
      panel.message("m1", "chunk " .. i .. "\n", true)
    end
    -- It keeps the newest 400 chunks, plus the two header lines.
    assert.is_true(#panel_lines("Claude Notes") <= 403)
    local text = panel_text("Claude Notes")
    assert.is_falsy(text:match("chunk 1\n"))
    assert.is_truthy(text:match("chunk 450"))
  end)

  it("clear_notes empties the buffer", function()
    panel.message("m1", "something", true)
    panel.clear_notes()
    assert.is_falsy(panel_text("Claude Notes"):match("something"))
  end)
end)

describe("panel windows", function()
  local panel

  before_each(function()
    H.reset_buffers()
    panel = H.reload("claude.panel")
  end)

  local function window_count_for(name)
    local n = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == name then
        n = n + 1
      end
    end
    return n
  end

  it("toggle_plan opens a window, then closes it", function()
    panel.toggle_plan()
    assert.equals(1, window_count_for("Claude Plan"))
    panel.toggle_plan()
    assert.equals(0, window_count_for("Claude Plan"))
  end)

  it("opening a panel does not move your cursor out of your window", function()
    local before = vim.api.nvim_get_current_win()
    panel.toggle_plan()
    assert.equals(before, vim.api.nvim_get_current_win())
    panel.toggle_plan()
  end)

  it("toggle_notes opens its own window", function()
    panel.toggle_notes()
    assert.equals(1, window_count_for("Claude Notes"))
    panel.toggle_notes()
    assert.equals(0, window_count_for("Claude Notes"))
  end)
end)
