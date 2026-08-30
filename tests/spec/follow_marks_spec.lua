-- Change marks: the lines Claude wrote get a background colour, so new code
-- stands out from the code you wrote.

local H = require("helpers")

local function marks_on(bufnr)
  local ns = vim.api.nvim_get_namespaces()["claude_changes"]
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

local function highlighted_lines(bufnr)
  local lines = {}
  for _, m in ipairs(marks_on(bufnr)) do
    if m[4].line_hl_group == "ClaudeAdded" then
      table.insert(lines, m[2] + 1)
    end
  end
  table.sort(lines)
  return lines
end

describe("follow change marks", function()
  local follow, dir

  before_each(function()
    H.reset_buffers()
    follow = H.reload("claude.follow")
    follow.pace_ms = 0
    follow.highlight_changes = true
    dir = H.tmpdir()
  end)

  it("highlights every line of a written chunk", function()
    local path = H.write_file(dir, "a.lua", {
      "local a = 1",
      "local b = 2",
      "local c = 3",
      "local d = 4",
    })
    follow.mark(path, { "local b = 2\nlocal c = 3" })
    H.settle(80)

    local buf = vim.fn.bufnr(path)
    assert.same({ 2, 3 }, highlighted_lines(buf))
  end)

  it("labels only the first line of a chunk", function()
    local path = H.write_file(dir, "b.lua", { "one", "two", "three" })
    follow.mark(path, { "two\nthree" })
    H.settle(80)

    local labels = {}
    for _, m in ipairs(marks_on(vim.fn.bufnr(path))) do
      if m[4].virt_text then
        table.insert(labels, { line = m[2] + 1, text = m[4].virt_text[1][1] })
      end
    end
    assert.equals(1, #labels)
    assert.equals(2, labels[1].line)
    assert.is_truthy(labels[1].text:match("claude"))
  end)

  it("marks several chunks from one MultiEdit", function()
    local path = H.write_file(dir, "c.lua", {
      "first", "gap", "second", "gap", "third",
    })
    follow.mark(path, { "first", "third" })
    H.settle(80)
    assert.same({ 1, 5 }, highlighted_lines(vim.fn.bufnr(path)))
  end)

  it("anchors on the first line with content, not on blank padding", function()
    local path = H.write_file(dir, "d.lua", { "keep", "", "target", "tail" })
    -- The chunk starts with a blank line, as a real edit often does.
    follow.mark(path, { "\ntarget\ntail" })
    H.settle(80)
    assert.same({ 2, 3, 4 }, highlighted_lines(vim.fn.bufnr(path)))
  end)

  it("prefers an exact line match over a substring match", function()
    local path = H.write_file(dir, "e.lua", {
      "local value = 1 -- decoy substring",
      "local value = 1",
    })
    follow.mark(path, { "local value = 1" })
    H.settle(80)
    assert.same({ 2 }, highlighted_lines(vim.fn.bufnr(path)))
  end)

  it("does nothing when the chunk is not in the file", function()
    local path = H.write_file(dir, "f.lua", { "one", "two" })
    follow.mark(path, { "nothing like this" })
    H.settle(80)
    assert.same({}, highlighted_lines(vim.fn.bufnr(path)))
  end)

  it("ignores an empty or whitespace chunk", function()
    local path = H.write_file(dir, "g.lua", { "one", "two" })
    follow.mark(path, { "", "   ", "\n\n" })
    H.settle(80)
    assert.same({}, highlighted_lines(vim.fn.bufnr(path)))
  end)

  it("ignores a file that does not exist", function()
    assert.has_no.errors(function()
      follow.mark(dir .. "/missing.lua", { "anything" })
      H.settle(30)
    end)
  end)

  it("does not mark when highlighting is off", function()
    local path = H.write_file(dir, "h.lua", { "one", "two" })
    follow.highlight_changes = false
    follow.mark(path, { "two" })
    H.settle(80)
    -- It returns before it loads the buffer, so no buffer exists at all.
    assert.equals(-1, vim.fn.bufnr(path))
  end)

  it("clear_marks removes the marks from a buffer", function()
    local path = H.write_file(dir, "i.lua", { "one", "two" })
    follow.mark(path, { "two" })
    H.settle(80)
    local buf = vim.fn.bufnr(path)
    assert.same({ 2 }, highlighted_lines(buf))

    follow.clear_marks(buf)
    assert.same({}, highlighted_lines(buf))
  end)

  it("clear_marks with no argument clears every buffer", function()
    local a = H.write_file(dir, "j.lua", { "alpha" })
    local b = H.write_file(dir, "k.lua", { "beta" })
    follow.mark(a, { "alpha" })
    follow.mark(b, { "beta" })
    H.settle(80)

    follow.clear_marks()
    assert.same({}, highlighted_lines(vim.fn.bufnr(a)))
    assert.same({}, highlighted_lines(vim.fn.bufnr(b)))
  end)

  it("toggle_marks turns the feature off and clears what is on screen", function()
    local path = H.write_file(dir, "l.lua", { "one", "two" })
    follow.mark(path, { "two" })
    H.settle(80)

    local seen = H.capture_notify(function()
      follow.toggle_marks()
    end)
    assert.is_false(follow.highlight_changes)
    assert.same({}, highlighted_lines(vim.fn.bufnr(path)))
    assert.is_truthy(seen[1].msg:match("off"))

    H.capture_notify(function()
      follow.toggle_marks()
    end)
    assert.is_true(follow.highlight_changes)
  end)

  it("marks survive an edit above them, because they are extmarks", function()
    local path = H.write_file(dir, "m.lua", { "one", "two", "three" })
    follow.mark(path, { "three" })
    H.settle(80)

    local buf = vim.fn.bufnr(path)
    assert.same({ 3 }, highlighted_lines(buf))

    -- Insert a line at the top. The mark must follow its text down.
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new first line" })
    assert.same({ 4 }, highlighted_lines(buf))
  end)

  it("defines its highlight groups with default, so a colourscheme wins", function()
    follow.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "ClaudeAdded" })
    assert.is_truthy(hl.link == "DiffAdd" or next(hl) ~= nil)
  end)
end)
