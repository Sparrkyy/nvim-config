-- The pacing queue: Claude edits faster than you can read, so jumps replay
-- one at a time.

local H = require("helpers")

describe("follow pacing", function()
  local follow, dir

  before_each(function()
    H.reset_buffers()
    follow = H.reload("claude.follow")
    dir = H.tmpdir()
    follow.pace_ms = 0 -- most tests set this themselves
    follow.clear_queue()
  end)

  after_each(function()
    follow.clear_queue()
  end)

  it("shows the jump at once when pacing is off", function()
    local path = H.write_file(dir, "a.lua", { "one", "two", "three" })
    follow.pace_ms = 0
    assert.equals("ok", follow.open(path, 2))
    assert.equals(path, H.current_file())
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("queues instead of jumping when pacing is on", function()
    local a = H.write_file(dir, "a.lua", { "one" })
    local b = H.write_file(dir, "b.lua", { "two" })
    follow.pace_ms = 5000

    assert.equals("queued", follow.open(a, 1))
    assert.equals("queued", follow.open(b, 1))

    -- The first drains at once. The second waits for the gap.
    H.settle(60)
    assert.equals(a, H.current_file())
  end)

  it("replays queued jumps in order", function()
    local a = H.write_file(dir, "a.lua", { "one" })
    local b = H.write_file(dir, "b.lua", { "two" })
    follow.pace_ms = 30

    follow.open(a, 1)
    follow.open(b, 1)

    vim.wait(500, function()
      return H.current_file() == b
    end)
    assert.equals(b, H.current_file())
  end)

  it("collapses a repeated jump to the same place", function()
    local a = H.write_file(dir, "a.lua", { "one" })
    follow.pace_ms = 5000

    follow.open(a, 3)
    follow.open(a, 3)
    follow.open(a, 3)

    -- Nothing yields between these calls, so nothing drains yet.
    assert.equals(1, follow.queue_length())
  end)

  it("caps the queue so you never fall far behind", function()
    follow.pace_ms = 5000
    for i = 1, 60 do
      local p = H.write_file(dir, "f" .. i .. ".lua", { "x" })
      follow.open(p, 1)
    end
    -- MAX_QUEUE is 40. The queue drops the oldest beyond that.
    assert.is_true(follow.queue_length() <= 40)
  end)

  it("refuses to jump while you type in a file", function()
    local a = H.write_file(dir, "a.lua", { "one" })
    follow.pace_ms = 0
    local original = vim.fn.mode
    vim.fn.mode = function()
      return "i"
    end
    local result = follow.open(a, 1)
    vim.fn.mode = original
    assert.equals("busy", result)
  end)

  it("reports disabled when follow mode is off", function()
    local a = H.write_file(dir, "a.lua", { "one" })
    follow.enabled = false
    assert.equals("disabled", follow.open(a, 1))
    follow.enabled = true
  end)

  it("rejects an empty path", function()
    assert.equals("nopath", follow.open("", 1))
    assert.equals("nopath", follow.open(nil, 1))
  end)

  it("reports an unreadable file", function()
    follow.pace_ms = 0
    assert.equals("unreadable", follow.open(dir .. "/missing.lua", 1))
  end)

  it("clamps the line to the file length", function()
    local path = H.write_file(dir, "a.lua", { "one", "two" })
    follow.pace_ms = 0
    follow.open(path, 999)
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("clear_queue drops the backlog", function()
    follow.pace_ms = 5000
    for i = 1, 5 do
      follow.open(H.write_file(dir, "q" .. i .. ".lua", { "x" }), 1)
    end
    follow.clear_queue()
    assert.equals(0, follow.queue_length())
  end)

  it("set_pace clamps a negative value to zero", function()
    H.capture_notify(function()
      follow.set_pace(-500)
    end)
    assert.equals(0, follow.pace_ms)
  end)

  it("set_pace accepts a numeric string", function()
    H.capture_notify(function()
      follow.set_pace("250")
    end)
    assert.equals(250, follow.pace_ms)
  end)

  it("next() warns when nothing is queued", function()
    follow.clear_queue()
    local seen = H.capture_notify(function()
      follow.next()
    end)
    assert.equals(1, #seen)
    assert.is_truthy(seen[1].msg:match("Nothing queued"))
  end)

  it("toggling follow off clears the queue", function()
    follow.pace_ms = 5000
    for i = 1, 4 do
      follow.open(H.write_file(dir, "t" .. i .. ".lua", { "x" }), 1)
    end
    H.capture_notify(function()
      follow.toggle()
    end)
    assert.is_false(follow.enabled)
    assert.equals(0, follow.queue_length())
    H.capture_notify(function()
      follow.toggle()
    end)
    assert.is_true(follow.enabled)
  end)
end)
